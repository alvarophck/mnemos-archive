# Bloque B: desarrollo SQL asistido por IA

**Herramienta:** Claude (Anthropic), usado como asistente durante todo el proyecto: diseño del esquema, generación de scripts T-SQL, datos de prueba, documentación y revisión de errores.

**Método de verificación común:** nada se dio por bueno sin ejecutarlo. Cada script se ejecutó con `sqlcmd -b` (se detiene al primer error), se revisó la salida y se añadieron pruebas automáticas (`tests/tests.sql`, `tests/tests_ia.sql`).

Los casos de abajo son reales: en cuatro de ellos el código generado por la IA **falló al ejecutarse** y hubo que corregirlo.

---

## Caso 1. Script de comprobación del entorno

**Prompt (resumen):** "Prepara un script de PowerShell que compruebe que tengo Git, SQL Server 2025 con el tipo `vector`, y Ollama con los modelos bge-m3 y qwen3:4b. Solo debe leer, sin cambiar nada."

**Respuesta de la IA:** `scripts/check-env.ps1`, que conectaba a `localhost`, leía `SERVERPROPERTY('ProductMajorVersion')` y probaba `CAST('[1,2,3]' AS VECTOR(3))`.

**Qué se aceptó:** la estructura (secciones OK / WARN / FAIL con pistas) y las comprobaciones de Ollama.

**Qué se corrigió:** al ejecutarlo, dijo que SQL Server era la versión 16.0 (2022). El equipo tenía **dos instancias** y el script solo miraba la predeterminada. Se pidió a la IA que comprobara todas las instancias locales; la versión nueva recorre los servicios `MSSQL*`, prueba cada una e indica cuál usar.

**Cómo se verificó:** ejecutándolo antes y después de instalar SQL Server 2025. El resultado final: `.\SQL2025 -> SQL Server 17.0 (Enterprise Developer Edition)` y `Native vector type works`.

---

## Caso 2. Consulta con funciones de ventana

**Prompt (resumen):** "Escribe una consulta con CTE y funciones de ventana que muestre lo facturado a cada cliente: importe, acumulado, total del cliente, porcentaje del año y ranking de clientes."

**Respuesta de la IA:** un CTE y, en el SELECT, `DENSE_RANK() OVER (ORDER BY SUM(importe_total) OVER (PARTITION BY cliente) DESC)`.

**Qué se aceptó:** el acumulado con `ROWS UNBOUNDED PRECEDING` y el porcentaje sobre el total.

**Qué se corrigió:** SQL Server devolvió el **error 4109**: *Windowed functions cannot be used in the context of another windowed function*. Se calcularon los totales en un segundo CTE (`con_totales`) y el `DENSE_RANK` se aplica después sobre esa columna.

**Cómo se verificó:** el resultado cuadra a mano: Pedro García 1.210 + 2.100 + 1.510 = 4.820, que es el 38,36 % de 12.564. Además, la prueba 2 de `tests/tests.sql` comprueba que el total de Pedro es 4.820,00.

---

## Caso 3. Índices y opciones SET

**Prompt (resumen):** "Propón los índices que necesita el esquema, incluido uno filtrado para los documentos pendientes de procesar."

**Respuesta de la IA:** `08_indexes.sql` con índices compuestos con `INCLUDE` y `IX_documentos_pendientes ... WHERE estado = 'pendiente'`.

**Qué se aceptó:** todos los índices.

**Qué se corrigió:** al ejecutarlo con `sqlcmd` falló con el **error 1934**: los índices filtrados exigen `QUOTED_IDENTIFIER ON`, que SSMS activa por defecto pero `sqlcmd` no. Además, los procedimientos guardan esa opción al crearse, así que un procedimiento creado con ella desactivada fallaría después al modificar la tabla. Solución: `SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON;` al principio de todos los scripts y `sqlcmd -I` en el instalador.

**Cómo se verificó:** reconstruyendo la base de datos desde cero con `sqlcmd -b`, sin errores.

---

## Caso 4. Optimización de una consulta

**Prompt (resumen):** "La consulta de documentos de un tercero por rango de fechas hace un scan. Propón un índice y explica por qué mejora."

**Respuesta de la IA:** `CREATE INDEX IX_documentos_tercero_fecha ON archivo.documentos (tercero_id, fecha_documento) INCLUDE (numero, importe_total)`, con la explicación de igualdad primero, rango después e `INCLUDE` para cubrir la consulta.

**Qué se aceptó:** el orden de las columnas y la idea de índice cubriente.

**Qué se corrigió:** tras crear el índice, la consulta **seguía haciendo Clustered Index Scan** con las mismas 4.511 lecturas. El plan mostró por qué: la política de Row-Level Security añade a la consulta un filtro sobre `departamento`, que no estaba en el índice. Para usar el índice habría tenido que hacer un *Key Lookup* por cada fila, y el optimizador prefirió recorrer la tabla. Se añadió `departamento` al `INCLUDE`.

**Cómo se verificó:** `SET STATISTICS IO ON` y el plan real: de 4.512 a 18 lecturas lógicas, y de *Clustered Index Scan + Sort* a *Index Seek*. Detalle en [optimizacion.md](optimizacion.md).

---

## Caso 5. Pruebas automáticas

**Prompt (resumen):** "Escribe pruebas en T-SQL que comprueben duplicados, restricciones, triggers, borrado en cascada y seguridad, sin dejar datos en la base de datos."

**Respuesta de la IA:** todas las pruebas dentro de una transacción con `ROLLBACK` al final.

**Qué se aceptó:** las diez comprobaciones.

**Qué se corrigió:** varias pruebas provocan errores a propósito (un documento vacío, un tipo inválido). Con `XACT_ABORT ON` dentro de los procedimientos, ese error deja la transacción "condenada" y la siguiente prueba falla con el **error 3930**. Se quitó la transacción global y se añadió una limpieza explícita al final.

**Cómo se verificó:** `Todas las pruebas pasaron (10/10)` y comprobando después que la base de datos quedaba igual (mismos documentos, total original y auditoría vacía).

---

## Caso 6. Datos de prueba

**Prompt (resumen):** "Genera datos de prueba realistas para un estudio de diseño en Madrid: clientes, proveedores, facturas emitidas y recibidas, contratos y presupuestos, con el texto completo de cada documento. Todo inventado."

**Respuesta de la IA:** `03_insert_data.sql`, con 11 terceros y 22 documentos.

**Qué se aceptó:** el contenido. Se pidió que algunos documentos quedaran sin clasificar y con el texto "sucio" (sin tildes, abreviaturas) para probar la extracción con IA y el fuzzy matching.

**Cómo se verificó:** la consulta 5b de `10_advanced_queries.sql` comprueba con expresiones regulares que, en cada factura emitida, base + IVA = total. Todas "cuadran".

---

## Lo que la IA no hizo sola

- Las decisiones de producto (local, sin nube, cifras calculadas y no estimadas, borrado en cascada por el RGPD) se fijaron antes de pedir código.
- Cada error se detectó **ejecutando**, no leyendo. Por eso cada script se ejecuta con `-b` y deja su salida en `evidencias/`.

# Bloque B: desarrollo SQL asistido por IA

**Herramienta:** Claude (Anthropic), usado como asistente durante todo el proyecto: diseño del esquema, generación de scripts T-SQL, datos de prueba, documentación y revisión de errores.

**Método de verificación común:** nada se dio por bueno sin ejecutarlo. Cada script se ejecutó con `sqlcmd -b` (se detiene al primer error), se revisó la salida y se añadieron pruebas automáticas (`tests/tests.sql`, `tests/tests_ia.sql`).

Los casos de abajo son reales: en ocho de ellos el código generado por la IA **falló al ejecutarse** y hubo que corregirlo.

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

## Caso 7. Expresiones regulares en la versión RTM de SQL Server 2025

**Prompt (resumen):** "Escribe consultas que usen las funciones REGEXP_* de SQL Server 2025 para leer los importes del texto de las facturas."

**Respuesta de la IA:** `REGEXP_MATCHES(d.texto, ...)` y `REGEXP_SUBSTR(d.texto, ...)` directamente sobre la columna `texto` (`nvarchar(max)`). La documentación dice que admiten `nvarchar(max)` hasta 2 MB.

**Qué se aceptó:** los patrones y la comprobación base + IVA = total.

**Qué se corrigió:** en el equipo de entrega, con SQL Server 2025 **RTM (17.0.1000.7)**, falló con el **error 19304**: *la función "REGEXP_MATCHES" no admite entradas NVARCHAR(max)*. El código se había probado en una versión con actualizaciones acumulativas, donde sí funciona. Se convirtió el texto a `nvarchar(4000)` antes de aplicar la expresión regular, y en las funciones que reciben textos largos (contar marcas de página, limpiar la respuesta del modelo) se sustituyó la regex por `REPLACE` y `CHARINDEX`.

**Cómo se verificó:** volviendo a ejecutar `instalar.ps1` en el equipo RTM y las pruebas en el equipo actualizado.

---

## Caso 8. Elección del modelo de lenguaje

**Prompt (resumen):** "Elige un modelo local con licencia permisiva para extraer campos y responder preguntas en español."

**Respuesta de la IA:** `qwen3:4b` (Apache 2.0), con `"think": false` en la petición a Ollama para que respondiera directamente.

**Qué se aceptó:** la familia de modelos (Qwen3, Apache 2.0, 4B parámetros: cabe en un portátil).

**Qué se corrigió:** al ejecutar el RAG, cada respuesta empezaba con "Okay, let's see..." y tardaba entre 40 y 200 segundos; la de más de 230 segundos superó el límite de `sp_invoke_external_rest_endpoint` (**error 31629**). Añadir `/no_think` tampoco sirvió. Consultando el registro de Ollama se vio por qué: la etiqueta `qwen3:4b` apunta hoy a **`qwen3:4b-thinking-2507`**, una variante que razona siempre. Se cambió a **`qwen3:4b-instruct`** (sin razonamiento) en `archivo.config_ia`, y la limpieza de la respuesta se quedó solo con lo que va después de `</think>` por si alguien configura un modelo que razona.

**Cómo se verificó:** volviendo a ejecutar el RAG (hoy `ai/09_rag.sql`) y comprobando en su evidencia que las respuestas son directas, en español y con su cita.

---

## Caso 9. Comprobar las cifras de la respuesta

**Prompt (resumen):** "Haz que se pueda preguntar en lenguaje natural cuánto se ha pagado a un tercero y en qué fechas. El modelo no puede hacer las cuentas: que las haga SQL y que se compruebe que la respuesta no cambia ninguna cifra."

**Respuesta de la IA:** el flujo entender → calcular → redactar (`ai/08_consultas_de_datos.sql`) y una función `fn_cifras_sin_respaldo` que sacaba cada número de la respuesta con `REGEXP_MATCHES` y lo convertía con la función escalar ya existente `fn_importe_texto` (que usa `REGEXP_REPLACE`).

**Qué se aceptó:** el reparto de trabajo (el LLM solo produce un JSON con campos fijos y no escribe SQL) y la idea de comprobar cada número.

**Qué se corrigió:** al probar la función, **el servicio de SQL Server se detuvo** ("Hit Fatal Error: Server is terminating", con volcado de memoria). Aislando la consulta se vio que bastaba con llamar a `fn_importe_texto` sobre la salida de `REGEXP_MATCHES`. La conversión se reescribió dentro de la propia función con `REPLACE` y `TRY_CAST`, sin funciones escalares ni regex anidadas. También falló la primera versión del resumen de datos con el error *Cannot perform an aggregate function on an expression containing an aggregate or a subquery*: el detalle de cada grupo se calcula ahora en un paso previo.

**Cómo se verificó:** las pruebas 7 a 10 de `tests/tests_ia.sql`. La 9 comprueba que "150,00" se marca como inventada y que "145,20 EUR el 31/1/2026 [1]" pasa. Antes de tener Ollama se probó el flujo completo con un modelo simulado que devolvía a propósito una cifra falsa: la respuesta se descartó y se devolvieron los datos calculados.

---

## Caso 10. Fechas vacías que se convertían en 1900

**Prompt (resumen):** "Haz una app en .NET 9 con Blazor para archivar PDFs, preguntar y ver los documentos, encima de los procedimientos que ya existen."

**Respuesta de la IA:** la app (`app/`) y un recorrido automático con Playwright que archivaba PDFs, hacía preguntas y sacaba capturas de cada pantalla.

**Qué se aceptó:** la app y el recorrido como forma de revisarla.

**Qué se corrigió:** en las capturas aparecían documentos con fecha **1/1/1900** y una pregunta sin periodo que no encontraba nada. La causa estaba en el T-SQL generado antes: cuando el modelo devuelve `""` en un campo de fecha (el esquema le pide cadena vacía si no aparece), `TRY_CONVERT(date, '', 23)` no devuelve `NULL` sino **1900-01-01**. Afectaba a la extracción (`ai/07`) y al periodo de las preguntas de datos (`ai/08`). Se cambió a `TRY_CONVERT(date, NULLIF(TRIM(fecha), ''), 23)`. En el mismo recorrido se vio que los contratos salían en dos grupos (emitidos y recibidos) con la misma etiqueta: ahora un contrato es un contrato, lo firme quien lo firme.

**Cómo se verificó:** reinstalando la base de datos y repitiendo el recorrido: las fechas que no aparecen se muestran como "—" y la pregunta sin periodo cuenta todo el archivo.

---

## Caso 11. "El doble" con cifras reales y respuesta falsa

**Prueba (del usuario, en la app):** "¿Cuánto es el doble de lo que le he pagado a Tecnologías Arganzuela este año?"

**Respuesta del sistema:** `72,60 EUR × 2 = 145,20 EUR`, marcada como "Cifras comprobadas". Es falsa: lo pagado es 145,20 € y el doble serían 290,40 €. El modelo multiplicó una sola factura y presentó el resultado como el doble del total.

**Por qué pasó la comprobación:** `fn_cifras_sin_respaldo` solo mira que cada número exista en los datos calculados, y 72,60, 2 y 145,20 existen. Era el límite que ya estaba documentado: el número existe, pero no está en la frase correcta.

**Qué se corrigió:** el modelo nunca opera con las cifras. Primera versión: si la pregunta pedía una cuenta, se respondía "Ese cálculo no lo hago". Después, a petición del usuario, se hizo bien: el intérprete devuelve la operación como datos (`operacion: multiplicar`, `valor: 2`, `sobre: pagado`) y la hace T-SQL (`fn_magnitud` + `usp_calcular_operacion`), con una lista cerrada (multiplicar, dividir, porcentaje, sumar, restar, media, comparar periodos). El modelo solo redacta, y se comprueba que la respuesta no trae cuentas propias (`fn_tiene_operacion`) y que contiene el resultado de SQL; si no, se usa una respuesta fija calculada por SQL. Lo que queda fuera de la lista se sigue respondiendo con "Ese cálculo no lo hago".

**Cómo se verificó:** pruebas 9b (la frase exacta del modelo se detecta como cuenta) y 9c (el doble de lo pagado a Arganzuela en 2026 da 290,40 EUR; el 21 % de lo facturado a Pedro García, 1.012,20 EUR; dividir entre cero se rechaza) de `tests/tests_ia.sql`.

---

## Caso 12. "Prorrateado a 14 meses" respondido como un total

**Prueba (del usuario, en la app):** "cuánto le he pagado a tecnlogias arganzuela, prorrateado a 14 meses".

**Respuesta del sistema:** "145,20 EUR", marcada como "Cifras comprobadas". La cifra es real, pero no es lo que se preguntaba: el reparto en 14 meses son 10,37 EUR. qwen3:4b-instruct marcó `operacion: ninguna` porque "prorratear" no estaba entre los ejemplos del intérprete, y el respaldo por palabras tampoco la incluía. La pregunta se respondió en silencio como si no pidiera ninguna cuenta.

**Qué se corrigió:**
- `fn_operacion_por_reglas`: reglas sin IA (expresiones regulares) para las cuentas habituales: porcentaje, prorratear o repartir entre N, entre N meses, la mitad, el doble o el triple, multiplicado por N, N veces y la media. Si encajan, mandan sobre el modelo.
- Si la pregunta trae un número que no es un año ni parte del nombre del tercero y no se sabe qué hacer con él, ya no se ignora: se responde "Ese cálculo no lo hago" y las cifras del archivo.
- El intérprete tiene un ejemplo de prorrateo.

**Cómo se verificó:** prueba 9d de `tests/tests_ia.sql` con la frase exacta del usuario, incluida la falta de ortografía.

**Lección:** con un modelo pequeño, lo que importa no es que acierte siempre, sino que cuando falle no se responda otra cosa como si fuera correcta. Cada fallo visto se convierte en una regla o una prueba.

---

## Lo que la IA no hizo sola

- Las decisiones de producto (local, sin nube, cifras calculadas y no estimadas, borrado en cascada por el RGPD) se fijaron antes de pedir código.
- Cada error se detectó **ejecutando**, no leyendo. Por eso cada script se ejecuta con `-b` y deja su salida en `evidencias/`.

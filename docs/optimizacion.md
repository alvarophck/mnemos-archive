# Bloque D: optimización de consultas

Script: [`database/11_optimization.sql`](../database/11_optimization.sql)

## La consulta

Documentos de un tercero en un periodo, ordenados por fecha. Es la base del resumen de cliente o proveedor y de cualquier filtro "facturas de X en 2025".

```sql
SELECT documento_id, numero, fecha_documento, importe_total
FROM archivo.documentos
WHERE tercero_id = 7
  AND fecha_documento >= '2025-01-01' AND fecha_documento < '2026-01-01'
ORDER BY fecha_documento;
```

Para que la diferencia se note, el script carga **200.000 documentos históricos sintéticos** (sin texto, así no entran en la parte de IA) repartidos entre los 11 terceros y diez años. Al terminar los borra.

## Estado inicial

Solo existen la clave primaria (índice agrupado por `documento_id`) y los índices de `08_indexes.sql`, que no empiezan por `tercero_id`.

| Medida | Valor |
|---|---|
| Operador principal | **Clustered Index Scan** sobre `PK_documentos` |
| Además | **Sort** para el `ORDER BY` |
| Lecturas lógicas | **4.512** |
| Tiempo | ~28 ms |

El motor recorre todas las páginas de la tabla y comprueba cada fila contra el `WHERE`, aunque solo devuelve unas 1.800.

## Optimización

```sql
CREATE INDEX IX_documentos_tercero_fecha
    ON archivo.documentos (tercero_id, fecha_documento)
    INCLUDE (numero, importe_total, departamento);
```

- **`tercero_id` primero**: es una igualdad. El índice salta directamente a las filas del tercero 7.
- **`fecha_documento` después**: es un rango y, dentro de cada tercero, las filas ya están ordenadas por fecha. El `ORDER BY` sale gratis y desaparece el *Sort*.
- **`INCLUDE (numero, importe_total)`**: son las columnas del `SELECT`. Al estar en el índice, no hace falta volver a la tabla (*Key Lookup*). El índice "cubre" la consulta.
- **`INCLUDE (departamento)`**: ver el apartado siguiente.

## El detalle que no se veía

La primera versión del índice no incluía `departamento`, y la consulta **seguía haciendo el mismo scan**. El plan lo explicaba: el predicado del `WHERE` incluía algo que no estaba en la consulta.

```
Clustered Index Scan(... WHERE: tercero_id = 7 AND fecha_documento >= ... AND
   (is_member('db_owner') = 1 OR ... departamento = 'contabilidad' ...))
```

Es el filtro de **Row-Level Security** (`09_security.sql`), que SQL Server añade a todas las consultas sobre `documentos`. Sin `departamento` en el índice, cada fila encontrada obligaría a un *Key Lookup* para leerlo. Con ~1.800 filas, al optimizador le salía más barato recorrer la tabla entera.

Con `departamento` en el `INCLUDE`:

## Resultado

| Medida | Antes | Después |
|---|---|---|
| Operador | Clustered Index Scan + Sort | **Index Seek** |
| Lecturas lógicas | 4.512 | **18** |
| Tiempo | ~28 ms | **~2 ms** |

```
ANTES                            DESPUÉS
Consulta                         Consulta
   ↓                                ↓
Clustered Index Scan             Index Seek (IX_documentos_tercero_fecha)
   ↓                                ↓
Sort                             (sin Sort: ya viene ordenado)
   ↓                                ↓
4.512 lecturas                   18 lecturas
```

Las cifras son de la ejecución en el entorno de pruebas. Al ejecutar el script en tu equipo se guardan en `evidencias/database_11_optimization.txt`.

**Capturas para el PDF y la presentación:** en SSMS, activar "Incluir plan de ejecución real" (Ctrl+M), ejecutar el script y capturar el plan de la primera consulta (scan) y de la segunda (seek). Para conservar los datos sintéticos y enseñar el plan en directo, comentar el bloque 5 del script.

## Por qué mejora y cuánto cuesta

- **Mejora** porque pasa de leer toda la tabla a leer solo las páginas del índice que contienen al tercero 7 en 2025, ya ordenadas.
- **Cuesta**: el índice ocupa espacio y cada `INSERT` o `UPDATE` de esas columnas también lo actualiza. Para un archivo de documentos, que se escribe poco y se consulta mucho, compensa.
- **Lección**: las políticas de seguridad (RLS) forman parte del plan de ejecución. Un índice que parece perfecto para la consulta escrita puede no servir para la consulta que realmente se ejecuta.

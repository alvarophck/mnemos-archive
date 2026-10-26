/* =====================================================================
   Mnemos Archive · 11_optimization.sql
   Bloque D: estudio de rendimiento de una consulta real del proyecto.

   Consulta: "documentos de un tercero en un rango de fechas, con su importe"
   (la usa el resumen de cliente y cualquier filtro por proveedor y periodo).

   Pasos:
     1. Cargar 200.000 documentos históricos sintéticos (sin texto, así
        no se trocean ni se vectorizan) para que la diferencia se note.
     2. ANTES: ejecutar con STATISTICS IO/TIME y el plan real
        (en SSMS: Ctrl+M "Incluir plan de ejecución real").
     3. Crear un índice compuesto (tercero_id, fecha_documento) con INCLUDE.
     4. DESPUÉS: misma consulta y comparar.
     5. (Opcional) Limpiar los datos sintéticos.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO
SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------
   1. Carga de histórico sintético (solo la primera vez)
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM archivo.documentos WHERE nombre_archivo LIKE N'historico-%')
BEGIN
    DROP INDEX IF EXISTS IX_documentos_tercero_fecha ON archivo.documentos;

    ;WITH n AS
    (
        SELECT TOP (200000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
        FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
    )
    INSERT INTO archivo.documentos
        (nombre_archivo, hash_sha256, tipo, direccion, departamento, tercero_id,
         numero, fecha_documento, importe_total, texto, estado)
    SELECT CONCAT(N'historico-', n.i, N'.pdf'),
           HASHBYTES('SHA2_256', CONCAT(N'historico-', n.i)),
           'factura',
           CASE WHEN n.i % 3 = 0 THEN 'emitido' ELSE 'recibido' END,
           'contabilidad',
           1 + (n.i % 11),                                        -- reparte entre los 11 terceros
           CONCAT(N'H-', n.i),
           DATEADD(DAY, -(n.i % 3650), CAST('2026-10-01' AS date)), -- últimos 10 años
           CAST(50 + (n.i * 37 % 5000) AS decimal(12,2)),
           NULL,                                                   -- sin texto: no entra en la IA
           'procesado'
    FROM n;

    PRINT 'Cargados 200.000 documentos históricos.';
END
GO

UPDATE STATISTICS archivo.documentos WITH FULLSCAN;
GO

/* ---------------------------------------------------------------------
   2. ANTES (sin índice específico)
   --------------------------------------------------------------------- */
DROP INDEX IF EXISTS IX_documentos_tercero_fecha ON archivo.documentos;
DBCC FREEPROCCACHE WITH NO_INFOMSGS;   -- solo en un entorno de pruebas
GO

SET STATISTICS IO, TIME ON;

SELECT documento_id, numero, fecha_documento, importe_total
FROM archivo.documentos
WHERE tercero_id = 7
  AND fecha_documento >= '2025-01-01' AND fecha_documento < '2026-01-01'
ORDER BY fecha_documento;

SET STATISTICS IO, TIME OFF;
GO
/* Resultado esperado ANTES:
   - Plan: Clustered Index Scan sobre PK_documentos (recorre toda la tabla)
     + Sort para el ORDER BY.
   - STATISTICS IO: varios miles de lecturas lógicas (toda la tabla).
   Anota tus cifras reales en docs/optimizacion.md. */

/* ---------------------------------------------------------------------
   3. Optimización: índice compuesto
      - tercero_id primero: es una igualdad (busca un solo tercero)
      - fecha_documento después: es un rango y además da el orden
        del ORDER BY, así que desaparece el Sort
      - INCLUDE de las columnas del SELECT: el índice "cubre" la consulta
        y no hace falta volver a la tabla (sin Key Lookup)
      - INCLUDE de departamento: la política de Row-Level Security
        (09_security.sql) añade a TODAS las consultas un filtro por
        departamento. Sin esa columna en el índice, el optimizador
        tendría que hacer un Key Lookup por fila y prefiere seguir
        recorriendo la tabla entera. Ver docs/optimizacion.md.
   --------------------------------------------------------------------- */
CREATE INDEX IX_documentos_tercero_fecha
    ON archivo.documentos (tercero_id, fecha_documento)
    INCLUDE (numero, importe_total, departamento);
GO

/* ---------------------------------------------------------------------
   4. DESPUÉS
   --------------------------------------------------------------------- */
DBCC FREEPROCCACHE WITH NO_INFOMSGS;
GO
SET STATISTICS IO, TIME ON;

SELECT documento_id, numero, fecha_documento, importe_total
FROM archivo.documentos
WHERE tercero_id = 7
  AND fecha_documento >= '2025-01-01' AND fecha_documento < '2026-01-01'
ORDER BY fecha_documento;

SET STATISTICS IO, TIME OFF;
GO
/* Resultado esperado DESPUÉS:
   - Plan: Index Seek sobre IX_documentos_tercero_fecha, sin Sort.
   - STATISTICS IO: unas pocas decenas de lecturas lógicas.
   Ver la explicación completa en docs/optimizacion.md. */

/* Mismas cifras sin depender de los mensajes: lecturas de la última ejecución */
SELECT TOP (2)
       SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1, 80) AS consulta,
       qs.last_logical_reads,
       qs.last_elapsed_time / 1000.0 AS last_ms
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE st.text LIKE N'%tercero_id = 7%' AND st.text NOT LIKE N'%dm_exec_query_stats%'
ORDER BY qs.last_execution_time DESC;
GO

/* ---------------------------------------------------------------------
   5. Quitar el histórico sintético para que no altere el resto de
      consultas (totales por cliente, RAG...). El índice se queda.
      Para repetir la demostración basta con volver a ejecutar el script.
      Si quieres conservar los datos para enseñar el plan en directo,
      comenta este bloque.
   --------------------------------------------------------------------- */
DISABLE TRIGGER archivo.trg_documentos_borrado ON archivo.documentos;   -- no auditar 200.000 borrados de prueba
DELETE FROM archivo.documentos WHERE nombre_archivo LIKE N'historico-%';
ENABLE TRIGGER archivo.trg_documentos_borrado ON archivo.documentos;
PRINT 'Histórico sintético eliminado. El índice IX_documentos_tercero_fecha se mantiene.';
GO

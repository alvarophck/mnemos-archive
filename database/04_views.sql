/* =====================================================================
   Mnemos Archive · 04_views.sql
   Vistas de consulta habitual.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

/* Ficha resumida de cada documento con su tercero y el estado de la IA */
CREATE OR ALTER VIEW archivo.v_documentos
AS
SELECT d.documento_id,
       d.nombre_archivo,
       d.tipo,
       d.direccion,
       d.departamento,
       d.numero,
       d.fecha_documento,
       d.importe_total,
       d.moneda,
       t.nombre  AS tercero,
       t.nif     AS nif_tercero,
       d.estado,
       (SELECT COUNT(*) FROM archivo.campos_extraidos AS c WHERE c.documento_id = d.documento_id) AS campos,
       (SELECT COUNT(*) FROM archivo.fragmentos AS f
         WHERE f.documento_id = d.documento_id AND f.embedding IS NOT NULL)                     AS fragmentos_con_vector
FROM archivo.documentos AS d
LEFT JOIN archivo.terceros AS t ON t.tercero_id = d.tercero_id;
GO

/* Facturación por mes: emitido (ingresos) y recibido (gastos).
   Las sumas las hace la base de datos, nunca el modelo de lenguaje. */
CREATE OR ALTER VIEW archivo.v_facturacion_mensual
AS
SELECT DATEFROMPARTS(YEAR(d.fecha_documento), MONTH(d.fecha_documento), 1) AS mes,
       SUM(CASE WHEN d.direccion = 'emitido'  THEN d.importe_total ELSE 0 END) AS ingresos,
       SUM(CASE WHEN d.direccion = 'recibido' THEN d.importe_total ELSE 0 END) AS gastos,
       SUM(CASE WHEN d.direccion = 'emitido'  THEN d.importe_total ELSE -d.importe_total END) AS resultado,
       COUNT(*) AS facturas
FROM archivo.documentos AS d
WHERE d.tipo = 'factura'
  AND d.fecha_documento IS NOT NULL
  AND d.importe_total IS NOT NULL
GROUP BY DATEFROMPARTS(YEAR(d.fecha_documento), MONTH(d.fecha_documento), 1);
GO

/* Trabajo pendiente para la IA */
CREATE OR ALTER VIEW archivo.v_pendientes_ia
AS
SELECT d.documento_id,
       d.nombre_archivo,
       CASE
           WHEN d.tipo = 'sin_clasificar' THEN 'clasificar y extraer campos'
           WHEN NOT EXISTS (SELECT 1 FROM archivo.fragmentos AS f WHERE f.documento_id = d.documento_id)
                THEN 'trocear y generar embeddings'
           ELSE 'generar embeddings'
       END AS tarea
FROM archivo.documentos AS d
WHERE d.texto IS NOT NULL
  AND (   d.tipo = 'sin_clasificar'
       OR NOT EXISTS (SELECT 1 FROM archivo.fragmentos AS f WHERE f.documento_id = d.documento_id)
       OR EXISTS     (SELECT 1 FROM archivo.fragmentos AS f WHERE f.documento_id = d.documento_id AND f.embedding IS NULL));
GO

/* Contratos con sus fechas y condiciones clave en una sola fila (PIVOT) */
CREATE OR ALTER VIEW archivo.v_contratos
AS
SELECT p.documento_id, p.numero, p.tercero, p.fecha_documento,
       p.fecha_inicio, p.fecha_entrega, p.preaviso, p.duracion, p.penalizacion
FROM (
    SELECT d.documento_id, d.numero, t.nombre AS tercero, d.fecha_documento,
           c.nombre_campo,
           COALESCE(c.valor_texto, CONVERT(nvarchar(400), c.valor_fecha, 23), CONVERT(nvarchar(400), c.valor_numero)) AS valor
    FROM archivo.documentos AS d
    JOIN archivo.terceros AS t ON t.tercero_id = d.tercero_id
    LEFT JOIN archivo.campos_extraidos AS c ON c.documento_id = d.documento_id
    WHERE d.tipo = 'contrato'
) AS s
PIVOT (MAX(valor) FOR nombre_campo IN ([fecha_inicio], [fecha_entrega], [preaviso], [duracion], [penalizacion])) AS p;
GO

PRINT 'Vistas creadas: v_documentos, v_facturacion_mensual, v_pendientes_ia, v_contratos.';
GO

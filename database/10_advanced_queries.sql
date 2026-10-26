/* =====================================================================
   Mnemos Archive · 10_advanced_queries.sql
   Consultas T-SQL avanzadas: CTE, funciones de ventana, JSON,
   expresiones regulares, fuzzy matching y subconsultas correlacionadas.
   Solo lectura: se puede ejecutar tantas veces como se quiera.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

/* 1. CTE + funciones de ventana
   Ingresos por cliente: total, peso sobre el total del año, ranking
   y acumulado mes a mes. */
WITH facturas_emitidas AS
(
    SELECT t.nombre AS cliente, d.fecha_documento, d.importe_total
    FROM archivo.documentos AS d
    JOIN archivo.terceros   AS t ON t.tercero_id = d.tercero_id
    WHERE d.tipo = 'factura' AND d.direccion = 'emitido' AND YEAR(d.fecha_documento) = 2026
),
con_totales AS
(
    SELECT cliente, fecha_documento, importe_total,
           SUM(importe_total) OVER (PARTITION BY cliente ORDER BY fecha_documento
                                    ROWS UNBOUNDED PRECEDING) AS acumulado_cliente,
           SUM(importe_total) OVER (PARTITION BY cliente)     AS total_cliente,
           SUM(importe_total) OVER ()                         AS total_anio
    FROM facturas_emitidas
)
SELECT cliente,
       fecha_documento,
       importe_total,
       acumulado_cliente,
       total_cliente,
       CAST(100.0 * total_cliente / total_anio AS decimal(5,2)) AS pct_del_anio,
       DENSE_RANK() OVER (ORDER BY total_cliente DESC)          AS ranking_cliente
FROM con_totales
ORDER BY ranking_cliente, fecha_documento;
GO

/* 2. LAG: variación del gasto recurrente (hosting, gestoría, luz) frente a la factura anterior */
SELECT t.nombre AS proveedor,
       d.fecha_documento,
       d.importe_total,
       LAG(d.importe_total) OVER (PARTITION BY d.tercero_id ORDER BY d.fecha_documento) AS anterior,
       d.importe_total - LAG(d.importe_total) OVER (PARTITION BY d.tercero_id ORDER BY d.fecha_documento) AS variacion
FROM archivo.documentos AS d
JOIN archivo.terceros   AS t ON t.tercero_id = d.tercero_id
WHERE d.tipo = 'factura' AND d.direccion = 'recibido'
ORDER BY proveedor, d.fecha_documento;
GO

/* 3. Subconsulta correlacionada: facturas cuyo importe supera la media de ese mismo tercero */
SELECT d.numero, t.nombre, d.importe_total,
       (SELECT AVG(d2.importe_total)
          FROM archivo.documentos AS d2
         WHERE d2.tercero_id = d.tercero_id AND d2.tipo = 'factura') AS media_tercero
FROM archivo.documentos AS d
JOIN archivo.terceros   AS t ON t.tercero_id = d.tercero_id
WHERE d.tipo = 'factura'
  AND d.importe_total > (SELECT AVG(d2.importe_total)
                           FROM archivo.documentos AS d2
                          WHERE d2.tercero_id = d.tercero_id AND d2.tipo = 'factura');
GO

/* 4. JSON: ficha completa de un documento con sus campos, como la consumiría una API */
SELECT d.documento_id, d.nombre_archivo, d.tipo, d.numero,
       JSON_QUERY((SELECT t.nombre, t.ciudad
                   FROM archivo.terceros AS t WHERE t.tercero_id = d.tercero_id
                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))                       AS tercero,
       JSON_QUERY((SELECT c.nombre_campo AS campo,
                          COALESCE(c.valor_texto, CONVERT(nvarchar(40), c.valor_numero), CONVERT(nvarchar(40), c.valor_fecha, 23)) AS valor,
                          c.confianza, c.extraido_por
                   FROM archivo.campos_extraidos AS c WHERE c.documento_id = d.documento_id
                   FOR JSON PATH))                                              AS campos
FROM archivo.documentos AS d
WHERE d.numero = N'2026-014'
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
GO

/* 4b. JSON a filas con OPENJSON: así se lee la respuesta de la IA en ai/07 */
DECLARE @respuesta_ia nvarchar(max) = N'{"tipo":"factura","emisor":"Transportes Henares S.L.","nif":"B19876543","fecha":"2026-09-12","total":102.85,"confianza":0.92}';
SELECT *
FROM OPENJSON(@respuesta_ia)
WITH (tipo varchar(20), emisor nvarchar(200), nif varchar(12), fecha date, total decimal(12,2), confianza decimal(4,3));
GO

/* 5. Expresiones regulares (SQL Server 2025)
   Nota: en la versión RTM (17.0.1000) las funciones REGEXP_* no aceptan
   nvarchar(max); por eso el texto se convierte a nvarchar(4000).
   5a. Leer del texto todos los importes con formato español y su etiqueta */
SELECT d.nombre_archivo,
       m.match_value                                         AS coincidencia,
       archivo.fn_importe_es(REGEXP_SUBSTR(m.match_value, '[0-9]{1,3}(\.[0-9]{3})*,[0-9]{2}')) AS importe
FROM archivo.documentos AS d
CROSS APPLY REGEXP_MATCHES(CAST(d.texto AS nvarchar(4000)), '(?i)(base imponible|iva 21 %|total)[^0-9]*[0-9]{1,3}(\.[0-9]{3})*,[0-9]{2}') AS m
WHERE d.numero = N'2026-048';
GO

/* 5b. Comprobar que el total leído coincide con base + IVA (honestidad: la cifra se calcula) */
WITH importes AS
(
    SELECT d.documento_id, d.numero, d.importe_total,
           archivo.fn_importe_es(REGEXP_SUBSTR(CAST(d.texto AS nvarchar(4000)), '(?i)base imponible: ([0-9.,]+)', 1, 1, '', 1)) AS base,
           archivo.fn_importe_es(REGEXP_SUBSTR(CAST(d.texto AS nvarchar(4000)), '(?i)iva 21 %: ([0-9.,]+)', 1, 1, '', 1))         AS iva
    FROM archivo.documentos AS d
    WHERE d.tipo = 'factura' AND d.direccion = 'emitido'
)
SELECT numero, base, iva, base + iva AS suma, importe_total,
       CASE WHEN base + iva = importe_total THEN 'cuadra' ELSE 'revisar' END AS comprobacion
FROM importes;
GO

/* 5c. NIF con formato no válido entre los terceros (función con REGEXP_LIKE) */
SELECT nombre, nif, archivo.fn_nif_valido(nif) AS formato_valido
FROM archivo.terceros
ORDER BY formato_valido, nombre;
GO

/* 6. Fuzzy string matching (preview): un nombre mal escrito encuentra al tercero */
SELECT t.nombre,
       JARO_WINKLER_SIMILARITY(UPPER(t.nombre), UPPER(N'Energia Clara SA'))  AS similitud_jaro_winkler,
       EDIT_DISTANCE(UPPER(t.nombre), UPPER(N'Energia Clara SA'))            AS distancia_edicion
FROM archivo.terceros AS t
ORDER BY similitud_jaro_winkler DESC;

SELECT * FROM archivo.fn_buscar_tercero(N'Construcciones Valecas', NULL);
GO

/* 7. Vencimientos: contratos cuya fecha clave está en los próximos 90 días o ya pasó */
SELECT c.numero, c.tercero, c.fecha_entrega, c.preaviso,
       DATEDIFF(DAY, CAST(GETDATE() AS date), TRY_CAST(c.fecha_entrega AS date)) AS dias_hasta_entrega
FROM archivo.v_contratos AS c
WHERE c.fecha_entrega IS NOT NULL;
GO

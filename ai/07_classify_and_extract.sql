/* =====================================================================
   Mnemos Archive · ai/07_classify_and_extract.sql
   La IA lee un documento sin clasificar y decide:
     - qué es (factura, contrato, presupuesto, recibo, otro)
     - si lo emitimos nosotros o lo recibimos
     - quién es la otra parte, número, fecha e importes
   Todo dentro de SQL Server: el modelo responde un JSON con forma fija
   (JSON Schema) y T-SQL lo valida antes de guardar nada.

   Reglas de honestidad:
     - Si un dato no aparece, el modelo devuelve null; no se rellena.
     - Si base + IVA no coincide con el total, se baja la confianza
       y se guarda un aviso.
     - Un campo corregido a mano nunca se sobrescribe.
     - El tercero se enlaza por NIF o por nombre aproximado
       (fn_buscar_tercero, fuzzy matching); si no hay coincidencia
       clara, se deja sin enlazar.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

/* Importe escrito por el modelo: "1210.50", "1.210,50", "1210,50 €" o "" */
CREATE OR ALTER FUNCTION archivo.fn_importe_texto (@texto nvarchar(40))
RETURNS decimal(12,2)
AS
BEGIN
    DECLARE @limpio nvarchar(40) = REGEXP_REPLACE(ISNULL(@texto, N''), '[^0-9.,]', '');
    IF @limpio = N'' RETURN NULL;
    RETURN CASE WHEN @limpio LIKE N'%,%' THEN archivo.fn_importe_es(@limpio)
                ELSE TRY_CAST(@limpio AS decimal(12,2)) END;
END;
GO

CREATE OR ALTER PROCEDURE archivo.usp_clasificar_y_extraer
    @documento_id int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @texto nvarchar(max) = (SELECT texto FROM archivo.documentos WHERE documento_id = @documento_id);
    IF @texto IS NULL
        THROW 50030, 'El documento no existe o no tiene texto que leer.', 1;

    DECLARE @modelo varchar(60) = (SELECT valor FROM archivo.config_ia WHERE clave = 'modelo_llm');

    DECLARE @sistema nvarchar(max) = N'
Eres el lector de documentos de Mnemos Archive para la empresa Estudio Ámbar S.L. (NIF B12345674).
Lee el documento y extrae sus datos. Reglas:
- "tipo": factura, contrato, presupuesto, recibo u otro.
- "direccion": "emitido" si lo emite Estudio Ámbar; "recibido" si lo emite otra empresa.
- "contraparte" y "nif_contraparte": la OTRA parte, nunca Estudio Ámbar.
- "fecha" en formato AAAA-MM-DD. Importes con punto decimal y sin separador de miles (1210.50).
- Si un dato no aparece en el texto, devuelve una cadena vacía "". No inventes nada.
- "confianza": de 0 a 1, cuánto te fías de tu lectura.';

    -- Todo como texto ("" si no aparece): la gramática que Ollama genera a partir
    -- del esquema es más fiable así; T-SQL convierte y valida después.
    DECLARE @esquema nvarchar(max) = N'{
      "type": "object",
      "properties": {
        "tipo":            {"type": "string", "enum": ["factura","contrato","presupuesto","recibo","otro"]},
        "direccion":       {"type": "string", "enum": ["emitido","recibido","desconocido"]},
        "contraparte":     {"type": "string"},
        "nif_contraparte": {"type": "string"},
        "numero":          {"type": "string"},
        "fecha":           {"type": "string"},
        "base_imponible":  {"type": "string"},
        "iva":             {"type": "string"},
        "total":           {"type": "string"},
        "confianza":       {"type": "number"}
      },
      "required": ["tipo","direccion","contraparte","nif_contraparte","numero","fecha","base_imponible","iva","total","confianza"]
    }';

    DECLARE @usuario nvarchar(max) = CONCAT(N'Documento:', NCHAR(10), N'"""', NCHAR(10), @texto, NCHAR(10), N'"""');
    DECLARE @json nvarchar(max), @ms int;

    EXEC archivo.usp_llm_chat @sistema = @sistema, @usuario = @usuario, @formato_json = @esquema,
                              @respuesta = @json OUTPUT, @duracion_ms = @ms OUTPUT;

    IF ISJSON(@json) <> 1
    BEGIN
        UPDATE archivo.documentos SET estado = 'error' WHERE documento_id = @documento_id;
        DECLARE @e nvarchar(2048) = CONCAT(N'El modelo no devolvió un JSON válido: ', LEFT(@json, 300));
        THROW 50031, @e, 1;
    END

    /* Leer y validar la respuesta */
    DECLARE @tipo varchar(20), @direccion varchar(10), @contraparte nvarchar(200), @nif varchar(12),
            @numero nvarchar(50), @fecha date, @base decimal(12,2), @iva decimal(12,2), @total decimal(12,2),
            @confianza decimal(4,3), @aviso nvarchar(400) = NULL;

    SELECT @tipo        = CASE WHEN tipo IN ('factura','contrato','presupuesto','recibo','otro') THEN tipo ELSE 'otro' END,
           @direccion   = CASE WHEN direccion IN ('emitido','recibido') THEN direccion END,
           @contraparte = NULLIF(LTRIM(RTRIM(contraparte)), N''),
           @nif         = UPPER(REPLACE(REPLACE(NULLIF(LTRIM(RTRIM(nif_contraparte)), N''), '-', ''), ' ', '')),
           @numero      = NULLIF(LTRIM(RTRIM(numero)), N''),
           @fecha       = TRY_CONVERT(date, NULLIF(TRIM(fecha), ''), 23),   -- '' no es 1900-01-01: es que no aparece
           @base        = archivo.fn_importe_texto(base_imponible),
           @iva         = archivo.fn_importe_texto(iva),
           @total       = archivo.fn_importe_texto(total),
           @confianza   = CASE WHEN confianza BETWEEN 0 AND 1 THEN confianza ELSE 0.5 END
    FROM OPENJSON(@json) WITH (
        tipo varchar(20), direccion varchar(10), contraparte nvarchar(200), nif_contraparte varchar(20),
        numero nvarchar(50), fecha varchar(20), base_imponible nvarchar(40), iva nvarchar(40), total nvarchar(40),
        confianza float);

    -- La cifra se comprueba, no se cree: base + IVA debe dar el total
    IF @base IS NOT NULL AND @iva IS NOT NULL AND @total IS NOT NULL AND ABS(@base + @iva - @total) > 0.01
    BEGIN
        SET @confianza = @confianza * 0.5;
        SET @aviso = CONCAT(N'Base + IVA = ', @base + @iva, N' no coincide con el total leído (', @total, N'). Revisar.');
    END

    -- El NIF leído tiene que tener formato válido; si no, no se usa para enlazar
    IF @nif IS NOT NULL AND archivo.fn_nif_valido(@nif) = 0
        SET @nif = NULL;

    DECLARE @tercero_id int, @similitud int;
    SELECT @tercero_id = tercero_id, @similitud = similitud
    FROM archivo.fn_buscar_tercero(@contraparte, @nif);

    /* Guardar */
    BEGIN TRANSACTION;

    UPDATE archivo.documentos
    SET tipo            = @tipo,
        direccion       = COALESCE(direccion, @direccion),
        departamento    = CASE WHEN @tipo = 'contrato' THEN 'legal' ELSE departamento END,
        tercero_id      = COALESCE(tercero_id, @tercero_id),
        numero          = COALESCE(numero, @numero),
        fecha_documento = COALESCE(fecha_documento, @fecha),
        importe_total   = COALESCE(importe_total, @total),
        estado          = 'procesado',
        conservar_hasta = COALESCE(conservar_hasta, DATEADD(YEAR, 6, @fecha))
    WHERE documento_id = @documento_id;

    MERGE archivo.campos_extraidos AS destino
    USING (
        SELECT nombre_campo, valor_texto, valor_numero, valor_fecha
        FROM (VALUES
            ('contraparte',     CAST(@contraparte AS nvarchar(400)), CAST(NULL AS decimal(12,2)), CAST(NULL AS date)),
            ('nif_contraparte', @nif,     NULL,   NULL),
            ('numero',          @numero,  NULL,   NULL),
            ('fecha',           NULL,     NULL,   @fecha),
            ('base_imponible',  NULL,     @base,  NULL),
            ('iva',             NULL,     @iva,   NULL),
            ('total',           NULL,     @total, NULL),
            ('aviso',           @aviso,   NULL,   NULL)
        ) AS v (nombre_campo, valor_texto, valor_numero, valor_fecha)
        WHERE v.valor_texto IS NOT NULL OR v.valor_numero IS NOT NULL OR v.valor_fecha IS NOT NULL
    ) AS origen
    ON destino.documento_id = @documento_id AND destino.nombre_campo = origen.nombre_campo
    WHEN MATCHED AND destino.corregido = 0 THEN
        UPDATE SET valor_texto = origen.valor_texto, valor_numero = origen.valor_numero, valor_fecha = origen.valor_fecha,
                   confianza = @confianza, extraido_por = @modelo, fecha_extraccion = sysutcdatetime()
    WHEN NOT MATCHED THEN
        INSERT (documento_id, nombre_campo, valor_texto, valor_numero, valor_fecha, confianza, extraido_por, pagina)
        VALUES (@documento_id, origen.nombre_campo, origen.valor_texto, origen.valor_numero, origen.valor_fecha, @confianza, @modelo, 1);

    COMMIT;

    /* Resultado legible */
    SELECT d.documento_id, d.nombre_archivo, d.tipo, d.direccion, d.departamento,
           t.nombre AS tercero_enlazado, @similitud AS similitud_tercero,
           d.numero, d.fecha_documento, d.importe_total,
           @confianza AS confianza, @aviso AS aviso, @ms AS milisegundos_modelo,
           @json AS respuesta_modelo
    FROM archivo.documentos AS d
    LEFT JOIN archivo.terceros AS t ON t.tercero_id = d.tercero_id
    WHERE d.documento_id = @documento_id;
END;
GO

/* Procesa todo lo pendiente: clasificar, extraer y vectorizar */
CREATE OR ALTER PROCEDURE archivo.usp_procesar_pendientes
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id int;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT documento_id FROM archivo.documentos
        WHERE tipo = 'sin_clasificar' AND texto IS NOT NULL
        ORDER BY documento_id;

    OPEN c;
    FETCH NEXT FROM c INTO @id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC archivo.usp_clasificar_y_extraer @documento_id = @id;
        END TRY
        BEGIN CATCH
            PRINT CONCAT('Documento ', @id, ': ', ERROR_MESSAGE());
        END CATCH
        FETCH NEXT FROM c INTO @id;
    END
    CLOSE c; DEALLOCATE c;

    -- Los documentos recién clasificados cambian de cabecera (tipo, tercero):
    -- se vuelven a vectorizar
    DELETE f FROM archivo.fragmentos AS f
    JOIN archivo.campos_extraidos AS c ON c.documento_id = f.documento_id
    WHERE c.extraido_por <> 'manual' AND f.fecha_embedding < c.fecha_extraccion;

    EXEC archivo.usp_generar_embeddings;
END;
GO

/* Ejecutar: los 4 escaneos sin clasificar */
SELECT documento_id, nombre_archivo, tipo, estado FROM archivo.documentos WHERE tipo = 'sin_clasificar';
EXEC archivo.usp_procesar_pendientes;
GO

SELECT * FROM archivo.v_documentos WHERE nombre_archivo LIKE N'escaneo-%';
GO

/* =====================================================================
   Mnemos Archive · 06_procedures.sql
   Procedimientos almacenados de la parte relacional.
   (Los de IA están en la carpeta ai/.)
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

/* Archiva un documento nuevo a partir de su texto.
   Si el mismo contenido ya estaba archivado, no lo duplica: devuelve el id existente. */
CREATE OR ALTER PROCEDURE archivo.usp_archivar_documento
    @nombre_archivo nvarchar(260),
    @texto          nvarchar(max),
    @departamento   varchar(20) = 'contabilidad',
    @paginas        smallint    = 1,
    @documento_id   int OUTPUT,
    @ya_existia     bit OUTPUT,
    @archivo_local  nvarchar(260) = NULL   -- nombre del PDF original guardado por la app
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@texto)), N'') IS NULL
        THROW 50010, 'El documento no tiene texto. Si es un escaneo, hay que pasarle OCR antes de archivarlo.', 1;

    DECLARE @hash binary(32) = HASHBYTES('SHA2_256', @texto);

    SELECT @documento_id = documento_id FROM archivo.documentos WHERE hash_sha256 = @hash;
    IF @documento_id IS NOT NULL
    BEGIN
        -- Ya estaba: si antes solo teníamos el texto, se le enlaza ahora el PDF original
        IF @archivo_local IS NOT NULL
            UPDATE archivo.documentos SET archivo_local = @archivo_local
            WHERE documento_id = @documento_id AND archivo_local IS NULL;
        SET @ya_existia = 1;
        RETURN;
    END

    INSERT INTO archivo.documentos (nombre_archivo, hash_sha256, departamento, paginas, texto, archivo_local)
    VALUES (@nombre_archivo, @hash, @departamento, @paginas, @texto, @archivo_local);

    SET @documento_id = SCOPE_IDENTITY();
    SET @ya_existia = 0;
END;
GO

/* Corrige el valor de un campo extraído. Lo marca como corregido
   para que la IA no lo vuelva a sobrescribir (el trigger lo audita). */
CREATE OR ALTER PROCEDURE archivo.usp_corregir_campo
    @documento_id int,
    @nombre_campo varchar(40),
    @valor_texto  nvarchar(400) = NULL,
    @valor_numero decimal(12,2) = NULL,
    @valor_fecha  date          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @valor_texto IS NULL AND @valor_numero IS NULL AND @valor_fecha IS NULL
        THROW 50011, 'Indica al menos un valor para el campo.', 1;

    BEGIN TRANSACTION;

    UPDATE archivo.campos_extraidos
    SET valor_texto = @valor_texto,
        valor_numero = @valor_numero,
        valor_fecha = @valor_fecha,
        confianza = 1,
        corregido = 1,
        extraido_por = 'manual'
    WHERE documento_id = @documento_id AND nombre_campo = @nombre_campo;

    IF @@ROWCOUNT = 0
        INSERT INTO archivo.campos_extraidos (documento_id, nombre_campo, valor_texto, valor_numero, valor_fecha, confianza, corregido)
        VALUES (@documento_id, @nombre_campo, @valor_texto, @valor_numero, @valor_fecha, 1, 1);

    -- Los campos principales también viven en la fila del documento
    UPDATE archivo.documentos
    SET importe_total   = CASE WHEN @nombre_campo = 'total'  THEN @valor_numero ELSE importe_total END,
        fecha_documento = CASE WHEN @nombre_campo = 'fecha'  THEN @valor_fecha  ELSE fecha_documento END,
        numero          = CASE WHEN @nombre_campo = 'numero' THEN @valor_texto  ELSE numero END
    WHERE documento_id = @documento_id;

    COMMIT;
END;
GO

/* Borra un documento y todo lo derivado de él (campos, fragmentos, vectores).
   Derecho de supresión del RGPD en una sola llamada. */
CREATE OR ALTER PROCEDURE archivo.usp_borrar_documento
    @documento_id int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM archivo.documentos WHERE documento_id = @documento_id)
        THROW 50012, 'No existe ese documento o no tienes permiso para verlo.', 1;

    DELETE FROM archivo.documentos WHERE documento_id = @documento_id;   -- ON DELETE CASCADE
END;
GO

/* Resumen de la relación con un tercero: lo facturado, lo pagado y lo pendiente.
   Busca al tercero por nombre aproximado o por NIF. */
CREATE OR ALTER PROCEDURE archivo.usp_resumen_tercero
    @nombre nvarchar(200) = NULL,
    @nif    varchar(12)   = NULL,
    @anio   int           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @tercero_id int, @nombre_real nvarchar(200), @similitud int;

    SELECT @tercero_id = tercero_id, @nombre_real = nombre, @similitud = similitud
    FROM archivo.fn_buscar_tercero(@nombre, @nif);

    IF @tercero_id IS NULL
    BEGIN
        SELECT CONCAT(N'No encuentro ningún tercero parecido a "', ISNULL(@nombre, @nif), N'".') AS mensaje;
        RETURN;
    END

    SELECT @nombre_real AS tercero, @similitud AS similitud_nombre,
           ISNULL(SUM(CASE WHEN tipo = 'factura' AND direccion = 'emitido'  THEN importe_total END), 0) AS facturado,
           ISNULL(SUM(CASE WHEN tipo = 'factura' AND direccion = 'recibido' THEN importe_total END), 0) AS gastado,
           COUNT(*) AS documentos
    FROM archivo.fn_documentos_de_tercero(@tercero_id)
    WHERE @anio IS NULL OR YEAR(fecha_documento) = @anio;

    SELECT tipo, direccion, numero, fecha_documento, importe_total, nombre_archivo
    FROM archivo.fn_documentos_de_tercero(@tercero_id)
    WHERE @anio IS NULL OR YEAR(fecha_documento) = @anio
    ORDER BY fecha_documento;
END;
GO

PRINT 'Procedimientos creados: usp_archivar_documento, usp_corregir_campo, usp_borrar_documento, usp_resumen_tercero.';
GO

/* =====================================================================
   Mnemos Archive · 05_functions.sql
   Funciones escalares y de tabla.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

/* ¿Tiene formato de NIF/CIF español? (expresión regular de SQL Server 2025)
   Persona física: 8 dígitos + letra. Sociedad: letra + 7 dígitos + dígito o letra.
   Solo comprueba el formato, no la letra de control. */
CREATE OR ALTER FUNCTION archivo.fn_nif_valido (@nif varchar(12))
RETURNS bit
AS
BEGIN
    RETURN CASE
        WHEN @nif IS NULL THEN 0
        WHEN REGEXP_LIKE(@nif, '^[0-9]{8}[A-Z]$')                 THEN 1
        WHEN REGEXP_LIKE(@nif, '^[ABCDEFGHJNPQRSUVW][0-9]{7}[0-9A-J]$') THEN 1
        ELSE 0
    END;
END;
GO

/* Convierte un importe escrito en formato español ("1.210,00") a decimal */
CREATE OR ALTER FUNCTION archivo.fn_importe_es (@texto nvarchar(40))
RETURNS decimal(12,2)
AS
BEGIN
    RETURN TRY_CAST(REPLACE(REPLACE(REPLACE(@texto, N' ', N''), N'.', N''), N',', N'.') AS decimal(12,2));
END;
GO

/* Busca el tercero más parecido a un nombre mal escrito o abreviado
   ("Energia Clara SA" -> "Energía Clara S.A."), con fuzzy matching.
   Lo usa la extracción con IA para enlazar el documento con su tercero. */
CREATE OR ALTER FUNCTION archivo.fn_buscar_tercero (@nombre nvarchar(200), @nif varchar(12))
RETURNS TABLE
AS
RETURN
    SELECT TOP (1) t.tercero_id, t.nombre, t.nif, s.similitud
    FROM archivo.terceros AS t
    CROSS APPLY (SELECT CASE
                     WHEN @nif IS NOT NULL AND t.nif = UPPER(REPLACE(REPLACE(@nif, '-', ''), ' ', '')) THEN 100
                     ELSE JARO_WINKLER_SIMILARITY(UPPER(t.nombre), UPPER(ISNULL(@nombre, N'')))
                 END AS similitud) AS s
    WHERE s.similitud >= 85
    ORDER BY s.similitud DESC;
GO

/* Documentos de un tercero, con su total (función de tabla en línea) */
CREATE OR ALTER FUNCTION archivo.fn_documentos_de_tercero (@tercero_id int)
RETURNS TABLE
AS
RETURN
    SELECT d.documento_id, d.tipo, d.direccion, d.numero, d.fecha_documento, d.importe_total, d.nombre_archivo
    FROM archivo.documentos AS d
    WHERE d.tercero_id = @tercero_id;
GO

/* Página en la que empieza un fragmento: cuenta las marcas "[página "
   que hay en el texto antes de su posición. (Sin regex: en la RTM de
   SQL Server 2025 las funciones REGEXP_* no aceptan nvarchar(max).) */
CREATE OR ALTER FUNCTION archivo.fn_pagina_en (@texto nvarchar(max), @posicion int)
RETURNS smallint
AS
BEGIN
    DECLARE @antes nvarchar(max) = LEFT(@texto, @posicion);
    DECLARE @marca nvarchar(10) = N'[página';
    RETURN 1 + (DATALENGTH(@antes) - DATALENGTH(REPLACE(@antes, @marca, N''))) / DATALENGTH(@marca);
END;
GO

PRINT 'Funciones creadas: fn_nif_valido, fn_importe_es, fn_buscar_tercero, fn_documentos_de_tercero, fn_pagina_en.';
GO

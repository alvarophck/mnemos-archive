/* =====================================================================
   Mnemos Archive · ai/03_generate_embeddings.sql
   Bloque E: trocea el texto de cada documento y guarda un embedding
   por fragmento.

   Qué se vectoriza: una cabecera con el tipo, el tercero y el archivo,
   más el texto del fragmento. Así un fragmento suelto ("Cláusula 4.
   Preaviso...") sigue sabiendo de qué contrato y de qué empresa es.

   Modelo: bge-m3 · Dimensión: 1024 · Métrica de búsqueda: coseno
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

CREATE OR ALTER PROCEDURE archivo.usp_generar_embeddings
    @documento_id int = NULL     -- NULL: todos los pendientes
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @tamano int = (SELECT CAST(valor AS int) FROM archivo.config_ia WHERE clave = 'tamano_fragmento');
    DECLARE @solape int = (SELECT CAST(valor AS int) FROM archivo.config_ia WHERE clave = 'solape_fragmento');
    DECLARE @modelo varchar(60) = (SELECT valor FROM archivo.config_ia WHERE clave = 'modelo_embeddings');

    /* 1. Trocear los documentos que aún no tienen fragmentos */
    INSERT INTO archivo.fragmentos (documento_id, orden, pagina, texto)
    SELECT d.documento_id,
           c.chunk_order,
           archivo.fn_pagina_en(d.texto, c.chunk_offset),
           c.chunk
    FROM archivo.documentos AS d
    CROSS APPLY AI_GENERATE_CHUNKS (SOURCE = d.texto, CHUNK_TYPE = FIXED,
                                    CHUNK_SIZE = @tamano, OVERLAP = @solape) AS c
    WHERE d.texto IS NOT NULL
      AND (@documento_id IS NULL OR d.documento_id = @documento_id)
      AND NOT EXISTS (SELECT 1 FROM archivo.fragmentos AS f WHERE f.documento_id = d.documento_id);

    PRINT CONCAT('Fragmentos nuevos: ', @@ROWCOUNT);

    /* 2. Generar los embeddings que faltan, documento a documento:
          si Ollama falla con uno, los demás siguen y el error se ve. */
    DECLARE @id int, @hechos int = 0, @errores int = 0;

    DECLARE pendientes CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT f.documento_id
        FROM archivo.fragmentos AS f
        WHERE f.embedding IS NULL
          AND (@documento_id IS NULL OR f.documento_id = @documento_id);

    OPEN pendientes;
    FETCH NEXT FROM pendientes INTO @id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            UPDATE f
            SET embedding = AI_GENERATE_EMBEDDINGS(
                                CONCAT(d.tipo, N' · ', ISNULL(t.nombre, N'sin tercero'), N' · ', d.nombre_archivo,
                                       N' · página ', f.pagina, NCHAR(10), f.texto)
                                USE MODEL modelo_embeddings),
                modelo = @modelo,
                fecha_embedding = sysutcdatetime()
            FROM archivo.fragmentos AS f
            JOIN archivo.documentos AS d ON d.documento_id = f.documento_id
            LEFT JOIN archivo.terceros AS t ON t.tercero_id = d.tercero_id
            WHERE f.documento_id = @id AND f.embedding IS NULL;

            SET @hechos += 1;
        END TRY
        BEGIN CATCH
            SET @errores += 1;
            PRINT CONCAT('No se pudo vectorizar el documento ', @id, ': ', ERROR_MESSAGE());
        END CATCH
        FETCH NEXT FROM pendientes INTO @id;
    END
    CLOSE pendientes; DEALLOCATE pendientes;

    PRINT CONCAT('Documentos vectorizados: ', @hechos, ' · con error: ', @errores);
END;
GO

/* Ejecutar para todos los documentos */
EXEC archivo.usp_generar_embeddings;
GO

/* Comprobación: qué se ha guardado */
SELECT TOP (8)
       f.fragmento_id, d.nombre_archivo, f.orden, f.pagina,
       LEFT(f.texto, 70) + N'...'                AS fragmento,
       VECTORPROPERTY(f.embedding, 'Dimensions') AS dimensiones,
       f.modelo
FROM archivo.fragmentos AS f
JOIN archivo.documentos AS d ON d.documento_id = f.documento_id
ORDER BY f.fragmento_id;

SELECT COUNT(*) AS fragmentos,
       SUM(CASE WHEN embedding IS NOT NULL THEN 1 ELSE 0 END) AS con_vector
FROM archivo.fragmentos;
GO

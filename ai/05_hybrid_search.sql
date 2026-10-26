/* =====================================================================
   Mnemos Archive · ai/05_hybrid_search.sql
   Bloque F (ampliación): búsqueda híbrida = Full-Text + vectores.

   - Full-Text encuentra palabras exactas: números de factura, NIF,
     nombres propios ("TA-26-0219", "B19876543").
   - Los vectores encuentran el significado aunque cambien las palabras.
   - Se combinan con Reciprocal Rank Fusion (RRF):
         puntuación = 1/(60 + posición_texto) + 1/(60 + posición_vector)
     RRF usa solo posiciones, no puntuaciones, así que no hace falta
     normalizar dos escalas que no tienen nada que ver.

   Requiere la característica "Búsqueda de texto completo" instalada.
   Si no lo está, el procedimiento usa solo la búsqueda vectorial y lo dice.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

BEGIN TRY
    IF FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') = 1
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = 'catalogo_mnemos')
            CREATE FULLTEXT CATALOG catalogo_mnemos;

        IF NOT EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID('archivo.fragmentos'))
            CREATE FULLTEXT INDEX ON archivo.fragmentos (texto LANGUAGE 3082)   -- 3082 = español
                KEY INDEX PK_fragmentos ON catalogo_mnemos
                WITH CHANGE_TRACKING AUTO;

        PRINT 'Índice de texto completo listo (se rellena en segundo plano unos segundos).';
    END
    ELSE
        PRINT 'Búsqueda de texto completo no instalada: la búsqueda híbrida usará solo vectores.';
END TRY
BEGIN CATCH
    PRINT CONCAT('No se pudo crear el índice de texto completo (', ERROR_MESSAGE(), '). La búsqueda híbrida usará solo vectores.');
END CATCH
GO

CREATE OR ALTER PROCEDURE archivo.usp_buscar_hibrida
    @consulta nvarchar(1000),
    @top      int = 5
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @q vector(1024) = AI_GENERATE_EMBEDDINGS(@consulta USE MODEL modelo_embeddings);
    DECLARE @k int = 60;   -- constante habitual de RRF

    CREATE TABLE #rank_vector (fragmento_id int PRIMARY KEY, posicion int);
    CREATE TABLE #rank_texto  (fragmento_id int PRIMARY KEY, posicion int);

    INSERT INTO #rank_vector (fragmento_id, posicion)
    SELECT TOP (20) f.fragmento_id,
           ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('cosine', f.embedding, @q))
    FROM archivo.fragmentos AS f
    WHERE f.embedding IS NOT NULL
    ORDER BY VECTOR_DISTANCE('cosine', f.embedding, @q);

    IF FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') = 1
       AND EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID('archivo.fragmentos'))
    BEGIN
        -- SQL dinámico: así el procedimiento compila aunque no haya índice de texto completo
        INSERT INTO #rank_texto (fragmento_id, posicion)
        EXEC sp_executesql N'
            SELECT TOP (20) ft.[KEY], ROW_NUMBER() OVER (ORDER BY ft.RANK DESC)
            FROM FREETEXTTABLE(archivo.fragmentos, texto, @c, LANGUAGE 3082) AS ft
            ORDER BY ft.RANK DESC;',
            N'@c nvarchar(1000)', @c = @consulta;
    END
    ELSE
        PRINT 'Sin texto completo: resultado solo por similitud de vectores.';

    WITH fusion AS
    (
        SELECT COALESCE(v.fragmento_id, t.fragmento_id) AS fragmento_id,
               v.posicion AS posicion_vector,
               t.posicion AS posicion_texto,
               ISNULL(1.0 / (@k + v.posicion), 0) + ISNULL(1.0 / (@k + t.posicion), 0) AS rrf
        FROM #rank_vector AS v
        FULL JOIN #rank_texto AS t ON t.fragmento_id = v.fragmento_id
    ),
    por_documento AS
    (
        SELECT fu.*, f.documento_id, f.pagina, f.texto,
               ROW_NUMBER() OVER (PARTITION BY f.documento_id ORDER BY fu.rrf DESC) AS n
        FROM fusion AS fu
        JOIN archivo.fragmentos AS f ON f.fragmento_id = fu.fragmento_id
    )
    SELECT TOP (@top)
           ROW_NUMBER() OVER (ORDER BY p.rrf DESC) AS posicion,
           CAST(p.rrf AS decimal(8,6))             AS puntuacion_rrf,
           p.posicion_vector,
           p.posicion_texto,
           d.nombre_archivo,
           p.pagina,
           LEFT(REPLACE(p.texto, NCHAR(10), N' '), 140) AS fragmento
    FROM por_documento AS p
    JOIN archivo.documentos AS d ON d.documento_id = p.documento_id
    WHERE p.n = 1
    ORDER BY p.rrf DESC;
END;
GO

-- Espera breve a que se rellene el índice de texto completo la primera vez
WAITFOR DELAY '00:00:05';
GO

-- Un número de factura exacto: aquí el texto completo aporta mucho
EXEC archivo.usp_buscar_hibrida @consulta = N'TA-26-0219';
-- Una idea: aquí aportan los vectores
EXEC archivo.usp_buscar_hibrida @consulta = N'penalización por retraso en la obra';
GO

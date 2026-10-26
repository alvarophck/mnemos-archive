/* =====================================================================
   Mnemos Archive · ai/02_create_external_model.sql
   Bloque E: registra el modelo de embeddings local dentro de SQL Server.

     SQL Server 2025 --CREATE EXTERNAL MODEL--> Caddy (HTTPS :11435)
                     --> Ollama (:11434) --> bge-m3 --> vector(1024)
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

IF EXISTS (SELECT 1 FROM sys.external_models WHERE name = 'modelo_embeddings')
    DROP EXTERNAL MODEL modelo_embeddings;
GO

CREATE EXTERNAL MODEL modelo_embeddings
WITH (
    LOCATION   = 'https://localhost:11435/api/embed',
    API_FORMAT = 'Ollama',
    MODEL_TYPE = EMBEDDINGS,
    MODEL      = 'bge-m3'
);
GO

/* Prueba: un texto -> un vector de 1024 dimensiones */
DECLARE @v vector(1024) = AI_GENERATE_EMBEDDINGS(N'Factura de diseño de una página web' USE MODEL modelo_embeddings);

SELECT VECTORPROPERTY(@v, 'Dimensions') AS dimensiones,
       VECTORPROPERTY(@v, 'BaseType')   AS tipo_base,
       LEFT(CAST(@v AS nvarchar(max)), 120) + N' ...' AS primeros_valores;

/* Dos frases que dicen lo mismo con palabras distintas están cerca;
   una que habla de otra cosa, lejos. Esto es lo que hace funcionar la búsqueda. */
DECLARE @a vector(1024) = AI_GENERATE_EMBEDDINGS(N'plazo de entrega antes del verano'       USE MODEL modelo_embeddings);
DECLARE @b vector(1024) = AI_GENERATE_EMBEDDINGS(N'los diseños se entregarán antes de julio' USE MODEL modelo_embeddings);
DECLARE @c vector(1024) = AI_GENERATE_EMBEDDINGS(N'factura de electricidad de agosto'        USE MODEL modelo_embeddings);

SELECT VECTOR_DISTANCE('cosine', @a, @b) AS distancia_misma_idea,
       VECTOR_DISTANCE('cosine', @a, @c) AS distancia_otra_idea;
GO

/* =====================================================================
   Mnemos Archive · ai/08_rag.sql
   Bloque G: RAG (Retrieval-Augmented Generation) con modelo local.

     Pregunta
       -> embedding (bge-m3, AI_GENERATE_EMBEDDINGS)
       -> búsqueda vectorial en SQL Server (VECTOR_DISTANCE coseno)
       -> fragmentos relevantes + datos verificados de esos documentos
       -> contexto numerado [1], [2]...
       -> LLM local (qwen3:4b-instruct) con la orden de usar SOLO ese contexto
       -> respuesta que cita [n] = archivo · página

   El procedimiento devuelve por separado, como pide el enunciado:
     1. la pregunta  2. los documentos recuperados
     3. el contexto que recibe el modelo  4. la respuesta final
   y lo guarda todo en archivo.consultas_rag.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

CREATE OR ALTER PROCEDURE archivo.usp_preguntar
    @pregunta       nvarchar(1000),
    @top_k          int   = 4,
    @distancia_max  float = 0.60    -- más lejos que esto no se considera relevante (ajustable)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @modelo varchar(60) = (SELECT valor FROM archivo.config_ia WHERE clave = 'modelo_llm');
    DECLARE @q vector(1024) = AI_GENERATE_EMBEDDINGS(@pregunta USE MODEL modelo_embeddings);

    /* 1. Recuperación: los k fragmentos más cercanos (RLS filtra lo que el usuario no puede ver) */
    DECLARE @recuperados TABLE
    (
        n            int PRIMARY KEY,
        fragmento_id int,
        documento_id int,
        archivo      nvarchar(260),
        pagina       smallint,
        distancia    float,
        texto        nvarchar(max)
    );

    INSERT INTO @recuperados (n, fragmento_id, documento_id, archivo, pagina, distancia, texto)
    SELECT TOP (@top_k)
           ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('cosine', f.embedding, @q)),
           f.fragmento_id, f.documento_id, d.nombre_archivo, f.pagina,
           VECTOR_DISTANCE('cosine', f.embedding, @q),
           f.texto
    FROM archivo.fragmentos AS f
    JOIN archivo.documentos AS d ON d.documento_id = f.documento_id
    WHERE f.embedding IS NOT NULL
      AND VECTOR_DISTANCE('cosine', f.embedding, @q) <= @distancia_max
    ORDER BY VECTOR_DISTANCE('cosine', f.embedding, @q);

    /* 2. Contexto: fragmentos numerados + datos ya verificados de esos documentos
          (las cifras vienen de la base de datos, no de lo que "recuerde" el modelo) */
    DECLARE @contexto nvarchar(max) =
    (
        SELECT STRING_AGG(CONVERT(nvarchar(max),
                   CONCAT(N'[', r.n, N'] ', r.archivo, N' · p. ', r.pagina, NCHAR(10), r.texto)),
                   CONCAT(NCHAR(10), NCHAR(10))) WITHIN GROUP (ORDER BY r.n)
        FROM @recuperados AS r
    );

    DECLARE @datos nvarchar(max) =
    (
        SELECT STRING_AGG(CONVERT(nvarchar(max),
                   CONCAT(N'- ', d.nombre_archivo, N': tipo ', d.tipo,
                          N', ', ISNULL(d.direccion, N'?'),
                          N', tercero ', ISNULL(t.nombre, N'?'),
                          N', nº ', ISNULL(d.numero, N'?'),
                          N', fecha ', ISNULL(CONVERT(nvarchar(10), d.fecha_documento, 23), N'?'),
                          N', total ', ISNULL(CONVERT(nvarchar(20), d.importe_total), N'?'), N' ', d.moneda)),
                   NCHAR(10))
        FROM archivo.documentos AS d
        LEFT JOIN archivo.terceros AS t ON t.tercero_id = d.tercero_id
        WHERE d.documento_id IN (SELECT documento_id FROM @recuperados)
    );

    IF @datos IS NOT NULL
        SET @contexto = CONCAT(@contexto, NCHAR(10), NCHAR(10), N'Datos verificados de estos documentos:', NCHAR(10), @datos);

    /* 3. Generación */
    DECLARE @respuesta nvarchar(max), @ms int = 0;

    IF NOT EXISTS (SELECT 1 FROM @recuperados)
    BEGIN
        -- Sin contexto no se pregunta al modelo: así no puede inventar
        SET @respuesta = N'No encuentro nada sobre eso en los documentos archivados que puedes consultar.';
    END
    ELSE
    BEGIN
        DECLARE @sistema nvarchar(max) = N'
Eres Mnemos Archive, el archivo de documentos de Estudio Ámbar S.L.
Responde en español, en pocas frases, usando SOLO la información del CONTEXTO.
Después de cada dato indica su fuente con el número entre corchetes, por ejemplo [1].
Si el contexto no contiene la respuesta, di exactamente: "No lo encuentro en los documentos."
No inventes datos, fechas ni importes. Si sumas importes, muestra la operación.';

        DECLARE @usuario nvarchar(max) = CONCAT(N'CONTEXTO:', NCHAR(10), @contexto, NCHAR(10), NCHAR(10),
                                                N'PREGUNTA: ', @pregunta);

        EXEC archivo.usp_llm_chat @sistema = @sistema, @usuario = @usuario,
                                  @respuesta = @respuesta OUTPUT, @duracion_ms = @ms OUTPUT;
    END

    /* 4. Trazabilidad */
    DECLARE @docs_json nvarchar(max) =
        (SELECT n, archivo, pagina, CAST(1 - distancia AS decimal(5,4)) AS similitud
         FROM @recuperados ORDER BY n FOR JSON PATH);

    INSERT INTO archivo.consultas_rag (pregunta, documentos_json, contexto, respuesta, modelo_llm, duracion_ms)
    VALUES (@pregunta, @docs_json, @contexto, @respuesta, @modelo, @ms);

    /* Resultados, en el orden del enunciado */
    SELECT @pregunta AS [1_pregunta];

    SELECT n AS [2_fuente], archivo, pagina,
           CAST(1 - distancia AS decimal(5,4)) AS similitud,
           LEFT(REPLACE(texto, NCHAR(10), N' '), 120) AS fragmento
    FROM @recuperados ORDER BY n;

    SELECT @contexto AS [3_contexto_enviado_al_modelo];

    SELECT @respuesta AS [4_respuesta], @modelo AS modelo, @ms AS milisegundos;
END;
GO

/* Para comparar: el mismo modelo SIN recuperar nada de SQL Server.
   Sirve para enseñar la diferencia entre "LLM" y "SQL Server + vectores + contexto + LLM". */
CREATE OR ALTER PROCEDURE archivo.usp_preguntar_sin_rag
    @pregunta nvarchar(1000)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r nvarchar(max), @ms int;
    EXEC archivo.usp_llm_chat
         @sistema   = N'Responde en español, en pocas frases.',
         @usuario   = @pregunta,
         @respuesta = @r OUTPUT,
         @duracion_ms = @ms OUTPUT;
    SELECT @pregunta AS pregunta, @r AS respuesta_solo_llm, @ms AS milisegundos;
END;
GO

/* ---------------------------------------------------------------------
   Demostración
   --------------------------------------------------------------------- */
EXEC archivo.usp_preguntar N'¿Con cuánto tiempo de antelación tengo que avisar si quiero dejar la oficina?';
EXEC archivo.usp_preguntar N'¿Qué pasa si entregamos tarde los diseños a Construcciones Vallecas?';
EXEC archivo.usp_preguntar N'¿Cuánto le he facturado a Pedro García este año?', @top_k = 6;
EXEC archivo.usp_preguntar N'¿Cuál es la contraseña del wifi de la oficina?';   -- no está: debe decirlo

-- LLM solo vs RAG con la misma pregunta
EXEC archivo.usp_preguntar_sin_rag N'¿Con cuánto tiempo de antelación tengo que avisar si quiero dejar la oficina?';
GO

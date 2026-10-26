/* =====================================================================
   Mnemos Archive · ai/06_llm_chat.sql
   Llamada al modelo de lenguaje local (qwen3:4b en Ollama) desde T-SQL
   con sp_invoke_external_rest_endpoint.

   Lo usan la clasificación de documentos (ai/07) y el RAG (ai/08).
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

CREATE OR ALTER PROCEDURE archivo.usp_llm_chat
    @sistema      nvarchar(max),          -- instrucciones fijas (rol, reglas)
    @usuario      nvarchar(max),          -- la petición concreta
    @formato_json nvarchar(max) = NULL,   -- JSON Schema: obliga al modelo a responder con esa forma
    @respuesta    nvarchar(max) OUTPUT,
    @duracion_ms  int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @url    nvarchar(400) = (SELECT valor FROM archivo.config_ia WHERE clave = 'url_chat');
    DECLARE @modelo nvarchar(100) = (SELECT valor FROM archivo.config_ia WHERE clave = 'modelo_llm');
    DECLARE @inicio datetime2 = sysutcdatetime();

    -- Cuerpo de la petición a Ollama /api/chat
    DECLARE @payload nvarchar(max) = JSON_OBJECT(
        'model'    : @modelo,
        'stream'   : CAST(0 AS bit),
        'think'    : CAST(0 AS bit),              -- qwen3: sin razonamiento visible, respuesta directa
        'options'  : JSON_OBJECT('temperature' : 0, 'num_ctx' : 8192),
        'messages' : JSON_ARRAY(
                        JSON_OBJECT('role' : 'system', 'content' : @sistema),
                        JSON_OBJECT('role' : 'user',   'content' : @usuario)));

    IF @formato_json IS NOT NULL
        SET @payload = JSON_MODIFY(@payload, '$.format', JSON_QUERY(@formato_json));

    DECLARE @resultado int, @http nvarchar(max);

    EXEC @resultado = sys.sp_invoke_external_rest_endpoint
         @url      = @url,
         @method   = 'POST',
         @headers  = N'{"Content-Type":"application/json"}',
         @payload  = @payload,
         @timeout  = 230,
         @response = @http OUTPUT;

    IF @resultado <> 0
    BEGIN
        DECLARE @msg nvarchar(2048) = CONCAT(N'El modelo no respondió bien (HTTP ', @resultado, N'). ',
                                             N'Comprueba que Ollama y Caddy están en marcha. Detalle: ',
                                             LEFT(JSON_QUERY(@http, '$.result'), 500));
        THROW 50020, @msg, 1;
    END

    -- La respuesta viene en $.result.message.content (puede superar 4000 caracteres: OPENJSON)
    SELECT @respuesta = content
    FROM OPENJSON(@http, '$.result.message') WITH (content nvarchar(max) '$.content');

    -- Por si el modelo devuelve razonamiento entre etiquetas <think>
    SET @respuesta = TRIM(NCHAR(10) + NCHAR(13) + N' ' FROM REGEXP_REPLACE(@respuesta, '(?s)<think>.*?</think>', ''));
    SET @duracion_ms = DATEDIFF(MILLISECOND, @inicio, sysutcdatetime());
END;
GO

/* Prueba rápida */
DECLARE @r nvarchar(max), @ms int;
EXEC archivo.usp_llm_chat
     @sistema   = N'Responde en español, en una sola frase.',
     @usuario   = N'¿Qué es una factura?',
     @respuesta = @r OUTPUT,
     @duracion_ms = @ms OUTPUT;
SELECT @r AS respuesta_modelo, @ms AS milisegundos;
GO

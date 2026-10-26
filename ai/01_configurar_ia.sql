/* =====================================================================
   Mnemos Archive · ai/01_configurar_ia.sql
   Prepara SQL Server 2025 para hablar con los modelos locales de Ollama.

   Requisito previo (ver README, "Instalación", paso 4):
     Ollama escucha en http://localhost:11434, pero SQL Server solo llama
     a endpoints HTTPS. Caddy hace de puente en https://localhost:11435
     con un certificado local de confianza (ai/caddy/Caddyfile).

   Modelos (licencias permisivas, se ejecutan en local):
     bge-m3    -> embeddings, 1024 dimensiones, multilingüe (MIT)
     qwen3:4b-instruct -> modelo de lenguaje para extraer campos y responder (Apache 2.0)
                          (no qwen3:4b: esa etiqueta es la versión que razona antes
                          de responder y tarda varios minutos por pregunta)
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE master;
GO

-- sp_invoke_external_rest_endpoint y AI_GENERATE_EMBEDDINGS vienen desactivados
EXEC sp_configure 'external rest endpoint enabled', 1;
RECONFIGURE WITH OVERRIDE;
GO

USE MnemosArchive;
GO

/* Configuración en una tabla, no escrita en el código:
   en un ordenador con menos memoria basta con cambiar el modelo aquí. */
DROP TABLE IF EXISTS archivo.config_ia;
CREATE TABLE archivo.config_ia
(
    clave  varchar(40)    NOT NULL CONSTRAINT PK_config_ia PRIMARY KEY,
    valor  nvarchar(400)  NOT NULL,
    nota   nvarchar(400)  NULL
);

INSERT INTO archivo.config_ia (clave, valor, nota) VALUES
('url_chat',          N'https://localhost:11435/api/chat',  N'Ollama /api/chat detrás de Caddy (HTTPS)'),
('url_embed',         N'https://localhost:11435/api/embed', N'Ollama /api/embed; lo usa CREATE EXTERNAL MODEL'),
('modelo_llm',        N'qwen3:4b-instruct', N'Variante sin razonamiento visible: responde directamente'),
('modelo_embeddings', N'bge-m3',    N'Si se cambia, hay que cambiar también vector(1024) y regenerar los embeddings'),
('tamano_fragmento',  N'500',       N'Caracteres por fragmento (AI_GENERATE_CHUNKS)'),
('solape_fragmento',  N'15',        N'Porcentaje de solape entre fragmentos');
GO

-- Comprobación
SELECT name, value_in_use FROM sys.configurations WHERE name = 'external rest endpoint enabled';
SELECT * FROM archivo.config_ia;
GO

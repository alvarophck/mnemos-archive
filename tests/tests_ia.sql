/* =====================================================================
   Mnemos Archive · tests/tests_ia.sql
   Pruebas de la parte de IA (necesitan Ollama + Caddy en marcha y
   haber ejecutado ai/01 ... ai/09).
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO
SET NOCOUNT ON;

BEGIN TRY
    DECLARE @n int, @v vector(1024);

    /* 1. El modelo de embeddings está registrado y devuelve 1024 dimensiones */
    IF NOT EXISTS (SELECT 1 FROM sys.external_models WHERE name = 'modelo_embeddings')
        THROW 50200, 'No existe el EXTERNAL MODEL modelo_embeddings (ai/02).', 1;
    SET @v = AI_GENERATE_EMBEDDINGS(N'prueba' USE MODEL modelo_embeddings);
    IF VECTORPROPERTY(@v, 'Dimensions') <> 1024 THROW 50200, 'El embedding no tiene 1024 dimensiones.', 1;
    PRINT 'OK  1 modelo de embeddings (1024 dimensiones)';

    /* 2. Todos los fragmentos tienen vector */
    SELECT @n = COUNT(*) FROM archivo.fragmentos WHERE embedding IS NULL;
    IF @n > 0 OR NOT EXISTS (SELECT 1 FROM archivo.fragmentos)
        THROW 50201, 'Hay fragmentos sin embedding (ejecuta archivo.usp_generar_embeddings).', 1;
    PRINT 'OK  2 todos los fragmentos vectorizados';

    /* 3. La búsqueda semántica encuentra el contrato de alquiler al preguntar por el preaviso */
    DECLARE @res TABLE (posicion int, similitud decimal(5,4), nombre_archivo nvarchar(260), tipo varchar(20),
                        tercero nvarchar(200), pagina smallint, fragmento nvarchar(200));
    INSERT INTO @res EXEC archivo.usp_buscar_semantica N'¿con cuánto tiempo tengo que avisar para dejar la oficina?', 3;
    IF NOT EXISTS (SELECT 1 FROM @res WHERE nombre_archivo = N'contrato-alquiler-oficina.pdf')
        THROW 50202, 'La búsqueda no devolvió el contrato de alquiler entre los 3 primeros.', 1;
    PRINT 'OK  3 búsqueda semántica';

    /* 4. Los documentos sin clasificar se clasificaron */
    IF EXISTS (SELECT 1 FROM archivo.documentos WHERE tipo = 'sin_clasificar')
        THROW 50203, 'Quedan documentos sin clasificar (ejecuta archivo.usp_procesar_pendientes).', 1;
    IF NOT EXISTS (SELECT 1 FROM archivo.documentos AS d JOIN archivo.terceros AS t ON t.tercero_id = d.tercero_id
                   WHERE d.nombre_archivo = N'escaneo-0003.pdf' AND t.nombre = N'Energía Clara S.A.')
        PRINT 'AVISO 4 escaneo-0003 no se enlazó con Energía Clara (revisar la extracción).';
    ELSE
        PRINT 'OK  4 clasificación y enlace con el tercero';

    /* 5. El RAG responde y deja trazabilidad */
    DECLARE @antes int = (SELECT COUNT(*) FROM archivo.consultas_rag);
    EXEC archivo.usp_preguntar N'¿Qué penalización hay si se entrega tarde la señalética?';
    IF (SELECT COUNT(*) FROM archivo.consultas_rag) <> @antes + 1
        THROW 50204, 'La consulta RAG no quedó registrada.', 1;
    IF (SELECT TOP (1) respuesta FROM archivo.consultas_rag ORDER BY consulta_id DESC) IS NULL
        THROW 50204, 'El RAG no devolvió respuesta.', 1;
    PRINT 'OK  5 RAG con trazabilidad';

    /* 6. El RAG respeta Row-Level Security: contabilidad no recupera contratos */
    EXECUTE AS USER = 'usr_contable';
        EXEC archivo.usp_preguntar N'¿Con cuánto tiempo de antelación tengo que avisar si quiero dejar la oficina?';
    REVERT;
    IF EXISTS (SELECT 1 FROM OPENJSON((SELECT TOP (1) documentos_json FROM archivo.consultas_rag ORDER BY consulta_id DESC))
               WITH (archivo nvarchar(260)) WHERE archivo LIKE N'contrato%')
        THROW 50205, 'usr_contable recuperó un contrato en el RAG.', 1;
    PRINT 'OK  6 RAG filtrado por permisos';

    PRINT '';
    PRINT 'Pruebas de IA superadas.';
END TRY
BEGIN CATCH
    IF USER_NAME() <> 'dbo' REVERT;
    PRINT CONCAT('FALLO: ', ERROR_MESSAGE());
    THROW;
END CATCH
GO

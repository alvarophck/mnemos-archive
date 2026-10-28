/* =====================================================================
   Mnemos Archive · tests/tests_ia.sql
   Pruebas de la parte de IA (necesitan Ollama + Caddy en marcha y
   haber ejecutado ai/01 ... ai/10).
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

    /* 7. Preguntas de datos: SQL calcula lo pagado a un tercero (sin IA) */
    DECLARE @datos nvarchar(max), @docs nvarchar(max), @cifras nvarchar(max), @directa nvarchar(1000);
    EXEC archivo.usp_consultar_datos @tercero = N'tecnologias arganzuela', @desde = '2026-01-01', @hasta = '2026-12-31',
         @mostrar = 0, @datos = @datos OUTPUT, @documentos_json = @docs OUTPUT,
         @cifras_json = @cifras OUTPUT, @respuesta_directa = @directa OUTPUT;
    IF @datos NOT LIKE N'%facturas recibidas (lo que has pagado): 2 documento(s) en el periodo, importe total 145,20 EUR%'
       OR @datos NOT LIKE N'%contratos%: 1 documento(s)%'
       OR (SELECT COUNT(*) FROM OPENJSON(@docs)) <> 3
        THROW 50206, 'usp_consultar_datos no calcula bien lo pagado a Tecnologías Arganzuela en 2026.', 1;
    PRINT 'OK  7 datos calculados por SQL (sin "tildes" y con nombre parcial)';

    /* 8. Si el tercero no existe, se dice sin llamar al modelo */
    EXEC archivo.usp_consultar_datos @tercero = N'Pepinos en salsa', @mostrar = 0, @respuesta_directa = @directa OUTPUT;
    IF @directa NOT LIKE N'No hay ningún tercero parecido a%'
        THROW 50207, 'Con un tercero inexistente no se devolvió la respuesta directa.', 1;
    PRINT 'OK  8 tercero inexistente';

    /* 9. Una cifra que no está en los datos se detecta */
    IF NOT EXISTS (SELECT 1 FROM archivo.fn_cifras_sin_respaldo(N'Le has pagado 150,00 EUR.', @cifras, N'') WHERE cifra = N'150,00')
       OR EXISTS (SELECT 1 FROM archivo.fn_cifras_sin_respaldo(N'Le has pagado 145,20 EUR el 31/1/2026 [1].', @cifras, N''))
        THROW 50208, 'fn_cifras_sin_respaldo no distingue cifras calculadas de inventadas.', 1;
    PRINT 'OK  9 comprobación de cifras';

    /* 9b. Operaciones con las cifras: se detectan en la pregunta y en la respuesta */
    IF (SELECT si FROM archivo.fn_pide_calculo_extra(N'¿Cuánto es el doble de lo que le he pagado a Arganzuela?')) <> 1
       OR (SELECT si FROM archivo.fn_pide_calculo_extra(N'¿Cuánto le he pagado a Arganzuela este año?')) <> 0
       OR (SELECT si FROM archivo.fn_tiene_operacion(N'72,60 EUR × 2 = 145,20 EUR')) <> 1
       OR (SELECT si FROM archivo.fn_tiene_operacion(N'Le has pagado 145,20 EUR el 31/1/2026 y el 28/2/2026.')) <> 0
        THROW 50209, 'No se distinguen las preguntas o respuestas que operan con las cifras.', 1;
    PRINT 'OK  9b operaciones con las cifras';

    /* 9c. Las cuentas pedidas las hace SQL: el doble, un porcentaje, y lo que no se puede */
    DECLARE @l nvarchar(1000), @f nvarchar(400), @res nvarchar(60), @fija nvarchar(1000), @extra nvarchar(max), @no nvarchar(400),
            @arg int = (SELECT tercero_id FROM archivo.terceros WHERE nombre = N'Tecnologías Arganzuela S.L.'),
            @ped int = (SELECT tercero_id FROM archivo.terceros WHERE nombre = N'Pedro García Ruiz');
    EXEC archivo.usp_calcular_operacion @tercero_id = @arg, @tercero_nombre = N'Tecnologías Arganzuela S.L.',
         @desde = '2026-01-01', @hasta = '2026-12-31', @operacion = 'multiplicar', @valor = 2, @sobre = 'pagado',
         @linea = @l OUTPUT, @formula = @f OUTPUT, @resultado_txt = @res OUTPUT, @respuesta_fija = @fija OUTPUT,
         @cifras_extra = @extra OUTPUT, @no_se_puede = @no OUTPUT;
    IF @res <> N'290,40 EUR' OR @f <> N'145,20 EUR × 2 = 290,40 EUR'
        THROW 50210, 'El doble de lo pagado a Arganzuela en 2026 no da 290,40 EUR.', 1;
    EXEC archivo.usp_calcular_operacion @tercero_id = @ped, @tercero_nombre = N'Pedro García Ruiz',
         @desde = '2026-01-01', @hasta = '2026-12-31', @operacion = 'porcentaje', @valor = 21, @sobre = 'facturado',
         @linea = @l OUTPUT, @formula = @f OUTPUT, @resultado_txt = @res OUTPUT, @respuesta_fija = @fija OUTPUT,
         @cifras_extra = @extra OUTPUT, @no_se_puede = @no OUTPUT;
    IF @res <> N'1.012,20 EUR'
        THROW 50210, 'El 21 % de lo facturado a Pedro García en 2026 no da 1.012,20 EUR.', 1;
    EXEC archivo.usp_calcular_operacion @tercero_id = @arg, @tercero_nombre = N'Tecnologías Arganzuela S.L.',
         @desde = '2026-01-01', @hasta = '2026-12-31', @operacion = 'dividir', @valor = 0, @sobre = 'pagado',
         @linea = @l OUTPUT, @formula = @f OUTPUT, @resultado_txt = @res OUTPUT, @respuesta_fija = @fija OUTPUT,
         @cifras_extra = @extra OUTPUT, @no_se_puede = @no OUTPUT;
    IF @no IS NULL OR @res IS NOT NULL
        THROW 50210, 'Dividir entre cero no se rechazó.', 1;
    PRINT 'OK  9c cuentas hechas por SQL (doble, porcentaje, división entre cero)';

    /* 9d. Reglas sin IA: la cuenta se reconoce aunque el modelo no la vea */
    IF NOT EXISTS (SELECT 1 FROM archivo.fn_operacion_por_reglas(N'cuanto le he pagado a tecnlogias arganzuela, prorrateado a 14 meses')
                   WHERE operacion = 'dividir' AND valor = N'14')
       OR NOT EXISTS (SELECT 1 FROM archivo.fn_operacion_por_reglas(N'¿Cuánto es el 21 % de lo facturado?') WHERE operacion = 'porcentaje' AND valor = N'21')
       OR EXISTS (SELECT 1 FROM archivo.fn_operacion_por_reglas(N'¿Cuánto le he pagado a Arganzuela en 2026?'))
        THROW 50211, 'Las reglas no reconocen bien las cuentas (prorrateo, porcentaje) o ven una donde no la hay.', 1;
    PRINT 'OK  9d cuentas reconocidas sin IA (prorrateo, porcentaje)';

    /* 10. El enrutador manda la pregunta de datos por SQL y la respuesta lleva la cifra exacta */
    EXEC archivo.usp_preguntar N'¿Cuánto le he pagado a Tecnologías Arganzuela este año?';
    IF (SELECT TOP (1) respuesta FROM archivo.consultas_rag ORDER BY consulta_id DESC) NOT LIKE N'%145,20%'
        PRINT 'AVISO 10 la respuesta no incluye 145,20 (revisar en archivo.consultas_rag si el modelo la clasificó como contenido).';
    ELSE
        PRINT 'OK  10 pregunta de datos de principio a fin';

    PRINT '';
    PRINT 'Pruebas de IA superadas.';
END TRY
BEGIN CATCH
    IF USER_NAME() <> 'dbo' REVERT;
    PRINT CONCAT('FALLO: ', ERROR_MESSAGE());
    THROW;
END CATCH
GO

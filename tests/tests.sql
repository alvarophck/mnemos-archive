/* =====================================================================
   Mnemos Archive · tests/tests.sql
   Pruebas de la parte relacional. Al terminar (bien o mal) se deshacen
   los cambios de prueba: la base de datos queda como estaba.
   (No se usa una transacción global porque varias pruebas provocan
   errores a propósito y eso la invalidaría.)
   Cada prueba imprime OK o lanza un error con lo que ha fallado.
   (Las pruebas de IA están en tests/tests_ia.sql: necesitan Ollama.)
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT OFF;
GO
USE MnemosArchive;
GO
SET NOCOUNT ON;

DECLARE @id int, @existia bit, @n int;
DECLARE @auditoria_inicio bigint = ISNULL((SELECT MAX(auditoria_id) FROM archivo.auditoria), 0);
DECLARE @total_original decimal(12,2) = (SELECT valor_numero FROM archivo.campos_extraidos WHERE documento_id = 1 AND nombre_campo = 'total');

BEGIN TRY

    /* 1. Datos de prueba cargados */
    IF (SELECT COUNT(*) FROM archivo.documentos) < 22 THROW 50100, 'Faltan documentos de prueba.', 1;
    IF (SELECT COUNT(*) FROM archivo.terceros)   < 11 THROW 50100, 'Faltan terceros de prueba.', 1;
    PRINT 'OK  1 datos de prueba';

    /* 2. Las sumas cuadran: lo facturado a Pedro García en 2026 son 4.820,00 */
    IF (SELECT SUM(importe_total) FROM archivo.documentos
        WHERE tercero_id = 1 AND tipo = 'factura' AND direccion = 'emitido' AND YEAR(fecha_documento) = 2026) <> 4820.00
        THROW 50101, 'El total facturado a Pedro García no es 4.820,00.', 1;
    PRINT 'OK  2 total facturado calculado por la base de datos';

    /* 3. Archivar el mismo contenido dos veces no lo duplica */
    EXEC archivo.usp_archivar_documento N'prueba.pdf', N'Texto de prueba único 7f3a', 'contabilidad', 1, @id OUTPUT, @existia OUTPUT;
    IF @existia <> 0 THROW 50102, 'El primer archivado debería ser nuevo.', 1;
    DECLARE @id2 int;
    EXEC archivo.usp_archivar_documento N'copia.pdf', N'Texto de prueba único 7f3a', 'contabilidad', 1, @id2 OUTPUT, @existia OUTPUT;
    IF @existia <> 1 OR @id2 <> @id THROW 50102, 'El duplicado no se detectó.', 1;
    PRINT 'OK  3 deduplicación por hash SHA-256';

    /* 4. Un documento sin texto se rechaza con un mensaje claro */
    BEGIN TRY
        EXEC archivo.usp_archivar_documento N'vacio.pdf', N'   ', 'contabilidad', 1, @id2 OUTPUT, @existia OUTPUT;
        THROW 50103, 'Se aceptó un documento vacío.', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() <> 50010 THROW;
    END CATCH
    PRINT 'OK  4 documento vacío rechazado';

    /* 5. Restricciones CHECK */
    BEGIN TRY
        UPDATE archivo.documentos SET tipo = 'banana' WHERE documento_id = @id;
        THROW 50104, 'Se aceptó un tipo de documento inválido.', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() = 50104 THROW;
    END CATCH
    PRINT 'OK  5 CHECK de tipo de documento';

    /* 6. Corregir un campo: queda marcado y auditado */
    EXEC archivo.usp_corregir_campo @documento_id = 1, @nombre_campo = 'total', @valor_numero = 1211.00;
    IF NOT EXISTS (SELECT 1 FROM archivo.campos_extraidos WHERE documento_id = 1 AND nombre_campo = 'total' AND corregido = 1 AND valor_numero = 1211.00)
        THROW 50105, 'La corrección no se guardó.', 1;
    IF NOT EXISTS (SELECT 1 FROM archivo.auditoria WHERE tabla = 'campos_extraidos' AND accion = 'UPDATE'
                   AND JSON_VALUE(detalle, '$.antes.numero') = '1210.00' AND JSON_VALUE(detalle, '$.despues.numero') = '1211.00')
        THROW 50105, 'El trigger no auditó la corrección.', 1;
    IF (SELECT importe_total FROM archivo.documentos WHERE documento_id = 1) <> 1211.00
        THROW 50105, 'El total del documento no se actualizó.', 1;
    PRINT 'OK  6 corrección de campo + auditoría por trigger';

    /* 7. Borrado RGPD: se va todo lo derivado y queda constancia sin el contenido */
    INSERT INTO archivo.fragmentos (documento_id, orden, texto) VALUES (@id, 1, N'fragmento de prueba');
    EXEC archivo.usp_borrar_documento @documento_id = @id;
    IF EXISTS (SELECT 1 FROM archivo.fragmentos WHERE documento_id = @id) THROW 50106, 'Quedaron fragmentos huérfanos.', 1;
    IF NOT EXISTS (SELECT 1 FROM archivo.auditoria WHERE tabla = 'documentos' AND accion = 'DELETE' AND registro_id = @id)
        THROW 50106, 'El borrado no quedó auditado.', 1;
    PRINT 'OK  7 borrado en cascada y auditado';

    /* 8. Funciones */
    IF archivo.fn_nif_valido('B12345674') <> 1 OR archivo.fn_nif_valido('12345') <> 0 THROW 50107, 'fn_nif_valido falla.', 1;
    IF archivo.fn_importe_es(N'1.247,93') <> 1247.93 THROW 50107, 'fn_importe_es falla.', 1;
    IF (SELECT tercero_id FROM archivo.fn_buscar_tercero(N'Energia Clara SA', NULL)) <> 7 THROW 50107, 'fn_buscar_tercero no encontró a Energía Clara.', 1;
    IF archivo.fn_pagina_en(N'uno [página 2] dos', 15) <> 2 THROW 50107, 'fn_pagina_en falla.', 1;
    PRINT 'OK  8 funciones (regex, importes, fuzzy, páginas)';

    /* 9. Vistas */
    IF NOT EXISTS (SELECT 1 FROM archivo.v_facturacion_mensual WHERE mes = '2026-02-01') THROW 50108, 'v_facturacion_mensual vacía.', 1;
    IF (SELECT COUNT(*) FROM archivo.v_contratos) <> 4 THROW 50108, 'v_contratos no devuelve 4 contratos.', 1;
    PRINT 'OK  9 vistas';

    /* 10. Seguridad: RLS y máscaras */
    EXECUTE AS USER = 'usr_legal';
        SELECT @n = COUNT(*) FROM archivo.documentos WHERE tipo <> 'contrato';
    REVERT;
    IF @n <> 0 THROW 50109, 'usr_legal ve documentos que no son contratos.', 1;

    EXECUTE AS USER = 'usr_contable';
        SELECT @n = COUNT(*) FROM archivo.documentos WHERE tipo = 'contrato';
        DECLARE @nif varchar(12) = (SELECT nif FROM archivo.terceros WHERE tercero_id = 1);
    REVERT;
    IF @n <> 0 THROW 50109, 'usr_contable ve contratos.', 1;
    IF @nif NOT LIKE '*****%' THROW 50109, 'El NIF no sale enmascarado para usr_contable.', 1;

    EXECUTE AS USER = 'usr_contable';
    BEGIN TRY
        DELETE FROM archivo.documentos WHERE documento_id = 1;
        REVERT;
        THROW 50109, 'usr_contable pudo borrar.', 1;
    END TRY
    BEGIN CATCH
        IF USER_NAME() <> 'dbo' REVERT;
        IF ERROR_NUMBER() = 50109 THROW;
    END CATCH
    PRINT 'OK 10 seguridad (RLS, enmascaramiento, DENY DELETE)';

    PRINT '';
    PRINT 'Todas las pruebas pasaron (10/10).';
END TRY
BEGIN CATCH
    IF USER_NAME() <> 'dbo' REVERT;
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT CONCAT('FALLO: ', ERROR_MESSAGE());
END CATCH;

/* Limpieza: deshacer los cambios de las pruebas */
DISABLE TRIGGER archivo.trg_campos_auditoria ON archivo.campos_extraidos;
UPDATE archivo.campos_extraidos SET valor_numero = @total_original, corregido = 0
WHERE documento_id = 1 AND nombre_campo = 'total';
ENABLE TRIGGER archivo.trg_campos_auditoria ON archivo.campos_extraidos;
UPDATE archivo.documentos SET importe_total = @total_original WHERE documento_id = 1;
DELETE FROM archivo.documentos WHERE nombre_archivo IN (N'prueba.pdf', N'copia.pdf', N'vacio.pdf');
DELETE FROM archivo.auditoria WHERE auditoria_id > @auditoria_inicio;
PRINT 'Datos de prueba restaurados.';
GO

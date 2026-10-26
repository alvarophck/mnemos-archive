/* =====================================================================
   Mnemos Archive · 07_triggers.sql
   Auditoría automática: quién cambió qué y cuándo.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

/* Cada cambio de valor en un campo extraído queda registrado con
   el valor anterior y el nuevo (en JSON). */
CREATE OR ALTER TRIGGER archivo.trg_campos_auditoria
ON archivo.campos_extraidos
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO archivo.auditoria (tabla, accion, registro_id, detalle)
    SELECT 'campos_extraidos', 'UPDATE', i.campo_id,
           (SELECT i.documento_id AS documento_id,
                   i.nombre_campo AS campo,
                   d.valor_texto  AS [antes.texto],  d.valor_numero AS [antes.numero], d.valor_fecha AS [antes.fecha],
                   i.valor_texto  AS [despues.texto], i.valor_numero AS [despues.numero], i.valor_fecha AS [despues.fecha],
                   i.extraido_por AS [despues.extraido_por]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)
    FROM inserted AS i
    JOIN deleted  AS d ON d.campo_id = i.campo_id
    WHERE EXISTS (SELECT i.valor_texto, i.valor_numero, i.valor_fecha
                  EXCEPT
                  SELECT d.valor_texto, d.valor_numero, d.valor_fecha);   -- solo si el valor cambió
END;
GO

/* Los borrados de documentos se registran (sin guardar el texto:
   si se borra por RGPD, el contenido no debe quedarse en la auditoría). */
CREATE OR ALTER TRIGGER archivo.trg_documentos_borrado
ON archivo.documentos
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO archivo.auditoria (tabla, accion, registro_id, detalle)
    SELECT 'documentos', 'DELETE', d.documento_id,
           (SELECT d.nombre_archivo AS archivo, d.tipo AS tipo, d.numero AS numero
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM deleted AS d;
END;
GO

/* Un documento que cambia de texto deja de tener fragmentos válidos:
   se borran para que se vuelvan a trocear y vectorizar. */
CREATE OR ALTER TRIGGER archivo.trg_documentos_texto
ON archivo.documentos
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(texto) RETURN;

    DELETE f
    FROM archivo.fragmentos AS f
    JOIN inserted AS i ON i.documento_id = f.documento_id
    JOIN deleted  AS d ON d.documento_id = i.documento_id
    WHERE HASHBYTES('SHA2_256', i.texto) <> HASHBYTES('SHA2_256', d.texto);
END;
GO

PRINT 'Triggers creados: trg_campos_auditoria, trg_documentos_borrado, trg_documentos_texto.';
GO

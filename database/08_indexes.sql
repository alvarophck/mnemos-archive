/* =====================================================================
   Mnemos Archive · 08_indexes.sql
   Índices de apoyo a las consultas habituales.
   El índice que se estudia en la optimización (tercero + fecha) NO está
   aquí a propósito: lo crea 11_optimization.sql para comparar antes y después.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

-- Claves foráneas: SQL Server no las indexa solo
-- (campos_extraidos y fragmentos ya están cubiertos por sus UNIQUE (documento_id, ...))
DROP INDEX IF EXISTS IX_documentos_tipo_fecha ON archivo.documentos;
CREATE INDEX IX_documentos_tipo_fecha
    ON archivo.documentos (tipo, fecha_documento)
    INCLUDE (direccion, importe_total, tercero_id);
GO

-- Filtrado: los documentos que la IA aún tiene que procesar son pocos;
-- un índice filtrado solo guarda esas filas.
DROP INDEX IF EXISTS IX_documentos_pendientes ON archivo.documentos;
CREATE INDEX IX_documentos_pendientes
    ON archivo.documentos (fecha_alta)
    WHERE estado = 'pendiente';
GO

-- Búsqueda de campos por nombre y valor ("todas las facturas con total > 1.000")
DROP INDEX IF EXISTS IX_campos_nombre_numero ON archivo.campos_extraidos;
CREATE INDEX IX_campos_nombre_numero
    ON archivo.campos_extraidos (nombre_campo, valor_numero)
    INCLUDE (documento_id);
GO

DROP INDEX IF EXISTS IX_campos_nombre_fecha ON archivo.campos_extraidos;
CREATE INDEX IX_campos_nombre_fecha
    ON archivo.campos_extraidos (nombre_campo, valor_fecha)
    INCLUDE (documento_id);
GO

-- Auditoría por registro
DROP INDEX IF EXISTS IX_auditoria_tabla_registro ON archivo.auditoria;
CREATE INDEX IX_auditoria_tabla_registro
    ON archivo.auditoria (tabla, registro_id, fecha);
GO

PRINT 'Índices creados.';
GO

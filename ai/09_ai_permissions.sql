/* =====================================================================
   Mnemos Archive · ai/09_ai_permissions.sql
   Permisos para que contabilidad y legal puedan buscar y preguntar,
   y demostración de que el RAG respeta Row-Level Security:
   un usuario solo obtiene respuestas de los documentos que puede ver.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

GRANT EXECUTE ON archivo.usp_buscar_semantica TO rol_contabilidad, rol_legal;
GRANT EXECUTE ON archivo.usp_buscar_hibrida   TO rol_contabilidad, rol_legal;
GRANT EXECUTE ON archivo.usp_preguntar        TO rol_contabilidad, rol_legal;

-- Usar el modelo de embeddings y llamar al endpoint del LLM
GRANT EXECUTE ON EXTERNAL MODEL::modelo_embeddings TO rol_contabilidad, rol_legal, rol_administracion;
GRANT EXECUTE ANY EXTERNAL ENDPOINT TO rol_contabilidad, rol_legal, rol_administracion;

-- Clasificar documentos (escribe en la base de datos): solo administración
GRANT EXECUTE ON archivo.usp_clasificar_y_extraer TO rol_administracion;
GRANT EXECUTE ON archivo.usp_procesar_pendientes  TO rol_administracion;
GO

/* La misma pregunta, dos usuarios */
PRINT '--- usr_contable pregunta por el preaviso del alquiler (es un contrato: no lo ve)';
EXECUTE AS USER = 'usr_contable';
    EXEC archivo.usp_preguntar N'¿Con cuánto tiempo de antelación tengo que avisar si quiero dejar la oficina?';
REVERT;

PRINT '--- usr_legal hace la misma pregunta (sí ve los contratos)';
EXECUTE AS USER = 'usr_legal';
    EXEC archivo.usp_preguntar N'¿Con cuánto tiempo de antelación tengo que avisar si quiero dejar la oficina?';
REVERT;
GO

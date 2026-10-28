/* =====================================================================
   Mnemos Archive · demo/demo.sql
   Guion para probar a mano (o enseñar en la presentación) desde SSMS.
   Selecciona un bloque y pulsa F5 para ejecutar solo ese bloque.
   Requisitos: instalar.ps1 ejecutado, Ollama y Caddy en marcha.
   ===================================================================== */
USE MnemosArchive;
GO

/* 1. Qué hay archivado */
SELECT documento_id, nombre_archivo, tipo, direccion, tercero, fecha_documento, importe_total, estado
FROM archivo.v_documentos
ORDER BY documento_id;

/* 2. Las cifras las calcula la base de datos */
EXEC archivo.usp_resumen_tercero @nombre = N'Pedro Garcia', @anio = 2026;   -- sin tilde: fuzzy matching

/* 3. Búsqueda por significado (no hace falta acertar las palabras) */
EXEC archivo.usp_buscar_semantica N'cláusula de entrega antes del verano';
EXEC archivo.usp_buscar_semantica N'gastos de luz', @top = 3;

/* 4. Preguntar al archivo (RAG): pregunta, fuentes, contexto y respuesta */
EXEC archivo.usp_preguntar N'¿Con cuánto tiempo de antelación tengo que avisar si quiero dejar la oficina?';

/* 5. Lo mismo sin RAG: el modelo solo, sin tus documentos, se lo inventa */
EXEC archivo.usp_preguntar_sin_rag N'¿Con cuánto tiempo de antelación tengo que avisar si quiero dejar la oficina?';

/* 5b. Preguntas de datos: el LLM entiende la pregunta, SQL cuenta y suma, el LLM redacta.
       Las cifras de la respuesta se comprueban contra lo calculado (columna cifras_verificadas) */
EXEC archivo.usp_preguntar N'¿En cuántos contratos aparece Tecnologías Arganzuela, cuánto les he pagado este año y en qué fechas?';
EXEC archivo.usp_preguntar N'¿Cuánto le he pagado a Pepinos en salsa este año?';   -- no existe: lo dice sin preguntar al modelo
EXEC archivo.usp_preguntar N'¿Cuánto es el doble de lo que le he pagado a Tecnologías Arganzuela este año?';   -- la cuenta la hace SQL (columna calculo)
EXEC archivo.usp_consultar_datos @tercero = N'pedro garcia', @desde = '2026-01-01', @hasta = '2026-12-31';   -- lo que calcula SQL, sin IA

/* 6. Si no está en los documentos, lo dice */
EXEC archivo.usp_preguntar N'¿Cuál es la contraseña del wifi de la oficina?';

/* 7. Seguridad: la misma pregunta como contabilidad (no ve contratos) */
EXECUTE AS USER = 'usr_contable';
    EXEC archivo.usp_preguntar N'¿Con cuánto tiempo de antelación tengo que avisar si quiero dejar la oficina?';
    SELECT TOP (3) nombre, nif, email FROM archivo.terceros;   -- NIF y email enmascarados
REVERT;

/* 8. Archivar un documento nuevo y que la IA lo lea */
DECLARE @id int, @existia bit;
EXEC archivo.usp_archivar_documento
     @nombre_archivo = N'escaneo-demo.pdf',
     @texto = N'Imprenta Lavapies SL - B86234519. Factura IL-0502 de 20/10/2026.
Impresion de 200 tarjetas de visita. Base 80,00 EUR, IVA 21% 16,80 EUR, total 96,80 EUR.',
     @documento_id = @id OUTPUT, @ya_existia = @existia OUTPUT;
EXEC archivo.usp_clasificar_y_extraer @documento_id = @id;   -- tipo, tercero, fecha e importes
EXEC archivo.usp_generar_embeddings @documento_id = @id;     -- ya se puede buscar
EXEC archivo.usp_preguntar N'¿Cuánto costaron las tarjetas de visita?';

/* 9. Borrado RGPD: desaparece todo lo derivado y queda constancia */
EXEC archivo.usp_borrar_documento @documento_id = @id;
SELECT TOP (3) * FROM archivo.auditoria ORDER BY auditoria_id DESC;

/* 10. Historial de preguntas */
SELECT TOP (10) consulta_id, usuario, pregunta, LEFT(respuesta, 120) AS respuesta, duracion_ms, fecha
FROM archivo.consultas_rag
ORDER BY consulta_id DESC;

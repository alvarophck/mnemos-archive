/* =====================================================================
   Mnemos Archive · 09_security.sql
   Cuatro mecanismos de seguridad:
     1. Usuarios y roles con privilegio mínimo (GRANT / DENY / REVOKE)
     2. Row-Level Security: cada departamento solo ve sus documentos
     3. Dynamic Data Masking: NIF, email y teléfono enmascarados
     4. Auditoría de cambios (triggers de 07_triggers.sql)

   Los usuarios se crean SIN LOGIN: no hay contraseñas en el repositorio.
   Se prueban con EXECUTE AS USER (al final del script).

     usr_admin     -> rol_administracion : todo, sin máscara
     usr_contable  -> rol_contabilidad   : facturas, presupuestos y recibos
     usr_legal     -> rol_legal          : solo contratos
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

/* ---------------------------------------------------------------------
   0. Limpieza (el script se puede ejecutar varias veces)
   --------------------------------------------------------------------- */
DROP SECURITY POLICY IF EXISTS archivo.politica_departamento;
DROP FUNCTION IF EXISTS archivo.fn_rls_documento;
DROP FUNCTION IF EXISTS archivo.fn_rls_departamento;
GO

IF USER_ID('usr_admin')    IS NOT NULL DROP USER usr_admin;
IF USER_ID('usr_contable') IS NOT NULL DROP USER usr_contable;
IF USER_ID('usr_legal')    IS NOT NULL DROP USER usr_legal;
IF DATABASE_PRINCIPAL_ID('rol_administracion') IS NOT NULL DROP ROLE rol_administracion;
IF DATABASE_PRINCIPAL_ID('rol_contabilidad')   IS NOT NULL DROP ROLE rol_contabilidad;
IF DATABASE_PRINCIPAL_ID('rol_legal')          IS NOT NULL DROP ROLE rol_legal;
GO

/* ---------------------------------------------------------------------
   1. Roles, usuarios y permisos (privilegio mínimo)
   --------------------------------------------------------------------- */
CREATE ROLE rol_administracion;
CREATE ROLE rol_contabilidad;
CREATE ROLE rol_legal;

CREATE USER usr_admin    WITHOUT LOGIN;
CREATE USER usr_contable WITHOUT LOGIN;
CREATE USER usr_legal    WITHOUT LOGIN;

ALTER ROLE rol_administracion ADD MEMBER usr_admin;
ALTER ROLE rol_contabilidad   ADD MEMBER usr_contable;
ALTER ROLE rol_legal          ADD MEMBER usr_legal;
GO

-- Administración: lectura y escritura en todo el esquema, y ve los datos sin máscara
GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE ON SCHEMA::archivo TO rol_administracion;
GRANT UNMASK TO rol_administracion;

-- Contabilidad: consulta documentos y terceros, corrige campos, no borra
GRANT SELECT ON archivo.documentos       TO rol_contabilidad;
GRANT SELECT ON archivo.terceros         TO rol_contabilidad;
GRANT SELECT ON archivo.campos_extraidos TO rol_contabilidad;
GRANT SELECT ON archivo.fragmentos       TO rol_contabilidad;
GRANT SELECT ON archivo.v_documentos           TO rol_contabilidad;
GRANT SELECT ON archivo.v_facturacion_mensual  TO rol_contabilidad;
GRANT EXECUTE ON archivo.usp_corregir_campo    TO rol_contabilidad;
GRANT EXECUTE ON archivo.usp_resumen_tercero   TO rol_contabilidad;
DENY  DELETE ON SCHEMA::archivo                TO rol_contabilidad;
DENY  SELECT ON archivo.auditoria              TO rol_contabilidad;

-- Legal: solo contratos (RLS) y la vista de contratos; sin datos de contacto
GRANT SELECT ON archivo.documentos       TO rol_legal;
GRANT SELECT ON archivo.campos_extraidos TO rol_legal;
GRANT SELECT ON archivo.fragmentos       TO rol_legal;
GRANT SELECT ON archivo.v_contratos      TO rol_legal;
GRANT SELECT ON archivo.terceros (tercero_id, nombre, ciudad) TO rol_legal;   -- permiso por columnas
DENY  DELETE ON SCHEMA::archivo          TO rol_legal;
DENY  SELECT ON archivo.auditoria        TO rol_legal;
GO

-- Ejemplo de REVOKE: durante una prueba se dio permiso de INSERT a contabilidad
-- y se retira; queda sin permiso concedido ni denegado.
GRANT  INSERT ON archivo.documentos TO rol_contabilidad;
REVOKE INSERT ON archivo.documentos FROM rol_contabilidad;
GO

/* ---------------------------------------------------------------------
   2. Row-Level Security por departamento
   --------------------------------------------------------------------- */
CREATE FUNCTION archivo.fn_rls_departamento (@departamento varchar(20))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS permitido
    WHERE IS_MEMBER('db_owner') = 1
       OR IS_MEMBER('rol_administracion') = 1
       OR (@departamento = 'contabilidad' AND IS_MEMBER('rol_contabilidad') = 1)
       OR (@departamento = 'legal'        AND IS_MEMBER('rol_legal') = 1);
GO

-- Para las tablas hijas (campos y fragmentos): se mira el departamento del documento.
-- Sin esto, un usuario de legal podría leer el texto de una factura desde fragmentos.
CREATE FUNCTION archivo.fn_rls_documento (@documento_id int)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS permitido
    FROM archivo.documentos AS d
    WHERE d.documento_id = @documento_id
      AND (   IS_MEMBER('db_owner') = 1
           OR IS_MEMBER('rol_administracion') = 1
           OR (d.departamento = 'contabilidad' AND IS_MEMBER('rol_contabilidad') = 1)
           OR (d.departamento = 'legal'        AND IS_MEMBER('rol_legal') = 1));
GO

CREATE SECURITY POLICY archivo.politica_departamento
    ADD FILTER PREDICATE archivo.fn_rls_departamento(departamento) ON archivo.documentos,
    ADD BLOCK  PREDICATE archivo.fn_rls_departamento(departamento) ON archivo.documentos AFTER INSERT,
    ADD BLOCK  PREDICATE archivo.fn_rls_departamento(departamento) ON archivo.documentos AFTER UPDATE,
    ADD FILTER PREDICATE archivo.fn_rls_documento(documento_id)    ON archivo.campos_extraidos,
    ADD FILTER PREDICATE archivo.fn_rls_documento(documento_id)    ON archivo.fragmentos
WITH (STATE = ON);
GO

/* ---------------------------------------------------------------------
   3. Dynamic Data Masking
   --------------------------------------------------------------------- */
ALTER TABLE archivo.terceros ALTER COLUMN nif      ADD MASKED WITH (FUNCTION = 'partial(0,"*****",4)');
ALTER TABLE archivo.terceros ALTER COLUMN email    ADD MASKED WITH (FUNCTION = 'email()');
ALTER TABLE archivo.terceros ALTER COLUMN telefono ADD MASKED WITH (FUNCTION = 'partial(0,"XXXXXX",3)');
GO

/* ---------------------------------------------------------------------
   4. Demostración: el mismo SELECT con tres usuarios distintos
   --------------------------------------------------------------------- */
PRINT '--- usr_admin: ve todos los documentos y los datos sin máscara';
EXECUTE AS USER = 'usr_admin';
    SELECT USER_NAME() AS usuario, tipo, COUNT(*) AS documentos FROM archivo.documentos GROUP BY tipo;
    SELECT TOP (3) nombre, nif, email, telefono FROM archivo.terceros ORDER BY tercero_id;
REVERT;

PRINT '--- usr_contable: no ve los contratos; NIF, email y teléfono enmascarados';
EXECUTE AS USER = 'usr_contable';
    SELECT USER_NAME() AS usuario, tipo, COUNT(*) AS documentos FROM archivo.documentos GROUP BY tipo;
    SELECT TOP (3) nombre, nif, email, telefono FROM archivo.terceros ORDER BY tercero_id;
REVERT;

PRINT '--- usr_legal: solo ve contratos y no puede leer NIF ni email';
EXECUTE AS USER = 'usr_legal';
    SELECT USER_NAME() AS usuario, tipo, COUNT(*) AS documentos FROM archivo.documentos GROUP BY tipo;
    SELECT USER_NAME() AS usuario, COUNT(*) AS fragmentos_visibles FROM archivo.fragmentos;
    BEGIN TRY
        SELECT TOP (1) nif FROM archivo.terceros;
    END TRY
    BEGIN CATCH
        SELECT USER_NAME() AS usuario, ERROR_MESSAGE() AS denegado;
    END CATCH
    BEGIN TRY
        DELETE FROM archivo.documentos WHERE documento_id = 1;
    END TRY
    BEGIN CATCH
        SELECT USER_NAME() AS usuario, ERROR_MESSAGE() AS denegado;
    END CATCH
REVERT;
GO

/* =====================================================================
   Mnemos Archive · 01_create_database.sql
   Crea la base de datos MnemosArchive y la deja preparada para las
   funciones nuevas de SQL Server 2025 (vectores, regex, IA).
   Ejecutar conectado a la instancia SQL Server 2025 (p. ej. .\SQL2025).
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE master;
GO

IF DB_ID(N'MnemosArchive') IS NULL
BEGIN
    -- Intercalación insensible a mayúsculas y acentos:
    -- "garcia" encuentra "García" y "FACTURA" encuentra "factura".
    CREATE DATABASE MnemosArchive COLLATE Latin1_General_100_CI_AI_SC;
    PRINT 'Base de datos MnemosArchive creada.';
END
ELSE
    PRINT 'La base de datos MnemosArchive ya existe.';
GO

-- Nivel 170 = SQL Server 2025: necesario para REGEXP_LIKE y AI_GENERATE_CHUNKS.
ALTER DATABASE MnemosArchive SET COMPATIBILITY_LEVEL = 170;
GO

USE MnemosArchive;
GO

-- Funciones en preview que usamos: fuzzy matching (JARO_WINKLER_SIMILARITY,
-- EDIT_DISTANCE) e índice vectorial opcional.
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO

IF SCHEMA_ID(N'archivo') IS NULL
    EXEC (N'CREATE SCHEMA archivo AUTHORIZATION dbo;');
GO

PRINT 'Base de datos lista (compatibilidad 170, preview activado, esquema archivo).';
GO

/* =====================================================================
   Mnemos Archive · 02_create_tables.sql
   Modelo de datos:
     terceros          clientes y proveedores
     documentos        un archivo por fila (factura, contrato, presupuesto...)
     campos_extraidos  datos estructurados que lee la IA (total, fecha...)
     fragmentos        trozos de texto con su embedding vector(1024)
     auditoria         registro de correcciones y borrados (lo llenan triggers)
     consultas_rag     historial de preguntas RAG con su contexto y respuesta
   El script se puede ejecutar varias veces: borra y recrea las tablas.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

-- Si ya se ejecutó 09_security.sql, la política RLS está ligada a las tablas
DROP SECURITY POLICY IF EXISTS archivo.politica_departamento;
DROP FUNCTION IF EXISTS archivo.fn_rls_documento;
DROP FUNCTION IF EXISTS archivo.fn_rls_departamento;
GO

-- Orden inverso a las dependencias
DROP TABLE IF EXISTS archivo.consultas_rag;
DROP TABLE IF EXISTS archivo.auditoria;
DROP TABLE IF EXISTS archivo.fragmentos;
DROP TABLE IF EXISTS archivo.campos_extraidos;
DROP TABLE IF EXISTS archivo.documentos;
DROP TABLE IF EXISTS archivo.terceros;
GO

/* ---------------------------------------------------------------------
   terceros
   --------------------------------------------------------------------- */
CREATE TABLE archivo.terceros
(
    tercero_id   int IDENTITY(1,1) NOT NULL,
    nombre       nvarchar(200)     NOT NULL,
    nif          varchar(12)       NOT NULL,
    tipo         varchar(10)       NOT NULL,
    email        varchar(200)      NULL,
    telefono     varchar(20)       NULL,
    ciudad       nvarchar(100)     NULL,
    fecha_alta   datetime2(0)      NOT NULL CONSTRAINT DF_terceros_fecha_alta DEFAULT (sysutcdatetime()),

    CONSTRAINT PK_terceros PRIMARY KEY (tercero_id),
    CONSTRAINT UQ_terceros_nif UNIQUE (nif),
    CONSTRAINT CK_terceros_tipo CHECK (tipo IN ('cliente', 'proveedor', 'ambos')),
    CONSTRAINT CK_terceros_email CHECK (email IS NULL OR email LIKE '%_@_%._%')
);
GO

/* ---------------------------------------------------------------------
   documentos
   departamento decide quién puede verlo (Row-Level Security, 09_security)
   --------------------------------------------------------------------- */
CREATE TABLE archivo.documentos
(
    documento_id     int IDENTITY(1,1) NOT NULL,
    nombre_archivo   nvarchar(260)     NOT NULL,
    hash_sha256      binary(32)        NOT NULL,   -- evita archivar dos veces el mismo archivo
    tipo             varchar(20)       NOT NULL CONSTRAINT DF_documentos_tipo DEFAULT ('sin_clasificar'),
    direccion        varchar(10)       NULL,       -- emitido (lo enviamos) / recibido (nos lo envían)
    departamento     varchar(20)       NOT NULL CONSTRAINT DF_documentos_departamento DEFAULT ('contabilidad'),
    tercero_id       int               NULL,
    numero           nvarchar(50)      NULL,       -- nº de factura, contrato...
    fecha_documento  date              NULL,
    importe_total    decimal(12,2)     NULL,
    moneda           char(3)           NOT NULL CONSTRAINT DF_documentos_moneda DEFAULT ('EUR'),
    paginas          smallint          NOT NULL CONSTRAINT DF_documentos_paginas DEFAULT (1),
    texto            nvarchar(max)     NULL,       -- texto completo del documento
    estado           varchar(12)       NOT NULL CONSTRAINT DF_documentos_estado DEFAULT ('pendiente'),
    fecha_alta       datetime2(0)      NOT NULL CONSTRAINT DF_documentos_fecha_alta DEFAULT (sysutcdatetime()),
    conservar_hasta  date              NULL,       -- plazo de conservación (RGPD)

    CONSTRAINT PK_documentos PRIMARY KEY (documento_id),
    CONSTRAINT UQ_documentos_hash UNIQUE (hash_sha256),
    CONSTRAINT FK_documentos_terceros FOREIGN KEY (tercero_id) REFERENCES archivo.terceros (tercero_id),
    CONSTRAINT CK_documentos_tipo CHECK (tipo IN ('factura', 'contrato', 'presupuesto', 'recibo', 'otro', 'sin_clasificar')),
    CONSTRAINT CK_documentos_direccion CHECK (direccion IS NULL OR direccion IN ('emitido', 'recibido')),
    CONSTRAINT CK_documentos_departamento CHECK (departamento IN ('contabilidad', 'legal')),
    CONSTRAINT CK_documentos_estado CHECK (estado IN ('pendiente', 'procesado', 'error')),
    CONSTRAINT CK_documentos_importe CHECK (importe_total IS NULL OR importe_total >= 0),
    CONSTRAINT CK_documentos_paginas CHECK (paginas >= 1),
    CONSTRAINT CK_documentos_moneda CHECK (moneda LIKE '[A-Z][A-Z][A-Z]')
);
GO

/* ---------------------------------------------------------------------
   campos_extraidos: un valor por campo y documento, con tipo real
   para poder sumar y filtrar en SQL (las cifras se calculan, no se estiman)
   --------------------------------------------------------------------- */
CREATE TABLE archivo.campos_extraidos
(
    campo_id          int IDENTITY(1,1) NOT NULL,
    documento_id      int               NOT NULL,
    nombre_campo      varchar(40)       NOT NULL,   -- emisor, nif, fecha, total, base_imponible, iva...
    valor_texto       nvarchar(400)     NULL,
    valor_numero      decimal(12,2)     NULL,
    valor_fecha       date              NULL,
    confianza         decimal(4,3)      NULL,       -- 0,000 a 1,000
    pagina            smallint          NULL,
    fragmento_origen  nvarchar(400)     NULL,       -- texto del que se leyó (para citar)
    extraido_por      varchar(60)       NOT NULL CONSTRAINT DF_campos_extraido_por DEFAULT ('manual'),
    corregido         bit               NOT NULL CONSTRAINT DF_campos_corregido DEFAULT (0),
    fecha_extraccion  datetime2(0)      NOT NULL CONSTRAINT DF_campos_fecha DEFAULT (sysutcdatetime()),

    CONSTRAINT PK_campos_extraidos PRIMARY KEY (campo_id),
    CONSTRAINT FK_campos_documentos FOREIGN KEY (documento_id)
        REFERENCES archivo.documentos (documento_id) ON DELETE CASCADE,
    CONSTRAINT UQ_campos_documento_nombre UNIQUE (documento_id, nombre_campo),
    CONSTRAINT CK_campos_confianza CHECK (confianza IS NULL OR confianza BETWEEN 0 AND 1),
    CONSTRAINT CK_campos_tiene_valor CHECK (valor_texto IS NOT NULL OR valor_numero IS NOT NULL OR valor_fecha IS NOT NULL)
);
GO

/* ---------------------------------------------------------------------
   fragmentos: texto troceado + embedding (bge-m3 -> 1024 dimensiones)
   --------------------------------------------------------------------- */
CREATE TABLE archivo.fragmentos
(
    fragmento_id     int IDENTITY(1,1) NOT NULL,
    documento_id     int               NOT NULL,
    orden            int               NOT NULL,
    pagina           smallint          NOT NULL CONSTRAINT DF_fragmentos_pagina DEFAULT (1),
    texto            nvarchar(max)     NOT NULL,
    embedding        vector(1024)      NULL,
    modelo           varchar(60)       NULL,
    fecha_embedding  datetime2(0)      NULL,

    CONSTRAINT PK_fragmentos PRIMARY KEY (fragmento_id),
    CONSTRAINT FK_fragmentos_documentos FOREIGN KEY (documento_id)
        REFERENCES archivo.documentos (documento_id) ON DELETE CASCADE,
    CONSTRAINT UQ_fragmentos_documento_orden UNIQUE (documento_id, orden),
    CONSTRAINT CK_fragmentos_orden CHECK (orden >= 1)
);
GO

/* ---------------------------------------------------------------------
   auditoria: la escriben los triggers de 07_triggers.sql
   --------------------------------------------------------------------- */
CREATE TABLE archivo.auditoria
(
    auditoria_id    bigint IDENTITY(1,1) NOT NULL,
    tabla           sysname        NOT NULL,
    accion          varchar(10)    NOT NULL,
    registro_id     int            NOT NULL,
    detalle         nvarchar(max)  NULL,        -- JSON con valores antes / después
    usuario         sysname        NOT NULL CONSTRAINT DF_auditoria_usuario DEFAULT (USER_NAME()),
    fecha           datetime2(3)   NOT NULL CONSTRAINT DF_auditoria_fecha DEFAULT (sysutcdatetime()),

    CONSTRAINT PK_auditoria PRIMARY KEY (auditoria_id),
    CONSTRAINT CK_auditoria_accion CHECK (accion IN ('INSERT', 'UPDATE', 'DELETE')),
    CONSTRAINT CK_auditoria_detalle_json CHECK (detalle IS NULL OR ISJSON(detalle) = 1)
);
GO

/* ---------------------------------------------------------------------
   consultas_rag: trazabilidad de cada pregunta (pregunta, documentos,
   contexto enviado al modelo y respuesta)
   --------------------------------------------------------------------- */
CREATE TABLE archivo.consultas_rag
(
    consulta_id           int IDENTITY(1,1) NOT NULL,
    pregunta              nvarchar(1000)  NOT NULL,
    documentos_json       nvarchar(max)   NULL,
    contexto              nvarchar(max)   NULL,
    respuesta             nvarchar(max)   NULL,
    modelo_llm            varchar(60)     NULL,
    duracion_ms           int             NULL,
    usuario               sysname         NOT NULL CONSTRAINT DF_consultas_usuario DEFAULT (USER_NAME()),
    fecha                 datetime2(0)    NOT NULL CONSTRAINT DF_consultas_fecha DEFAULT (sysutcdatetime()),

    CONSTRAINT PK_consultas_rag PRIMARY KEY (consulta_id),
    CONSTRAINT CK_consultas_docs_json CHECK (documentos_json IS NULL OR ISJSON(documentos_json) = 1)
);
GO

PRINT 'Tablas creadas: terceros, documentos, campos_extraidos, fragmentos, auditoria, consultas_rag.';
GO

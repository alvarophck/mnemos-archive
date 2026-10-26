/* =====================================================================
   Mnemos Archive · 03_insert_data.sql
   Datos de prueba INVENTADOS para "Estudio Ámbar S.L.", un pequeño
   estudio de diseño. Ninguna persona, empresa ni NIF es real.
     - 11 terceros (clientes y proveedores)
     - 22 documentos con su texto completo
         · 18 ya clasificados, con sus campos verificados a mano
         ·  4 "sin_clasificar": solo texto, para que la IA los lea
           (ai/07_classify_and_extract.sql)
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO
SET NOCOUNT ON;
GO

-- Permite volver a cargar los datos desde cero
DELETE FROM archivo.consultas_rag;
DELETE FROM archivo.documentos;   -- borra en cascada campos y fragmentos
DELETE FROM archivo.terceros;
DELETE FROM archivo.auditoria;    -- después: los triggers registran los borrados anteriores

-- Reinicia los identificadores solo en las tablas que ya tuvieron filas
-- (en una tabla recién creada, RESEED 0 haría que el primer id fuese 0)
DECLARE @tabla sysname, @sql nvarchar(400);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT QUOTENAME(SCHEMA_NAME(t.schema_id)) + '.' + QUOTENAME(t.name)
    FROM sys.identity_columns AS ic
    JOIN sys.tables AS t ON t.object_id = ic.object_id
    WHERE SCHEMA_NAME(t.schema_id) = 'archivo' AND ic.last_value IS NOT NULL;
OPEN c;
FETCH NEXT FROM c INTO @tabla;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'DBCC CHECKIDENT (''' + @tabla + N''', RESEED, 0) WITH NO_INFOMSGS;';
    EXEC (@sql);
    FETCH NEXT FROM c INTO @tabla;
END
CLOSE c; DEALLOCATE c;
GO

/* ---------------------------------------------------------------------
   Terceros
   --------------------------------------------------------------------- */
INSERT INTO archivo.terceros (nombre, nif, tipo, email, telefono, ciudad)
VALUES
 (N'Pedro García Ruiz',               '12345678Z', 'cliente',   'pedro.garcia@correo-ejemplo.es',   '600111222', N'Madrid'),
 (N'Tecnologías Arganzuela S.L.',     'B84512367', 'proveedor', 'facturas@arganzuela-tec.example',  '910000101', N'Madrid'),
 (N'Imprenta Lavapiés S.L.',          'B86234519', 'proveedor', 'pedidos@imprenta-lavapies.example','910000102', N'Madrid'),
 (N'Gestoría Moncloa S.L.',           'B87123458', 'proveedor', 'clientes@gestoria-moncloa.example','910000103', N'Madrid'),
 (N'Construcciones Vallecas S.A.',    'A28765432', 'cliente',   'compras@cvallecas.example',        '910000104', N'Madrid'),
 (N'Café Malasaña S.L.',              'B88345671', 'cliente',   'hola@cafemalasana.example',        '910000105', N'Madrid'),
 (N'Energía Clara S.A.',              'A81234567', 'proveedor', 'atencion@energiaclara.example',    '900000106', N'Bilbao'),
 (N'Transportes Henares S.L.',        'B19876543', 'proveedor', 'admin@thenares.example',           '949000107', N'Guadalajara'),
 (N'Laura Méndez Ortega',             '50123456K', 'cliente',   'laura.mendez@correo-ejemplo.es',   '600333444', N'Toledo'),
 (N'Inmobiliaria Retiro S.L.',        'B85678912', 'proveedor', 'alquileres@inmoretiro.example',    '910000109', N'Madrid'),
 (N'Papelería Chamberí S.L.',         'B83456781', 'proveedor', 'ventas@papeleria-chamberi.example','910000110', N'Madrid');
GO

/* ---------------------------------------------------------------------
   Documentos
   --------------------------------------------------------------------- */
DECLARE @d TABLE
(
    archivo      nvarchar(260),
    tipo         varchar(20),
    direccion    varchar(10),
    departamento varchar(20),
    nif          varchar(12),
    numero       nvarchar(50),
    fecha        date,
    total        decimal(12,2),
    paginas      smallint,
    texto        nvarchar(max)
);

INSERT INTO @d VALUES
-- ===================== Facturas emitidas (contabilidad) =====================
(N'factura-2026-014.pdf','factura','emitido','contabilidad','12345678Z',N'2026-014','2026-02-10',1210.00,1,
N'FACTURA Nº 2026-014
Emisor: Estudio Ámbar S.L. · NIF B12345674 · Calle del Pez 12, 28004 Madrid
Cliente: Pedro García Ruiz · NIF 12345678Z · Madrid
Fecha de emisión: 10/02/2026 · Vencimiento: 10/03/2026
Concepto: Diseño de identidad visual para su consulta de fisioterapia (logotipo, paleta de color y tarjetas de visita).
Base imponible: 1.000,00 EUR
IVA 21 %: 210,00 EUR
TOTAL: 1.210,00 EUR
Forma de pago: transferencia a ES00 0000 0000 0000 0000 0001'),

(N'factura-2026-031.pdf','factura','emitido','contabilidad','12345678Z',N'2026-031','2026-05-06',2100.00,1,
N'FACTURA Nº 2026-031
Emisor: Estudio Ámbar S.L. · NIF B12345674
Cliente: Pedro García Ruiz · NIF 12345678Z
Fecha de emisión: 06/05/2026
Concepto: Diseño y maquetación de la página web de la consulta, cinco secciones, adaptada a móvil.
Base imponible: 1.735,54 EUR
IVA 21 %: 364,46 EUR
TOTAL: 2.100,00 EUR'),

(N'factura-2026-048.pdf','factura','emitido','contabilidad','12345678Z',N'2026-048','2026-09-15',1510.00,2,
N'FACTURA Nº 2026-048
Emisor: Estudio Ámbar S.L. · NIF B12345674
Cliente: Pedro García Ruiz · NIF 12345678Z
Fecha de emisión: 15/09/2026
Concepto: Campaña de otoño: cartelería, folletos y adaptación para redes sociales.
[página 2]
Detalle: 3 carteles A3, 500 folletos díptico, 12 piezas para redes.
Base imponible: 1.247,93 EUR
IVA 21 %: 262,07 EUR
TOTAL: 1.510,00 EUR'),

(N'factura-2026-022.pdf','factura','emitido','contabilidad','A28765432',N'2026-022','2026-03-30',6050.00,1,
N'FACTURA Nº 2026-022
Emisor: Estudio Ámbar S.L. · NIF B12345674
Cliente: Construcciones Vallecas S.A. · NIF A28765432
Fecha de emisión: 30/03/2026
Concepto: Primer hito del contrato de señalética de obra: diseño de 40 carteles de seguridad y lonas de fachada.
Base imponible: 5.000,00 EUR
IVA 21 %: 1.050,00 EUR
TOTAL: 6.050,00 EUR'),

(N'factura-2026-037.pdf','factura','emitido','contabilidad','B88345671',N'2026-037','2026-06-20',968.00,1,
N'FACTURA Nº 2026-037
Emisor: Estudio Ámbar S.L. · NIF B12345674
Cliente: Café Malasaña S.L. · NIF B88345671
Fecha de emisión: 20/06/2026
Concepto: Rediseño de la carta y menú de verano, versión impresa y digital.
Base imponible: 800,00 EUR
IVA 21 %: 168,00 EUR
TOTAL: 968,00 EUR'),

(N'factura-2026-041.pdf','factura','emitido','contabilidad','50123456K',N'2026-041','2026-07-14',726.00,1,
N'FACTURA Nº 2026-041
Emisor: Estudio Ámbar S.L. · NIF B12345674
Cliente: Laura Méndez Ortega · NIF 50123456K
Fecha de emisión: 14/07/2026
Concepto: Ilustraciones para portfolio, 6 piezas.
Base imponible: 600,00 EUR
IVA 21 %: 126,00 EUR
TOTAL: 726,00 EUR'),

-- ===================== Facturas recibidas (contabilidad) =====================
(N'arganzuela-hosting-enero.pdf','factura','recibido','contabilidad','B84512367',N'TA-26-0107','2026-01-31',72.60,1,
N'Tecnologías Arganzuela S.L. · NIF B84512367
FACTURA TA-26-0107 · Fecha 31/01/2026
Cliente: Estudio Ámbar S.L. · NIF B12345674
Servicio de alojamiento web y correo, plan Profesional, enero 2026.
Base imponible: 60,00 EUR · IVA 21 %: 12,60 EUR · TOTAL: 72,60 EUR
Cargo por domiciliación bancaria.'),

(N'arganzuela-hosting-febrero.pdf','factura','recibido','contabilidad','B84512367',N'TA-26-0219','2026-02-28',72.60,1,
N'Tecnologías Arganzuela S.L. · NIF B84512367
FACTURA TA-26-0219 · Fecha 28/02/2026
Cliente: Estudio Ámbar S.L.
Servicio de alojamiento web y correo, plan Profesional, febrero 2026.
Base imponible: 60,00 EUR · IVA 21 %: 12,60 EUR · TOTAL: 72,60 EUR'),

(N'imprenta-lavapies-0458.pdf','factura','recibido','contabilidad','B86234519',N'IL-0458','2026-09-10',423.50,1,
N'IMPRENTA LAVAPIÉS S.L. · NIF B86234519
Factura IL-0458 · 10/09/2026
Cliente: Estudio Ámbar S.L.
Impresión de 500 folletos díptico en papel estucado de 170 g y 3 carteles A3.
Base imponible: 350,00 EUR · IVA 21 %: 73,50 EUR
TOTAL A PAGAR: 423,50 EUR'),

(N'gestoria-moncloa-t1.pdf','factura','recibido','contabilidad','B87123458',N'GM-2026-T1-077','2026-04-05',217.80,1,
N'Gestoría Moncloa S.L. · NIF B87123458
Factura GM-2026-T1-077 · 05/04/2026
Honorarios de asesoría fiscal y contable, primer trimestre de 2026: presentación de los modelos 303 y 111.
Base imponible: 180,00 EUR · IVA 21 %: 37,80 EUR · TOTAL: 217,80 EUR'),

(N'gestoria-moncloa-t2.pdf','factura','recibido','contabilidad','B87123458',N'GM-2026-T2-131','2026-07-05',217.80,1,
N'Gestoría Moncloa S.L. · NIF B87123458
Factura GM-2026-T2-131 · 05/07/2026
Honorarios de asesoría fiscal y contable, segundo trimestre de 2026: modelos 303 y 111.
Base imponible: 180,00 EUR · IVA 21 %: 37,80 EUR · TOTAL: 217,80 EUR'),

(N'energia-clara-julio.pdf','factura','recibido','contabilidad','A81234567',N'EC-7781203','2026-07-31',96.32,1,
N'ENERGÍA CLARA S.A. · NIF A81234567
Factura de electricidad EC-7781203 · Periodo 01/07/2026 - 31/07/2026
Titular: Estudio Ámbar S.L. · Suministro: Calle del Pez 12, Madrid
Consumo: 412 kWh. Potencia contratada: 4,6 kW.
Importe total: 96,32 EUR (impuestos incluidos)'),

-- ===================== Presupuestos (contabilidad) =====================
(N'presupuesto-cafe-malasana-web.pdf','presupuesto','emitido','contabilidad','B88345671',N'P-2026-019','2026-09-02',3025.00,1,
N'PRESUPUESTO P-2026-019 · 02/09/2026
De: Estudio Ámbar S.L. · Para: Café Malasaña S.L.
Proyecto: tienda online de café en grano con pasarela de pago y 20 fichas de producto.
Plazo de entrega: 8 semanas desde la aceptación.
Validez de la oferta: 30 días.
Base imponible: 2.500,00 EUR · IVA 21 %: 525,00 EUR · TOTAL: 3.025,00 EUR'),

(N'presupuesto-vallecas-fase2.pdf','presupuesto','emitido','contabilidad','A28765432',N'P-2026-024','2026-10-01',9680.00,1,
N'PRESUPUESTO P-2026-024 · 01/10/2026
De: Estudio Ámbar S.L. · Para: Construcciones Vallecas S.A.
Fase 2 de señalética: diseño de la señalización interior de 3 edificios de viviendas y planos de evacuación.
Plazo: 10 semanas. Validez: 45 días.
Base imponible: 8.000,00 EUR · IVA 21 %: 1.680,00 EUR · TOTAL: 9.680,00 EUR'),

-- ===================== Contratos (legal) =====================
(N'contrato-alquiler-oficina.pdf','contrato','recibido','legal','B85678912',N'CA-2025-118','2025-12-15',950.00,2,
N'CONTRATO DE ARRENDAMIENTO DE LOCAL DE OFICINA
Nº CA-2025-118 · Madrid, 15 de diciembre de 2025
Arrendador: Inmobiliaria Retiro S.L., NIF B85678912.
Arrendatario: Estudio Ámbar S.L., NIF B12345674.
Objeto: local de 65 m2 en Calle del Pez 12, bajo, 28004 Madrid, para uso de oficina.
Cláusula 1. Duración: un año desde el 1 de enero de 2026, prorrogable por periodos anuales.
Cláusula 2. Renta: 950,00 EUR al mes, pagaderos los cinco primeros días de cada mes.
[página 2]
Cláusula 3. Fianza: dos mensualidades, 1.900,00 EUR.
Cláusula 4. Preaviso: cualquiera de las partes podrá resolver el contrato avisando con dos meses de antelación por escrito.
Cláusula 5. Actualización: la renta se actualizará cada año según el IPC.'),

(N'contrato-senaletica-vallecas.pdf','contrato','emitido','legal','A28765432',N'CS-2026-003','2026-02-20',15000.00,2,
N'CONTRATO DE PRESTACIÓN DE SERVICIOS DE DISEÑO
Nº CS-2026-003 · Madrid, 20 de febrero de 2026
Cliente: Construcciones Vallecas S.A., NIF A28765432.
Proveedor: Estudio Ámbar S.L., NIF B12345674.
Objeto: diseño de la señalética de obra y de fachada para la promoción "Residencial Vallecas Sur".
Cláusula 1. Precio: 15.000,00 EUR más IVA, pagaderos en tres hitos.
Cláusula 2. Plazo de entrega: todos los diseños finales se entregarán antes del 30 de junio de 2026, antes del inicio del verano.
[página 2]
Cláusula 3. Penalización: por cada semana de retraso en la entrega se descontará un 2 % del precio, hasta un máximo del 10 %.
Cláusula 4. Propiedad intelectual: el cliente adquiere los derechos de uso de los diseños una vez abonado el precio total.
Cláusula 5. Confidencialidad durante la obra y dos años después.'),

(N'nda-laura-mendez.pdf','contrato','emitido','legal','50123456K',N'NDA-2026-007','2026-06-01',NULL,1,
N'ACUERDO DE CONFIDENCIALIDAD
Nº NDA-2026-007 · 1 de junio de 2026
Partes: Estudio Ámbar S.L. (NIF B12345674) y Laura Méndez Ortega (NIF 50123456K), ilustradora colaboradora.
Las partes se obligan a no divulgar la información de clientes a la que tengan acceso durante la colaboración.
Duración de la obligación: tres años desde la firma.
Incumplimiento: indemnización por los daños y perjuicios causados.'),

(N'contrato-mantenimiento-web.pdf','contrato','recibido','legal','B84512367',N'TA-SLA-2026','2026-01-10',600.00,1,
N'CONTRATO DE MANTENIMIENTO Y SOPORTE
Nº TA-SLA-2026 · 10 de enero de 2026
Proveedor: Tecnologías Arganzuela S.L. (NIF B84512367). Cliente: Estudio Ámbar S.L.
Servicio: mantenimiento de servidores y copias de seguridad diarias.
Precio: 600,00 EUR al año.
Tiempo de respuesta ante incidencias críticas: 4 horas laborables. Incidencias normales: 2 días laborables.
Duración: un año, renovable automáticamente salvo aviso con un mes de antelación.'),

-- ===================== Sin clasificar: solo texto (para la IA) =====================
(N'escaneo-0001.pdf','sin_clasificar',NULL,'contabilidad',NULL,NULL,NULL,NULL,1,
N'TRANSPORTES HENARES S.L. - CIF B19876543
Fra. num. TH/2026/0912   Fecha: 12-09-2026
A la atención de: Estudio Ámbar S.L.
Servicio de mensajería urgente: entrega de material impreso Madrid - Guadalajara, 2 bultos.
Base 85,00 € | IVA (21%) 17,85 € | Total 102,85 €'),

(N'escaneo-0002.pdf','sin_clasificar',NULL,'contabilidad',NULL,NULL,NULL,NULL,1,
N'Papelería Chamberí S.L. (B83456781)
Presupuesto nº PCH-311 del 03/10/2026 para Estudio Ámbar
- 10 resmas de papel A4 de 90 g
- 4 cartuchos de tinta para plotter
Importe total con IVA: 387,20 euros. Oferta válida 15 días.'),

(N'escaneo-0003.pdf','sin_clasificar',NULL,'contabilidad',NULL,NULL,NULL,NULL,1,
N'Energia Clara SA · A81234567 · Factura EC-7790415
Periodo de facturación: 01/08/2026 a 31/08/2026
Titular: Estudio Ambar SL
Consumo 388 kWh
Total factura 91,07 EUR, impuestos incluidos'),

(N'escaneo-0004.pdf','sin_clasificar',NULL,'contabilidad',NULL,NULL,NULL,NULL,1,
N'Recibí de Café Malasaña S.L. la cantidad de 484,00 euros en concepto de anticipo del 50 % del rediseño de la carta de invierno.
Madrid, 8 de octubre de 2026.
Firmado: Estudio Ámbar S.L.');

INSERT INTO archivo.documentos
    (nombre_archivo, hash_sha256, tipo, direccion, departamento, tercero_id,
     numero, fecha_documento, importe_total, paginas, texto, estado, conservar_hasta)
SELECT d.archivo,
       HASHBYTES('SHA2_256', d.texto),
       d.tipo, d.direccion, d.departamento, t.tercero_id,
       d.numero, d.fecha, d.total, d.paginas, d.texto,
       CASE WHEN d.tipo = 'sin_clasificar' THEN 'pendiente' ELSE 'procesado' END,
       -- Obligación mercantil: conservar 6 años los documentos contables
       CASE WHEN d.fecha IS NOT NULL THEN DATEADD(YEAR, 6, d.fecha) END
FROM @d AS d
LEFT JOIN archivo.terceros AS t ON t.nif = d.nif;
GO

/* ---------------------------------------------------------------------
   Campos extraídos de los documentos ya clasificados
   (verificados a mano: extraido_por = 'manual', confianza = 1)
   --------------------------------------------------------------------- */
-- Campos comunes que salen de la propia fila del documento
INSERT INTO archivo.campos_extraidos (documento_id, nombre_campo, valor_texto, valor_numero, valor_fecha, confianza, pagina)
SELECT d.documento_id, v.nombre_campo, v.valor_texto, v.valor_numero, v.valor_fecha, 1.000, 1
FROM archivo.documentos AS d
JOIN archivo.terceros AS t ON t.tercero_id = d.tercero_id
CROSS APPLY (VALUES
    ('numero',          d.numero,  NULL,            NULL),
    ('fecha',           NULL,      NULL,            d.fecha_documento),
    ('contraparte',     t.nombre,  NULL,            NULL),
    ('nif_contraparte', t.nif,     NULL,            NULL),
    ('total',           NULL,      d.importe_total, NULL)
) AS v (nombre_campo, valor_texto, valor_numero, valor_fecha)
WHERE d.tipo <> 'sin_clasificar'
  AND (v.valor_texto IS NOT NULL OR v.valor_numero IS NOT NULL OR v.valor_fecha IS NOT NULL);

-- Base imponible e IVA de facturas y presupuestos (cuando el documento los desglosa)
INSERT INTO archivo.campos_extraidos (documento_id, nombre_campo, valor_numero, confianza, pagina)
SELECT d.documento_id, v.nombre_campo, v.importe, 1.000, d.paginas
FROM archivo.documentos AS d
JOIN (VALUES
    (N'2026-014',  1000.00,  210.00), (N'2026-031', 1735.54, 364.46), (N'2026-048', 1247.93, 262.07),
    (N'2026-022',  5000.00, 1050.00), (N'2026-037',  800.00, 168.00), (N'2026-041',  600.00, 126.00),
    (N'TA-26-0107',  60.00,   12.60), (N'TA-26-0219',  60.00,  12.60), (N'IL-0458',  350.00,  73.50),
    (N'GM-2026-T1-077', 180.00, 37.80), (N'GM-2026-T2-131', 180.00, 37.80),
    (N'P-2026-019', 2500.00,  525.00), (N'P-2026-024', 8000.00, 1680.00)
) AS b (numero, base, iva) ON b.numero = d.numero
CROSS APPLY (VALUES ('base_imponible', b.base), ('iva', b.iva)) AS v (nombre_campo, importe);

-- Campos propios de los contratos
INSERT INTO archivo.campos_extraidos (documento_id, nombre_campo, valor_texto, valor_numero, valor_fecha, confianza, pagina, fragmento_origen)
SELECT d.documento_id, v.nombre_campo, v.valor_texto, v.valor_numero, v.valor_fecha, 1.000, v.pagina, v.fragmento
FROM archivo.documentos AS d
JOIN (VALUES
    (N'CA-2025-118', 'fecha_inicio',   NULL,               NULL,     CAST('2026-01-01' AS date), 1, N'Duración: un año desde el 1 de enero de 2026'),
    (N'CA-2025-118', 'renta_mensual',  NULL,               950.00,   NULL, 1, N'Renta: 950,00 EUR al mes'),
    (N'CA-2025-118', 'preaviso',       N'2 meses',         NULL,     NULL, 2, N'avisando con dos meses de antelación por escrito'),
    (N'CS-2026-003', 'fecha_entrega',  NULL,               NULL,     CAST('2026-06-30' AS date), 1, N'se entregarán antes del 30 de junio de 2026'),
    (N'CS-2026-003', 'penalizacion',   N'2 % por semana, máx. 10 %', NULL, NULL, 2, N'se descontará un 2 % del precio, hasta un máximo del 10 %'),
    (N'NDA-2026-007','duracion',       N'3 años',          NULL,     NULL, 1, N'tres años desde la firma'),
    (N'TA-SLA-2026', 'respuesta_critica', N'4 horas laborables', NULL, NULL, 1, N'incidencias críticas: 4 horas laborables')
) AS v (numero, nombre_campo, valor_texto, valor_numero, valor_fecha, pagina, fragmento) ON v.numero = d.numero;
GO

SELECT 'terceros' AS tabla, COUNT(*) AS filas FROM archivo.terceros
UNION ALL SELECT 'documentos', COUNT(*) FROM archivo.documentos
UNION ALL SELECT 'campos_extraidos', COUNT(*) FROM archivo.campos_extraidos;
GO

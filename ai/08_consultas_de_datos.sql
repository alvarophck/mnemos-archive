/* =====================================================================
   Mnemos Archive · ai/08_consultas_de_datos.sql
   Preguntas de datos en lenguaje natural:
     "¿En cuántos contratos aparece Tecnologías Arganzuela, cuánto les he
      pagado este año y en qué fechas?"

   El RAG (ai/09) no sirve para esto: recupera unos pocos fragmentos y no
   puede contar ni sumar todo el archivo. Aquí el trabajo se reparte así:

     1. ENTENDER   usp_interpretar_pregunta
                   El LLM NO responde. Solo convierte la pregunta en un JSON
                   con campos fijos (tipo de pregunta, tercero, periodo).
                   No escribe SQL: no puede romper nada ni saltarse permisos.
     2. CALCULAR   usp_consultar_datos
                   T-SQL busca el tercero (sin tildes, nombre parcial o
                   Jaro-Winkler) y cuenta, suma y lista las fechas.
                   Row-Level Security se aplica igual que en el resto.
     3. REDACTAR   usp_preguntar_datos
                   El LLM convierte esas cifras en una respuesta normal.
                   Después T-SQL comprueba que cada número de la respuesta
                   está en los datos calculados. Si el modelo ha cambiado o
                   inventado una cifra, se descarta su texto y se devuelven
                   los datos tal cual.
     2b. OPERAR   usp_calcular_operacion
                   Si se pide una cuenta con esas cifras ("el doble", "el 21 %",
                   "la media por factura", "cuánto más que el año pasado"), el
                   modelo solo dice cuál es; la hace T-SQL. Lista cerrada: lo que
                   no está en ella se responde con "Ese cálculo no lo hago".
                   El modelo nunca escribe cuentas: si las escribe, se descartan.

   El enrutador archivo.usp_preguntar (ai/09) decide cada vez si la
   pregunta va por aquí o por el RAG.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

/* ---------------------------------------------------------------------
   0. Operaciones con las cifras: ni el modelo las hace ni se le piden.
      Funciones de tabla en línea (no escalares): con REGEXP_* son las que
      se han comportado bien en la RTM y en las CU.
   --------------------------------------------------------------------- */

-- ¿La pregunta pide operar con las cifras? (el doble, un porcentaje, una media...)
CREATE OR ALTER FUNCTION archivo.fn_pide_calculo_extra (@pregunta nvarchar(1000))
RETURNS TABLE
AS
RETURN
    SELECT CAST(CASE WHEN REGEXP_LIKE(@pregunta,
               N'(?i)(doble|triple|mitad|porcentaje|%|por ciento|media|promedio|diferencia|multiplic|divid|proyecci|prorrat|reparti|double|triple|half|percent|average|difference|multipl|divide|prorat|split)')
           THEN 1 ELSE 0 END AS bit) AS si;
GO

-- ¿La respuesta del modelo contiene una operación? ("72,60 EUR × 2 = 145,20", "el doble es...")
CREATE OR ALTER FUNCTION archivo.fn_tiene_operacion (@respuesta nvarchar(4000))
RETURNS TABLE
AS
RETURN
    SELECT CAST(CASE WHEN REGEXP_LIKE(@respuesta, N'\d\s*(EUR|€)?\s*[×xX*÷+=]\s*\d')
                       OR REGEXP_LIKE(@respuesta, N'(?i)(el doble|la mitad|multiplicad|dividid|twice|doubled|halved)')
           THEN 1 ELSE 0 END AS bit) AS si,
           -- Solo signos de operación: cuando SQL ya ha hecho la cuenta, "el doble" es una palabra válida
           CAST(CASE WHEN REGEXP_LIKE(@respuesta, N'\d\s*(EUR|€)?\s*[×xX*÷+=]\s*\d') THEN 1 ELSE 0 END AS bit) AS signos;
GO

-- Reglas sin IA para las cuentas más habituales. Si encajan, mandan sobre lo que diga el modelo:
-- "prorrateado a 14 meses" es dividir entre 14 aunque el modelo no lo vea.
CREATE OR ALTER FUNCTION archivo.fn_operacion_por_reglas (@pregunta nvarchar(1000))
RETURNS TABLE
AS
RETURN
    SELECT TOP (1) r.operacion, r.valor
    FROM (VALUES
        (1, 'porcentaje',  REGEXP_SUBSTR(@pregunta, N'(\d+(?:[.,]\d+)?)\s*(?:%|por\s*ciento|percent)', 1, 1, 'i', 1)),
        (2, 'dividir',     REGEXP_SUBSTR(@pregunta, N'(?:prorrate\w*|reparti\w*|divid\w*|prorat\w*|split\w*)\s+(?:(?:a|en|entre|por|para|into|over|by)\s+)?(\d+(?:[.,]\d+)?)', 1, 1, 'i', 1)),
        (3, 'dividir',     REGEXP_SUBSTR(@pregunta, N'\bentre\s+(\d+(?:[.,]\d+)?)\s+(?:meses|mensualidades|semanas|d[ií]as|a[ñn]os|personas|socios|partes|cuotas)', 1, 1, 'i', 1)),
        (4, 'dividir',     CASE WHEN REGEXP_LIKE(@pregunta, N'(?i)\b(mitad|half)\b') THEN N'2' END),
        (5, 'multiplicar', CASE WHEN REGEXP_LIKE(@pregunta, N'(?i)\b(doble|double|twice)\b') THEN N'2'
                                WHEN REGEXP_LIKE(@pregunta, N'(?i)\b(triple)\b') THEN N'3'
                                WHEN REGEXP_LIKE(@pregunta, N'(?i)\bcu[aá]druple\b') THEN N'4' END),
        (6, 'multiplicar', REGEXP_SUBSTR(@pregunta, N'(?:multiplic\w*)\s+(?:por\s+|by\s+)?(\d+(?:[.,]\d+)?)', 1, 1, 'i', 1)),
        (7, 'multiplicar', REGEXP_SUBSTR(@pregunta, N'(\d+(?:[.,]\d+)?)\s+veces', 1, 1, 'i', 1)),
        (8, 'media',       CASE WHEN REGEXP_LIKE(@pregunta, N'(?i)\b(media|promedio|average)\b') THEN N'' END)
    ) AS r (orden, operacion, valor)
    WHERE r.valor IS NOT NULL
    ORDER BY r.orden;
GO

/* ---------------------------------------------------------------------
   1. Entender la pregunta
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE archivo.usp_interpretar_pregunta
    @pregunta    nvarchar(1000),
    @intencion   nvarchar(max) OUTPUT,   -- {tipo_pregunta, tercero, desde, hasta, operacion, valor, sobre, desde2, hasta2} ya validado
    @duracion_ms int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @hoy  date = CAST(GETDATE() AS date);
    DECLARE @anio int  = YEAR(@hoy);
    DECLARE @a    nvarchar(4) = CAST(@anio AS nvarchar(4)), @a1 nvarchar(4) = CAST(@anio - 1 AS nvarchar(4));

    DECLARE @sistema nvarchar(max) = CONCAT(N'
Eres el intérprete de preguntas de Mnemos Archive, un archivo de facturas, contratos, presupuestos y recibos.
NO respondes la pregunta. Solo la clasificas y sacas sus filtros.
- "tipo_pregunta": "datos" si pide contar documentos, sumar importes, listar fechas, o saber cuánto se ha pagado, cobrado o facturado.
  "contenido" si pregunta qué dice un documento: cláusulas, plazos, condiciones, penalizaciones, obligaciones.
- "tercero": la empresa o persona por la que pregunta, tal como está escrita en la pregunta. "" si no menciona ninguna.
- "desde" y "hasta": el periodo en formato AAAA-MM-DD. "" si la pregunta no habla de fechas.
  Hoy es ', CONVERT(nchar(10), @hoy, 23), N'. "Este año" = ', @a, N'-01-01 a ', @a, N'-12-31. "El año pasado" = ', @a1, N'-01-01 a ', @a1, N'-12-31.
- "operacion": la cuenta que pide hacer con esas cifras. NO la hagas tú: solo di cuál es.
  "ninguna": solo pide cuántos documentos, el total pagado o facturado, o las fechas.
  "multiplicar": el doble (valor 2), el triple (3), por N.   "dividir": la mitad (2), entre 12 meses (12), prorrateado o repartido en N (N).
  "porcentaje": el 21 % (21).   "sumar" / "restar": una cantidad.   "media": la media por documento.
  "comparar_periodos": cuánto más o menos que en otro periodo.   "otra": cualquier otra cuenta.
- "valor": el número de la operación como texto ("2", "21", "50,5"). "" si no hay.
- "sobre": la cifra a la que se aplica: "pagado" (facturas y recibos recibidos), "facturado" (emitidos),
  "contratos" o "presupuestos". Si no hay operación, la que corresponda a la pregunta.
- "desde2" y "hasta2": solo en comparar_periodos, el periodo con el que se compara. "" en los demás casos.
Ejemplos:
P: ¿Cuánto le he pagado a Gestoría Moncloa este año?
R: {"tipo_pregunta":"datos","tercero":"Gestoría Moncloa","desde":"', @a, N'-01-01","hasta":"', @a, N'-12-31","operacion":"ninguna","valor":"","sobre":"pagado","desde2":"","hasta2":""}
P: ¿Qué penalización hay si entregamos tarde los diseños a Vallecas?
R: {"tipo_pregunta":"contenido","tercero":"Vallecas","desde":"","hasta":"","operacion":"ninguna","valor":"","sobre":"contratos","desde2":"","hasta2":""}
P: ¿Cuánto es el doble de lo que le he pagado a Imprenta Lavapiés este año?
R: {"tipo_pregunta":"datos","tercero":"Imprenta Lavapiés","desde":"', @a, N'-01-01","hasta":"', @a, N'-12-31","operacion":"multiplicar","valor":"2","sobre":"pagado","desde2":"","hasta2":""}
P: ¿Cuánto es el 21 % de lo que le facturé a Pedro García este año?
R: {"tipo_pregunta":"datos","tercero":"Pedro García","desde":"', @a, N'-01-01","hasta":"', @a, N'-12-31","operacion":"porcentaje","valor":"21","sobre":"facturado","desde2":"","hasta2":""}
P: Lo que le pagué a Gestoría Moncloa, prorrateado a 12 meses
R: {"tipo_pregunta":"datos","tercero":"Gestoría Moncloa","desde":"","hasta":"","operacion":"dividir","valor":"12","sobre":"pagado","desde2":"","hasta2":""}
P: ¿Cuánto más le he pagado a Energía Clara este año que el año pasado?
R: {"tipo_pregunta":"datos","tercero":"Energía Clara","desde":"', @a, N'-01-01","hasta":"', @a, N'-12-31","operacion":"comparar_periodos","valor":"","sobre":"pagado","desde2":"', @a1, N'-01-01","hasta2":"', @a1, N'-12-31"}');

    DECLARE @esquema nvarchar(max) = N'{
      "type": "object",
      "properties": {
        "tipo_pregunta": {"type": "string", "enum": ["datos","contenido"]},
        "tercero":       {"type": "string"},
        "desde":         {"type": "string"},
        "hasta":         {"type": "string"},
        "operacion":     {"type": "string", "enum": ["ninguna","multiplicar","dividir","porcentaje","sumar","restar","media","comparar_periodos","otra"]},
        "valor":         {"type": "string"},
        "sobre":         {"type": "string", "enum": ["pagado","facturado","contratos","presupuestos"]},
        "desde2":        {"type": "string"},
        "hasta2":        {"type": "string"}
      },
      "required": ["tipo_pregunta","tercero","desde","hasta","operacion","valor","sobre","desde2","hasta2"]
    }';

    DECLARE @json nvarchar(max);
    EXEC archivo.usp_llm_chat @sistema = @sistema, @usuario = @pregunta, @formato_json = @esquema,
                              @respuesta = @json OUTPUT, @duracion_ms = @duracion_ms OUTPUT;

    IF ISJSON(@json) <> 1
    BEGIN
        SET @intencion = NULL;   -- el enrutador lo tratará como pregunta de contenido
        RETURN;
    END

    -- Validar: nada de lo que diga el modelo se usa sin comprobarlo
    DECLARE @tipo varchar(10), @tercero nvarchar(200), @desde date, @hasta date,
            @operacion varchar(20), @valor decimal(18,4), @sobre varchar(15), @desde2 date, @hasta2 date;
    SELECT @tipo    = CASE WHEN tipo_pregunta IN ('datos', 'contenido') THEN tipo_pregunta ELSE 'contenido' END,
           @tercero = NULLIF(TRIM(tercero), N''),
           @desde   = TRY_CONVERT(date, NULLIF(TRIM(desde), ''), 23),   -- '' convertiría a 1900-01-01
           @hasta   = TRY_CONVERT(date, NULLIF(TRIM(hasta), ''), 23),
           @operacion = CASE WHEN operacion IN ('ninguna','multiplicar','dividir','porcentaje','sumar','restar','media','comparar_periodos')
                             THEN operacion ELSE 'otra' END,
           -- "2", "21 %", "50,5" o "1.250,00": solo cifras, coma decimal española
           @valor   = TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(TRIM(valor), N'%', N''), N' ', N''), N'.', N''), N',', N'.') AS decimal(18,4)),
           @sobre   = CASE WHEN sobre IN ('pagado','facturado','contratos','presupuestos') THEN sobre ELSE 'pagado' END,
           @desde2  = TRY_CONVERT(date, NULLIF(TRIM(desde2), ''), 23),
           @hasta2  = TRY_CONVERT(date, NULLIF(TRIM(hasta2), ''), 23)
    FROM OPENJSON(@json) WITH (tipo_pregunta varchar(20), tercero nvarchar(200), desde varchar(20), hasta varchar(20),
                               operacion varchar(30), valor nvarchar(40), sobre varchar(20), desde2 varchar(20), hasta2 varchar(20));

    -- Reglas sin IA: si reconocen la cuenta, mandan (el modelo pequeño a veces no la ve)
    DECLARE @op_regla varchar(20), @valor_regla nvarchar(40);
    SELECT @op_regla = operacion, @valor_regla = valor FROM archivo.fn_operacion_por_reglas(@pregunta);
    IF @op_regla IS NOT NULL
        SELECT @operacion = @op_regla,
               @valor = CASE WHEN @valor_regla = N'' THEN NULL
                             ELSE TRY_CAST(REPLACE(@valor_regla, N',', N'.') AS decimal(18,4)) END,
               @tipo = 'datos';

    -- Respaldo: si la pregunta nombra una operación que no se ha reconocido, no se responde
    -- como si fuera una pregunta normal (se diría el total donde se pedía otra cosa)
    IF @operacion = 'ninguna' AND EXISTS (SELECT 1 FROM archivo.fn_pide_calculo_extra(@pregunta) WHERE si = 1)
        SET @operacion = 'otra';

    -- Y si la pregunta trae un número que no es un año ni parte del nombre del tercero
    -- ("... a 14 meses") y no se sabe qué hacer con él, tampoco se ignora en silencio
    IF @tipo = 'datos' AND @operacion = 'ninguna'
       AND EXISTS (SELECT 1 FROM REGEXP_MATCHES(@pregunta, N'\d+(?:[.,]\d+)?') AS m
                   WHERE m.match_value NOT LIKE N'19__' AND m.match_value NOT LIKE N'20__'
                     AND (@tercero IS NULL OR CHARINDEX(m.match_value, @tercero) = 0))
        SET @operacion = 'otra';

    IF @desde > @hasta
        SELECT @desde = NULL, @hasta = NULL;   -- periodo incoherente: mejor sin filtro que con uno falso

    SET @intencion = JSON_OBJECT('tipo_pregunta' : @tipo, 'tercero' : @tercero,
                                 'desde' : CONVERT(char(10), @desde, 23), 'hasta' : CONVERT(char(10), @hasta, 23),
                                 'operacion' : @operacion, 'valor' : @valor, 'sobre' : @sobre,
                                 'desde2' : CONVERT(char(10), @desde2, 23), 'hasta2' : CONVERT(char(10), @hasta2, 23)
                                 NULL ON NULL);
END;
GO

/* ---------------------------------------------------------------------
   2. Calcular los datos (sin IA: es T-SQL determinista y se puede probar)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE archivo.usp_consultar_datos
    @tercero          nvarchar(200) = NULL,   -- nombre parcial, sin tildes o NIF; NULL = todos
    @desde            date = NULL,
    @hasta            date = NULL,
    @mostrar          bit  = 1,               -- 1: devuelve tablas (uso directo); 0: solo parámetros OUTPUT
    @datos            nvarchar(max) = NULL OUTPUT,   -- resumen en texto para el LLM
    @documentos_json  nvarchar(max) = NULL OUTPUT,   -- documentos usados (fuentes)
    @cifras_json      nvarchar(max) = NULL OUTPUT,   -- todos los números que aparecen en @datos
    @respuesta_directa nvarchar(1000) = NULL OUTPUT, -- si no hace falta el LLM (tercero no encontrado, sin datos...)
    @tercero_resuelto  int = NULL OUTPUT,            -- tercero encontrado (NULL: todos)
    @tercero_nombre_resuelto nvarchar(200) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @datos = NULL, @documentos_json = NULL, @cifras_json = NULL, @respuesta_directa = NULL,
           @tercero_resuelto = NULL, @tercero_nombre_resuelto = NULL;

    /* 2.1 Encontrar al tercero */
    DECLARE @tercero_id int, @tercero_nombre nvarchar(200);

    IF @tercero IS NOT NULL
    BEGIN
        DECLARE @candidatos TABLE (tercero_id int PRIMARY KEY, nombre nvarchar(200), similitud int);
        DECLARE @patron nvarchar(210) = CONCAT(N'%', REPLACE(REPLACE(@tercero, N'[', N'[[]'), N'_', N'[_]'), N'%');
        DECLARE @nif varchar(12) = UPPER(REPLACE(REPLACE(@tercero, '-', ''), ' ', ''));

        -- a) el nombre contiene lo escrito (sin distinguir tildes ni mayúsculas) o es su NIF
        INSERT INTO @candidatos (tercero_id, nombre, similitud)
        SELECT tercero_id, nombre, 100
        FROM archivo.terceros
        WHERE nombre COLLATE Latin1_General_CI_AI LIKE @patron COLLATE Latin1_General_CI_AI
           OR nif = @nif;

        -- b) si no, nombre aproximado (Jaro-Winkler, el mismo criterio que la ingesta)
        IF NOT EXISTS (SELECT 1 FROM @candidatos)
            INSERT INTO @candidatos (tercero_id, nombre, similitud)
            SELECT tercero_id, nombre, similitud FROM archivo.fn_buscar_tercero(@tercero, NULL);

        DECLARE @n_candidatos int = (SELECT COUNT(*) FROM @candidatos);

        IF @n_candidatos = 0
        BEGIN
            SET @respuesta_directa = CONCAT(N'No hay ningún tercero parecido a «', @tercero, N'» en el archivo.');
            IF @mostrar = 1 SELECT @respuesta_directa AS respuesta;
            RETURN;
        END

        IF @n_candidatos > 1
        BEGIN
            SET @respuesta_directa = CONCAT(N'Hay varios terceros que encajan con «', @tercero, N'»: ',
                (SELECT STRING_AGG(nombre, N', ') WITHIN GROUP (ORDER BY nombre) FROM @candidatos),
                N'. Pregunta de nuevo con el nombre completo.');
            IF @mostrar = 1 SELECT @respuesta_directa AS respuesta;
            RETURN;
        END

        SELECT @tercero_id = tercero_id, @tercero_nombre = nombre FROM @candidatos;
        SELECT @tercero_resuelto = @tercero_id, @tercero_nombre_resuelto = @tercero_nombre;
    END

    /* 2.2 Documentos del tercero (enlazados o que lo nombran en el texto).
           Row-Level Security filtra aquí lo que el usuario no puede ver. */
    DECLARE @docs TABLE
    (
        documento_id   int PRIMARY KEY,
        nombre_archivo nvarchar(260),
        tipo           varchar(20),
        direccion      varchar(10),
        tercero        nvarchar(200),
        fecha          date,
        importe        decimal(12,2),
        moneda         char(3),
        en_periodo     bit
    );

    INSERT INTO @docs
    SELECT d.documento_id, d.nombre_archivo, d.tipo,
           CASE WHEN d.tipo IN ('contrato', 'otro') THEN NULL ELSE d.direccion END,   -- un contrato es un contrato, lo firme quien lo firme
           t.nombre, d.fecha_documento,
           d.importe_total, d.moneda,
           CASE WHEN (@desde IS NULL OR d.fecha_documento >= @desde)
                 AND (@hasta IS NULL OR d.fecha_documento <= @hasta) THEN 1 ELSE 0 END
    FROM archivo.documentos AS d
    LEFT JOIN archivo.terceros AS t ON t.tercero_id = d.tercero_id
    WHERE d.tipo <> 'sin_clasificar'
      AND (@tercero_id IS NULL
           OR d.tercero_id = @tercero_id
           OR d.texto LIKE CONCAT(N'%', @tercero_nombre, N'%'));

    DECLARE @hay_periodo bit = CASE WHEN @desde IS NOT NULL OR @hasta IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @quien nvarchar(220) = ISNULL(@tercero_nombre, N'todos los terceros');

    IF NOT EXISTS (SELECT 1 FROM @docs WHERE en_periodo = 1)
    BEGIN
        SET @respuesta_directa = CONCAT(N'No hay documentos de ', @quien,
            CASE WHEN @hay_periodo = 1 THEN CONCAT(N' entre el ', FORMAT(ISNULL(@desde, '19000101'), 'd/M/yyyy'),
                                                   N' y el ', FORMAT(ISNULL(@hasta, '99991231'), 'd/M/yyyy')) END,
            N' que puedas consultar.',
            CASE WHEN EXISTS (SELECT 1 FROM @docs)
                 THEN CONCAT(N' Fuera de ese periodo hay ', (SELECT COUNT(*) FROM @docs), N'.') END);
        IF @mostrar = 1 SELECT @respuesta_directa AS respuesta;
        RETURN;
    END

    /* 2.3 Agrupar por clase de documento. Cada grupo dice qué significa su importe,
           para que "pagado" no se confunda con "facturado" ni con lo pactado en un contrato. */
    DECLARE @grupos TABLE
    (
        orden       int,
        tipo        varchar(20),
        direccion   varchar(10),
        moneda      char(3),
        etiqueta    nvarchar(120),
        docs_total  int,
        docs_periodo int,
        importe_periodo decimal(14,2),
        detalle     nvarchar(max) NULL
    );

    INSERT INTO @grupos (orden, tipo, direccion, moneda, etiqueta, docs_total, docs_periodo, importe_periodo)
    SELECT ROW_NUMBER() OVER (ORDER BY MIN(c.orden), g.direccion),
           g.tipo, g.direccion, g.moneda, MIN(c.etiqueta),
           COUNT(*), SUM(CAST(g.en_periodo AS int)),
           SUM(CASE WHEN g.en_periodo = 1 THEN g.importe END)
    FROM @docs AS g
    CROSS APPLY (SELECT
        CASE g.tipo WHEN 'contrato' THEN 1 WHEN 'factura' THEN 2 WHEN 'recibo' THEN 3 WHEN 'presupuesto' THEN 4 ELSE 5 END AS orden,
        CASE
            WHEN g.tipo = 'contrato'                                THEN N'contratos (el importe es lo pactado, no un pago)'
            WHEN g.tipo = 'factura' AND g.direccion = 'recibido'    THEN N'facturas recibidas (lo que has pagado)'
            WHEN g.tipo = 'factura' AND g.direccion = 'emitido'     THEN N'facturas emitidas (lo que has facturado)'
            WHEN g.tipo = 'recibo'  AND g.direccion = 'recibido'    THEN N'recibos recibidos (lo que has pagado)'
            WHEN g.tipo = 'recibo'  AND g.direccion = 'emitido'     THEN N'recibos emitidos (lo que has cobrado)'
            WHEN g.tipo = 'presupuesto' AND g.direccion = 'emitido' THEN N'presupuestos enviados (no son cobros)'
            WHEN g.tipo = 'presupuesto'                             THEN N'presupuestos recibidos (no son pagos)'
            ELSE N'otros documentos'
        END AS etiqueta) AS c
    GROUP BY g.tipo, g.direccion, g.moneda;

    /* 2.4 Texto para el LLM: cifras ya formateadas en español para que las copie tal cual.
           Primero el detalle de cada grupo (hasta 15 documentos), después el resumen. */
    DECLARE @max_detalle int = 15;

    WITH detalle AS
    (
        SELECT d.*, ROW_NUMBER() OVER (PARTITION BY d.tipo, d.direccion, d.moneda ORDER BY d.fecha, d.documento_id) AS rn
        FROM @docs AS d
        WHERE d.en_periodo = 1
    )
    UPDATE g
    SET detalle = CONCAT(
            (SELECT STRING_AGG(CONVERT(nvarchar(max), CONCAT(NCHAR(10), N'    · ',
                        ISNULL(FORMAT(x.fecha, 'd/M/yyyy'), N'sin fecha'), N' · ',
                        ISNULL(FORMAT(x.importe, 'N2', 'es-ES') + N' ' + x.moneda, N'sin importe'), N' · ',
                        x.nombre_archivo)), N'') WITHIN GROUP (ORDER BY x.rn)
             FROM detalle AS x
             WHERE x.tipo = g.tipo AND ISNULL(x.direccion, '') = ISNULL(g.direccion, '')
               AND x.moneda = g.moneda AND x.rn <= @max_detalle),
            CASE WHEN g.docs_periodo > @max_detalle
                 THEN CONCAT(NCHAR(10), N'    · y ', g.docs_periodo - @max_detalle, N' más') END)
    FROM @grupos AS g;

    SELECT @datos = CONCAT(
        N'Tercero: ', @quien, NCHAR(10),
        N'Periodo: ', CASE WHEN @hay_periodo = 1
                           THEN CONCAT(N'del ', FORMAT(ISNULL(@desde, '19000101'), 'd/M/yyyy'),
                                       N' al ', FORMAT(ISNULL(@hasta, '99991231'), 'd/M/yyyy'))
                           ELSE N'todo el archivo' END, NCHAR(10),
        N'Solo se cuentan los documentos que el usuario tiene permiso para ver.', NCHAR(10),
        STRING_AGG(CONVERT(nvarchar(max), CONCAT(NCHAR(10),
            N'- ', g.etiqueta, N': ', g.docs_periodo, N' documento(s)',
            CASE WHEN @hay_periodo = 1 THEN N' en el periodo' END,
            CASE WHEN g.importe_periodo IS NOT NULL
                 THEN CONCAT(N', importe total ', FORMAT(g.importe_periodo, 'N2', 'es-ES'), N' ', g.moneda) END,
            CASE WHEN @hay_periodo = 1 AND g.docs_total <> g.docs_periodo
                 THEN CONCAT(N' (', g.docs_total, N' en todo el archivo)') END,
            N'.', g.detalle)), N'') WITHIN GROUP (ORDER BY g.orden))
    FROM @grupos AS g;   -- también los grupos con 0 en el periodo: "0 contratos este año (1 en total)" 

    /* 2.5 Números permitidos en la respuesta: todo lo que aparece en @datos */
    DECLARE @cifras TABLE (valor decimal(14,2));
    INSERT INTO @cifras (valor)
    SELECT docs_periodo FROM @grupos
    UNION SELECT docs_total FROM @grupos
    UNION SELECT importe_periodo FROM @grupos WHERE importe_periodo IS NOT NULL
    UNION SELECT importe FROM @docs WHERE en_periodo = 1 AND importe IS NOT NULL
    UNION SELECT DAY(fecha)   FROM @docs WHERE en_periodo = 1 AND fecha IS NOT NULL
    UNION SELECT MONTH(fecha) FROM @docs WHERE en_periodo = 1 AND fecha IS NOT NULL
    UNION SELECT YEAR(fecha)  FROM @docs WHERE en_periodo = 1 AND fecha IS NOT NULL
    UNION SELECT DAY(@desde) WHERE @desde IS NOT NULL UNION SELECT MONTH(@desde) WHERE @desde IS NOT NULL
    UNION SELECT YEAR(@desde) WHERE @desde IS NOT NULL
    UNION SELECT DAY(@hasta) WHERE @hasta IS NOT NULL UNION SELECT MONTH(@hasta) WHERE @hasta IS NOT NULL
    UNION SELECT YEAR(@hasta) WHERE @hasta IS NOT NULL;

    SET @cifras_json = (SELECT valor FROM @cifras FOR JSON PATH);

    SET @documentos_json =
        (SELECT ROW_NUMBER() OVER (ORDER BY fecha, documento_id) AS n,
                nombre_archivo AS archivo, tipo, direccion, fecha, importe, moneda, documento_id
         FROM @docs WHERE en_periodo = 1
         ORDER BY fecha, documento_id
         FOR JSON PATH);

    IF @mostrar = 1
    BEGIN
        SELECT etiqueta AS clase, docs_periodo AS documentos, importe_periodo AS importe, moneda,
               docs_total AS en_todo_el_archivo
        FROM @grupos ORDER BY orden;

        SELECT nombre_archivo, tipo, direccion, tercero, fecha, importe, moneda
        FROM @docs WHERE en_periodo = 1 ORDER BY tipo, fecha;

        SELECT @datos AS datos_para_el_modelo;
    END
END;
GO

/* ---------------------------------------------------------------------
   Comprobación de la respuesta: números que el modelo ha escrito y que
   NO están en los datos calculados (ni en la pregunta).
   - REGEXP_MATCHES sobre nvarchar(4000): la RTM no acepta nvarchar(max).
   - El número se convierte aquí mismo, sin llamar a fn_importe_texto:
     una función escalar con REGEXP_REPLACE aplicada a la salida de
     REGEXP_MATCHES tumbó el servicio en las pruebas (SQL Server 2025 CU10).
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION archivo.fn_cifras_sin_respaldo
    (@respuesta nvarchar(4000), @cifras_json nvarchar(max), @pregunta nvarchar(1000))
RETURNS TABLE
AS
RETURN
    WITH escritas AS
    (
        SELECT m.match_value AS cifra, m.start_position AS posicion, 'respuesta' AS origen
        FROM REGEXP_MATCHES(@respuesta, N'\d+(?:[.,]\d+)*') AS m
        UNION ALL
        SELECT q.match_value, q.start_position, 'pregunta'
        FROM REGEXP_MATCHES(@pregunta, N'\d+(?:[.,]\d+)*') AS q
    ),
    valores AS
    (   -- "1.210,50" -> 1210.50 · "145,20" -> 145.20 · "145.20" -> 145.20 · "01" -> 1
        SELECT e.cifra, e.posicion, e.origen,
               TRY_CAST(CASE WHEN e.cifra LIKE N'%,%' THEN REPLACE(REPLACE(e.cifra, N'.', N''), N',', N'.')
                             ELSE e.cifra END AS decimal(14,2)) AS valor
        FROM escritas AS e
    )
    SELECT DISTINCT v.cifra
    FROM valores AS v
    WHERE v.origen = 'respuesta'
      AND v.valor IS NOT NULL
      AND SUBSTRING(@respuesta, v.posicion - 1, 1) <> N'['            -- marcas de cita [1]
      AND NOT EXISTS (SELECT 1
                      FROM OPENJSON(ISNULL(@cifras_json, N'[]')) WITH (valor decimal(14,2) '$.valor') AS p
                      WHERE p.valor = v.valor)
      AND NOT EXISTS (SELECT 1 FROM valores AS q WHERE q.origen = 'pregunta' AND q.valor = v.valor);
GO

/* ---------------------------------------------------------------------
   2b. Operar con las cifras (T-SQL, nunca el modelo)
   --------------------------------------------------------------------- */

-- Una cifra del archivo: lo pagado, lo facturado, lo pactado en contratos o lo presupuestado
-- a un tercero (o a todos) en un periodo. Mismo criterio que usp_consultar_datos. RLS aplicada.
CREATE OR ALTER FUNCTION archivo.fn_magnitud (@tercero_id int, @desde date, @hasta date, @sobre varchar(15))
RETURNS TABLE
AS
RETURN
    SELECT d.moneda, SUM(d.importe_total) AS importe, COUNT(d.importe_total) AS documentos
    FROM archivo.documentos AS d
    LEFT JOIN archivo.terceros AS t ON t.tercero_id = @tercero_id
    WHERE (@desde IS NULL OR d.fecha_documento >= @desde)
      AND (@hasta IS NULL OR d.fecha_documento <= @hasta)
      AND (@tercero_id IS NULL OR d.tercero_id = @tercero_id OR d.texto LIKE CONCAT(N'%', t.nombre, N'%'))
      AND (   (@sobre = 'pagado'       AND d.tipo IN ('factura', 'recibo') AND d.direccion = 'recibido')
           OR (@sobre = 'facturado'    AND d.tipo IN ('factura', 'recibo') AND d.direccion = 'emitido')
           OR (@sobre = 'contratos'    AND d.tipo = 'contrato')
           OR (@sobre = 'presupuestos' AND d.tipo = 'presupuesto'))
    GROUP BY d.moneda;
GO

CREATE OR ALTER PROCEDURE archivo.usp_calcular_operacion
    @tercero_id     int,
    @tercero_nombre nvarchar(200),
    @desde date, @hasta date,
    @desde2 date = NULL, @hasta2 date = NULL,
    @operacion      varchar(20),
    @valor          decimal(18,4) = NULL,
    @sobre          varchar(15),
    @linea          nvarchar(1000) OUTPUT,   -- para los datos que lee el modelo (sin signos de operación)
    @formula        nvarchar(400)  OUTPUT,   -- para enseñar: "145,20 EUR × 2 = 290,40 EUR"
    @resultado_txt  nvarchar(60)   OUTPUT,   -- "290,40 EUR": la respuesta tiene que contenerlo
    @respuesta_fija nvarchar(1000) OUTPUT,   -- si el modelo no la redacta bien, esta es la respuesta
    @cifras_extra   nvarchar(max)  OUTPUT,   -- números nuevos que la respuesta puede usar
    @no_se_puede    nvarchar(400)  OUTPUT    -- por qué no se puede hacer (NULL si se ha hecho)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @linea = NULL, @formula = NULL, @resultado_txt = NULL, @respuesta_fija = NULL,
           @cifras_extra = NULL, @no_se_puede = NULL;

    DECLARE @es nvarchar(5) = 'es-ES';
    DECLARE @que nvarchar(60) = CASE @sobre WHEN 'pagado' THEN N'lo pagado' WHEN 'facturado' THEN N'lo facturado'
                                            WHEN 'contratos' THEN N'el importe de los contratos'
                                            ELSE N'el importe de los presupuestos' END;
    DECLARE @a_quien nvarchar(220) = CASE WHEN @tercero_nombre IS NULL THEN N'' ELSE CONCAT(N' a ', @tercero_nombre) END;
    DECLARE @periodo nvarchar(60) = CASE WHEN @desde IS NULL AND @hasta IS NULL THEN N' en todo el archivo'
        ELSE CONCAT(N' del ', FORMAT(ISNULL(@desde, '19000101'), 'd/M/yyyy'), N' al ', FORMAT(ISNULL(@hasta, '99991231'), 'd/M/yyyy')) END;

    -- 1. La cifra de partida
    DECLARE @monedas int, @moneda char(3), @base decimal(14,2), @n int;
    SELECT @monedas = COUNT(*), @moneda = MAX(moneda), @base = SUM(importe), @n = SUM(documentos)
    FROM archivo.fn_magnitud(@tercero_id, @desde, @hasta, @sobre);

    IF @monedas > 1
    BEGIN
        SET @no_se_puede = N'hay importes en monedas distintas y no se mezclan';
        RETURN;
    END
    IF ISNULL(@n, 0) = 0
    BEGIN
        SET @no_se_puede = CONCAT(N'no hay importes de ', @que, @a_quien, @periodo, N' sobre los que calcular');
        RETURN;
    END

    IF @operacion IN ('multiplicar', 'dividir', 'porcentaje', 'sumar', 'restar') AND @valor IS NULL
    BEGIN
        SET @no_se_puede = N'no he entendido con qué número hacer la cuenta';
        RETURN;
    END
    IF @operacion = 'dividir' AND @valor = 0
    BEGIN
        SET @no_se_puede = N'no se puede dividir entre cero';
        RETURN;
    END

    -- 2. La cuenta
    DECLARE @r decimal(18,2), @base2 decimal(14,2), @n2 int, @v nvarchar(30) = FORMAT(@valor, '0.####', @es);
    DECLARE @B nvarchar(40) = CONCAT(FORMAT(@base, 'N2', @es), N' ', @moneda), @nombre_op nvarchar(120);

    IF @operacion = 'comparar_periodos'
    BEGIN
        IF @desde2 IS NULL AND @hasta2 IS NULL
        BEGIN
            SET @no_se_puede = N'no he entendido con qué periodo comparar';
            RETURN;
        END
        SELECT @base2 = ISNULL(SUM(importe), 0), @n2 = ISNULL(SUM(documentos), 0)
        FROM archivo.fn_magnitud(@tercero_id, @desde2, @hasta2, @sobre)
        WHERE moneda = @moneda;
        SET @base2 = ISNULL(@base2, 0);
    END

    SET @r = CASE @operacion
                 WHEN 'multiplicar' THEN @base * @valor
                 WHEN 'dividir'     THEN @base / @valor
                 WHEN 'porcentaje'  THEN @base * @valor / 100
                 WHEN 'sumar'       THEN @base + @valor
                 WHEN 'restar'      THEN @base - @valor
                 WHEN 'media'       THEN @base / @n
                 WHEN 'comparar_periodos' THEN @base - @base2
             END;

    IF @r IS NULL
    BEGIN
        SET @no_se_puede = N'esa operación no está entre las que sé hacer';
        RETURN;
    END

    SET @resultado_txt = CONCAT(FORMAT(@r, 'N2', @es), N' ', @moneda);
    SET @nombre_op = CASE @operacion
        WHEN 'multiplicar' THEN CASE @valor WHEN 2 THEN N'El doble' WHEN 3 THEN N'El triple' ELSE CONCAT(N'Multiplicado por ', @v) END
        WHEN 'dividir'     THEN CASE @valor WHEN 2 THEN N'La mitad' ELSE CONCAT(N'Dividido entre ', @v) END
        WHEN 'porcentaje'  THEN CONCAT(N'El ', @v, N' %')
        WHEN 'sumar'       THEN CONCAT(N'Sumando ', @v, N' ', @moneda)
        WHEN 'restar'      THEN CONCAT(N'Restando ', @v, N' ', @moneda)
        WHEN 'media'       THEN CONCAT(N'La media por documento (', @n, N' documentos)')
        ELSE CONCAT(N'La diferencia con', N' el periodo del ', FORMAT(ISNULL(@desde2, '19000101'), 'd/M/yyyy'),
                    N' al ', FORMAT(ISNULL(@hasta2, '99991231'), 'd/M/yyyy'),
                    N' (', FORMAT(@base2, 'N2', @es), N' ', @moneda, N')') END;

    SET @formula = CASE @operacion
        WHEN 'multiplicar' THEN CONCAT(@B, N' × ', @v, N' = ', @resultado_txt)
        WHEN 'dividir'     THEN CONCAT(@B, N' ÷ ', @v, N' = ', @resultado_txt)
        WHEN 'porcentaje'  THEN CONCAT(@v, N' % de ', @B, N' = ', @resultado_txt)
        WHEN 'sumar'       THEN CONCAT(@B, N' + ', @v, N' = ', @resultado_txt)
        WHEN 'restar'      THEN CONCAT(@B, N' − ', @v, N' = ', @resultado_txt)
        WHEN 'media'       THEN CONCAT(@B, N' ÷ ', @n, N' documentos = ', @resultado_txt)
        ELSE CONCAT(@B, N' − ', FORMAT(@base2, 'N2', @es), N' ', @moneda, N' = ', @resultado_txt) END;

    -- Para el modelo: frase sin signos, para que la copie sin escribir cuentas
    SET @linea = CONCAT(N'- CÁLCULO PEDIDO, ya hecho por SQL Server sobre ', @que, @a_quien, @periodo,
                        N' (', @B, N'): ', @nombre_op, N'. Resultado: ', @resultado_txt, N'.');
    SET @respuesta_fija = CONCAT(N'Lo que corresponde a ', @que, @a_quien, @periodo, N' es ', @B, N'. ',
                                 @nombre_op, N': ', @resultado_txt, N'.');

    SET @cifras_extra = (SELECT valor FROM (VALUES (@base), (@valor), (@r), (ABS(@r)), (@n), (@base2), (@n2),
                                                   (DAY(@desde2)), (MONTH(@desde2)), (YEAR(@desde2)),
                                                   (DAY(@hasta2)), (MONTH(@hasta2)), (YEAR(@hasta2))) AS c(valor)
                         WHERE valor IS NOT NULL FOR JSON PATH);
END;
GO

/* ---------------------------------------------------------------------
   3. Redactar la respuesta y comprobarla
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE archivo.usp_preguntar_datos
    @pregunta           nvarchar(1000),
    @intencion          nvarchar(max),     -- salida de usp_interpretar_pregunta
    @duracion_previa_ms int = 0            -- tiempo ya gastado en interpretar la pregunta
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @modelo varchar(60) = (SELECT valor FROM archivo.config_ia WHERE clave = 'modelo_llm');
    DECLARE @tercero nvarchar(200) = JSON_VALUE(@intencion, '$.tercero'),
            @desde   date = TRY_CONVERT(date, NULLIF(JSON_VALUE(@intencion, '$.desde'), ''), 23),
            @hasta   date = TRY_CONVERT(date, NULLIF(JSON_VALUE(@intencion, '$.hasta'), ''), 23),
            @desde2  date = TRY_CONVERT(date, NULLIF(JSON_VALUE(@intencion, '$.desde2'), ''), 23),
            @hasta2  date = TRY_CONVERT(date, NULLIF(JSON_VALUE(@intencion, '$.hasta2'), ''), 23),
            @operacion varchar(20) = ISNULL(JSON_VALUE(@intencion, '$.operacion'), 'ninguna'),
            @valor   decimal(18,4) = TRY_CAST(JSON_VALUE(@intencion, '$.valor') AS decimal(18,4)),
            @sobre   varchar(15) = ISNULL(JSON_VALUE(@intencion, '$.sobre'), 'pagado');

    -- Respaldo sin IA (también si se llama a este procedimiento sin pasar por el intérprete)
    IF @operacion = 'ninguna' AND EXISTS (SELECT 1 FROM archivo.fn_pide_calculo_extra(@pregunta) WHERE si = 1)
        SET @operacion = 'otra';

    DECLARE @datos nvarchar(max), @documentos_json nvarchar(max), @cifras_json nvarchar(max),
            @respuesta nvarchar(max), @ms int = 0, @verificada bit = 1,
            @tercero_id int, @tercero_nombre nvarchar(200),
            @linea nvarchar(1000), @formula nvarchar(400), @resultado_txt nvarchar(60),
            @respuesta_fija nvarchar(1000), @cifras_extra nvarchar(max), @no_se_puede nvarchar(400);

    EXEC archivo.usp_consultar_datos
         @tercero = @tercero, @desde = @desde, @hasta = @hasta, @mostrar = 0,
         @datos = @datos OUTPUT, @documentos_json = @documentos_json OUTPUT,
         @cifras_json = @cifras_json OUTPUT, @respuesta_directa = @respuesta OUTPUT,
         @tercero_resuelto = @tercero_id OUTPUT, @tercero_nombre_resuelto = @tercero_nombre OUTPUT;

    /* La cuenta pedida la hace SQL. Si no está en la lista o no se puede, se dice. */
    IF @respuesta IS NULL AND @operacion NOT IN ('ninguna', 'otra')
    BEGIN
        EXEC archivo.usp_calcular_operacion
             @tercero_id = @tercero_id, @tercero_nombre = @tercero_nombre,
             @desde = @desde, @hasta = @hasta, @desde2 = @desde2, @hasta2 = @hasta2,
             @operacion = @operacion, @valor = @valor, @sobre = @sobre,
             @linea = @linea OUTPUT, @formula = @formula OUTPUT, @resultado_txt = @resultado_txt OUTPUT,
             @respuesta_fija = @respuesta_fija OUTPUT, @cifras_extra = @cifras_extra OUTPUT,
             @no_se_puede = @no_se_puede OUTPUT;

        IF @linea IS NOT NULL
        BEGIN
            SET @datos = CONCAT(@datos, NCHAR(10), NCHAR(10), @linea);
            -- Los números del cálculo se añaden a los permitidos en la respuesta
            SET @cifras_json = (SELECT valor FROM (
                                    SELECT valor FROM OPENJSON(@cifras_json) WITH (valor decimal(14,2) '$.valor')
                                    UNION SELECT valor FROM OPENJSON(@cifras_extra) WITH (valor decimal(14,2) '$.valor')) AS u
                                FOR JSON PATH);
        END
    END

    -- Si SQL ya tiene la respuesta (tercero no encontrado, ambiguo o sin documentos), no se llama al modelo
    IF @respuesta IS NULL
    BEGIN
        DECLARE @sistema nvarchar(max) = N'
Eres Mnemos Archive. Responde en español, en pocas frases y en lenguaje natural, a la PREGUNTA usando SOLO los DATOS CALCULADOS.
Reglas:
- Copia las cifras y las fechas exactamente como aparecen en los datos. No sumes, no restes, no multipliques y no redondees.
- "Pagado" son las facturas y recibos recibidos. "Facturado" o "cobrado" son los emitidos. El importe de un contrato es lo pactado, no un pago.
- Nunca escribas cuentas ni signos como ×, =, + o /.
- Responde solo a lo que se pregunta. Si la pregunta pide algo que no está en los datos, dilo.
- Al final, nombra los archivos de los que salen los datos. No uses corchetes.';

        IF @linea IS NOT NULL
            SET @sistema += N'
- Los datos incluyen un CÁLCULO PEDIDO ya hecho por SQL Server. Da su resultado tal cual aparece y la cifra de partida.';
        ELSE IF @operacion <> 'ninguna'
            SET @sistema += N'
- La pregunta pide una cuenta que no está en los datos. NO la hagas y no la menciones: da solo las cifras de los datos.';

        DECLARE @usuario nvarchar(max) = CONCAT(N'DATOS CALCULADOS:', NCHAR(10), @datos, NCHAR(10), NCHAR(10),
                                                N'PREGUNTA: ', @pregunta);

        EXEC archivo.usp_llm_chat @sistema = @sistema, @usuario = @usuario,
                                  @respuesta = @respuesta OUTPUT, @duracion_ms = @ms OUTPUT;

        -- Las cifras se comprueban, no se creen
        DECLARE @texto4000 nvarchar(4000) = CAST(LEFT(@respuesta, 4000) AS nvarchar(4000));
        DECLARE @sin_respaldo nvarchar(400) =
            (SELECT STRING_AGG(cifra, N', ') FROM archivo.fn_cifras_sin_respaldo(@texto4000, @cifras_json, @pregunta));
        DECLARE @con_cuentas bit = (SELECT CASE WHEN @linea IS NULL THEN si ELSE signos END
                                    FROM archivo.fn_tiene_operacion(@texto4000));
        DECLARE @sin_resultado bit = CASE WHEN @resultado_txt IS NOT NULL
                                           AND CHARINDEX(REPLACE(@resultado_txt, N' EUR', N''), @texto4000) = 0 THEN 1 ELSE 0 END;

        IF @sin_respaldo IS NOT NULL OR @con_cuentas = 1 OR @sin_resultado = 1
        BEGIN
            SET @verificada = 0;
            SET @respuesta = CASE
                -- Con cálculo: la respuesta fija ya es exacta, calculada por SQL
                WHEN @respuesta_fija IS NOT NULL THEN @respuesta_fija
                WHEN @sin_respaldo IS NOT NULL THEN
                    CONCAT(N'No he podido redactar la respuesta sin alterar las cifras (el modelo escribió ',
                           @sin_respaldo, N', que no está en los datos). Estos son los datos calculados:', NCHAR(10), @datos)
                ELSE CONCAT(N'No he podido redactar la respuesta sin que el modelo operara con las cifras, ',
                            N'y esas cuentas no se aceptan. Estos son los datos calculados:', NCHAR(10), @datos) END;
        END

        IF @operacion = 'otra'
            SET @respuesta = CONCAT(N'Ese cálculo no lo hago: no está entre las cuentas que sé hacer ',
                                    N'(multiplicar, dividir, porcentaje, sumar, restar, media y comparar periodos). ',
                                    N'Estas son las cifras del archivo.', NCHAR(10), NCHAR(10), @respuesta);
        ELSE IF @no_se_puede IS NOT NULL
            SET @respuesta = CONCAT(N'Ese cálculo no lo puedo hacer: ', @no_se_puede, N'.', NCHAR(10), NCHAR(10), @respuesta);
    END

    SET @ms += @duracion_previa_ms;

    DECLARE @contexto nvarchar(max) = CONCAT(N'Intención: ', @intencion, NCHAR(10), NCHAR(10), @datos);

    INSERT INTO archivo.consultas_rag (pregunta, documentos_json, contexto, respuesta, modelo_llm, duracion_ms)
    VALUES (@pregunta, @documentos_json, @contexto, @respuesta, @modelo, @ms);

    /* Resultados, en el mismo orden que el RAG */
    SELECT @pregunta AS [1_pregunta];

    SELECT n AS [2_fuente], archivo, tipo, direccion, fecha, importe, moneda, documento_id
    FROM OPENJSON(ISNULL(@documentos_json, N'[]'))
         WITH (n int, archivo nvarchar(260), tipo varchar(20), direccion varchar(10),
               fecha date, importe decimal(12,2), moneda char(3), documento_id int)
    ORDER BY n;

    SELECT @contexto AS [3_contexto_enviado_al_modelo];

    SELECT @respuesta AS [4_respuesta], 'datos' AS camino, @verificada AS cifras_verificadas,
           @modelo AS modelo, @ms AS milisegundos, @formula AS calculo;
END;
GO

/* Prueba sin IA: lo que SQL calcula para la pregunta de ejemplo */
EXEC archivo.usp_consultar_datos @tercero = N'tecnologias arganzuela', @desde = '2026-01-01', @hasta = '2026-12-31';
GO

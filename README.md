# Mnemos Archive

> Tus documentos, recordados.

Archivo de documentos local construido sobre **SQL Server 2025**. Lee facturas, contratos y presupuestos, guarda sus datos en tablas, busca por significado con vectores y responde preguntas citando el documento y la página. Todo se ejecuta en el propio ordenador: sin nube, sin cuentas y sin claves de API.

Mini-proyecto de la certificación **Microsoft DP-800: SQL AI Developer Associate**.

**Nivel del proyecto: 3 (Avanzado)** · Diseño de BD + T-SQL + seguridad + optimización + embeddings + vector search + RAG con modelo local.

---

## Descripción

Un autónomo o una pequeña empresa acumula cientos de PDFs: facturas emitidas y recibidas, contratos, presupuestos. Encontrar algo obliga a abrirlos uno a uno, y las preguntas útiles ("¿cuánto le he facturado a Pedro este año?", "¿con cuánto preaviso puedo dejar la oficina?") no se pueden hacer con una búsqueda por palabras.

Mnemos Archive guarda cada documento en SQL Server con:

- **Sus datos estructurados** (tercero, fecha, base, IVA, total), para que las cifras las calcule la base de datos.
- **Su texto troceado y convertido en vectores** (embeddings), para buscar por significado.
- **Un modelo de lenguaje local** que clasifica los documentos nuevos y responde preguntas usando solo lo que hay en la base de datos (RAG), citando siempre la fuente.

Escenario de ejemplo: **Estudio Ámbar S.L.**, un estudio de diseño ficticio con 22 documentos y 11 clientes y proveedores, todos inventados.

## Arquitectura

```
                     ┌──────────────────────────┐
                     │ Usuario (SSMS / sqlcmd)  │
                     │ admin · contable · legal │
                     └────────────┬─────────────┘
                                  │ T-SQL
                                  ▼
   ┌─────────────────────────────────────────────────────────────┐
   │                 SQL Server 2025 · MnemosArchive             │
   │                                                             │
   │  Tablas: terceros · documentos · campos_extraidos ·         │
   │          fragmentos (vector(1024)) · auditoria · consultas  │
   │  Vistas · funciones · procedimientos · triggers · índices   │
   │  Seguridad: roles + GRANT/DENY · Row-Level Security ·       │
   │             Dynamic Data Masking · auditoría                │
   │                                                             │
   │  IA:  AI_GENERATE_CHUNKS     -> trocea el texto             │
   │       AI_GENERATE_EMBEDDINGS -> CREATE EXTERNAL MODEL       │
   │       VECTOR_DISTANCE        -> búsqueda semántica          │
   │       FREETEXTTABLE + RRF    -> búsqueda híbrida            │
   │       sp_invoke_external_rest_endpoint -> LLM (RAG)         │
   └──────────────────────────┬──────────────────────────────────┘
                              │ HTTPS  https://localhost:11435
                              ▼
                     ┌──────────────────┐
                     │      Caddy       │  certificado local (tls internal)
                     └────────┬─────────┘
                              │ HTTP  localhost:11434
                              ▼
                     ┌──────────────────────────────────┐
                     │ Ollama (local)                   │
                     │  bge-m3   -> embeddings 1024 dim │
                     │  qwen3:4b -> extracción y RAG    │
                     └──────────────────────────────────┘
```

Más detalle (modelo de datos y flujos) en [docs/arquitectura.md](docs/arquitectura.md).

**Por qué Caddy:** SQL Server 2025 solo admite modelos y endpoints REST por **HTTPS**, y Ollama escucha por HTTP. Caddy se pone delante con un certificado de su autoridad local, que se marca como de confianza en Windows.

## Tecnologías

```
SQL Server 2025 (Enterprise Developer)   T-SQL   SSMS 21/22
Ollama   bge-m3 (MIT)   qwen3:4b (Apache 2.0)   Caddy (Apache 2.0)
Git   GitHub   PowerShell   Claude (asistente de IA, ver Bloque B)
```

## Funcionalidades DP-800 implementadas

```
✓ Diseño de base de datos      6 tablas, PK, FK, UNIQUE, CHECK, DEFAULT, ON DELETE CASCADE
✓ Datos de prueba              11 terceros, 22 documentos, 122 campos verificados
✓ Vistas                       4  (v_documentos, v_facturacion_mensual, v_pendientes_ia, v_contratos con PIVOT)
✓ Funciones                    6  (regex, importes, fuzzy matching, páginas, tabla en línea)
✓ Procedimientos               4 relacionales + 8 de IA
✓ Triggers                     3  (auditoría de cambios, de borrados, invalidar vectores)
✓ Índices                      compuestos, con INCLUDE y filtrado
✓ T-SQL avanzado               CTE, funciones de ventana, LAG, subconsultas correlacionadas,
                               JSON (FOR JSON / OPENJSON / JSON_OBJECT), REGEXP_*, fuzzy matching
✓ Desarrollo asistido por IA   docs/ia-asistida.md (prompts, respuestas, correcciones, verificación)
✓ Seguridad                    roles + GRANT/DENY/REVOKE, Row-Level Security, Dynamic Data Masking,
                               usuarios sin login, auditoría
✓ Optimización                 Clustered Index Scan -> Index Seek: 4.512 -> 18 lecturas lógicas
✓ Modelos y embeddings         CREATE EXTERNAL MODEL + AI_GENERATE_CHUNKS + AI_GENERATE_EMBEDDINGS
✓ Vector Search                VECTOR_DISTANCE coseno, ranking por documento
✓ Búsqueda híbrida             Full-Text + vectores con Reciprocal Rank Fusion
✓ RAG                          pregunta -> vectores -> contexto -> LLM local -> respuesta con citas
✓ IA en la ingesta             el LLM clasifica y extrae campos con JSON Schema, validado en T-SQL
✓ Pruebas                      tests/tests.sql (10 pruebas) y tests/tests_ia.sql (6 pruebas)
```

## Estructura del repositorio

```
mnemos-archive/
├── README.md
├── database/
│   ├── 01_create_database.sql     compatibilidad 170, PREVIEW_FEATURES, esquema archivo
│   ├── 02_create_tables.sql       6 tablas con sus restricciones
│   ├── 03_insert_data.sql         datos de prueba inventados
│   ├── 04_views.sql
│   ├── 05_functions.sql
│   ├── 06_procedures.sql
│   ├── 07_triggers.sql
│   ├── 08_indexes.sql
│   ├── 09_security.sql            roles, RLS, máscaras y demostración con 3 usuarios
│   ├── 10_advanced_queries.sql    CTE, ventana, JSON, regex, fuzzy, correlacionadas
│   └── 11_optimization.sql        antes / después con 200.000 filas
├── ai/
│   ├── caddy/Caddyfile            puente HTTPS hacia Ollama
│   ├── 01_configurar_ia.sql       activa REST y guarda la configuración de modelos
│   ├── 02_create_external_model.sql
│   ├── 03_generate_embeddings.sql
│   ├── 04_vector_search.sql
│   ├── 05_hybrid_search.sql
│   ├── 06_llm_chat.sql            llamada al LLM desde T-SQL
│   ├── 07_classify_and_extract.sql  el LLM clasifica los documentos nuevos
│   ├── 08_rag.sql
│   └── 09_ai_permissions.sql      permisos y RAG con Row-Level Security
├── tests/
│   ├── tests.sql
│   └── tests_ia.sql
├── scripts/
│   ├── check-env.ps1              comprueba SQL Server 2025, Ollama, modelos y HTTPS
│   └── instalar.ps1               ejecuta todo en orden y guarda las evidencias
├── evidencias/                    salida real de cada script (la genera instalar.ps1)
├── docs/
│   ├── arquitectura.md
│   ├── ia-asistida.md             Bloque B
│   └── optimizacion.md            Bloque D
└── presentation/
```

## Instalación

Pensado para Windows 11 con SQL Server 2025 Enterprise Developer, SSMS 22 y Ollama.

**1. Clonar el repositorio**

```powershell
git clone https://github.com/alvarophck/mnemos-archive.git
cd mnemos-archive
```

**2. SQL Server 2025.** Instancia con nombre `SQL2025`, autenticación de Windows y, si es posible, la característica *Búsqueda de texto completo* (para la búsqueda híbrida; sin ella todo funciona igual con solo vectores). Si tu instancia se llama de otra forma, cambia `-SqlInstance` en los comandos.

**3. Ollama y los modelos**

```powershell
winget install Ollama.Ollama
ollama pull bge-m3
ollama pull qwen3:4b
```

En un equipo con poca memoria se puede usar `qwen3:1.7b`: basta cambiar `modelo_llm` en la tabla `archivo.config_ia`.

**4. Puente HTTPS con Caddy** (SQL Server solo llama a modelos por HTTPS)

4.1 Instalar Caddy: `winget install CaddyServer.Caddy`, o descargar `caddy.exe` de <https://caddyserver.com/download> y ponerlo en el PATH.

4.2 Arrancarlo en una ventana de PowerShell que se queda abierta:

```powershell
caddy run --config ai\caddy\Caddyfile
```

4.3 La primera vez, confiar en su certificado. En **otra** PowerShell **como administrador**:

```powershell
Import-Certificate -FilePath "$env:APPDATA\Caddy\pki\authorities\local\root.crt" `
                   -CertStoreLocation Cert:\LocalMachine\Root
```

Comprobación: `Invoke-RestMethod https://localhost:11435/api/tags` debe listar los modelos sin errores de certificado.

**5. Comprobar el entorno**

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\check-env.ps1
```

**6. Crear todo**

```powershell
.\scripts\instalar.ps1            # todo, con IA
.\scripts\instalar.ps1 -SinIA     # solo la parte relacional (no necesita Ollama)
```

Cada script deja su salida en `evidencias\`. También se pueden abrir y ejecutar uno a uno en SSMS, en el orden de los números.

No hay contraseñas en el repositorio: la conexión usa autenticación de Windows y los usuarios de demostración se crean `WITHOUT LOGIN` y se prueban con `EXECUTE AS USER`.

## Base de datos

| Tabla | Qué guarda | Claves y restricciones |
|---|---|---|
| `terceros` | clientes y proveedores | PK, NIF único, CHECK de tipo y email |
| `documentos` | un archivo por fila: tipo, dirección, departamento, tercero, nº, fecha, total, texto | PK, FK a terceros, hash SHA-256 único (no se archiva dos veces), CHECK de tipo, estado, importe y moneda |
| `campos_extraidos` | datos leídos de cada documento, con tipo real (texto, número, fecha), confianza y fragmento de origen | FK con borrado en cascada, UNIQUE (documento, campo), CHECK de confianza |
| `fragmentos` | texto troceado y su `vector(1024)` | FK con borrado en cascada, UNIQUE (documento, orden) |
| `auditoria` | cambios y borrados (la llenan triggers) | CHECK de JSON válido |
| `consultas_rag` | cada pregunta con sus documentos, contexto y respuesta | CHECK de JSON válido |

Decisiones:

- **Las cifras viven en columnas `decimal`**, no en texto: "lo facturado a Pedro en 2026" es un `SUM`, no una estimación del modelo.
- **Borrado en cascada**: borrar un documento borra sus campos, fragmentos y vectores. El derecho de supresión del RGPD es una sola llamada (`usp_borrar_documento`), y la auditoría guarda que se borró, pero no el contenido.
- **Intercalación `Latin1_General_100_CI_AI_SC`**: "garcia" encuentra "García".

## Ejemplos

**Lo facturado por cliente, con ranking y acumulado** (`10_advanced_queries.sql`)

```
cliente                       fecha       importe  acumulado  total    % año  ranking
Construcciones Vallecas S.A.  2026-03-30  6050.00  6050.00    6050.00  48.15  1
Pedro García Ruiz             2026-02-10  1210.00  1210.00    4820.00  38.36  2
Pedro García Ruiz             2026-05-06  2100.00  3310.00    4820.00  38.36  2
Pedro García Ruiz             2026-09-15  1510.00  4820.00    4820.00  38.36  2
```

**Comprobar con regex que base + IVA = total en cada factura**

```
numero    base     iva      suma     total    comprobacion
2026-014  1000.00  210.00   1210.00  1210.00  cuadra
2026-048  1247.93  262.07   1510.00  1510.00  cuadra
```

**Fuzzy matching: un nombre mal escrito encuentra al proveedor**

```sql
SELECT * FROM archivo.fn_buscar_tercero(N'Energia Clara SA', NULL);
-- 7  Energía Clara S.A.  A81234567  similitud 98
```

**Seguridad: la misma consulta con tres usuarios** (`09_security.sql`)

```
usr_admin     contrato 4 · factura 12 · presupuesto 2 · sin_clasificar 4    NIF 12345678Z
usr_contable  factura 12 · presupuesto 2 · sin_clasificar 4                 NIF *****678Z
usr_legal     contrato 4                                                    NIF -> permiso denegado
```

**Búsqueda por significado** (`ai/04_vector_search.sql`)

```sql
EXEC archivo.usp_buscar_semantica N'cláusula de entrega antes del verano';
-- 1º contrato-senaletica-vallecas.pdf: "...se entregarán antes del 30 de junio..."
```

**RAG** (`ai/08_rag.sql`)

```sql
EXEC archivo.usp_preguntar N'¿Con cuánto tiempo de antelación tengo que avisar si quiero dejar la oficina?';
```

Devuelve, por separado: la pregunta, los fragmentos recuperados con su similitud, el contexto exacto enviado al modelo y la respuesta con su cita (`[1] contrato-alquiler-oficina.pdf · p. 2`). Las salidas reales de tu ejecución quedan en `evidencias\ai_08_rag.txt`.

### LLM frente a RAG

```
LLM solo:  pregunta -> modelo -> respuesta con lo que "sabe" (no conoce tu contrato: inventa o generaliza)

RAG:       SQL Server + Vector Search + Contexto + LLM
           pregunta -> embedding -> los fragmentos más cercanos de TUS documentos
                    -> contexto numerado -> modelo con la orden de usar solo eso
                    -> respuesta con citas, o "No lo encuentro" si no está
```

`archivo.usp_preguntar_sin_rag` hace la misma pregunta al modelo sin contexto, para comparar las dos respuestas en la demo.

### Por qué distancia coseno

Los embeddings de bge-m3 codifican el significado en la **dirección** del vector; la longitud no aporta nada. La distancia coseno compara solo el ángulo (0 = misma dirección), y es la métrica con la que se entrenó el modelo. Se muestra como `similitud = 1 − distancia`.

La búsqueda es exacta (recorre todos los fragmentos): con unos cientos tarda milisegundos. El índice aproximado DiskANN (`CREATE VECTOR INDEX`, preview) compensa con decenas de miles de filas; el script deja el ejemplo comentado.

## Bloque B: desarrollo asistido por IA

El proyecto se desarrolló con **Claude** (Anthropic) como asistente. En [docs/ia-asistida.md](docs/ia-asistida.md) están los casos documentados: el prompt, la respuesta, qué se aceptó, qué se corrigió y cómo se verificó. Entre ellos, cuatro errores reales del código generado que aparecieron al ejecutarlo y se corrigieron.

## Bloque D: optimización

Consulta: documentos de un tercero en un rango de fechas. Con 200.000 documentos:

```
ANTES    Clustered Index Scan + Sort     4.512 lecturas lógicas   28 ms
DESPUÉS  Index Seek (sin Sort)              18 lecturas lógicas    2 ms
```

(Medido en el entorno de pruebas; las cifras de cada ejecución quedan en `evidencias\database_11_optimization.txt`.)

Lo interesante: el primer índice propuesto **no** se usaba, porque Row-Level Security añade un filtro por `departamento` a todas las consultas y esa columna no estaba en el índice. Explicación completa en [docs/optimizacion.md](docs/optimizacion.md).

## Conclusiones

**Qué he aprendido**

- SQL Server 2025 puede hacer todo el ciclo de IA sin salir de T-SQL: trocear, vectorizar, buscar y llamar a un modelo local.
- Un RAG es tan bueno como su recuperación: lo que no llega al contexto, el modelo no lo puede usar. Por eso cada fragmento se vectoriza con una cabecera (tipo, tercero, archivo).
- Las cifras no se le piden al modelo: se calculan en SQL y se le pasan como "datos verificados".
- La seguridad se hereda: como RAG y búsqueda leen las tablas con RLS, cada usuario solo recibe respuestas de los documentos que puede ver.

**Problemas y cómo se resolvieron**

| Problema | Solución |
|---|---|
| Tenía SQL Server 2022 instalado, no 2025 (versión 16.0) | El script `check-env.ps1` lo detectó; instalada una instancia `SQL2025` aparte |
| SQL Server solo llama a modelos por HTTPS y Ollama es HTTP | Caddy delante de Ollama con certificado local de confianza |
| Índice filtrado: error 1934 por `QUOTED_IDENTIFIER` al ejecutar con sqlcmd | `SET QUOTED_IDENTIFIER ON` en todos los scripts y `sqlcmd -I` |
| El índice de la optimización no se usaba | Añadir `departamento` (columna del predicado RLS) al `INCLUDE` |
| Funciones de ventana anidadas (error 4109) | Calcular los totales en un CTE y ordenar después |
| Las pruebas dentro de una transacción fallaban al provocar errores (3930) | Pruebas sin transacción global, con limpieza al final |
| En SQL Server 2025 RTM, `REGEXP_MATCHES` no acepta `nvarchar(max)` (error 19304) | Convertir a `nvarchar(4000)` y, en textos largos, usar `REPLACE`/`CHARINDEX` |

**Mejoras posibles**

- Ingesta de PDFs reales con OCR (fuera de T-SQL: un script que extraiga el texto y llame a `usp_archivar_documento`).
- Índice vectorial DiskANN cuando el archivo crezca.
- Fragmentar por párrafos o cláusulas en lugar de por número de caracteres.
- Interfaz de escritorio para usuarios no técnicos.

## Licencia y datos

Código bajo licencia MIT. Todos los nombres, empresas, NIF e importes de los datos de prueba son inventados.

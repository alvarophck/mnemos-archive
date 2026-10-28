using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace MnemosArchive.Web.Services;

/// <summary>
/// Error que se puede enseñar tal cual. O trae una clave de texto de la interfaz (Clave),
/// o el mensaje que escribió SQL Server con THROW (los errores 50000+ del archivo ya están redactados).
/// </summary>
public sealed class ArchivoException(string? clave, string? mensajeSql = null, Exception? inner = null)
    : Exception(clave ?? mensajeSql, inner)
{
    public string? Clave { get; } = clave;
    public string? MensajeSql { get; } = mensajeSql;
}

/// <summary>
/// Acceso a SQL Server. Toda la lógica (búsqueda, IA, cálculos, permisos) vive en los procedimientos
/// del esquema "archivo"; aquí solo se llaman y se leen sus resultados.
/// </summary>
public sealed class ArchivoDb(IOptions<OpcionesArchivo> opciones)
{
    private readonly OpcionesArchivo _op = opciones.Value;

    /* ------------------------------------------------------------------ preguntar */

    public async Task<RespuestaPregunta> PreguntarAsync(string pregunta, Perfil perfil, CancellationToken ct = default)
    {
        var conjuntos = await EjecutarConjuntosAsync(
            "EXEC archivo.usp_preguntar @pregunta = @pregunta;", perfil, ct,
            new SqlParameter("@pregunta", SqlDbType.NVarChar, 1000) { Value = pregunta });

        var respuesta = conjuntos.FirstOrDefault(c => c.Columnas.Contains("4_respuesta"))?.Filas.FirstOrDefault()
                        ?? throw new ArchivoException("ErrorSinRespuesta");
        var fuentes = conjuntos.FirstOrDefault(c => c.Columnas.Contains("2_fuente"))?.Filas ?? [];
        var contexto = conjuntos.FirstOrDefault(c => c.Columnas.Contains("3_contexto_enviado_al_modelo"))?.Filas.FirstOrDefault();

        return new RespuestaPregunta(
            Pregunta: pregunta,
            Respuesta: Texto(respuesta, "4_respuesta") ?? "",
            Camino: Texto(respuesta, "camino") ?? "documentos",
            CifrasVerificadas: Valor<bool?>(respuesta, "cifras_verificadas"),
            Modelo: Texto(respuesta, "modelo"),
            Milisegundos: Valor<int?>(respuesta, "milisegundos"),
            Contexto: contexto is null ? null : Texto(contexto, "3_contexto_enviado_al_modelo"),
            Fuentes: fuentes.Select(f => new Fuente(
                N: Valor<int?>(f, "2_fuente") ?? 0,
                DocumentoId: Valor<int?>(f, "documento_id"),
                Archivo: Texto(f, "archivo") ?? "",
                Pagina: Valor<short?>(f, "pagina") is { } p ? p : null,
                Similitud: Valor<decimal?>(f, "similitud"),
                Pasaje: Texto(f, "fragmento_completo") ?? Texto(f, "fragmento"),
                Tipo: Texto(f, "tipo"),
                Direccion: Texto(f, "direccion"),
                Fecha: Valor<DateTime?>(f, "fecha") is { } d ? DateOnly.FromDateTime(d) : null,
                Importe: Valor<decimal?>(f, "importe"),
                Moneda: Texto(f, "moneda"))).ToList(),
            Calculo: Texto(respuesta, "calculo"));
    }

    /* ------------------------------------------------------------------ archivar */

    public async Task<(int DocumentoId, bool YaExistia)> ArchivarAsync(
        string nombreArchivo, string texto, int paginas, string archivoLocal, CancellationToken ct = default)
    {
        await using var cn = await AbrirAsync(Perfil.Administracion, ct);
        await using var cmd = Comando(cn, "archivo.usp_archivar_documento", Perfil.Administracion, procedimiento: true);
        cmd.Parameters.Add(new SqlParameter("@nombre_archivo", SqlDbType.NVarChar, 260) { Value = Recortar(nombreArchivo, 260) });
        cmd.Parameters.Add(new SqlParameter("@texto", SqlDbType.NVarChar, -1) { Value = texto });
        cmd.Parameters.Add(new SqlParameter("@paginas", SqlDbType.SmallInt) { Value = (short)Math.Min(paginas, short.MaxValue) });
        cmd.Parameters.Add(new SqlParameter("@archivo_local", SqlDbType.NVarChar, 260) { Value = archivoLocal });
        var id = cmd.Parameters.Add(new SqlParameter("@documento_id", SqlDbType.Int) { Direction = ParameterDirection.Output });
        var existia = cmd.Parameters.Add(new SqlParameter("@ya_existia", SqlDbType.Bit) { Direction = ParameterDirection.Output });
        await Proteger(() => cmd.ExecuteNonQueryAsync(ct));
        return ((int)id.Value, (bool)existia.Value);
    }

    /// <summary>La IA local lee el documento: tipo, tercero, fecha, importes (usp_clasificar_y_extraer).</summary>
    public async Task<ResultadoClasificacion> ClasificarAsync(int documentoId, CancellationToken ct = default)
    {
        var conjuntos = await EjecutarConjuntosAsync(
            "EXEC archivo.usp_clasificar_y_extraer @documento_id = @id;", Perfil.Administracion, ct,
            new SqlParameter("@id", SqlDbType.Int) { Value = documentoId });
        var f = conjuntos.LastOrDefault(c => c.Columnas.Contains("tipo"))?.Filas.FirstOrDefault()
                ?? throw new ArchivoException("ErrorSinRespuesta");
        return new ResultadoClasificacion(
            Tipo: Texto(f, "tipo") ?? "otro",
            Direccion: Texto(f, "direccion"),
            Tercero: Texto(f, "tercero_enlazado"),
            Numero: Texto(f, "numero"),
            Fecha: Valor<DateTime?>(f, "fecha_documento") is { } d ? DateOnly.FromDateTime(d) : null,
            Importe: Valor<decimal?>(f, "importe_total"),
            Confianza: Valor<decimal?>(f, "confianza"),
            Aviso: Texto(f, "aviso"));
    }

    /// <summary>Trocea el documento y genera sus vectores. Devuelve cuántos fragmentos se quedaron sin vector.</summary>
    public async Task<int> IndexarAsync(int documentoId, CancellationToken ct = default)
    {
        await using var cn = await AbrirAsync(Perfil.Administracion, ct);
        // La clasificación cambia la cabecera de los fragmentos (tipo · tercero): se rehacen
        const string sql = """
            DELETE FROM archivo.fragmentos WHERE documento_id = @id;
            EXEC archivo.usp_generar_embeddings @documento_id = @id;
            SELECT COUNT(*) FROM archivo.fragmentos WHERE documento_id = @id AND embedding IS NULL;
            """;
        await using var cmd = Comando(cn, sql, Perfil.Administracion);
        cmd.Parameters.Add(new SqlParameter("@id", SqlDbType.Int) { Value = documentoId });
        return await Proteger(async () => Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)));
    }

    /* ------------------------------------------------------------------ documentos */

    public async Task<IReadOnlyList<FilaDocumento>> ListarAsync(FiltroDocumentos filtro, Perfil perfil, CancellationToken ct = default)
    {
        const string sql = """
            SELECT d.documento_id, d.nombre_archivo, d.tipo, d.direccion, t.nombre AS tercero, d.numero,
                   d.fecha_documento, d.importe_total, d.moneda, d.estado,
                   CAST(CASE WHEN d.archivo_local IS NULL THEN 0 ELSE 1 END AS bit) AS tiene_pdf
            FROM archivo.documentos AS d
            LEFT JOIN archivo.terceros AS t ON t.tercero_id = d.tercero_id
            WHERE (@tipo IS NULL OR d.tipo = @tipo)
              AND (@anio IS NULL OR YEAR(d.fecha_documento) = @anio)
              AND (@texto IS NULL
                   OR d.nombre_archivo LIKE @patron OR t.nombre LIKE @patron OR d.numero LIKE @patron)
            ORDER BY d.fecha_documento DESC, d.documento_id DESC;
            """;
        var texto = string.IsNullOrWhiteSpace(filtro.Texto) ? null : filtro.Texto.Trim();
        var conjuntos = await EjecutarConjuntosAsync(sql, perfil, ct,
            new SqlParameter("@tipo", SqlDbType.VarChar, 20) { Value = (object?)filtro.Tipo ?? DBNull.Value },
            new SqlParameter("@anio", SqlDbType.Int) { Value = (object?)filtro.Anio ?? DBNull.Value },
            new SqlParameter("@texto", SqlDbType.NVarChar, 200) { Value = (object?)texto ?? DBNull.Value },
            new SqlParameter("@patron", SqlDbType.NVarChar, 210) { Value = texto is null ? DBNull.Value : $"%{EscaparLike(texto)}%" });
        return conjuntos.FirstOrDefault()?.Filas.Select(LeerFila).ToList() ?? [];
    }

    public async Task<IReadOnlyList<int>> AniosAsync(Perfil perfil, CancellationToken ct = default)
    {
        var conjuntos = await EjecutarConjuntosAsync(
            "SELECT DISTINCT YEAR(fecha_documento) AS anio FROM archivo.documentos WHERE fecha_documento IS NOT NULL ORDER BY anio DESC;",
            perfil, ct);
        return conjuntos.FirstOrDefault()?.Filas.Select(f => Valor<int?>(f, "anio") ?? 0).ToList() ?? [];
    }

    public async Task<DetalleDocumento?> ObtenerAsync(int documentoId, Perfil perfil, CancellationToken ct = default)
    {
        const string sql = """
            SELECT d.documento_id, d.nombre_archivo, d.tipo, d.direccion, t.nombre AS tercero, d.numero,
                   d.fecha_documento, d.importe_total, d.moneda, d.estado,
                   CAST(CASE WHEN d.archivo_local IS NULL THEN 0 ELSE 1 END AS bit) AS tiene_pdf,
                   d.departamento, d.paginas, d.texto, d.conservar_hasta, d.archivo_local,
                   (SELECT COUNT(*) FROM archivo.fragmentos AS f WHERE f.documento_id = d.documento_id) AS fragmentos,
                   (SELECT COUNT(*) FROM archivo.fragmentos AS f WHERE f.documento_id = d.documento_id AND f.embedding IS NOT NULL) AS con_vector
            FROM archivo.documentos AS d
            LEFT JOIN archivo.terceros AS t ON t.tercero_id = d.tercero_id
            WHERE d.documento_id = @id;

            SELECT nombre_campo,
                   COALESCE(valor_texto, CONVERT(nvarchar(40), valor_numero), CONVERT(nvarchar(10), valor_fecha, 23)) AS valor,
                   confianza, corregido, extraido_por
            FROM archivo.campos_extraidos
            WHERE documento_id = @id
            ORDER BY campo_id;
            """;
        var conjuntos = await EjecutarConjuntosAsync(sql, perfil, ct, new SqlParameter("@id", SqlDbType.Int) { Value = documentoId });
        var f = conjuntos[0].Filas.FirstOrDefault();
        if (f is null)
            return null;   // no existe o el perfil no tiene permiso (Row-Level Security)

        return new DetalleDocumento(
            Documento: LeerFila(f),
            Departamento: Texto(f, "departamento") ?? "",
            Paginas: Valor<short?>(f, "paginas") ?? 1,
            Texto: Texto(f, "texto"),
            ConservarHasta: Valor<DateTime?>(f, "conservar_hasta") is { } c ? DateOnly.FromDateTime(c) : null,
            ArchivoLocal: Texto(f, "archivo_local"),
            Fragmentos: Valor<int?>(f, "fragmentos") ?? 0,
            FragmentosConVector: Valor<int?>(f, "con_vector") ?? 0,
            Campos: conjuntos.Count > 1
                ? conjuntos[1].Filas.Select(c => new CampoExtraido(
                    Texto(c, "nombre_campo") ?? "", Texto(c, "valor"), Valor<decimal?>(c, "confianza"),
                    Valor<bool?>(c, "corregido") ?? false, Texto(c, "extraido_por") ?? "")).ToList()
                : []);
    }

    /// <summary>Nombre del PDF original de un documento, comprobando antes que el perfil puede verlo.</summary>
    public async Task<(string NombreArchivo, string? ArchivoLocal)?> ArchivoOriginalAsync(int documentoId, Perfil perfil, CancellationToken ct = default)
    {
        var conjuntos = await EjecutarConjuntosAsync(
            "SELECT nombre_archivo, archivo_local FROM archivo.documentos WHERE documento_id = @id;", perfil, ct,
            new SqlParameter("@id", SqlDbType.Int) { Value = documentoId });
        var f = conjuntos.FirstOrDefault()?.Filas.FirstOrDefault();
        return f is null ? null : (Texto(f, "nombre_archivo") ?? "", Texto(f, "archivo_local"));
    }

    /// <summary>Borrado RGPD: el documento y todo lo derivado (campos, fragmentos). Queda constancia en auditoría.</summary>
    public async Task BorrarAsync(int documentoId, CancellationToken ct = default)
    {
        await using var cn = await AbrirAsync(Perfil.Administracion, ct);
        await using var cmd = Comando(cn, "archivo.usp_borrar_documento", Perfil.Administracion, procedimiento: true);
        cmd.Parameters.Add(new SqlParameter("@documento_id", SqlDbType.Int) { Value = documentoId });
        await Proteger(() => cmd.ExecuteNonQueryAsync(ct));
    }

    /* ------------------------------------------------------------------ infraestructura */

    private sealed record Conjunto(HashSet<string> Columnas, List<Dictionary<string, object?>> Filas);

    private async Task<List<Conjunto>> EjecutarConjuntosAsync(string sql, Perfil perfil, CancellationToken ct, params SqlParameter[] parametros)
    {
        await using var cn = await AbrirAsync(perfil, ct);
        await using var cmd = Comando(cn, sql, perfil);
        cmd.Parameters.AddRange(parametros);

        return await Proteger(async () =>
        {
            var conjuntos = new List<Conjunto>();
            await using var lector = await cmd.ExecuteReaderAsync(ct);
            do
            {
                if (lector.FieldCount == 0)
                    continue;
                var columnas = Enumerable.Range(0, lector.FieldCount).Select(lector.GetName).ToArray();
                var conjunto = new Conjunto(new HashSet<string>(columnas, StringComparer.OrdinalIgnoreCase), []);
                while (await lector.ReadAsync(ct))
                {
                    var fila = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
                    for (var i = 0; i < columnas.Length; i++)
                        fila[columnas[i]] = lector.IsDBNull(i) ? null : lector.GetValue(i);
                    conjunto.Filas.Add(fila);
                }
                conjuntos.Add(conjunto);
            } while (await lector.NextResultAsync(ct));
            return conjuntos;
        });
    }

    private async Task<SqlConnection> AbrirAsync(Perfil perfil, CancellationToken ct)
    {
        var cadena = new SqlConnectionStringBuilder(_op.Conexion) { ApplicationName = "Mnemos Archive" };
        // Con EXECUTE AS la conexión no vuelve al pool: así un error a mitad nunca deja
        // una conexión suplantando a otro usuario para la siguiente consulta.
        if (perfil.UsuarioSql() is not null)
            cadena.Pooling = false;

        var cn = new SqlConnection(cadena.ConnectionString);
        await Proteger(async () => { await cn.OpenAsync(ct); return 0; });
        return cn;
    }

    private SqlCommand Comando(SqlConnection cn, string sql, Perfil perfil, bool procedimiento = false)
    {
        var usuario = perfil.UsuarioSql();   // valor fijo de una lista cerrada, nunca texto del usuario
        if (procedimiento && usuario is not null)
            throw new InvalidOperationException("Los procedimientos que modifican datos solo se ejecutan como administración.");

        var texto = usuario is null ? sql : $"EXECUTE AS USER = N'{usuario}';\n{sql}\nREVERT;";
        return new SqlCommand(texto, cn)
        {
            CommandType = procedimiento ? CommandType.StoredProcedure : CommandType.Text,
            CommandTimeout = _op.TiempoMaximoSegundos,
        };
    }

    /// <summary>Convierte los errores de SQL Server en mensajes que se pueden enseñar.</summary>
    private static async Task<T> Proteger<T>(Func<Task<T>> accion)
    {
        try
        {
            return await accion();
        }
        catch (SqlException ex)
        {
            throw Traducir(ex);
        }
    }

    public static ArchivoException Traducir(SqlException ex) => ex.Number switch
    {
        >= 50000 => new ArchivoException(null, ex.Message, ex),                 // THROW del archivo: ya redactado
        -2 => new ArchivoException("ErrorTiempo", null, ex),                     // tiempo de espera agotado
        2 or 53 or -1 or 10061 or 11001 => new ArchivoException("ErrorConexion", null, ex),
        4060 => new ArchivoException("ErrorBaseDatos", null, ex),                // la base de datos no existe
        18456 => new ArchivoException("ErrorLogin", null, ex),
        31608 or 31609 or 31629 => new ArchivoException("ErrorModelo", null, ex), // Ollama o Caddy no responden
        229 or 230 => new ArchivoException("ErrorPermiso", null, ex),
        _ => new ArchivoException(null, ex.Message, ex),
    };

    private static FilaDocumento LeerFila(Dictionary<string, object?> f) => new(
        DocumentoId: Valor<int?>(f, "documento_id") ?? 0,
        NombreArchivo: Texto(f, "nombre_archivo") ?? "",
        Tipo: Texto(f, "tipo") ?? "",
        Direccion: Texto(f, "direccion"),
        Tercero: Texto(f, "tercero"),
        Numero: Texto(f, "numero"),
        Fecha: Valor<DateTime?>(f, "fecha_documento") is { } d ? DateOnly.FromDateTime(d) : null,
        Importe: Valor<decimal?>(f, "importe_total"),
        Moneda: Texto(f, "moneda") ?? "EUR",
        Estado: Texto(f, "estado") ?? "",
        TienePdf: Valor<bool?>(f, "tiene_pdf") ?? false);

    private static string? Texto(Dictionary<string, object?> fila, string columna) =>
        fila.TryGetValue(columna, out var v) && v is not null ? Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture)?.Trim() : null;

    private static T? Valor<T>(Dictionary<string, object?> fila, string columna)
    {
        if (!fila.TryGetValue(columna, out var v) || v is null)
            return default;
        var destino = Nullable.GetUnderlyingType(typeof(T)) ?? typeof(T);
        return (T)Convert.ChangeType(v, destino, System.Globalization.CultureInfo.InvariantCulture);
    }

    private static string Recortar(string s, int max) => s.Length <= max ? s : s[..max];

    public static string EscaparLike(string s) => s.Replace("[", "[[]").Replace("%", "[%]").Replace("_", "[_]");
}

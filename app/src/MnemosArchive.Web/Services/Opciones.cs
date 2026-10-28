namespace MnemosArchive.Web.Services;

/// <summary>Configuración de la app (sección "Archivo" de appsettings.json).</summary>
public sealed class OpcionesArchivo
{
    public const string Seccion = "Archivo";

    /// <summary>Cadena de conexión a SQL Server. Por defecto, la instancia local con tu usuario de Windows.</summary>
    public string Conexion { get; set; } =
        "Server=localhost;Database=MnemosArchive;Integrated Security=true;Encrypt=true;TrustServerCertificate=true";

    /// <summary>Carpeta donde se guardan los PDF originales. Vacía: %LOCALAPPDATA%\Mnemos Archive\documentos.</summary>
    public string CarpetaDocumentos { get; set; } = "";

    /// <summary>Tamaño máximo de cada PDF, en MB.</summary>
    public int TamanoMaximoMb { get; set; } = 25;

    /// <summary>Segundos que se espera a SQL Server en las operaciones que llaman al modelo local.</summary>
    public int TiempoMaximoSegundos { get; set; } = 600;

    public string CarpetaEfectiva =>
        string.IsNullOrWhiteSpace(CarpetaDocumentos)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mnemos Archive", "documentos")
            : Environment.ExpandEnvironmentVariables(CarpetaDocumentos);
}

/// <summary>
/// Con qué permisos se consulta el archivo. La base de datos aplica Row-Level Security
/// y máscaras según el usuario: así se puede ver el mismo archivo como lo vería cada departamento.
/// </summary>
public enum Perfil
{
    Administracion,
    Contabilidad,
    Legal,
}

public static class PerfilExtensiones
{
    /// <summary>Usuario de base de datos (sin login) que se suplanta con EXECUTE AS. Null: tu propio usuario.</summary>
    public static string? UsuarioSql(this Perfil perfil) => perfil switch
    {
        Perfil.Contabilidad => "usr_contable",
        Perfil.Legal => "usr_legal",
        _ => null,
    };

    public static string Codigo(this Perfil perfil) => perfil switch
    {
        Perfil.Contabilidad => "contabilidad",
        Perfil.Legal => "legal",
        _ => "administracion",
    };

    public static Perfil DesdeCodigo(string? codigo) => codigo switch
    {
        "contabilidad" => Perfil.Contabilidad,
        "legal" => Perfil.Legal,
        _ => Perfil.Administracion,
    };

    /// <summary>Solo administración puede archivar, leer con la IA y borrar (lo exigen los permisos de SQL).</summary>
    public static bool PuedeModificar(this Perfil perfil) => perfil == Perfil.Administracion;
}

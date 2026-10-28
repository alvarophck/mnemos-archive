using System.Globalization;

namespace MnemosArchive.Web.Services;

public static class Preferencias
{
    public const string CookiePerfil = "mnemos-perfil";

    public static Perfil PerfilDe(HttpContext http) =>
        PerfilExtensiones.DesdeCodigo(http.Request.Cookies[CookiePerfil]);

    /// <summary>Formatos con la cultura de la interfaz: cifras y fechas siempre calculadas, nunca redondeadas a mano.</summary>
    public static string Importe(decimal? importe, string? moneda) =>
        importe is null ? "—" : $"{importe.Value.ToString("N2", CultureInfo.CurrentCulture)} {moneda ?? "EUR"}";

    public static string Fecha(DateOnly? fecha) =>
        fecha is null ? "—" : fecha.Value.ToString("d", CultureInfo.CurrentCulture);

    public static string Tamano(long bytes) => bytes switch
    {
        < 1024 => $"{bytes} B",
        < 1024 * 1024 => $"{(bytes / 1024d).ToString("N0", CultureInfo.CurrentCulture)} KB",
        _ => $"{(bytes / 1024d / 1024d).ToString("N1", CultureInfo.CurrentCulture)} MB",
    };
}

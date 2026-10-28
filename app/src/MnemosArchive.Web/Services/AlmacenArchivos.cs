using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Options;

namespace MnemosArchive.Web.Services;

/// <summary>
/// Guarda los PDF originales en una carpeta local. El nombre es el SHA-256 del archivo:
/// el mismo PDF nunca se guarda dos veces y nadie puede pedir una ruta arbitraria.
/// En la base de datos solo se guarda ese nombre (documentos.archivo_local).
/// </summary>
public sealed partial class AlmacenArchivos(IOptions<OpcionesArchivo> opciones)
{
    public string Carpeta { get; } = opciones.Value.CarpetaEfectiva;

    public static string NombrePara(ReadOnlySpan<byte> contenido) =>
        Convert.ToHexStringLower(SHA256.HashData(contenido)) + ".pdf";

    public static bool NombreValido(string? nombre) => nombre is not null && NombreSeguro().IsMatch(nombre);

    /// <summary>Guarda el PDF y devuelve su nombre. Si ya existía, no lo vuelve a escribir.</summary>
    public async Task<string> GuardarAsync(byte[] contenido, CancellationToken ct = default)
    {
        var nombre = NombrePara(contenido);
        var destino = Path.Combine(Carpeta, nombre);
        if (File.Exists(destino))
            return nombre;

        Directory.CreateDirectory(Carpeta);
        var temporal = destino + ".tmp";
        await File.WriteAllBytesAsync(temporal, contenido, ct);
        File.Move(temporal, destino, overwrite: true);   // así nunca queda un PDF a medias con su nombre final
        return nombre;
    }

    /// <summary>Ruta completa de un PDF guardado, o null si el nombre no es válido o el archivo ya no está.</summary>
    public string? Ruta(string? nombre)
    {
        if (!NombreValido(nombre))
            return null;
        var ruta = Path.Combine(Carpeta, nombre!);
        return File.Exists(ruta) ? ruta : null;
    }

    public void Borrar(string? nombre)
    {
        var ruta = Ruta(nombre);
        if (ruta is not null)
            File.Delete(ruta);
    }

    [GeneratedRegex("^[0-9a-f]{64}\\.pdf$")]
    private static partial Regex NombreSeguro();
}

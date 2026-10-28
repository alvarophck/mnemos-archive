using System.Text;
using System.Text.RegularExpressions;
using UglyToad.PdfPig;
using UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor;

namespace MnemosArchive.Web.Services;

/// <summary>Texto de un PDF con marcas "[página N]" (desde la 2), el formato que usa la base de datos para citar páginas.</summary>
public sealed record TextoPdf(string Texto, int Paginas, bool PareceEscaneado);

/// <summary>El PDF no se puede leer. Clave: texto de la interfaz que explica el motivo.</summary>
public sealed class PdfNoValidoException(string clave, Exception? inner = null) : Exception(clave, inner)
{
    public string Clave { get; } = clave;
}

/// <summary>
/// Lee el texto de un PDF página a página. SQL Server no sabe abrir PDFs: esto es lo único
/// que la app hace antes de entregar el documento a usp_archivar_documento.
/// </summary>
public static partial class LectorPdf
{
    /// <summary>Por debajo de esta media de letras por página se considera una imagen escaneada.</summary>
    public const int LetrasMinimasPorPagina = 25;

    public static bool EmpiezaComoPdf(ReadOnlySpan<byte> bytes) =>
        bytes.Length >= 5 && bytes[..5].SequenceEqual("%PDF-"u8);

    public static TextoPdf Leer(byte[] bytes)
    {
        if (!EmpiezaComoPdf(bytes))
            throw new PdfNoValidoException("NoEsPdf");

        PdfDocument documento;
        try
        {
            documento = PdfDocument.Open(bytes);
        }
        catch (Exception ex) when (ex.Message.Contains("password", StringComparison.OrdinalIgnoreCase)
                                   || ex.GetType().Name.Contains("Encryption", StringComparison.Ordinal))
        {
            throw new PdfNoValidoException("PdfConContrasena", ex);
        }
        catch (Exception ex)
        {
            throw new PdfNoValidoException("PdfDanado", ex);
        }

        using (documento)
        {
            var texto = new StringBuilder();
            var letras = 0;
            foreach (var pagina in documento.GetPages())
            {
                var contenido = Limpiar(ContentOrderTextExtractor.GetText(pagina));
                letras += contenido.Count(char.IsLetter);
                if (pagina.Number > 1)
                    texto.Append("\n\n[página ").Append(pagina.Number).Append("]\n");
                texto.Append(contenido);
            }

            var paginas = Math.Max(documento.NumberOfPages, 1);
            return new TextoPdf(texto.ToString().Trim(), paginas, letras < LetrasMinimasPorPagina * paginas);
        }
    }

    /// <summary>Quita espacios repetidos y líneas vacías de más, sin tocar el contenido.</summary>
    public static string Limpiar(string texto)
    {
        var lineas = texto.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n')
                          .Select(l => EspaciosRepetidos().Replace(l, " ").TrimEnd());
        return LineasVacias().Replace(string.Join('\n', lineas), "\n\n").Trim();
    }

    [GeneratedRegex(@"[ \t ]{2,}")]
    private static partial Regex EspaciosRepetidos();

    [GeneratedRegex(@"\n{3,}")]
    private static partial Regex LineasVacias();
}

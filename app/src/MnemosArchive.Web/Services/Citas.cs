using System.Text.RegularExpressions;

namespace MnemosArchive.Web.Services;

/// <summary>Un trozo de la respuesta: texto normal o una marca de cita [n].</summary>
public sealed record Segmento(string Texto, int? Cita);

/// <summary>Separa la respuesta del modelo en texto y citas [1], [2]... para enlazarlas con sus fuentes.</summary>
public static partial class Citas
{
    public static IReadOnlyList<Segmento> Separar(string? respuesta, int numeroFuentes)
    {
        var segmentos = new List<Segmento>();
        if (string.IsNullOrEmpty(respuesta))
            return segmentos;

        var posicion = 0;
        foreach (Match m in MarcaCita().Matches(respuesta))
        {
            var n = int.Parse(m.Groups[1].Value);
            if (n < 1 || n > numeroFuentes)
                continue;   // una marca que no corresponde a ninguna fuente se deja como texto
            if (m.Index > posicion)
                segmentos.Add(new Segmento(respuesta[posicion..m.Index], null));
            segmentos.Add(new Segmento(m.Value, n));
            posicion = m.Index + m.Length;
        }
        if (posicion < respuesta.Length)
            segmentos.Add(new Segmento(respuesta[posicion..], null));
        return segmentos;
    }

    /// <summary>Números de fuente citados en la respuesta, sin repetir y en orden.</summary>
    public static IReadOnlyList<int> Citadas(string? respuesta, int numeroFuentes) =>
        Separar(respuesta, numeroFuentes).Where(s => s.Cita is not null).Select(s => s.Cita!.Value).Distinct().ToList();

    [GeneratedRegex(@"\[(\d{1,2})\]")]
    private static partial Regex MarcaCita();
}

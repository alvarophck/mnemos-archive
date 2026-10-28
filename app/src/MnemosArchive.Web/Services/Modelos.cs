namespace MnemosArchive.Web.Services;

/// <summary>Una fuente de la respuesta: un pasaje (camino "documentos") o un documento con sus cifras (camino "datos").</summary>
public sealed record Fuente(
    int N,
    int? DocumentoId,
    string Archivo,
    int? Pagina,
    decimal? Similitud,
    string? Pasaje,
    string? Tipo,
    string? Direccion,
    DateOnly? Fecha,
    decimal? Importe,
    string? Moneda);

public sealed record RespuestaPregunta(
    string Pregunta,
    string Respuesta,
    string Camino,               // "documentos" (RAG) o "datos" (SQL calcula)
    bool? CifrasVerificadas,     // solo en el camino "datos"
    string? Modelo,
    int? Milisegundos,
    string? Contexto,
    IReadOnlyList<Fuente> Fuentes,
    string? Calculo = null)      // la cuenta hecha por SQL Server: "145,20 EUR × 2 = 290,40 EUR"
{
    public bool EsDatos => Camino == "datos";
}

public sealed record FilaDocumento(
    int DocumentoId,
    string NombreArchivo,
    string Tipo,
    string? Direccion,
    string? Tercero,
    string? Numero,
    DateOnly? Fecha,
    decimal? Importe,
    string Moneda,
    string Estado,
    bool TienePdf);

public sealed record FiltroDocumentos(string? Texto, string? Tipo, int? Anio);

public sealed record CampoExtraido(
    string Nombre,
    string? Valor,
    decimal? Confianza,
    bool Corregido,
    string ExtraidoPor);

public sealed record DetalleDocumento(
    FilaDocumento Documento,
    string Departamento,
    int Paginas,
    string? Texto,
    DateOnly? ConservarHasta,
    string? ArchivoLocal,
    int Fragmentos,
    int FragmentosConVector,
    IReadOnlyList<CampoExtraido> Campos);

public sealed record ResultadoClasificacion(
    string Tipo,
    string? Direccion,
    string? Tercero,
    string? Numero,
    DateOnly? Fecha,
    decimal? Importe,
    decimal? Confianza,
    string? Aviso);

/// <summary>Estado de un PDF en la cola de "Archivar".</summary>
public enum PasoArchivado
{
    EnCola,
    Leyendo,
    Guardando,
    Clasificando,
    Indexando,
    Listo,
    YaExistia,
    Escaneado,
    Error,
}

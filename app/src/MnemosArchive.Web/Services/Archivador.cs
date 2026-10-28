namespace MnemosArchive.Web.Services;

/// <summary>Un PDF en la cola de "Archivar" y lo que le ha pasado.</summary>
public sealed class ElementoArchivado(string nombre, long tamano)
{
    public string Nombre { get; } = nombre;
    public long Tamano { get; } = tamano;
    public PasoArchivado Paso { get; set; } = PasoArchivado.EnCola;
    public int? DocumentoId { get; set; }
    public int Paginas { get; set; }
    public ResultadoClasificacion? Clasificacion { get; set; }
    /// <summary>Clave de texto de la interfaz para el problema, o mensaje de SQL Server ya redactado.</summary>
    public string? ErrorClave { get; set; }
    public string? ErrorSql { get; set; }
    /// <summary>Fragmentos que se quedaron sin vector: el documento está archivado pero aún no se encuentra buscando.</summary>
    public int SinVector { get; set; }
    public bool Terminado => Paso is PasoArchivado.Listo or PasoArchivado.YaExistia or PasoArchivado.Escaneado or PasoArchivado.Error;
}

/// <summary>
/// Archivar un PDF de principio a fin:
/// leer el texto → guardar el original → usp_archivar_documento → la IA lo lee → vectores.
/// Si la IA falla, el documento queda archivado como pendiente y se puede reintentar desde su ficha.
/// </summary>
public sealed class Archivador(ArchivoDb db, AlmacenArchivos almacen)
{
    public async Task ProcesarAsync(ElementoArchivado e, byte[] contenido, Func<Task> avisar, CancellationToken ct = default)
    {
        async Task Paso(PasoArchivado p) { e.Paso = p; await avisar(); }

        try
        {
            await Paso(PasoArchivado.Leyendo);
            TextoPdf pdf;
            try
            {
                pdf = LectorPdf.Leer(contenido);
            }
            catch (PdfNoValidoException ex)
            {
                e.ErrorClave = ex.Clave;
                await Paso(PasoArchivado.Error);
                return;
            }

            e.Paginas = pdf.Paginas;
            if (pdf.PareceEscaneado)
            {
                // Sin texto no hay nada que leer: no se archiva un documento vacío ni se inventa su contenido
                await Paso(PasoArchivado.Escaneado);
                return;
            }

            await Paso(PasoArchivado.Guardando);
            var archivoLocal = await almacen.GuardarAsync(contenido, ct);
            var (id, yaExistia) = await db.ArchivarAsync(e.Nombre, pdf.Texto, pdf.Paginas, archivoLocal, ct);
            e.DocumentoId = id;
            if (yaExistia)
            {
                await Paso(PasoArchivado.YaExistia);
                return;
            }

            await LeerConIaAsync(e, avisar, ct);
        }
        catch (ArchivoException ex)
        {
            e.ErrorClave = ex.Clave;
            e.ErrorSql = ex.MensajeSql;
            await Paso(PasoArchivado.Error);
        }
    }

    /// <summary>Clasificación y vectores. También sirve para reintentar un documento pendiente.</summary>
    public async Task LeerConIaAsync(ElementoArchivado e, Func<Task> avisar, CancellationToken ct = default)
    {
        var id = e.DocumentoId ?? throw new InvalidOperationException("El documento aún no está archivado.");
        e.Paso = PasoArchivado.Clasificando; await avisar();
        e.Clasificacion = await db.ClasificarAsync(id, ct);
        e.Paso = PasoArchivado.Indexando; await avisar();
        e.SinVector = await db.IndexarAsync(id, ct);
        e.Paso = PasoArchivado.Listo; await avisar();
    }
}

using Microsoft.Extensions.Options;
using MnemosArchive.Web.Services;

namespace MnemosArchive.Tests;

public sealed class AlmacenTests : IDisposable
{
    private readonly string carpeta = Path.Combine(Path.GetTempPath(), "mnemos-tests-" + Guid.NewGuid().ToString("N"));
    private AlmacenArchivos Almacen() => new(Options.Create(new OpcionesArchivo { CarpetaDocumentos = carpeta }));

    [Fact]
    public async Task Guarda_con_el_hash_y_no_duplica()
    {
        var almacen = Almacen();
        var contenido = "%PDF-1.7 contenido"u8.ToArray();

        var nombre1 = await almacen.GuardarAsync(contenido);
        var nombre2 = await almacen.GuardarAsync(contenido);

        Assert.Equal(nombre1, nombre2);
        Assert.Matches("^[0-9a-f]{64}\\.pdf$", nombre1);
        Assert.Single(Directory.GetFiles(carpeta));
        Assert.Equal(contenido, await File.ReadAllBytesAsync(almacen.Ruta(nombre1)!));
    }

    [Theory]
    [InlineData("../secreto.pdf")]
    [InlineData("C:\\Windows\\win.ini")]
    [InlineData("abc.pdf")]
    [InlineData(null)]
    public void No_acepta_rutas_que_no_ha_creado(string? nombre)
    {
        Assert.False(AlmacenArchivos.NombreValido(nombre));
        Assert.Null(Almacen().Ruta(nombre));
    }

    [Fact]
    public async Task Borra_el_original()
    {
        var almacen = Almacen();
        var nombre = await almacen.GuardarAsync("%PDF-x"u8.ToArray());
        almacen.Borrar(nombre);
        Assert.Null(almacen.Ruta(nombre));
    }

    public void Dispose()
    {
        if (Directory.Exists(carpeta))
            Directory.Delete(carpeta, recursive: true);
    }
}

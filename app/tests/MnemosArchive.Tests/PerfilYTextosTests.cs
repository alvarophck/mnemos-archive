using System.Text.RegularExpressions;
using System.Xml.Linq;
using MnemosArchive.Web.Services;

namespace MnemosArchive.Tests;

public class PerfilYTextosTests
{
    [Theory]
    [InlineData("administracion", null)]
    [InlineData("contabilidad", "usr_contable")]
    [InlineData("legal", "usr_legal")]
    [InlineData("cualquier cosa'; DROP TABLE x --", null)]   // lo desconocido es administración: nunca se inyecta texto
    public void Cada_perfil_suplanta_a_su_usuario_de_base_de_datos(string codigo, string? usuario) =>
        Assert.Equal(usuario, PerfilExtensiones.DesdeCodigo(codigo).UsuarioSql());

    [Fact]
    public void Solo_administracion_modifica() =>
        Assert.Equal([Perfil.Administracion], Enum.GetValues<Perfil>().Where(p => p.PuedeModificar()));

    [Theory]
    [InlineData("50%", "50[%]")]
    [InlineData("a_b", "a[_]b")]
    [InlineData("[x]", "[[]x]")]
    public void Escapa_los_comodines_de_LIKE(string entrada, string esperado) =>
        Assert.Equal(esperado, ArchivoDb.EscaparLike(entrada));

    private static string Proyecto([System.Runtime.CompilerServices.CallerFilePath] string ruta = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(ruta)!, "..", "..", "src", "MnemosArchive.Web"));

    private static HashSet<string> Claves(string archivo) =>
        XDocument.Load(Path.Combine(Proyecto(), "Resources", archivo)).Root!
                 .Elements("data").Select(e => (string)e.Attribute("name")!).ToHashSet();

    [Fact]
    public void Espanol_e_ingles_tienen_los_mismos_textos()
    {
        var es = Claves("Textos.resx");
        var en = Claves("Textos.en.resx");
        Assert.Empty(es.Except(en));
        Assert.Empty(en.Except(es));
    }

    [Fact]
    public void Todo_texto_de_la_interfaz_existe_en_los_recursos()
    {
        var es = Claves("Textos.resx");
        var usadas = Directory.GetFiles(Path.Combine(Proyecto(), "Components"), "*.razor", SearchOption.AllDirectories)
            .SelectMany(f => Regex.Matches(File.ReadAllText(f), "L\\[\"([A-Za-z0-9_]+)\"\\]").Select(m => m.Groups[1].Value))
            .ToHashSet();
        Assert.Empty(usadas.Except(es));
    }
}

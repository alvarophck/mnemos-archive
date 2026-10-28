using MnemosArchive.Web.Services;

namespace MnemosArchive.Tests;

public class CitasTests
{
    [Fact]
    public void Separa_el_texto_y_las_citas()
    {
        var s = Citas.Separar("Hay que avisar con dos meses [1]. La renta es 950 € [2].", 2);

        Assert.Equal(5, s.Count);
        Assert.Equal("Hay que avisar con dos meses ", s[0].Texto);
        Assert.Equal(1, s[1].Cita);
        Assert.Equal(2, s[3].Cita);
        Assert.Equal(".", s[4].Texto);
    }

    [Fact]
    public void Una_cita_sin_fuente_se_queda_como_texto()
    {
        var s = Citas.Separar("Según [7], no.", 2);
        Assert.All(s, x => Assert.Null(x.Cita));
        Assert.Equal("Según [7], no.", string.Concat(s.Select(x => x.Texto)));
    }

    [Fact]
    public void Citadas_sin_repetir_y_en_orden()
    {
        Assert.Equal([2, 1], Citas.Citadas("x [2] y [1] z [2]", 3));
        Assert.Empty(Citas.Citadas("sin citas", 3));
        Assert.Empty(Citas.Separar(null, 3));
    }
}

using MnemosArchive.Web.Services;
using UglyToad.PdfPig.Content;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.Fonts.Standard14Fonts;
using UglyToad.PdfPig.Writer;

namespace MnemosArchive.Tests;

public class LectorPdfTests
{
    private static byte[] Pdf(params string[][] paginas)
    {
        var builder = new PdfDocumentBuilder();
        var fuente = builder.AddStandard14Font(Standard14Font.Helvetica);
        foreach (var lineas in paginas)
        {
            var pagina = builder.AddPage(PageSize.A4);
            var y = 780;
            foreach (var linea in lineas)
            {
                pagina.AddText(linea, 11, new PdfPoint(50, y), fuente);
                y -= 18;
            }
        }
        return builder.Build();
    }

    [Fact]
    public void Lee_el_texto_y_marca_las_paginas_desde_la_segunda()
    {
        var bytes = Pdf(
            ["Imprenta Lavapies SL - B86234519", "Factura IL-0611 de 14/10/2026"],
            ["Base imponible 300,00 EUR", "Total 363,00 EUR"]);

        var pdf = LectorPdf.Leer(bytes);

        Assert.Equal(2, pdf.Paginas);
        Assert.False(pdf.PareceEscaneado);
        Assert.StartsWith("Imprenta Lavapies SL", pdf.Texto);
        Assert.DoesNotContain("[página 1]", pdf.Texto);   // la página 1 no lleva marca: así cuenta fn_pagina_en
        var marca = pdf.Texto.IndexOf("[página 2]", StringComparison.Ordinal);
        Assert.True(marca > 0);
        Assert.True(pdf.Texto.IndexOf("Total 363,00 EUR", StringComparison.Ordinal) > marca);
    }

    [Fact]
    public void Un_pdf_sin_texto_parece_escaneado()
    {
        var builder = new PdfDocumentBuilder();
        builder.AddPage(PageSize.A4).DrawRectangle(new PdfPoint(50, 50), 300, 400);
        var pdf = LectorPdf.Leer(builder.Build());

        Assert.True(pdf.PareceEscaneado);
        Assert.Equal(1, pdf.Paginas);
    }

    [Fact]
    public void Rechaza_lo_que_no_es_pdf()
    {
        var ex = Assert.Throws<PdfNoValidoException>(() => LectorPdf.Leer("hola, no soy un PDF"u8.ToArray()));
        Assert.Equal("NoEsPdf", ex.Clave);
    }

    [Fact]
    public void Rechaza_un_pdf_danado()
    {
        var ex = Assert.Throws<PdfNoValidoException>(() => LectorPdf.Leer("%PDF-1.7\n basura sin estructura"u8.ToArray()));
        Assert.Equal("PdfDanado", ex.Clave);
    }

    [Theory]
    [InlineData("Total    363,00   EUR", "Total 363,00 EUR")]
    [InlineData("a\r\n\r\n\r\n\r\nb", "a\n\nb")]
    [InlineData("  línea con espacio final   \nsiguiente", "línea con espacio final\nsiguiente")]
    public void Limpia_espacios_sin_tocar_el_contenido(string entrada, string esperado) =>
        Assert.Equal(esperado, LectorPdf.Limpiar(entrada));
}

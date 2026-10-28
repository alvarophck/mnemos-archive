using System.Diagnostics;
using System.Globalization;
using Microsoft.AspNetCore.Localization;
using Microsoft.Extensions.Options;
using MnemosArchive.Web.Components;
using MnemosArchive.Web.Services;

var builder = WebApplication.CreateBuilder(args);

// Solo en este ordenador: la app escucha en 127.0.0.1 y nunca en la red
builder.WebHost.UseUrls(builder.Configuration["Urls"] ?? "http://127.0.0.1:5080");

// Estilos, fuentes y scripts (wwwroot) se sirven aunque la app se arranque desde otra carpeta
// o fuera del entorno de desarrollo: se localizan con el manifiesto que deja la compilación.
builder.WebHost.UseStaticWebAssets();

builder.Services.Configure<OpcionesArchivo>(builder.Configuration.GetSection(OpcionesArchivo.Seccion));
builder.Services.AddSingleton<AlmacenArchivos>();
builder.Services.AddSingleton<ArchivoDb>();
builder.Services.AddScoped<Archivador>();

builder.Services.AddLocalization(o => o.ResourcesPath = "Resources");
builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents(o => o.DetailedErrors = builder.Environment.IsDevelopment())
    .AddHubOptions(o => o.MaximumReceiveMessageSize = 64 * 1024);

var app = builder.Build();

if (!app.Environment.IsDevelopment())
    app.UseExceptionHandler("/Error", createScopeForErrors: true);

// Español e inglés desde el primer día. El idioma se guarda en una cookie.
var idiomas = new[] { "es", "en" };
app.UseRequestLocalization(new RequestLocalizationOptions()
    .SetDefaultCulture("es")
    .AddSupportedCultures(idiomas)
    .AddSupportedUICultures(idiomas));

app.UseAntiforgery();
app.MapStaticAssets();

// Preferencias: idioma y perfil. Se guardan en cookies y se recarga la página.
app.MapGet("/preferencias/idioma", (string valor, string? volver, HttpContext http) =>
{
    if (!idiomas.Contains(valor))
        valor = "es";
    http.Response.Cookies.Append(CookieRequestCultureProvider.DefaultCookieName,
        CookieRequestCultureProvider.MakeCookieValue(new RequestCulture(valor)),
        new CookieOptions { Expires = DateTimeOffset.UtcNow.AddYears(1), IsEssential = true, SameSite = SameSiteMode.Lax });
    return Results.LocalRedirect(RutaLocal(volver));
});

app.MapGet("/preferencias/perfil", (string valor, string? volver, HttpContext http) =>
{
    var perfil = PerfilExtensiones.DesdeCodigo(valor);
    http.Response.Cookies.Append(Preferencias.CookiePerfil, perfil.Codigo(),
        new CookieOptions { Expires = DateTimeOffset.UtcNow.AddYears(1), IsEssential = true, SameSite = SameSiteMode.Lax, HttpOnly = true });
    return Results.LocalRedirect(RutaLocal(volver));
});

// El PDF original. La base de datos decide si el perfil puede verlo (Row-Level Security).
app.MapGet("/archivo/{id:int}/pdf", async (int id, HttpContext http, ArchivoDb db, AlmacenArchivos almacen) =>
{
    var perfil = Preferencias.PerfilDe(http);
    var original = await db.ArchivoOriginalAsync(id, perfil, http.RequestAborted);
    var ruta = original is null ? null : almacen.Ruta(original.Value.ArchivoLocal);
    if (ruta is null)
        return Results.NotFound();
    http.Response.Headers.ContentDisposition = $"inline; filename*=UTF-8''{Uri.EscapeDataString(original!.Value.NombreArchivo)}";
    return Results.File(ruta, "application/pdf");
});

app.MapRazorComponents<App>()
    .AddInteractiveServerRenderMode();

// Al arrancar fuera de Visual Studio, se abre el navegador
app.Lifetime.ApplicationStarted.Register(() =>
{
    if (app.Configuration.GetValue("AbrirNavegador", false))
    {
        var url = app.Urls.FirstOrDefault() ?? "http://127.0.0.1:5080";
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch { app.Logger.LogInformation("Abre {Url} en el navegador.", url); }
    }
    app.Logger.LogInformation("Mnemos Archive está en {Url}", app.Urls.FirstOrDefault());
});

app.Run();

static string RutaLocal(string? volver) =>
    !string.IsNullOrEmpty(volver) && volver.StartsWith('/') && !volver.StartsWith("//") && !volver.StartsWith("/\\")
        ? volver : "/";

public partial class Program;

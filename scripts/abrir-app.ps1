<#
.SYNOPSIS
  Abre la app de Mnemos Archive en el navegador.

.DESCRIPTION
  Comprueba que está el SDK de .NET 9, compila la app la primera vez y la
  arranca en http://127.0.0.1:5080 (solo este ordenador). Se abre el
  navegador solo. Para cerrarla, pulsa Ctrl+C en esta ventana.

  Necesita lo mismo que el resto del proyecto: SQL Server con la base de
  datos MnemosArchive (scripts\instalar.ps1), Ollama y Caddy en marcha.

.PARAMETER Conexion
  Cadena de conexión, si tu SQL Server no es la instancia predeterminada
  (por ejemplo "Server=.\SQL2025;Database=MnemosArchive;Integrated Security=true;TrustServerCertificate=true").

.EXAMPLE
  .\scripts\abrir-app.ps1
#>
param(
    [string]$Conexion = ""
)

$ErrorActionPreference = "Stop"
$raiz = Split-Path -Parent $PSScriptRoot
$proyecto = Join-Path $raiz "app\src\MnemosArchive.Web"

# 1. SDK de .NET 9
$sdks = @()
if (Get-Command dotnet -ErrorAction SilentlyContinue) { $sdks = @(dotnet --list-sdks) }
if (-not ($sdks | Where-Object { $_ -match '^(9|1\d)\.' })) {
    Write-Host "Falta el SDK de .NET 9. Instálalo con:" -ForegroundColor Yellow
    Write-Host "  winget install Microsoft.DotNet.SDK.9" -ForegroundColor Cyan
    Write-Host "Después cierra y abre PowerShell y vuelve a ejecutar este script."
    exit 1
}

# 2. Arrancar (sin perfil de Visual Studio: entorno de producción y navegador automático)
if ($Conexion) { $env:Archivo__Conexion = $Conexion }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
Write-Host "Arrancando Mnemos Archive en http://127.0.0.1:5080 (Ctrl+C para cerrarla)..." -ForegroundColor Cyan
# Desde la carpeta del proyecto: ahí está wwwroot (estilos, fuentes y scripts)
Push-Location $proyecto
try {
    dotnet run -c Release --no-launch-profile
}
finally {
    Pop-Location
}

<#
.SYNOPSIS
  Crea Mnemos Archive desde cero y guarda la salida de cada script como evidencia.

.DESCRIPTION
  Ejecuta, en orden:
    database\01 ... 11   base de datos, datos, objetos, seguridad, consultas, optimizacion
    tests\tests.sql      pruebas de la parte relacional
    ai\01 ... 09         modelos, embeddings, busqueda, extraccion con IA y RAG  (salvo -SinIA)
    tests\tests_ia.sql   pruebas de la parte de IA                                (salvo -SinIA)
  La salida de cada script se guarda en evidencias\<script>.txt

.PARAMETER SqlInstance
  Instancia de SQL Server 2025. Por defecto .\SQL2025

.PARAMETER SinIA
  Solo la parte relacional (no necesita Ollama ni Caddy).

.EXAMPLE
  .\scripts\instalar.ps1
  .\scripts\instalar.ps1 -SinIA
  .\scripts\instalar.ps1 -SqlInstance ".\SQLEXPRESS"
#>
param(
    [string]$SqlInstance = ".\SQL2025",
    [switch]$SinIA
)

$raiz       = Split-Path -Parent $PSScriptRoot
$evidencias = Join-Path $raiz "evidencias"
New-Item -ItemType Directory -Force -Path $evidencias | Out-Null

$scripts = @()
$scripts += Get-ChildItem (Join-Path $raiz "database") -Filter "*.sql" | Sort-Object Name
$scripts += Get-Item (Join-Path $raiz "tests\tests.sql")
if (-not $SinIA) {
    $scripts += Get-ChildItem (Join-Path $raiz "ai") -Filter "*.sql" | Sort-Object Name
    $scripts += Get-Item (Join-Path $raiz "tests\tests_ia.sql")
}

Write-Host "Mnemos Archive - instalacion en $SqlInstance" -ForegroundColor White
$fallos = 0

foreach ($s in $scripts) {
    $carpeta = Split-Path -Leaf (Split-Path -Parent $s.FullName)
    $salida  = Join-Path $evidencias ("{0}_{1}.txt" -f $carpeta, $s.BaseName)
    Write-Host ("-> {0}\{1}" -f $carpeta, $s.Name) -ForegroundColor Cyan -NoNewline

    # -E Windows, -C confia en el certificado del servidor, -b para en error,
    # -I QUOTED_IDENTIFIER ON, -f 65001 lee los scripts en UTF-8 (tildes y enes)
    & sqlcmd -S $SqlInstance -E -C -b -I -f 65001 -W -i $s.FullName 2>&1 | Out-File -FilePath $salida -Encoding utf8
    if ($LASTEXITCODE -ne 0 -and (Select-String -Path $salida -Pattern "unknown|-f" -Quiet) -and
        -not (Select-String -Path $salida -Pattern "^Msg" -Quiet)) {
        # Versiones de sqlcmd sin la opcion -f: ya leen UTF-8 por defecto
        & sqlcmd -S $SqlInstance -E -C -b -I -W -i $s.FullName 2>&1 | Out-File -FilePath $salida -Encoding utf8
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ok" -ForegroundColor Green
    } else {
        $fallos++
        Write-Host "  ERROR (ver $salida)" -ForegroundColor Red
        Get-Content $salida | Select-String -Pattern "^Msg|FALLO" | Select-Object -First 3 |
            ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
        if ($carpeta -eq "database") { break }   # sin base de datos no tiene sentido seguir
    }
}

Write-Host ""
if ($fallos -eq 0) { Write-Host "Listo. Las salidas estan en evidencias\" -ForegroundColor Green }
else { Write-Host "$fallos script(s) con error. Revisa evidencias\" -ForegroundColor Red }
exit $fallos

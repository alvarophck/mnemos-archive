<#
.SYNOPSIS
  Comprueba que este equipo puede ejecutar Mnemos Archive.

.DESCRIPTION
  Revisa Git, sqlcmd, SQL Server 2025 (y el tipo vector), Ollama con sus
  modelos y el puente HTTPS de Caddy. Solo lee: no cambia nada.

.PARAMETER SqlInstance
  SQL Server instance to test. If omitted, every running local instance is
  tested and the first SQL Server 2025 one is reported.

.PARAMETER EmbeddingModel
  Ollama embedding model to look for. Default: bge-m3.

.PARAMETER LlmModel
  Ollama language model to look for. Default: qwen3:4b.

.EXAMPLE
  .\scripts\check-env.ps1
  .\scripts\check-env.ps1 -SqlInstance ".\SQLEXPRESS"
#>
param(
    [string]$SqlInstance = "localhost",
    [string]$EmbeddingModel = "bge-m3",
    [string]$LlmModel = "qwen3:4b",
    [string]$OllamaUrl = "http://localhost:11434"
)

$script:fail = 0
$script:warn = 0

function Ok($msg)   { Write-Host "  [ OK ] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow; $script:warn++ }
function Bad($msg)  { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:fail++ }
function Hint($msg) { Write-Host "         -> $msg" -ForegroundColor DarkGray }
function Section($t){ Write-Host ""; Write-Host $t -ForegroundColor Cyan }

Write-Host "Mnemos Archive - comprobacion del entorno" -ForegroundColor White

# --- Git -------------------------------------------------------------------
Section "Git"
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) { Ok (& git --version) } else { Bad "Git not found"; Hint "Install from https://git-scm.com/download/win" }

# --- SQL Server ------------------------------------------------------------
Section "SQL Server"

function Test-SqlInstance([string]$inst) {
    $q = "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS varchar(10)) + '|' + CAST(SERVERPROPERTY('ProductVersion') AS varchar(50)) + '|' + CAST(SERVERPROPERTY('Edition') AS varchar(100));"
    $out = & sqlcmd -S $inst -E -C -b -h -1 -W -l 5 -Q $q 2>&1
    $line = $out | Where-Object { $_ -match "^\d+\|" } | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or -not $line) {
        return [pscustomobject]@{ Instance = $inst; Ok = $false; Major = 0; Version = ""; Edition = ""; Error = ($out -join " ") }
    }
    $p = $line.Trim().Split("|")
    return [pscustomobject]@{ Instance = $inst; Ok = $true; Major = [int]$p[0]; Version = $p[1]; Edition = $p[2]; Error = "" }
}

$sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
if (-not $sqlcmd) {
    Bad "sqlcmd not found"
    Hint "Install it with: winget install Microsoft.Sqlcmd"
} else {
    Ok "sqlcmd found"

    # Which instances to test: the one given, or every local SQL Server service.
    $targets = @()
    if ($PSBoundParameters.ContainsKey("SqlInstance")) {
        $targets = @($SqlInstance)
    } else {
        $svc = Get-Service -Name "MSSQL*" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq "MSSQLSERVER" -or $_.Name -like 'MSSQL$*' }
        foreach ($s in $svc) {
            $inst = if ($s.Name -eq "MSSQLSERVER") { "localhost" } else { ".\" + $s.Name.Substring(6) }
            if ($s.Status -ne "Running") { Warn "Instance $inst is $($s.Status) (skipped)"; continue }
            $targets += $inst
        }
        if (-not $targets) { $targets = @($SqlInstance) }
    }

    $best = $null
    foreach ($t in $targets) {
        $r = Test-SqlInstance $t
        if (-not $r.Ok) {
            Warn "Could not connect to '$t'"
            Hint "sqlcmd said: $($r.Error)"
        } elseif ($r.Major -ge 17) {
            Ok "$t -> SQL Server $($r.Version) ($($r.Edition))"
            if (-not $best) { $best = $r }
        } else {
            Warn "$t -> SQL Server $($r.Version) is older than 2025 (not usable for Mnemos)"
        }
    }

    if (-not $best) {
        Bad "No SQL Server 2025 instance found"
        Hint "The vector type needs SQL Server 2025 (version 17)"
    } else {
        $vq = "SET NOCOUNT ON; SELECT CAST('[1,2,3]' AS VECTOR(3));"
        $vo = & sqlcmd -S $best.Instance -E -C -b -h -1 -W -Q $vq 2>&1
        if ($LASTEXITCODE -eq 0) { Ok "Native vector type works on $($best.Instance)" }
        else { Bad "Vector type failed on $($best.Instance): $($vo -join ' ')" }
        Write-Host ""
        Write-Host "  Use this instance for Mnemos: $($best.Instance)" -ForegroundColor White
    }
}

# --- Ollama ----------------------------------------------------------------
Section "Ollama"
$ollama = Get-Command ollama -ErrorAction SilentlyContinue
if ($ollama) { Ok (& ollama --version 2>&1 | Select-Object -First 1) }
else { Warn "ollama command not found"; Hint "Install from https://ollama.com/download" }

try {
    $tags = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 5
    Ok "Ollama server answers at $OllamaUrl"
    $names = @($tags.models | ForEach-Object { $_.name })
    foreach ($m in @($EmbeddingModel, $LlmModel)) {
        $found = $names | Where-Object { $_ -eq $m -or $_ -like "${m}:*" -or $_ -eq "${m}:latest" }
        if ($found) { Ok "Model '$m' is installed" }
        else { Warn "Model '$m' is not installed"; Hint "Run: ollama pull $m" }
    }
} catch {
    Bad "Ollama server does not answer at $OllamaUrl"
    Hint "Start the Ollama app, or run: ollama serve"
}

# --- HTTPS (Caddy) ---------------------------------------------------------
Section "HTTPS para SQL Server (Caddy)"
try {
    $null = Invoke-RestMethod -Uri "https://localhost:11435/api/tags" -TimeoutSec 5
    Ok "https://localhost:11435 responde con un certificado de confianza"
} catch {
    Bad "https://localhost:11435 no responde o su certificado no es de confianza"
    Hint "Arranca Caddy: caddy run --config ai\caddy\Caddyfile (README, paso 4)"
    Hint "Y confia en su certificado (README, paso 4.3)"
}

# --- Summary ---------------------------------------------------------------
Section "Summary"
if ($script:fail -eq 0 -and $script:warn -eq 0) { Write-Host "  Everything is ready." -ForegroundColor Green }
elseif ($script:fail -eq 0) { Write-Host "  Ready, with $($script:warn) warning(s)." -ForegroundColor Yellow }
else { Write-Host "  $($script:fail) problem(s) to fix before continuing." -ForegroundColor Red }
exit $script:fail

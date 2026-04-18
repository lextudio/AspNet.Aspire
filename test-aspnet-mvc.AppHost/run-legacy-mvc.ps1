param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [Parameter(Mandatory = $true)]
    [string]$ProjectFile,

    [string]$ConfigPath = '',

    [string]$SiteName = '',

    [int]$Port = 5056
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ProjectPath)) {
    throw "Project path not found: $ProjectPath"
}

if (-not (Test-Path -LiteralPath $ProjectFile)) {
    throw "Project file not found: $ProjectFile"
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$buildScript = Join-Path $repoRoot 'build.ps1'

if (-not (Test-Path -LiteralPath $buildScript)) {
    throw "Build script not found: $buildScript"
}

$iisExpressCandidates = @(
    'C:\Program Files\IIS Express\iisexpress.exe',
    'C:\Program Files (x86)\IIS Express\iisexpress.exe'
)

$iisExpress = $iisExpressCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $iisExpress) {
    throw 'IIS Express was not found. Install IIS Express or update run-legacy-mvc.ps1 with the correct path.'
}

Write-Host "Building legacy MVC app with $buildScript"
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $buildScript -ProjectPath $ProjectFile
if ($LASTEXITCODE -ne 0) {
    throw "Build failed with exit code $LASTEXITCODE"
}

Write-Host "Starting IIS Express from $iisExpress"
if ($ConfigPath -and $SiteName -and (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "Using applicationHost.config: $ConfigPath"
    Write-Host "Serving IIS Express site '$SiteName'"
    & $iisExpress "/config:$ConfigPath" "/site:$SiteName" /systray:false
}
else {
    Write-Host "applicationHost.config not found, falling back to /path mode"
    Write-Host "Serving $ProjectPath on http://localhost:$Port/"
    & $iisExpress "/path:$ProjectPath" "/port:$Port" /clr:v4.0 /systray:false
}
exit $LASTEXITCODE

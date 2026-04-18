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
$DebugPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

if ($env:IIS_APPHOST_CONFIG) {
    $ConfigPath = $env:IIS_APPHOST_CONFIG
}

if ($env:IIS_SITE_NAME) {
    $SiteName = $env:IIS_SITE_NAME
}

if (-not (Test-Path -LiteralPath $ProjectPath)) {
    throw "Project path not found: $ProjectPath"
}

if (-not (Test-Path -LiteralPath $ProjectFile)) {
    throw "Project file not found: $ProjectFile"
}

if ($env:BUILD_SCRIPT) {
    $buildScript = $env:BUILD_SCRIPT
    if (-not (Test-Path -LiteralPath $buildScript)) {
        throw "BUILD_SCRIPT not found: $buildScript"
    }
} else {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $buildScript = Join-Path $repoRoot 'build.ps1'
    if (-not (Test-Path -LiteralPath $buildScript)) {
        throw "Build script not found: $buildScript`nSet BUILD_SCRIPT environment variable to override."
    }
}

$iisExpress = $null

if ($env:IIS_EXPRESS_PATH) {
    if (Test-Path -LiteralPath $env:IIS_EXPRESS_PATH) {
        $iisExpress = $env:IIS_EXPRESS_PATH
    } else {
        throw "IIS_EXPRESS_PATH is set but not found: $env:IIS_EXPRESS_PATH"
    }
}

if (-not $iisExpress) {
    $iisExpress = (Get-Command iisexpress.exe -ErrorAction SilentlyContinue).Source
}

if (-not $iisExpress) {
    $programFilesCandidates = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    ) | Where-Object { $_ }

    foreach ($dir in $programFilesCandidates) {
        $candidate = Join-Path $dir 'IIS Express' 'iisexpress.exe'
        if (Test-Path -LiteralPath $candidate) {
            $iisExpress = $candidate
            break
        }
    }
}

if (-not $iisExpress) {
    throw 'IIS Express was not found. Set IIS_EXPRESS_PATH environment variable or ensure IIS Express is installed and registered.'
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
    Write-Host "No valid applicationHost.config provided, exit."
    exit 1
}
exit $LASTEXITCODE

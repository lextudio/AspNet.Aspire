param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [Parameter(Mandatory = $true)]
    [string]$ProjectFile,

    [string]$SiteName = 'test-aspnet-mvc',

    [int]$Port = 51578
)

$ErrorActionPreference = 'Stop'
$DebugPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

if ($env:IIS_SITE_NAME) {
    $SiteName = $env:IIS_SITE_NAME
}

if ($env:IIS_PORT) {
    $Port = [int]$env:IIS_PORT
}

if (-not (Test-Path -LiteralPath $ProjectPath)) {
    throw "Project path not found: $ProjectPath"
}

if (-not (Test-Path -LiteralPath $ProjectFile)) {
    throw "Project file not found: $ProjectFile"
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
if ($env:BUILD_SCRIPT) {
    $buildScript = $env:BUILD_SCRIPT
    if (-not (Test-Path -LiteralPath $buildScript)) {
        throw "BUILD_SCRIPT not found: $buildScript"
    }
} else {
    $buildScript = Join-Path $repoRoot 'build.ps1'
    if (-not (Test-Path -LiteralPath $buildScript)) {
        throw "Build script not found: $buildScript`nSet BUILD_SCRIPT environment variable to override."
    }
}

$appcmd = Join-Path $env:SystemRoot 'system32\inetsrv\appcmd.exe'
if (-not (Test-Path -LiteralPath $appcmd)) {
    throw "IIS is not installed or appcmd.exe not found at: $appcmd"
}

Write-Host "Building legacy MVC app with $buildScript"
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $buildScript -ProjectPath $ProjectFile
if ($LASTEXITCODE -ne 0) {
    throw "Build failed with exit code $LASTEXITCODE"
}

Write-Host "Configuring IIS site '$SiteName'"

$siteExists = & $appcmd list site /site.name:$SiteName 2>$null
if (-not $siteExists) {
    Write-Host "Creating IIS site: $SiteName on port $Port"
    & $appcmd add site /name:$SiteName /physicalPath:$ProjectPath /bindings:"http/*:${Port}:localhost"
} else {
    Write-Host "Site already exists: $SiteName - updating physical path"
    & $appcmd set vdir "$SiteName/" /physicalPath:$ProjectPath
}

Write-Host "Starting site: $SiteName"
& $appcmd start site /site.name:$SiteName

Write-Host "IIS site is running"

try {
    while ($true) {
        Start-Sleep -Seconds 2

        $state = & $appcmd list site /site.name:$SiteName /text:state 2>$null
        if (-not $state) {
            Write-Host "IIS site '$SiteName' was not found. Exiting."
            break
        }

        $state = "$state".Trim()
        if ($state -ne 'Started') {
            Write-Host "IIS site '$SiteName' state is '$state'. Exiting."
            break
        }
    }
}
finally {
    $state = (& $appcmd list site /site.name:$SiteName /text:state 2>$null)
    if ($state -and "$state".Trim() -eq 'Started') {
        Write-Host "Stopping site: $SiteName"
        & $appcmd stop site /site.name:$SiteName 2>&1 | Write-Host
    } else {
        Write-Host "Site already stopped: $SiteName"
    }

    exit 0
}

param(
    [string]$Configuration = 'Debug',
    [string]$ProjectPath = ''
)

if ($PSScriptRoot) { Set-Location $PSScriptRoot } else { Set-Location (Split-Path -Path $MyInvocation.MyCommand.Definition -Parent) }

if (-not $ProjectPath) {
    $ProjectPath = Join-Path $PWD 'test-aspnet-mvc\test-aspnet-mvc.csproj'
}

Write-Host "Working directory: $PWD"
Write-Host "Project to build: $ProjectPath"

$pf86 = ${env:ProgramFiles(x86)}
$pf = ${env:ProgramFiles}
$vswhereCandidates = @(
        "$pf86\Microsoft Visual Studio\Installer\vswhere.exe",
        "$pf\Microsoft Visual Studio\Installer\vswhere.exe"
)
$vswhere = $vswhereCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vswhere) {
    $cmd = Get-Command vswhere.exe -ErrorAction SilentlyContinue
    if ($cmd) { $vswhere = $cmd.Source }
}
if ($vswhere) { Write-Host "Found vswhere: $vswhere" } else { Write-Host "vswhere not found on disk or PATH" }

$msbuild = $null
if ($vswhere) {
    try {
        $msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\\**\\Bin\\MSBuild.exe' 2>$null | Select-Object -First 1
    } catch {
        $msbuild = $null
    }
    if (-not $msbuild) {
        $inst = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath 2>$null | Select-Object -First 1
        if ($inst) {
            $candidates = @(
                Join-Path $inst 'MSBuild\Current\Bin\MSBuild.exe',
                Join-Path $inst 'MSBuild\15.0\Bin\MSBuild.exe',
                Join-Path $inst 'MSBuild\14.0\Bin\MSBuild.exe'
            )
            $msbuild = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        }
    }
}

if (-not $msbuild) {
    $cmd = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($cmd) { $msbuild = $cmd.Source }
}

if (-not $msbuild) {
    $fallbacks = @(
        'C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\MSBuild\Current\Bin\MSBuild.exe',
        'C:\Program Files (x86)\Microsoft Visual Studio\2017\BuildTools\MSBuild\15.0\Bin\MSBuild.exe',
        'C:\Program Files\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe',
        'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe'
    )
    $msbuild = $fallbacks | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $msbuild) {
    Write-Error "MSBuild.exe not found. Install Visual Studio or Build Tools, or run from a Developer Command Prompt."
    exit 2
}

Write-Host "Using MSBuild: $msbuild"

& "$msbuild" "$ProjectPath" /m "/p:Configuration=$Configuration" /v:minimal
$exitCode = $LASTEXITCODE
Write-Host "MSBuild exit code: $exitCode"
exit $exitCode

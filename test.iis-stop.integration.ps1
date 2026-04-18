param(
    [string]$Project = '.\test-aspnet-mvc.AppHost\test-aspnet-mvc.AppHost.csproj',
    [int]$TimeoutSeconds = 180,
    [string]$SiteName = 'test-aspnet-mvc'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AppCmdPath {
    return Join-Path $env:SystemRoot 'system32\inetsrv\appcmd.exe'
}

function Get-IisSiteState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $appcmd = Get-AppCmdPath
    if (-not (Test-Path -LiteralPath $appcmd)) {
        throw "IIS is not installed or appcmd.exe not found at: $appcmd"
    }

    $state = & $appcmd list site /site.name:$Name /text:state 2>$null
    if (-not $state) {
        return $null
    }

    return "$state".Trim()
}

if (-not (Test-IsAdministrator)) {
    Write-Error "This integration test requires administrator privileges."
    Write-Error "Run PowerShell as Administrator and try again."
    exit 1
}

try {
    $projPath = Resolve-Path -Path $Project -ErrorAction Stop
} catch {
    Write-Error "Unable to resolve project path: $Project"
    exit 2
}

$log = Join-Path -Path $PSScriptRoot -ChildPath 'test.iis-stop.integration.log'
if (Test-Path -LiteralPath $log) {
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}

Write-Output "Running IIS stop integration test against: $($projPath.Path)"
Write-Output "Log: $log"

$env:HOSTING_MODE = 'IIS'
$env:ASPIRE_IIS_STOP_TEST_MODE = '1'
$env:ASPIRE_IIS_STOP_TEST_TIMEOUT_SECONDS = [string]$TimeoutSeconds
$env:ASPIRE_IIS_STOP_TEST_SETTLE_SECONDS = '5'
$env:ASPIRE_IIS_STOP_TEST_COMMAND_TIMEOUT_SECONDS = '30'

$argLine = '/c dotnet run --project "' + $projPath.Path + '" > "' + $log + '" 2>&1'
$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList $argLine -PassThru

if (-not $proc) {
    Write-Error 'Failed to start dotnet process.'
    exit 3
}

Write-Output "Started AppHost test process (pid $($proc.Id)). Waiting up to $TimeoutSeconds seconds..."
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$printedLines = 0

while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $log) {
        $lines = Get-Content -Path $log
        if ($lines.Count -gt $printedLines) {
            $newLines = $lines[$printedLines..($lines.Count - 1)]
            $newLines | ForEach-Object { Write-Output $_ }
            $printedLines = $lines.Count
        }
    }

    Start-Sleep -Seconds 1
}

if (-not $proc.HasExited) {
    Write-Error "Timed out waiting for AppHost self-test to finish."
    try {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    } catch {
    }

    if (Test-Path -LiteralPath $log) {
        Write-Output 'Last test log lines:'
        Get-Content -Path $log -Tail 200
    }

    exit 4
}

if (Test-Path -LiteralPath $log) {
    $lines = Get-Content -Path $log
    if ($lines.Count -gt $printedLines) {
        $lines[$printedLines..($lines.Count - 1)] | ForEach-Object { Write-Output $_ }
    }
}

$state = Get-IisSiteState -Name $SiteName
if ($null -eq $state -or $state -eq '') {
    Write-Output 'Final IIS site state: <missing>'
} else {
    Write-Output "Final IIS site state: $state"
}

if ($proc.ExitCode -ne 0) {
    Write-Error "Integration test failed with AppHost exit code $($proc.ExitCode)."
    exit $proc.ExitCode
}

if ($state -eq 'Started') {
    Write-Error "Integration test failed: IIS site '$SiteName' is still running."
    exit 20
}

Write-Output "Integration test passed: IIS site '$SiteName' stopped successfully."
exit 0

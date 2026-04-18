param(
    [string]$RunnerProject = '.\test-aspnet-mvc.IisRunner\test-aspnet-mvc.IisRunner.csproj',
    [string]$ProjectPath = '.\test-aspnet-mvc',
    [string]$ProjectFile = '.\test-aspnet-mvc\test-aspnet-mvc.csproj',
    [string]$ConfigPath = '.\.vs\test-aspnet-mvc.slnx\config\applicationhost.config',
    [string]$SiteName = 'test-aspnet-mvc',
    [string]$LogDirectory = '',
    [int]$Port = 51578,
    [int]$StartTimeoutSeconds = 120,
    [int]$StopTimeoutSeconds = 20,
    [int]$RestartStabilitySeconds = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RunnerProcess = $null
$script:RunnerLog = $null
$script:RunnerErrorLog = $null
$script:TranscriptPath = $null

if (-not $LogDirectory) {
    $LogDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'artifacts\iisexpress-test'
}

function Stop-TestProcesses {
    if ($script:RunnerProcess) {
        try {
            Stop-Process -Id $script:RunnerProcess.Id -Force -ErrorAction SilentlyContinue
        } catch {
        }
    }
}

function Write-NewLogLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ref]$PrintedLineCount
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $lines = Get-Content -Path $Path
    if ($null -eq $lines) {
        return
    }

    if ($lines -is [string]) {
        $lines = @($lines)
    }

    $currentCount = $lines.Count
    if ($currentCount -le $PrintedLineCount.Value) {
        return
    }

    for ($i = $PrintedLineCount.Value; $i -lt $currentCount; $i++) {
        Write-Output $lines[$i]
    }

    $PrintedLineCount.Value = $currentCount
}

function Write-RunnerLogTail {
    param(
        [int]$Tail = 200
    )

    if ($script:RunnerLog -and (Test-Path -LiteralPath $script:RunnerLog)) {
        Write-Output "Last runner log lines from $script:RunnerLog :"
        Get-Content -Path $script:RunnerLog -Tail $Tail
    } else {
        Write-Output 'Runner log is unavailable.'
    }

    if ($script:RunnerErrorLog -and (Test-Path -LiteralPath $script:RunnerErrorLog)) {
        Write-Output "Last runner error log lines from $script:RunnerErrorLog :"
        Get-Content -Path $script:RunnerErrorLog -Tail $Tail
    }
}

function Get-RunnerExePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunnerProjectPath
    )

    $projectDirectory = Split-Path -Path $RunnerProjectPath -Parent
    $projectName = [System.IO.Path]::GetFileNameWithoutExtension($RunnerProjectPath)
    return Join-Path -Path $projectDirectory -ChildPath "bin\Debug\net10.0\$projectName.exe"
}

function Start-RunnerProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunnerExePath,

        [Parameter(Mandatory = $true)]
        [string[]]$RunnerArguments
    )

    $script:RunnerProcess = Start-Process -FilePath $RunnerExePath `
        -ArgumentList $RunnerArguments `
        -PassThru `
        -RedirectStandardOutput $script:RunnerLog `
        -RedirectStandardError $script:RunnerErrorLog

    if (-not $script:RunnerProcess) {
        throw 'Failed to start IIS Express runner process.'
    }

    return $script:RunnerProcess
}

function Get-IisExpressProcessesForSite {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $escapedConfigPath = [Regex]::Escape($ResolvedConfigPath)
    $escapedSiteName = [Regex]::Escape($Name)

    Get-CimInstance Win32_Process -Filter "Name = 'iisexpress.exe'" |
        Where-Object {
            $_.CommandLine -match $escapedConfigPath -and $_.CommandLine -match $escapedSiteName
        }
}

function Stop-StaleIisExpressProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $staleProcesses = @(Get-IisExpressProcessesForSite -ResolvedConfigPath $ResolvedConfigPath -Name $Name)
    foreach ($process in $staleProcesses) {
        Write-Output "Stopping pre-existing IIS Express process pid $($process.ProcessId) for site '$Name'."
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        } catch {
        }
    }
}

function Test-HttpEndpointReady {
    param(
        [Parameter(Mandatory = $true)]
        [int]$HttpPort
    )

    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$HttpPort/" -UseBasicParsing -TimeoutSec 5
        return $response.StatusCode -ge 200 -and $response.StatusCode -lt 500
    } catch {
        return $false
    }
}

function Wait-ForRunnerReady {
    param(
        [Parameter(Mandatory = $true)]
        [int]$HttpPort,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [ref]$PrintedLineCount
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not $script:RunnerProcess.HasExited -and (Get-Date) -lt $deadline) {
        Write-NewLogLines -Path $script:RunnerLog -PrintedLineCount $PrintedLineCount

        if (Test-HttpEndpointReady -HttpPort $HttpPort) {
            return $true
        }

        Start-Sleep -Seconds 1
    }

    Write-NewLogLines -Path $script:RunnerLog -PrintedLineCount $PrintedLineCount
    return $false
}

if (-not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}

$script:TranscriptPath = Join-Path -Path $LogDirectory -ChildPath 'transcript.log'
if (Test-Path -LiteralPath $script:TranscriptPath) {
    Remove-Item -LiteralPath $script:TranscriptPath -Force -ErrorAction SilentlyContinue
}

Start-Transcript -Path $script:TranscriptPath -Force | Out-Null

try {
    try {
        $runnerProjectPath = Resolve-Path -Path $RunnerProject -ErrorAction Stop
        $projectDirectoryPath = Resolve-Path -Path $ProjectPath -ErrorAction Stop
        $projectFilePath = Resolve-Path -Path $ProjectFile -ErrorAction Stop
        $configFilePath = Resolve-Path -Path $ConfigPath -ErrorAction Stop
    } catch {
        Write-Error "Unable to resolve one or more paths."
        throw
    }

    $script:RunnerLog = Join-Path -Path $LogDirectory -ChildPath 'runner.log'
    if (Test-Path -LiteralPath $script:RunnerLog) {
        Remove-Item -LiteralPath $script:RunnerLog -Force -ErrorAction SilentlyContinue
    }

    $script:RunnerErrorLog = Join-Path -Path $LogDirectory -ChildPath 'runner.err.log'
    if (Test-Path -LiteralPath $script:RunnerErrorLog) {
        Remove-Item -LiteralPath $script:RunnerErrorLog -Force -ErrorAction SilentlyContinue
    }

    Write-Output "Running IIS Express integration test with runner project: $($runnerProjectPath.Path)"
    Write-Output "Log directory: $LogDirectory"
    Write-Output "Runner log: $script:RunnerLog"
    Write-Output "Runner error log: $script:RunnerErrorLog"
    Write-Output "Transcript: $script:TranscriptPath"

    Stop-StaleIisExpressProcesses -ResolvedConfigPath $configFilePath.Path -Name $SiteName

    Write-Output 'Building IIS runner executable...'
    & dotnet build $runnerProjectPath.Path | Write-Output
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to build IIS runner project. Exit code: $LASTEXITCODE"
        exit 2
    }

    $runnerExePath = Get-RunnerExePath -RunnerProjectPath $runnerProjectPath.Path
    if (-not (Test-Path -LiteralPath $runnerExePath)) {
        Write-Error "Runner executable not found at: $runnerExePath"
        exit 2
    }

    $runnerArgs = @(
        '--mode', 'iisexpress',
        '--project-path', $projectDirectoryPath.Path,
        '--project-file', $projectFilePath.Path,
        '--site-name', $SiteName,
        '--port', "$Port",
        '--config-path', $configFilePath.Path
    )

    Start-RunnerProcess -RunnerExePath $runnerExePath -RunnerArguments $runnerArgs | Out-Null
    Write-Output "Started IIS Express runner process (pid $($script:RunnerProcess.Id)). Waiting for endpoint startup..."

    $printedLines = 0
    $ready = Wait-ForRunnerReady -HttpPort $Port -TimeoutSeconds $StartTimeoutSeconds -PrintedLineCount ([ref]$printedLines)
    if (-not $ready) {
        Write-Error "IIS Express did not reach a healthy HTTP response on port $Port within $StartTimeoutSeconds seconds."
        Stop-TestProcesses
        Write-RunnerLogTail
        exit 4
    }

    Write-Output "Observed IIS Express site '$SiteName' responding on port $Port. Simulating resource stop by terminating runner pid $($script:RunnerProcess.Id)."
    Stop-Process -Id $script:RunnerProcess.Id -Force

    $stopDeadline = (Get-Date).AddSeconds($StopTimeoutSeconds)
    $stopped = $false
    while ((Get-Date) -lt $stopDeadline) {
        Write-NewLogLines -Path $script:RunnerLog -PrintedLineCount ([ref]$printedLines)

        $remaining = @(Get-IisExpressProcessesForSite -ResolvedConfigPath $configFilePath.Path -Name $SiteName)
        if ($remaining.Count -eq 0 -and -not (Test-HttpEndpointReady -HttpPort $Port)) {
            $stopped = $true
            break
        }

        Start-Sleep -Seconds 1
    }

    Write-NewLogLines -Path $script:RunnerLog -PrintedLineCount ([ref]$printedLines)

    if (-not $stopped) {
        Write-Error "Integration test failed: IIS Express did not stop within $StopTimeoutSeconds seconds."
        Write-RunnerLogTail
        Stop-StaleIisExpressProcesses -ResolvedConfigPath $configFilePath.Path -Name $SiteName
        exit 20
    }

    Write-Output "Stop phase passed. Restarting IIS Express runner..."

    Start-RunnerProcess -RunnerExePath $runnerExePath -RunnerArguments $runnerArgs | Out-Null
    Write-Output "Started replacement IIS Express runner process (pid $($script:RunnerProcess.Id)). Waiting for endpoint startup..."

    $restartReady = Wait-ForRunnerReady -HttpPort $Port -TimeoutSeconds $StartTimeoutSeconds -PrintedLineCount ([ref]$printedLines)
    if (-not $restartReady) {
        Write-Error "Integration test failed: restart did not bring IIS Express site '$SiteName' back."
        Stop-TestProcesses
        Write-RunnerLogTail
        exit 21
    }

    Write-Output "Restart phase reached a healthy response. Verifying endpoint remains up for $RestartStabilitySeconds seconds..."

    $stable = $true
    $stabilityDeadline = (Get-Date).AddSeconds($RestartStabilitySeconds)
    while ((Get-Date) -lt $stabilityDeadline) {
        Write-NewLogLines -Path $script:RunnerLog -PrintedLineCount ([ref]$printedLines)

        if (-not (Test-HttpEndpointReady -HttpPort $Port)) {
            $stable = $false
            break
        }

        Start-Sleep -Seconds 1
    }

    Write-NewLogLines -Path $script:RunnerLog -PrintedLineCount ([ref]$printedLines)

    if (-not $stable) {
        Write-Error "Integration test failed: restarted IIS Express site '$SiteName' did not remain healthy on port $Port."
        Stop-TestProcesses
        Write-RunnerLogTail
        exit 22
    }

    Write-Output "Integration test passed: stop and restart both worked for IIS Express site '$SiteName'."
    Stop-TestProcesses
    Stop-StaleIisExpressProcesses -ResolvedConfigPath $configFilePath.Path -Name $SiteName
    exit 0
} catch {
    Write-Error "Integration test crashed: $($_.Exception.Message)"
    Write-RunnerLogTail
    Stop-TestProcesses
    Stop-StaleIisExpressProcesses -ResolvedConfigPath $configFilePath.Path -Name $SiteName
    exit 99
} finally {
    try {
        Stop-Transcript | Out-Null
    } catch {
    }
}

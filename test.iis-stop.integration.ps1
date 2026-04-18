param(
    [string]$RunnerProject = '.\test-aspnet-mvc.IisRunner\test-aspnet-mvc.IisRunner.csproj',
    [string]$ProjectPath = '.\test-aspnet-mvc',
    [string]$ProjectFile = '.\test-aspnet-mvc\test-aspnet-mvc.csproj',
    [string]$SiteName = 'test-aspnet-mvc',
    [string]$LogDirectory = '',
    [int]$StartTimeoutSeconds = 120,
    [int]$StopTimeoutSeconds = 30,
    [int]$RestartStabilitySeconds = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RunnerProcess = $null
$script:RunnerLog = $null
$script:RunnerErrorLog = $null
$script:TranscriptPath = $null

if (-not $LogDirectory) {
    $LogDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'artifacts\iis-stop-test'
}

function Stop-TestProcesses {
    if ($script:RunnerProcess) {
        try {
            Stop-Process -Id $script:RunnerProcess.Id -Force -ErrorAction SilentlyContinue
        } catch {
        }
    }
}

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

function Stop-IisSiteIfStarted {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $appcmd = Get-AppCmdPath
    $state = Get-IisSiteState -Name $Name
    if ($state -eq 'Started') {
        Write-Output "Stopping pre-existing IIS site '$Name' before test run."
        & $appcmd stop site /site.name:$Name 2>$null | Write-Output
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

function Test-LogContains {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    return Select-String -Path $Path -Pattern $Pattern -SimpleMatch -Quiet
}

function Write-RunnerLogTail {
    param(
        [int]$Tail = 200
    )

    if (-not $script:RunnerLog -or -not (Test-Path -LiteralPath $script:RunnerLog)) {
        Write-Output 'Runner log is unavailable.'
    } else {
        Write-Output "Last runner log lines from $script:RunnerLog :"
        Get-Content -Path $script:RunnerLog -Tail $Tail
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
        throw 'Failed to start IIS runner process.'
    }

    return $script:RunnerProcess
}

function Wait-ForRunnerReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [ref]$PrintedLineCount
    )

    $startupDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $watchdogStarted = $false

    while (-not $script:RunnerProcess.HasExited -and (Get-Date) -lt $startupDeadline) {
        Write-NewLogLines -Path $script:RunnerLog -PrintedLineCount $PrintedLineCount

        if (-not $watchdogStarted -and (Test-LogContains -Path $script:RunnerLog -Pattern 'Started IIS watchdog process id:')) {
            $watchdogStarted = $true
            Write-Output 'Observed watchdog startup in runner log.'
        }

        $state = Get-IisSiteState -Name $Name
        if ($state -eq 'Started' -and $watchdogStarted) {
            return $true
        }

        Start-Sleep -Seconds 1
    }

    Write-NewLogLines -Path $script:RunnerLog -PrintedLineCount $PrintedLineCount
    return $false
}

if (-not (Test-IsAdministrator)) {
    Write-Error "This integration test requires administrator privileges."
    Write-Error "Run PowerShell as Administrator and try again."
    exit 1
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

    Write-Output "Running IIS stop integration test with runner project: $($runnerProjectPath.Path)"
    Write-Output "Log directory: $LogDirectory"
    Write-Output "Runner log: $script:RunnerLog"
    Write-Output "Runner error log: $script:RunnerErrorLog"
    Write-Output "Transcript: $script:TranscriptPath"

    Stop-IisSiteIfStarted -Name $SiteName

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
        '--project-path', $projectDirectoryPath.Path,
        '--project-file', $projectFilePath.Path,
        '--site-name', $SiteName,
        '--port', '51578'
    )

    Start-RunnerProcess -RunnerExePath $runnerExePath -RunnerArguments $runnerArgs | Out-Null

    Write-Output "Started IIS runner process (pid $($script:RunnerProcess.Id)). Waiting for site startup..."

    $printedLines = 0
    $siteStarted = Wait-ForRunnerReady -Name $SiteName -TimeoutSeconds $StartTimeoutSeconds -PrintedLineCount ([ref]$printedLines)

    if (-not $siteStarted) {
        Write-Error "Site '$SiteName' did not reach Started state with watchdog active within $StartTimeoutSeconds seconds."
        Stop-TestProcesses
        Write-RunnerLogTail
        exit 4
    }

    Write-Output "Observed IIS site '$SiteName' in Started state. Simulating resource stop by terminating runner pid $($script:RunnerProcess.Id)."
    Stop-Process -Id $script:RunnerProcess.Id -Force

    $stopDeadline = (Get-Date).AddSeconds($StopTimeoutSeconds)
    $siteStopped = $false

    while ((Get-Date) -lt $stopDeadline) {
        Write-NewLogLines -Path $script:RunnerLog -PrintedLineCount ([ref]$printedLines)

        $state = Get-IisSiteState -Name $SiteName
        if ($state -ne 'Started') {
            $siteStopped = $true
            break
        }

        Start-Sleep -Seconds 1
    }

    Write-NewLogLines -Path $script:RunnerLog -PrintedLineCount ([ref]$printedLines)

    $finalState = Get-IisSiteState -Name $SiteName
    if ($null -eq $finalState -or $finalState -eq '') {
        Write-Output 'Final IIS site state: <missing>'
    } else {
        Write-Output "Final IIS site state: $finalState"
    }

    if (-not $siteStopped -and $finalState -eq 'Started') {
        Write-Error "Integration test failed: watchdog did not stop IIS site '$SiteName' within $StopTimeoutSeconds seconds."
        Write-RunnerLogTail
        exit 20
    }

    Write-Output "Stop phase passed. Restarting IIS runner to verify the site comes back and remains up..."

    Start-RunnerProcess -RunnerExePath $runnerExePath -RunnerArguments $runnerArgs | Out-Null
    Write-Output "Started replacement IIS runner process (pid $($script:RunnerProcess.Id)). Waiting for site startup..."

    $restartReady = Wait-ForRunnerReady -Name $SiteName -TimeoutSeconds $StartTimeoutSeconds -PrintedLineCount ([ref]$printedLines)
    if (-not $restartReady) {
        Write-Error "Integration test failed: restart did not bring IIS site '$SiteName' back with watchdog active."
        Stop-TestProcesses
        Write-RunnerLogTail
        exit 21
    }

    Write-Output "Restart phase reached Started state. Verifying site remains Started for $RestartStabilitySeconds seconds..."

    $stabilityDeadline = (Get-Date).AddSeconds($RestartStabilitySeconds)
    $restartStable = $true
    while ((Get-Date) -lt $stabilityDeadline) {
        Write-NewLogLines -Path $script:RunnerLog -PrintedLineCount ([ref]$printedLines)

        $state = Get-IisSiteState -Name $SiteName
        if ($state -ne 'Started') {
            $restartStable = $false
            break
        }

        Start-Sleep -Seconds 1
    }

    Write-NewLogLines -Path $script:RunnerLog -PrintedLineCount ([ref]$printedLines)

    if (-not $restartStable) {
        $restartState = Get-IisSiteState -Name $SiteName
        Write-Error "Integration test failed: restarted IIS site '$SiteName' did not remain Started. Final state: $restartState"
        Stop-TestProcesses
        Write-RunnerLogTail
        exit 22
    }

    Write-Output "Integration test passed: stop and restart both worked for IIS site '$SiteName'."
    Stop-TestProcesses
    exit 0
} catch {
    Write-Error "Integration test crashed: $($_.Exception.Message)"
    Write-RunnerLogTail
    Stop-TestProcesses
    exit 99
} finally {
    try {
        Stop-Transcript | Out-Null
    } catch {
    }
}

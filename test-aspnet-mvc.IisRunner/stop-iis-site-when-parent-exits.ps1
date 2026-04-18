param(
    [Parameter(Mandatory = $true)]
    [int]$ParentProcessId,

    [Parameter(Mandatory = $true)]
    [string]$SiteName,

    [string]$LogPath = '',

    [int]$PollSeconds = 2
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $LogPath) {
        return
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    Add-Content -LiteralPath $LogPath -Value "[$timestamp] $Message"
}

function Get-AppCmdPath {
    return Join-Path $env:SystemRoot 'system32\inetsrv\appcmd.exe'
}

function Get-SiteState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $appcmd = Get-AppCmdPath
    if (-not (Test-Path -LiteralPath $appcmd)) {
        return $null
    }

    $state = & $appcmd list site /site.name:$Name /text:state 2>$null
    if (-not $state) {
        return $null
    }

    return "$state".Trim()
}

function Stop-Site {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $appcmd = Get-AppCmdPath
    if (-not (Test-Path -LiteralPath $appcmd)) {
        Write-Log "appcmd.exe not found at $appcmd"
        return
    }

    $state = Get-SiteState -Name $Name
    if ($state -eq 'Started') {
        Write-Log "Stopping IIS site '$Name' after parent process exit."
        & $appcmd stop site /site.name:$Name 2>&1 | Out-Null
    } else {
        Write-Log "Site '$Name' already not Started (state: $state)."
    }
}

Write-Log "Watchdog started for parent pid $ParentProcessId and site '$SiteName'."

while ($true) {
    Start-Sleep -Seconds $PollSeconds

    $parent = Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue
    if ($parent) {
        continue
    }

    Write-Log "Parent process $ParentProcessId no longer exists."
    Stop-Site -Name $SiteName
    Write-Log "Watchdog exiting."
    exit 0
}

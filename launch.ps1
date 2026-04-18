param(
	[string]$Project = '.\test-aspnet-mvc.AppHost\test-aspnet-mvc.AppHost.csproj',
	[int]$TimeoutSeconds = 30
)

<#
  Launch Aspire dashboard, stream logs to the console, detect the "Now listening on:" line,
  and open the default browser to the reported URL when ready.

  Behavior:
  - Starts `dotnet run --project <Project>` redirecting stdout/stderr to a log file.
  - Tails the log in real-time and prints lines to the console.
  - When a line matching `Now listening on: <url>` appears the script opens the URL in the default browser.
  - If the process exits before the listening URL appears, the script prints the last logs and exits with an error.
#>

Set-StrictMode -Version Latest

try {
	$projPath = Resolve-Path -Path $Project -ErrorAction Stop
} catch {
	Write-Error "Unable to resolve project path: $Project"
	exit 2
}

$log = Join-Path -Path $PSScriptRoot -ChildPath 'launch.log'
if (Test-Path $log) { Remove-Item $log -ErrorAction SilentlyContinue }

Write-Output "Starting project: $($projPath.Path)"
Write-Output "Log: $log"

$dotnetArgs = @('run', '--project', "$($projPath.Path)")

# Determine whether Start-Process supports stream redirection (PowerShell Core)
# Use cmd.exe redirection to merge stdout and stderr into a single log file reliably
$argLine = '/c dotnet run --project "' + $projPath.Path + '" > "' + $log + '" 2>&1'
$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList $argLine -PassThru

if (-not $proc) {
	Write-Error 'Failed to start dotnet process.'
	exit 3
}

Write-Output "Started (pid $($proc.Id)). Waiting for output..."

$Opened = $false
$regex = 'Now listening on:\s*(https?://\S+)'

# Wait for the log file to be created up to the timeout
$start = Get-Date
while (-not (Test-Path $log) -and -not $proc.HasExited) {
	Start-Sleep -Milliseconds 100
	if ( ((Get-Date) - $start).TotalSeconds -ge $TimeoutSeconds ) { break }
}

if (-not (Test-Path $log)) {
	Write-Warning 'Log file was not created in time. Waiting briefly for process output...'
}

# Tail the log and check each line for the listening URL. This will keep running until the process exits.
try {
	if (Test-Path $log) {
		Get-Content -Path $log -Wait -Tail 0 | ForEach-Object {
			Write-Output $_
			if (-not $Opened) {
				$m = [regex]::Match($_, $regex)
				if ($m.Success) {
					$url = $m.Groups[1].Value
					Write-Output "Opening browser to: $url"
					Start-Process $url
					$Opened = $true
				}
			}
		}
	} else {
		# If the log never appeared, just wait for the process to exit and then show output
		while (-not $proc.HasExited) { Start-Sleep -Milliseconds 200 }
	}
} catch {
	Write-Warning "Error while tailing log: $_"
}

if (-not $Opened) {
	if ($proc.HasExited) {
		Write-Error 'Application exited before a listening URL was detected.'
		if (Test-Path $log) { Get-Content -Path $log -Tail 200 | ForEach-Object { Write-Output $_ } }
		exit 4
	} else {
		Write-Warning 'Listening URL was not detected yet. Process is still running; check the log file.'
	}
} else {
	Write-Output 'Browser opened. Streaming logs until process exits (press Ctrl+C to stop).'
}

exit 0
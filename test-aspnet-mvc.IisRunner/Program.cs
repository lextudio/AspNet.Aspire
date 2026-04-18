using System.Diagnostics;
using System.Threading;

var options = RunnerOptions.Parse(args);
LegacyWebHostRunner runner = options.Mode switch
{
    HostingMode.Iis => new IisRunner(options),
    HostingMode.IisExpress => new IisExpressRunner(options),
    _ => throw new InvalidOperationException($"Unsupported hosting mode '{options.Mode}'.")
};

return await runner.RunAsync();

internal enum HostingMode
{
    Iis,
    IisExpress
}

internal sealed record RunnerOptions(
    HostingMode Mode,
    string ProjectPath,
    string ProjectFile,
    string SiteName,
    int Port,
    string? ConfigPath)
{
    public static RunnerOptions Parse(string[] args)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            if (!arg.StartsWith("--", StringComparison.Ordinal))
            {
                throw new ArgumentException($"Unexpected argument '{arg}'.");
            }

            if (i + 1 >= args.Length)
            {
                throw new ArgumentException($"Missing value for argument '{arg}'.");
            }

            values[arg] = args[++i];
        }

        static string GetRequired(Dictionary<string, string> values, string name)
        {
            if (!values.TryGetValue(name, out var value) || string.IsNullOrWhiteSpace(value))
            {
                throw new ArgumentException($"Missing required argument '{name}'.");
            }

            return value;
        }

        var modeValue = GetRequired(values, "--mode");
        if (!Enum.TryParse<HostingMode>(modeValue, ignoreCase: true, out var mode))
        {
            throw new ArgumentException($"Unsupported hosting mode '{modeValue}'.");
        }

        values.TryGetValue("--config-path", out var configPath);

        return new RunnerOptions(
            Mode: mode,
            ProjectPath: GetRequired(values, "--project-path"),
            ProjectFile: GetRequired(values, "--project-file"),
            SiteName: GetRequired(values, "--site-name"),
            Port: int.Parse(GetRequired(values, "--port")),
            ConfigPath: string.IsNullOrWhiteSpace(configPath) ? null : configPath);
    }
}

internal abstract class LegacyWebHostRunner
{
    protected LegacyWebHostRunner(RunnerOptions options)
    {
        Options = options;
        BuildScriptPath = Path.Combine(Directory.GetParent(options.ProjectPath)?.FullName ?? options.ProjectPath, "build.ps1");
    }

    protected RunnerOptions Options { get; }
    protected string BuildScriptPath { get; }
    protected CancellationTokenSource Shutdown { get; } = new();

    public async Task<int> RunAsync()
    {
        Console.CancelKeyPress += OnCancelKeyPress;
        AppDomain.CurrentDomain.ProcessExit += OnProcessExit;

        try
        {
            ValidateCommonInputs();

            Console.WriteLine($"Building legacy MVC app with {BuildScriptPath}");
            var buildExitCode = await ProcessUtil.RunStreamingProcessAsync(
                "powershell.exe",
                [
                    "-NoLogo",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    BuildScriptPath,
                    "-ProjectPath",
                    Options.ProjectFile
                ],
                Directory.GetParent(BuildScriptPath)?.FullName ?? Environment.CurrentDirectory);

            Console.WriteLine($"MSBuild exit code: {buildExitCode}");
            if (buildExitCode != 0)
            {
                Console.Error.WriteLine($"Build failed with exit code {buildExitCode}");
                return buildExitCode;
            }

            return await RunHostedProcessAsync();
        }
        finally
        {
            await CleanupAsync();
            Console.CancelKeyPress -= OnCancelKeyPress;
            AppDomain.CurrentDomain.ProcessExit -= OnProcessExit;
            Shutdown.Dispose();
        }
    }

    protected virtual void ValidateCommonInputs()
    {
        if (!Directory.Exists(Options.ProjectPath))
        {
            throw new DirectoryNotFoundException($"Project path not found: {Options.ProjectPath}");
        }

        if (!File.Exists(Options.ProjectFile))
        {
            throw new FileNotFoundException($"Project file not found: {Options.ProjectFile}", Options.ProjectFile);
        }

        if (!File.Exists(BuildScriptPath))
        {
            throw new FileNotFoundException($"Build script not found: {BuildScriptPath}", BuildScriptPath);
        }
    }

    protected abstract Task<int> RunHostedProcessAsync();

    protected virtual Task CleanupAsync() => Task.CompletedTask;

    protected void WaitUntilCancelled()
    {
        while (!Shutdown.IsCancellationRequested)
        {
            try
            {
                Task.Delay(TimeSpan.FromSeconds(2), Shutdown.Token).GetAwaiter().GetResult();
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private void OnCancelKeyPress(object? sender, ConsoleCancelEventArgs e)
    {
        Console.WriteLine($"Received console stop signal ({e.SpecialKey}). Shutting down {Options.Mode} runner.");
        e.Cancel = true;
        Shutdown.Cancel();
    }

    private void OnProcessExit(object? sender, EventArgs e)
    {
        Shutdown.Cancel();
    }
}

internal sealed class IisRunner : LegacyWebHostRunner
{
    private readonly string _appCmdPath;
    private readonly string _watchdogLogPath;
    private readonly string _ownerFilePath;
    private int _cleanupStarted;
    private Process? _watchdogProcess;

    public IisRunner(RunnerOptions options) : base(options)
    {
        _appCmdPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "inetsrv", "appcmd.exe");
        _watchdogLogPath = Path.Combine(AppContext.BaseDirectory, "iis-runner-watchdog.log");
        _ownerFilePath = Path.Combine(AppContext.BaseDirectory, "iis-runner-owner.txt");
    }

    protected override void ValidateCommonInputs()
    {
        base.ValidateCommonInputs();

        if (!File.Exists(_appCmdPath))
        {
            throw new FileNotFoundException($"IIS is not installed or appcmd.exe not found at: {_appCmdPath}", _appCmdPath);
        }
    }

    protected override async Task<int> RunHostedProcessAsync()
    {
        Console.WriteLine($"Configuring IIS site '{Options.SiteName}'");

        var siteExists = await SiteExistsAsync();
        if (!siteExists)
        {
            Console.WriteLine($"Creating IIS site: {Options.SiteName} on port {Options.Port}");
            await RunStreamingAppCmdAsync("add", "site", $"/name:{Options.SiteName}", $"/physicalPath:{Options.ProjectPath}", $"/bindings:http/*:{Options.Port}:localhost");
        }
        else
        {
            Console.WriteLine($"Site already exists: {Options.SiteName} - updating physical path");
            await RunStreamingAppCmdAsync("set", "vdir", $"{Options.SiteName}/", $"/physicalPath:{Options.ProjectPath}");
        }

        Console.WriteLine($"Starting site: {Options.SiteName}");
        await RunStreamingAppCmdAsync("start", "site", $"/site.name:{Options.SiteName}");
        Console.WriteLine("IIS site is running");
        Console.WriteLine($"IIS runner process id: {Environment.ProcessId}");
        File.WriteAllText(_ownerFilePath, Environment.ProcessId.ToString());
        StartWatchdog();

        while (!Shutdown.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(2), Shutdown.Token);
            }
            catch (OperationCanceledException)
            {
                break;
            }

            var state = await GetSiteStateAsync();
            if (string.IsNullOrWhiteSpace(state))
            {
                Console.WriteLine($"IIS site '{Options.SiteName}' was not found. Exiting.");
                break;
            }

            if (!string.Equals(state, "Started", StringComparison.OrdinalIgnoreCase))
            {
                Console.WriteLine($"IIS site '{Options.SiteName}' state is '{state}'. Exiting.");
                break;
            }
        }

        return 0;
    }

    protected override async Task CleanupAsync()
    {
        if (Interlocked.Exchange(ref _cleanupStarted, 1) != 0)
        {
            return;
        }

        try
        {
            var state = await GetSiteStateAsync();
            if (string.Equals(state, "Started", StringComparison.OrdinalIgnoreCase))
            {
                Console.WriteLine($"Stopping site: {Options.SiteName}");
                await RunStreamingAppCmdAsync("stop", "site", $"/site.name:{Options.SiteName}");
            }
            else
            {
                Console.WriteLine($"Site already stopped: {Options.SiteName}");
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Warning: failed to stop IIS site '{Options.SiteName}': {ex.Message}");
        }
        finally
        {
            TryStopWatchdog();
            TryReleaseOwnership();
        }
    }

    private async Task<bool> SiteExistsAsync()
    {
        var result = await ProcessUtil.RunCapturingProcessAsync(_appCmdPath, ["list", "site", $"/site.name:{Options.SiteName}"]);
        return result.ExitCode == 0 && !string.IsNullOrWhiteSpace(result.StandardOutput);
    }

    private async Task<string?> GetSiteStateAsync()
    {
        var result = await ProcessUtil.RunCapturingProcessAsync(_appCmdPath, ["list", "site", $"/site.name:{Options.SiteName}", "/text:state"]);
        if (result.ExitCode != 0 || string.IsNullOrWhiteSpace(result.StandardOutput))
        {
            return null;
        }

        return result.StandardOutput.Trim();
    }

    private async Task RunStreamingAppCmdAsync(params string[] arguments)
    {
        var exitCode = await ProcessUtil.RunStreamingProcessAsync(_appCmdPath, arguments, Environment.CurrentDirectory);
        if (exitCode != 0)
        {
            throw new InvalidOperationException($"appcmd exited with code {exitCode}.");
        }
    }

    private void StartWatchdog()
    {
        var watchdogScriptPath = Path.Combine(AppContext.BaseDirectory, "stop-iis-site-when-parent-exits.ps1");
        if (!File.Exists(watchdogScriptPath))
        {
            Console.Error.WriteLine($"Warning: IIS watchdog script not found at '{watchdogScriptPath}'.");
            return;
        }

        try
        {
            File.WriteAllText(_watchdogLogPath, string.Empty);
        }
        catch
        {
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = true,
            CreateNoWindow = false,
            WindowStyle = ProcessWindowStyle.Hidden
        };

        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(watchdogScriptPath);
        startInfo.ArgumentList.Add("-ParentProcessId");
        startInfo.ArgumentList.Add(Environment.ProcessId.ToString());
        startInfo.ArgumentList.Add("-SiteName");
        startInfo.ArgumentList.Add(Options.SiteName);
        startInfo.ArgumentList.Add("-LogPath");
        startInfo.ArgumentList.Add(_watchdogLogPath);
        startInfo.ArgumentList.Add("-OwnerFilePath");
        startInfo.ArgumentList.Add(_ownerFilePath);

        try
        {
            Console.WriteLine($"Launching IIS watchdog script: {watchdogScriptPath}");
            Console.WriteLine($"IIS watchdog log: {_watchdogLogPath}");
            _watchdogProcess = Process.Start(startInfo);
            if (_watchdogProcess is not null)
            {
                Console.WriteLine($"Started IIS watchdog process id: {_watchdogProcess.Id}");
            }
            else
            {
                Console.Error.WriteLine("Warning: Process.Start returned null for IIS watchdog.");
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Warning: failed to start IIS watchdog: {ex.Message}");
        }
    }

    private void TryStopWatchdog()
    {
        if (_watchdogProcess is null)
        {
            return;
        }

        try
        {
            if (!_watchdogProcess.HasExited)
            {
                _watchdogProcess.Kill(entireProcessTree: false);
            }
        }
        catch
        {
        }
        finally
        {
            _watchdogProcess.Dispose();
            _watchdogProcess = null;
        }
    }

    private void TryReleaseOwnership()
    {
        try
        {
            if (!File.Exists(_ownerFilePath))
            {
                return;
            }

            var owner = File.ReadAllText(_ownerFilePath).Trim();
            if (owner == Environment.ProcessId.ToString())
            {
                File.Delete(_ownerFilePath);
            }
        }
        catch
        {
        }
    }
}

internal sealed class IisExpressRunner : LegacyWebHostRunner
{
    private Process? _iisExpressProcess;

    public IisExpressRunner(RunnerOptions options) : base(options)
    {
    }

    protected override void ValidateCommonInputs()
    {
        base.ValidateCommonInputs();

        if (string.IsNullOrWhiteSpace(Options.ConfigPath))
        {
            throw new ArgumentException("IIS Express mode requires '--config-path'.");
        }

        if (!File.Exists(Options.ConfigPath))
        {
            throw new FileNotFoundException($"applicationHost.config not found: {Options.ConfigPath}", Options.ConfigPath);
        }
    }

    protected override async Task<int> RunHostedProcessAsync()
    {
        var iisExpressPath = FindIisExpressPath();
        Console.WriteLine($"Starting IIS Express from {iisExpressPath}");
        Console.WriteLine($"Using applicationHost.config: {Options.ConfigPath}");
        Console.WriteLine($"Serving IIS Express site '{Options.SiteName}'");

        _iisExpressProcess = Process.Start(new ProcessStartInfo
        {
            FileName = iisExpressPath,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = Options.ProjectPath,
            ArgumentList =
            {
                $"/config:{Options.ConfigPath}",
                $"/site:{Options.SiteName}",
                "/systray:false"
            }
        });

        if (_iisExpressProcess is null)
        {
            throw new InvalidOperationException("Failed to start IIS Express.");
        }

        var outputClosed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var errorClosed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        _iisExpressProcess.OutputDataReceived += (_, eventArgs) =>
        {
            if (eventArgs.Data is null)
            {
                outputClosed.TrySetResult();
            }
            else
            {
                Console.WriteLine(eventArgs.Data);
            }
        };

        _iisExpressProcess.ErrorDataReceived += (_, eventArgs) =>
        {
            if (eventArgs.Data is null)
            {
                errorClosed.TrySetResult();
            }
            else
            {
                Console.Error.WriteLine(eventArgs.Data);
            }
        };

        _iisExpressProcess.BeginOutputReadLine();
        _iisExpressProcess.BeginErrorReadLine();

        using var shutdownRegistration = Shutdown.Token.Register(() =>
        {
            try
            {
                if (_iisExpressProcess is { HasExited: false })
                {
                    _iisExpressProcess.Kill(entireProcessTree: true);
                }
            }
            catch
            {
            }
        });

        await _iisExpressProcess.WaitForExitAsync();
        await Task.WhenAll(outputClosed.Task, errorClosed.Task);
        return _iisExpressProcess.ExitCode;
    }

    protected override Task CleanupAsync()
    {
        if (_iisExpressProcess is null)
        {
            return Task.CompletedTask;
        }

        try
        {
            if (!_iisExpressProcess.HasExited)
            {
                _iisExpressProcess.Kill(entireProcessTree: true);
            }
        }
        catch
        {
        }
        finally
        {
            _iisExpressProcess.Dispose();
            _iisExpressProcess = null;
        }

        return Task.CompletedTask;
    }

    private static string FindIisExpressPath()
    {
        var configuredPath = Environment.GetEnvironmentVariable("IIS_EXPRESS_PATH");
        if (!string.IsNullOrWhiteSpace(configuredPath))
        {
            if (File.Exists(configuredPath))
            {
                return configuredPath;
            }

            throw new FileNotFoundException($"IIS_EXPRESS_PATH is set but not found: {configuredPath}", configuredPath);
        }

        var commandPath = GetCommandPath("iisexpress.exe");
        if (!string.IsNullOrWhiteSpace(commandPath))
        {
            return commandPath;
        }

        var programFilesCandidates = new[]
        {
            Environment.GetEnvironmentVariable("ProgramFiles"),
            Environment.GetEnvironmentVariable("ProgramFiles(x86)")
        }.Where(path => !string.IsNullOrWhiteSpace(path));

        foreach (var directory in programFilesCandidates)
        {
            var candidate = Path.Combine(directory!, "IIS Express", "iisexpress.exe");
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new FileNotFoundException("IIS Express was not found. Set IIS_EXPRESS_PATH or install IIS Express.");
    }

    private static string? GetCommandPath(string commandName)
    {
        var pathEntries = (Environment.GetEnvironmentVariable("PATH") ?? string.Empty)
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        foreach (var entry in pathEntries)
        {
            var candidate = Path.Combine(entry, commandName);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }
}

internal static class ProcessUtil
{
    public static async Task<int> RunStreamingProcessAsync(string fileName, IReadOnlyList<string> arguments, string workingDirectory)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            WorkingDirectory = workingDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        var outputClosed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var errorClosed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        process.OutputDataReceived += (_, eventArgs) =>
        {
            if (eventArgs.Data is null)
            {
                outputClosed.TrySetResult();
            }
            else
            {
                Console.WriteLine(eventArgs.Data);
            }
        };

        process.ErrorDataReceived += (_, eventArgs) =>
        {
            if (eventArgs.Data is null)
            {
                errorClosed.TrySetResult();
            }
            else
            {
                Console.Error.WriteLine(eventArgs.Data);
            }
        };

        if (!process.Start())
        {
            throw new InvalidOperationException($"Failed to start process '{fileName}'.");
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        await process.WaitForExitAsync();
        await Task.WhenAll(outputClosed.Task, errorClosed.Task);
        return process.ExitCode;
    }

    public static async Task<ProcessResult> RunCapturingProcessAsync(string fileName, IReadOnlyList<string> arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = startInfo };
        if (!process.Start())
        {
            throw new InvalidOperationException($"Failed to start process '{fileName}'.");
        }

        var standardOutput = await process.StandardOutput.ReadToEndAsync();
        var standardError = await process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();

        return new ProcessResult(process.ExitCode, standardOutput, standardError);
    }

    internal sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError);
}

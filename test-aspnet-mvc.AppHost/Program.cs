using Aspire.Hosting.ApplicationModel;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.DependencyInjection;

var builder = DistributedApplication.CreateBuilder(args);

var solutionRoot = Path.GetFullPath(Path.Combine(builder.AppHostDirectory, ".."));
var legacyProjectDirectory = Path.Combine(solutionRoot, "test-aspnet-mvc");
var legacyProjectFile = Path.Combine(legacyProjectDirectory, "test-aspnet-mvc.csproj");
var hostingMode = Environment.GetEnvironmentVariable("HOSTING_MODE") ?? "IISExpress";
var runnerScript = hostingMode == "IIS"
    ? Path.Combine(builder.AppHostDirectory, "run-legacy-mvc-iis.ps1")
    : Path.Combine(builder.AppHostDirectory, "run-legacy-mvc.ps1");
var iisConfigPath = Path.Combine(solutionRoot, ".vs", "test-aspnet-mvc.slnx", "config", "applicationhost.config");
const int appPort = 51578;
const int proxyPort = 5056;
const string siteName = "test-aspnet-mvc";
const string iisStopCommandName = "stop-iis-site";
var stopCommandSelfTest = string.Equals(Environment.GetEnvironmentVariable("ASPIRE_IIS_STOP_TEST_MODE"), "1", StringComparison.Ordinal);
var selfTestTimeoutSeconds = GetPositiveInt("ASPIRE_IIS_STOP_TEST_TIMEOUT_SECONDS", 120);
var selfTestSettleSeconds = GetPositiveInt("ASPIRE_IIS_STOP_TEST_SETTLE_SECONDS", 5);
var selfTestCommandTimeoutSeconds = GetPositiveInt("ASPIRE_IIS_STOP_TEST_COMMAND_TIMEOUT_SECONDS", 30);

var executableArgs = new List<string>
{
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    runnerScript,
    "-ProjectPath",
    legacyProjectDirectory,
    "-ProjectFile",
    legacyProjectFile,
    "-SiteName",
    siteName,
    "-Port",
    appPort.ToString()
};

if (hostingMode != "IIS")
{
    executableArgs.Add("-ConfigPath");
    executableArgs.Add(iisConfigPath);
}

var legacyMvc = builder.AddExecutable(
        name: "legacy-mvc",
        command: "powershell.exe",
        workingDirectory: solutionRoot,
        executableArgs.ToArray())
    .WithHttpEndpoint(port: proxyPort, targetPort: appPort, name: "http");

if (hostingMode == "IIS")
{
    legacyMvc.WithCommand(
        name: iisStopCommandName,
        displayName: "Stop IIS Site",
        executeCommand: _ =>
        {
            try
            {
                Console.WriteLine($"Custom IIS stop command invoked for site '{siteName}'.");
                StopIisSite(siteName);
                return Task.FromResult(CommandResults.Success());
            }
            catch (Exception ex)
            {
                return Task.FromResult(CommandResults.Failure($"Could not stop IIS site: {ex.Message}"));
            }
        },
        commandOptions: new CommandOptions
        {
            ConfirmationMessage = "Stop the IIS site for legacy-mvc?",
            IsHighlighted = true
        });
}

var app = builder.Build();

// Register cleanup handler for IIS mode
if (hostingMode == "IIS")
{
    var lifetime = app.Services.GetRequiredService<IHostApplicationLifetime>();

    if (stopCommandSelfTest)
    {
        lifetime.ApplicationStarted.Register(() =>
        {
            _ = Task.Run(async () =>
            {
                Environment.ExitCode = await RunStopCommandSelfTestAsync(app, lifetime, siteName, selfTestTimeoutSeconds, selfTestSettleSeconds, selfTestCommandTimeoutSeconds);
            });
        });
    }

    lifetime.ApplicationStopping.Register(() =>
    {
        Console.WriteLine("AppHost shutdown detected. Stopping IIS site...");
        try
        {
            StopIisSite(siteName);
            Console.WriteLine("IIS site stop command executed.");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Warning: Could not stop IIS site: {ex.Message}");
        }
    });
}

await app.RunAsync();

static async Task<int> RunStopCommandSelfTestAsync(
    DistributedApplication app,
    IHostApplicationLifetime lifetime,
    string siteName,
    int timeoutSeconds,
    int settleSeconds,
    int commandTimeoutSeconds)
{
    Console.WriteLine("IIS stop-command self-test enabled.");

    var deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
    while (DateTime.UtcNow < deadline)
    {
        var state = GetIisSiteState(siteName);
        if (string.Equals(state, "Started", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine($"Self-test observed IIS site '{siteName}' in Started state.");
            break;
        }

        await Task.Delay(TimeSpan.FromSeconds(1));
    }

    var initialState = GetIisSiteState(siteName);
    if (!string.Equals(initialState, "Started", StringComparison.OrdinalIgnoreCase))
    {
        Console.WriteLine($"Self-test failed before stop command. IIS site state: '{initialState ?? "<missing>"}'.");
        lifetime.StopApplication();
        return 10;
    }

    Console.WriteLine($"Self-test invoking Aspire resource command '{iisStopCommandName}' for 'legacy-mvc'.");
    using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(commandTimeoutSeconds));
    ExecuteCommandResult result;
    try
    {
        result = await app.ResourceCommands.ExecuteCommandAsync("legacy-mvc", iisStopCommandName, cts.Token);
    }
    catch (OperationCanceledException)
    {
        var timedOutState = GetIisSiteState(siteName);
        Console.WriteLine($"Self-test failed: command '{iisStopCommandName}' did not complete within {commandTimeoutSeconds} seconds. IIS site state: '{timedOutState ?? "<missing>"}'.");
        lifetime.StopApplication();
        return 30;
    }

    Console.WriteLine($"Self-test stop command result: success={result.Success}, canceled={result.Canceled}, error='{result.ErrorMessage ?? string.Empty}'.");

    await Task.Delay(TimeSpan.FromSeconds(settleSeconds));

    var finalState = GetIisSiteState(siteName);
    Console.WriteLine($"Self-test observed IIS site state after stop command: '{finalState ?? "<missing>"}'.");

    var exitCode = string.Equals(finalState, "Started", StringComparison.OrdinalIgnoreCase) ? 20 : 0;
    if (exitCode == 0)
    {
        Console.WriteLine("Self-test passed: IIS site is no longer running after stop command.");
    }
    else
    {
        Console.WriteLine("Self-test failed: IIS site is still running after stop command.");
    }

    lifetime.StopApplication();
    return exitCode;
}

static void StopIisSite(string siteName)
{
    var appcmd = Path.Combine(Environment.GetEnvironmentVariable("SystemRoot") ?? "C:\\Windows", "system32\\inetsrv\\appcmd.exe");
    if (!File.Exists(appcmd))
    {
        throw new FileNotFoundException($"appcmd.exe not found at: {appcmd}", appcmd);
    }

    var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
    {
        FileName = appcmd,
        Arguments = $"stop site /site.name:{siteName}",
        UseShellExecute = false,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        CreateNoWindow = true
    });

    if (process is null)
    {
        throw new InvalidOperationException("Failed to start appcmd.exe.");
    }

    process.WaitForExit(5000);

    var output = process.StandardOutput.ReadToEnd();
    var error = process.StandardError.ReadToEnd();

    if (!string.IsNullOrWhiteSpace(output))
    {
        Console.WriteLine($"appcmd output: {output.Trim()}");
    }

    if (process.ExitCode != 0)
    {
        throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? $"appcmd exited with code {process.ExitCode}." : error.Trim());
    }
}

static string? GetIisSiteState(string siteName)
{
    var appcmd = Path.Combine(Environment.GetEnvironmentVariable("SystemRoot") ?? "C:\\Windows", "system32\\inetsrv\\appcmd.exe");
    if (!File.Exists(appcmd))
    {
        return null;
    }

    var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
    {
        FileName = appcmd,
        Arguments = $"list site /site.name:{siteName} /text:state",
        UseShellExecute = false,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        CreateNoWindow = true
    });

    if (process is null)
    {
        return null;
    }

    process.WaitForExit(5000);
    return process.StandardOutput.ReadToEnd().Trim();
}

static int GetPositiveInt(string environmentVariable, int defaultValue)
{
    var value = Environment.GetEnvironmentVariable(environmentVariable);
    return int.TryParse(value, out var parsed) && parsed > 0
        ? parsed
        : defaultValue;
}

using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.DependencyInjection;

var builder = DistributedApplication.CreateBuilder(args);

var solutionRoot = Path.GetFullPath(Path.Combine(builder.AppHostDirectory, ".."));
var legacyProjectDirectory = Path.Combine(solutionRoot, "test-aspnet-mvc");
var legacyProjectFile = Path.Combine(legacyProjectDirectory, "test-aspnet-mvc.csproj");
var hostingMode = Environment.GetEnvironmentVariable("HOSTING_MODE") ?? "IISExpress";
var iisRunnerProject = Path.Combine(solutionRoot, "test-aspnet-mvc.IisRunner", "test-aspnet-mvc.IisRunner.csproj");
var iisConfigPath = Path.Combine(solutionRoot, ".vs", "test-aspnet-mvc.slnx", "config", "applicationhost.config");
const int appPort = 51578;
const int proxyPort = 5056;
const string siteName = "test-aspnet-mvc";

var executableCommand = "dotnet";
var executableArgs = new List<string>
{
    "run",
    "--project",
    iisRunnerProject,
    "--",
    "--mode",
    hostingMode.Equals("IIS", StringComparison.OrdinalIgnoreCase) ? "iis" : "iisexpress",
    "--project-path",
    legacyProjectDirectory,
    "--project-file",
    legacyProjectFile,
    "--site-name",
    siteName,
    "--port",
    appPort.ToString()
};

if (!hostingMode.Equals("IIS", StringComparison.OrdinalIgnoreCase))
{
    executableArgs.Add("--config-path");
    executableArgs.Add(iisConfigPath);
}

var legacyMvc = builder.AddExecutable(
        name: "legacy-mvc",
        command: executableCommand,
        workingDirectory: solutionRoot,
        executableArgs.ToArray())
    .WithHttpEndpoint(port: proxyPort, targetPort: appPort, name: "http");

var app = builder.Build();

// Register cleanup handler for IIS mode
if (hostingMode == "IIS")
{
    var lifetime = app.Services.GetRequiredService<IHostApplicationLifetime>();

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

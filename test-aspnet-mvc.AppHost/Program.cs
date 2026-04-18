var builder = DistributedApplication.CreateBuilder(args);

var solutionRoot = Path.GetFullPath(Path.Combine(builder.AppHostDirectory, ".."));
var legacyProjectDirectory = Path.Combine(solutionRoot, "test-aspnet-mvc");
var legacyProjectFile = Path.Combine(legacyProjectDirectory, "test-aspnet-mvc.csproj");
var runnerScript = Path.Combine(builder.AppHostDirectory, "run-legacy-mvc.ps1");
var iisConfigPath = Path.Combine(solutionRoot, ".vs", "test-aspnet-mvc.slnx", "config", "applicationhost.config");
const int appPort = 51578;
const int proxyPort = 5056;

builder.AddExecutable(
        name: "legacy-mvc",
        command: "powershell.exe",
        workingDirectory: solutionRoot,
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        runnerScript,
        "-ProjectPath",
        legacyProjectDirectory,
        "-ProjectFile",
        legacyProjectFile,
        "-ConfigPath",
        iisConfigPath,
        "-SiteName",
        "test-aspnet-mvc",
        "-Port",
        appPort.ToString())
    .WithHttpEndpoint(port: proxyPort, targetPort: appPort, name: "http");

builder.Build().Run();

# Aspire + ASP.NET MVC 5 on IIS Express

## Goal

This repository contains a classic ASP.NET 4.x MVC application in [test-aspnet-mvc/test-aspnet-mvc.csproj](test-aspnet-mvc/test-aspnet-mvc.csproj). The goal is to let .NET Aspire launch and observe the app during local development, even though Aspire does not natively support IIS or IIS Express as a web host for application resources.

The design here uses Aspire only as an orchestrator. The MVC app still runs under IIS Express.

## Constraint

Microsoft documents that Aspire does not support running web apps locally on IIS or IIS Express as a first-class hosting mode. Because of that, we do not try to model the MVC app as an Aspire `AddProject(...)` web resource.

Instead, we run IIS Express as an external executable resource.

## Design

### Overview

The implementation adds a small Aspire AppHost project at [test-aspnet-mvc.AppHost/test-aspnet-mvc.AppHost.csproj](test-aspnet-mvc.AppHost/test-aspnet-mvc.AppHost.csproj).

At startup:

1. Aspire runs the AppHost in [test-aspnet-mvc.AppHost/Program.cs](test-aspnet-mvc.AppHost/Program.cs).
2. The AppHost registers the legacy MVC app as an executable resource named `legacy-mvc`.
3. That resource launches PowerShell, which runs [test-aspnet-mvc.AppHost/run-legacy-mvc.ps1](test-aspnet-mvc.AppHost/run-legacy-mvc.ps1).
4. The script builds the MVC project by calling the existing [build.ps1](build.ps1).
5. The script starts `iisexpress.exe` using the site definition from `.vs\test-aspnet-mvc.slnx\config\applicationhost.config`.
6. IIS Express serves the real site on port `51578`.
7. Aspire exposes a proxy endpoint on port `5056`, which is the URL shown for the resource from the AppHost.

### Why `applicationhost.config`

Two IIS Express startup styles were evaluated:

- `/path:<folder> /port:<port>`
- `/config:<applicationhost.config> /site:<site-name>`

For this repository, the folder-based `/path` mode did start IIS Express, but the MVC app responded with incorrect results and did not behave like the Visual Studio site. The Visual Studio-generated `applicationhost.config` worked correctly and returned the MVC home page over both HTTP and HTTPS.

Because of that, this design intentionally prefers the config-and-site startup model.

### Port layout

- Aspire dashboard: `http://localhost:17134`
- Aspire resource endpoint for the MVC app: `http://localhost:5056`
- IIS Express HTTP site: `http://localhost:51578`
- IIS Express HTTPS site: `https://localhost:44318`

The separation between `5056` and `51578` matters. Aspire cannot own the same port IIS Express is already binding. The AppHost therefore exposes a proxy endpoint on `5056` that targets the actual IIS Express site on `51578`.

### Files

- [test-aspnet-mvc.AppHost/Program.cs](test-aspnet-mvc.AppHost/Program.cs)
  Defines the Aspire executable resource and endpoint mapping.
- [test-aspnet-mvc.AppHost/run-legacy-mvc.ps1](test-aspnet-mvc.AppHost/run-legacy-mvc.ps1)
  Builds the MVC project and launches IIS Express.
- [test-aspnet-mvc.AppHost/Properties/launchSettings.json](test-aspnet-mvc.AppHost/Properties/launchSettings.json)
  Provides the AppHost dashboard and resource-service settings needed for local `dotnet run`.
- [test-aspnet-mvc.slnx](test-aspnet-mvc.slnx)
  Includes both the legacy MVC project and the new AppHost project.
- [.vs/test-aspnet-mvc.slnx/config/applicationhost.config](.vs/test-aspnet-mvc.slnx/config/applicationhost.config)
  Contains the IIS Express site definition used by the helper script.

## Step-by-step checkout

### 1. Confirm prerequisites

Make sure these are available on the machine:

- .NET SDK installed
- IIS Express installed
- Visual Studio or MSBuild Build Tools installed

Quick checks:

```powershell
dotnet --info
& 'C:\Program Files\IIS Express\iisexpress.exe' /?
```

### 2. Build the AppHost

From the repository root:

```powershell
dotnet build .\test-aspnet-mvc.AppHost\test-aspnet-mvc.AppHost.csproj
```

Expected result:

- Build succeeds with no AppHost compile errors.

### 3. Run the AppHost

From the repository root:

```powershell
dotnet run --project .\test-aspnet-mvc.AppHost\test-aspnet-mvc.AppHost.csproj
```

Expected behavior:

- The Aspire dashboard starts on `http://localhost:17134`
- The helper script builds the MVC project
- IIS Express starts for site `test-aspnet-mvc`
- The MVC resource is exposed through Aspire on `http://localhost:5056`

### 4. Open the dashboard

Open this URL in a browser:

```text
http://localhost:17134
```

Expected result:

- The dashboard loads
- A resource named `legacy-mvc` appears
- The resource shows an HTTP endpoint

### 5. Verify the app through Aspire

Open:

```text
http://localhost:5056
```

Expected result:

- The MVC home page loads
- The page title begins with `Home Page`

### 6. Verify the underlying IIS Express site directly

Open:

```text
http://localhost:51578
```

Optional HTTPS check:

```text
https://localhost:44318
```

Expected result:

- The same MVC home page loads

### 7. Verify from PowerShell

These commands should return `200`:

```powershell
(Invoke-WebRequest http://localhost:5056 -UseBasicParsing).StatusCode
(Invoke-WebRequest http://localhost:51578 -UseBasicParsing).StatusCode
```

Expected result:

```text
200
200
```

## Troubleshooting

### Dashboard starts but the MVC app does not

Check whether the IIS Express config file exists:

```powershell
Test-Path .\.vs\test-aspnet-mvc.slnx\config\applicationhost.config
```

If it is missing, the helper script falls back to IIS Express `/path` mode. That fallback is less reliable for this repo.

### Port conflict

If a port is already in use, stop the conflicting process or update the ports in:

- [test-aspnet-mvc.AppHost/Program.cs](test-aspnet-mvc.AppHost/Program.cs)
- `.vs\test-aspnet-mvc.slnx\config\applicationhost.config`

Keep these aligned:

- AppHost target port for the app: `51578`
- IIS Express site binding: `51578`

The Aspire proxy port can be different.

### IIS Express starts but the page is wrong

Prefer running with:

```text
/config:<applicationhost.config> /site:test-aspnet-mvc
```

instead of:

```text
/path:<project-folder>
```

That difference was the key reason this design uses the `.vs` site definition.

## Tradeoffs

- This is a practical local-development workaround, not a first-class Aspire hosting model.
- The design depends on IIS Express and the local site config generated under `.vs`.
- Aspire can start and surface the app, but classic ASP.NET MVC does not automatically gain modern Aspire integrations such as native service discovery wiring.
- The setup is still useful for local orchestration, dashboards, and eventually adding other dependent resources beside the MVC app.

## Future improvement

The main improvement would be to stop depending on `.vs\...\applicationhost.config` and generate a repo-local IIS Express config file that the AppHost owns directly. That would make the setup more portable across machines and easier to document as a standalone workflow.

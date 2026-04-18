# Aspire + ASP.NET MVC 5

## Running on IIS Express

### Goal

This repository contains a classic ASP.NET 4.x MVC application in [test-aspnet-mvc/test-aspnet-mvc.csproj](test-aspnet-mvc/test-aspnet-mvc.csproj). The goal is to let .NET Aspire launch and observe the app during local development, even though Aspire does not natively support IIS or IIS Express as a web host for application resources.

The design here uses Aspire only as an orchestrator. The MVC app still runs under IIS Express.

### Constraint

Microsoft documents that Aspire does not support running web apps locally on IIS or IIS Express as a first-class hosting mode. Because of that, we do not try to model the MVC app as an Aspire `AddProject(...)` web resource.

Instead, we run IIS Express as an external executable resource.

### Design

#### Overview

The implementation adds a small Aspire AppHost project at [test-aspnet-mvc.AppHost/test-aspnet-mvc.AppHost.csproj](test-aspnet-mvc.AppHost/test-aspnet-mvc.AppHost.csproj).

At startup:

1. Aspire runs the AppHost in [test-aspnet-mvc.AppHost/Program.cs](test-aspnet-mvc.AppHost/Program.cs).
2. The AppHost registers the legacy MVC app as an executable resource named `legacy-mvc`.
3. That resource launches PowerShell, which runs [test-aspnet-mvc.AppHost/run-legacy-mvc.ps1](test-aspnet-mvc.AppHost/run-legacy-mvc.ps1).
4. The script builds the MVC project by calling the existing [build.ps1](build.ps1).
5. The script starts `iisexpress.exe` using the site definition from `.vs\test-aspnet-mvc.slnx\config\applicationhost.config`.
6. IIS Express serves the real site on port `51578`.
7. Aspire exposes a proxy endpoint on port `5056`, which is the URL shown for the resource from the AppHost.

#### Why `applicationhost.config`

Two IIS Express startup styles were evaluated:

- `/path:<folder> /port:<port>`
- `/config:<applicationhost.config> /site:<site-name>`

For this repository, the folder-based `/path` mode did start IIS Express, but the MVC app responded with incorrect results and did not behave like the Visual Studio site. The Visual Studio-generated `applicationhost.config` worked correctly and returned the MVC home page over both HTTP and HTTPS.

Because of that, this design intentionally prefers the config-and-site startup model.

#### Port layout

- Aspire dashboard: `http://localhost:17134`
- Aspire resource endpoint for the MVC app: `http://localhost:5056`
- IIS Express HTTP site: `http://localhost:51578`
- IIS Express HTTPS site: `https://localhost:44318`

The separation between `5056` and `51578` matters. Aspire cannot own the same port IIS Express is already binding. The AppHost therefore exposes a proxy endpoint on `5056` that targets the actual IIS Express site on `51578`.

#### Files

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

### Step-by-step checkout

#### 1. Confirm prerequisites

Make sure these are available on the machine:

- .NET SDK installed
- IIS Express installed
- Visual Studio or MSBuild Build Tools installed

Quick checks:

```powershell
dotnet --info
& 'C:\Program Files\IIS Express\iisexpress.exe' /?
```

#### 2. Build the AppHost

From the repository root:

```powershell
dotnet build .\test-aspnet-mvc.AppHost\test-aspnet-mvc.AppHost.csproj
```

Expected result:

- Build succeeds with no AppHost compile errors.

#### 3. Run the AppHost

From the repository root:

```powershell
dotnet run --project .\test-aspnet-mvc.AppHost\test-aspnet-mvc.AppHost.csproj
```

Expected behavior:

- The Aspire dashboard starts on `http://localhost:17134`
- The helper script builds the MVC project
- IIS Express starts for site `test-aspnet-mvc`
- The MVC resource is exposed through Aspire on `http://localhost:5056`

#### 4. Open the dashboard

Open this URL in a browser:

```text
http://localhost:17134
```

Expected result:

- The dashboard loads
- A resource named `legacy-mvc` appears
- The resource shows an HTTP endpoint

#### 5. Verify the app through Aspire

Open:

```text
http://localhost:5056
```

Expected result:

- The MVC home page loads
- The page title begins with `Home Page`

#### 6. Verify the underlying IIS Express site directly

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

#### 7. Verify from PowerShell

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

### Troubleshooting

#### Dashboard starts but the MVC app does not

Check whether the IIS Express config file exists:

```powershell
Test-Path .\.vs\test-aspnet-mvc.slnx\config\applicationhost.config
```

If it is missing, the helper script falls back to IIS Express `/path` mode. That fallback is less reliable for this repo.

#### Port conflict

If a port is already in use, stop the conflicting process or update the ports in:

- [test-aspnet-mvc.AppHost/Program.cs](test-aspnet-mvc.AppHost/Program.cs)
- `.vs\test-aspnet-mvc.slnx\config\applicationhost.config`

Keep these aligned:

- AppHost target port for the app: `51578`
- IIS Express site binding: `51578`

The Aspire proxy port can be different.

#### IIS Express starts but the page is wrong

Prefer running with:

```text
/config:<applicationhost.config> /site:test-aspnet-mvc
```

instead of:

```text
/path:<project-folder>
```

That difference was the key reason this design uses the `.vs` site definition.

### Tradeoffs

- This is a practical local-development workaround, not a first-class Aspire hosting model.
- The design depends on IIS Express and the local site config generated under `.vs`.
- Aspire can start and surface the app, but classic ASP.NET MVC does not automatically gain modern Aspire integrations such as native service discovery wiring.
- The setup is still useful for local orchestration, dashboards, and eventually adding other dependent resources beside the MVC app.

### Future improvement

The main improvement would be to stop depending on `.vs\...\applicationhost.config` and generate a repo-local IIS Express config file that the AppHost owns directly. That would make the setup more portable across machines and easier to document as a standalone workflow.

## Running on IIS

### Overview

Full IIS support is now available as an opt-in mode. This allows running the legacy MVC app under full IIS (instead of IIS Express) during local development, matching the production hosting environment more closely. The AppHost must run as local administrator to create and manage the IIS site.

### Mode Selection

Set the `HOSTING_MODE` environment variable:

- `HOSTING_MODE=IISExpress` (default) — Use IIS Express (no admin required)
- `HOSTING_MODE=IIS` — Use full IIS (requires admin)

When not set, defaults to IIS Express.

Example:

```powershell
$env:HOSTING_MODE = "IIS"
dotnet run --project .\test-aspnet-mvc.AppHost\test-aspnet-mvc.AppHost.csproj
```

### Process Model: Why a Polling Loop?

**IIS Express** is a **foreground executable**. Aspire launches it as a child process and terminates it when needed.

**Full IIS** is a **Windows Service (W3SVC)** managed globally by the operating system. The AppHost cannot launch IIS itself; instead, it must:

1. Configure the site and AppPool via `appcmd.exe`
2. Start the AppPool and Site
3. Enter a **polling loop** to remain alive (so Aspire sees the resource as healthy)
4. Check the site state every 5 seconds; exit the loop if the site stops

When Aspire terminates the script process, it uses `TerminateProcess` (harsh kill), which bypasses cleanup code. The IIS site continues running in the background — acceptable for local dev, as it can be manually stopped later or via IIS Manager.

### Implementation Details

**Script:** [run-legacy-mvc-iis.ps1](../test-aspnet-mvc.AppHost/run-legacy-mvc-iis.ps1)

**Parameters:**

| Parameter | Type | Default | Purpose |
|---|---|---|---|
| `-ProjectPath` | string | (required) | Project directory (same as IIS Express) |
| `-ProjectFile` | string | (required) | Path to .csproj file |
| `-SiteName` | string | `test-aspnet-mvc` | IIS site name |
| `-Port` | int | `51578` | HTTP port binding (only used for initial site creation) |

**Environment Variable Overrides:**

| Variable | Overrides | Purpose |
|---|---|---|
| `BUILD_SCRIPT` | Auto-detected `build.ps1` | Path to custom build script |
| `IIS_SITE_NAME` | `-SiteName` parameter | IIS site name |
| `IIS_PORT` | `-Port` parameter | Port binding for initial site creation (default 51578) |

**IIS Configuration:**

- **Site**: Top-level IIS site named `test-aspnet-mvc` (customizable via `IIS_SITE_NAME`)
  - Physical path: Project directory containing `web.config` (same as IIS Express)
  - Binding: `http://*:51578:localhost` (port set on first creation via `-Port` / `IIS_PORT`)
  - AppPool: Auto-assigned by IIS (uses DefaultAppPool or existing pool if site already exists)

**Execution Sequence:**

1. Build the project via `build.ps1`
2. Verify `appcmd.exe` is available (`%SystemRoot%\system32\inetsrv\appcmd.exe`)
3. Check if site exists:
   - If not: Create site with the configured port binding
   - If yes: Update physical path only (port binding left unchanged)
4. Start the site
5. Poll the site state every 5 seconds
6. Exit loop when site stops
7. `try/finally` block stops the site on exit (best-effort; process kill may skip this)

### Port Flow (IIS Mode)

```
Browser / External Client
  | port 5056 (Aspire reverse proxy)
  v
Aspire DCP Proxy
  | port 51578 (targetPort, forwarded internally)
  v
IIS W3SVC (Windows Service)
  | (via site binding: http/*:51578:localhost)
  v
test-aspnet-mvc (ASP.NET MVC 5 / .NET Framework 4.8)
```

### Prerequisites for IIS Mode

- **Windows Edition**: Pro, Enterprise, or Windows Server (not Home)
- **IIS Role**: Web Server role installed (`Get-WindowsFeature -Name Web-Server` should return Installed)
- **IIS Management**: `appcmd.exe` accessible at `%SystemRoot%\system32\inetsrv\appcmd.exe`
- **Administrator Privilege**: AppHost must run as local admin to create/manage IIS sites
- **.NET Framework 4.8**: Already required for the MVC app

### Verification Steps

1. Install IIS if not present: `Enable-WindowsOptionalFeature -FeatureName IIS-WebServer`
2. Start a PowerShell terminal as Administrator
3. Set the environment variable:
   ```powershell
   $env:HOSTING_MODE = "IIS"
   ```
4. Run the AppHost:
   ```powershell
   dotnet run --project .\test-aspnet-mvc.AppHost\test-aspnet-mvc.AppHost.csproj
   ```
5. Confirm in the Aspire dashboard:
   - The `legacy-mvc` resource appears as running
   - Opening `http://localhost:5056` serves the MVC home page
6. Verify in IIS Manager:
   - The site `test-aspnet-mvc` exists under Sites
7. Direct IIS check:
   ```powershell
   (Invoke-WebRequest http://localhost:51578 -UseBasicParsing).StatusCode
   ```
   Should return `200`.

### Cleanup

The IIS site created by the script persists after the AppHost exits. To remove it:

**Option 1: Via IIS Manager**
1. Open IIS Manager
2. Select the site `test-aspnet-mvc` and click Delete

**Option 2: Via appcmd.exe (requires admin)**
```powershell
%SystemRoot%\system32\inetsrv\appcmd.exe delete site /site.name:test-aspnet-mvc
```

### Tradeoffs: IIS vs IIS Express

| Aspect | IIS Express | Full IIS |
|---|---|---|
| **Admin Required** | No | Yes (one-time) |
| **Setup** | Automatic, no system state changes | Auto-creates site on first run |
| **Production Parity** | Lower (development-only tool) | Higher (production-like environment) |
| **Cleanup** | Automatic | Manual deletion of site |
| **Port Conflicts** | Per-user isolation | System-wide shared ports |

### Recommendation

**Default to IIS Express** for simplicity and accessibility. Use **IIS mode** when you need production-like hosting or to verify IIS-specific behavior locally. 

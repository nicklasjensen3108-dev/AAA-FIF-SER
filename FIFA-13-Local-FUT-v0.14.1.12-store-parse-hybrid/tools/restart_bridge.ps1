# Restart the local backend: Blaze bridge, trace proxy, FUT RS4, DIME/HTTP,
# and the four donor-parity POW endpoints.
#
# Run this before EVERY game launch. The bridge serves exactly one game session:
# once a session has disconnected, later connections are accepted, complete their
# TLS ("Authenticated as server"), then get dropped immediately. The game then
# boots with no online session at all — no Util::fetchClientConfig, no futBoot.xml
# download, futStatus back to 7 — which looks exactly like a FUT regression and
# is not one.
#
# Two launch gotchas are handled here:
#   * the certificate path is resolved against the CURRENT DIRECTORY
#     (<cwd>/secrets/gosredirector.protossl.der + .key), so the working directory
#     must be the parent of the secrets folder, not the build output folder. This
#     script sets the working directory accordingly and also passes
#     FUT13_REDIRECTOR_CERT explicitly, so the lookup no longer depends on the
#     working directory at all;
#   * the redirector port defaults to 44125, while this stack uses 42128.
#
# All local services are required. The RS4 server used to be started by hand,
# which made an incomplete stack look like a FUT regression: the bridge brings
# the game online, but CardsDLLzf.dll talks to the RS4 endpoint on port 8099, and
# without it the FUT hub gets nothing.
#
# The release package includes the self-contained Blaze bridge. Normal users use
# tools\trace_proxy.py for the trace relay, so no separate .NET 8 runtime is
# required. The C# trace-proxy project is retained only as developer/reference
# source. Developers can rebuild the bridge with:
#   dotnet publish src/bridge/Fut13Local.Bridge.csproj -c Release -o src/bridge/out

param(
    # Directory holding the local ProtoSSL redirector certificate material
    # (gosredirector.protossl.der + gosredirector.key). Defaults to
    # src\bridge\secrets, or to the directory of FUT13_REDIRECTOR_CERT when that
    # variable is already set.
    [string] $SecretsDirectory,
    # Where the redirected stdout/stderr of the four processes is written.
    # autoattach.py reads the bridge log from here, so both scripts must agree.
    [string] $LogDirectory,
    [int]    $DimePort       = 8080,
    [int]    $Rs4Port        = 8099,
    [int]    $BlazePort      = 10092,
    [int]    $TraceProxyPort = 42127,
    [int]    $RedirectorPort = 42128,
    [int]    $EaswFutPort    = 19501,
    [int]    $EaswAuthPort   = 19502,
    [int]    $EaswReqPort    = 19503,
    [int]    $EaswEventPort  = 19504,
    [int]    $EaswMediaPort  = 19505,
    [int]    $EaswGfPort     = 19506,
    [int]    $EaswRosterPort = 19507,
    [int]    $PowPort        = 19512,
    [int]    $PowNucleusPort = 19513,
    [int]    $PowContentPort = 19514,
    [int]    $PowMmmPort     = 19515,
    [string] $SessionId,
    [string] $Locale
)

$ErrorActionPreference = 'Stop'

function New-TrackedProcessEntry {
    param([string]$Name, [System.Diagnostics.Process]$Process, [string]$ErrorLog)
    if ($null -eq $Process) { throw ("{0} failed to return a process object." -f $Name) }

    # StartTime is metadata, not a health signal. On some Windows/PowerShell
    # combinations a freshly-started hidden powershell.exe can temporarily
    # expose StartTime as $null even though it is alive and will own its socket
    # a moment later. v0.14.1.3 incorrectly treated that transient state as a
    # fatal launch failure. Record StartTime when Windows provides it, but let
    # the PID/socket ownership checks below decide whether the service is healthy.
    $startedUtc = $null
    try {
        $Process.Refresh()
        if ($Process.HasExited) {
            $exitCode = '?'
            try { $exitCode = $Process.ExitCode } catch { }
            throw ("process exited immediately (exit code {0})" -f $exitCode)
        }
        $started = $Process.StartTime
        if ($null -ne $started) {
            $startedUtc = $started.ToUniversalTime().ToString('o')
        }
    } catch {
        # An actual exited process is fatal. Metadata-only failures are not.
        $stillAlive = Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
        if (-not $stillAlive) {
            $details = $_.Exception.Message
            if ($ErrorLog -and (Test-Path -LiteralPath $ErrorLog)) {
                $tail = (Get-Content -LiteralPath $ErrorLog -Tail 12 -ErrorAction SilentlyContinue | Out-String).Trim()
                if ($tail) { $details = $details + "`r`nProxy/service stderr:`r`n" + $tail }
            }
            throw ("{0} exited during startup (PID {1}). Details: {2}" -f $Name,$Process.Id,$details)
        }
        Write-Host ("  {0}: Windows did not expose StartTime for PID {1}; continuing to socket/PID health verification." -f $Name,$Process.Id) -ForegroundColor DarkYellow
    }

    return @{ name = $Name; pid = $Process.Id; startedUtc = $startedUtc }
}

# Windows PowerShell 5.1 flattens Start-Process -ArgumentList arrays into a
# single command line. Paths containing spaces therefore need to arrive already
# quoted when they are consumed by powershell.exe -File. Keep this helper tiny:
# our generated package paths cannot contain literal double quotes.
function Quote-ChildArgument {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '""' }
    $text = [string]$Value
    return '"' + $text.Replace('"','\"') + '"'
}


# `dotnet build` and `dotnet publish` put the executable in different places
# depending on the configuration, the target framework and whether a runtime
# identifier was used, and an explicit `-o` puts it somewhere else again. Rather
# than hardcoding one path, search the project directory and rank the candidates:
# an out\ or publish\ folder first (out\ is what the documented build command
# produces, publish\ is where a plain `dotnet publish` lands), then Release over
# Debug, then the most recently written file.
function Find-BuildOutput {
    param(
        [Parameter(Mandatory)] [string] $ProjectDirectory,
        [Parameter(Mandatory)] [string] $FileName,
        [Parameter(Mandatory)] [string] $BuildCommand
    )

    $candidates = @()
    if (Test-Path -LiteralPath $ProjectDirectory) {
        $candidates = @(Get-ChildItem -LiteralPath $ProjectDirectory -Recurse -Filter $FileName -File -ErrorAction SilentlyContinue |
            # obj\ holds the intermediate apphost under the very same name; only
            # bin\ and explicit output folders hold a runnable build.
            Where-Object { $_.FullName -notmatch '\\obj\\' })
    }

    if ($candidates.Count -eq 0) {
        throw ("{0} was not found under {1}.`r`nBuild it first:`r`n    {2}" -f $FileName, $ProjectDirectory, $BuildCommand)
    }

    # out\ outranks publish\ outranks Release\. A stale bin\Release\...\publish\
    # from an earlier plain `dotnet publish` must never win over the out\ folder
    # the documented build command writes, even though the stale path is the one
    # that also happens to contain "Release".
    return ($candidates |
        Sort-Object `
            @{ Expression = { $_.FullName -match '\\out\\' };     Descending = $true }, `
            @{ Expression = { $_.FullName -match '\\publish\\' }; Descending = $true }, `
            @{ Expression = { $_.FullName -match '\\Release\\' }; Descending = $true }, `
            @{ Expression = { $_.LastWriteTimeUtc };              Descending = $true } |
        Select-Object -First 1).FullName
}

$root      = Split-Path -Parent $PSScriptRoot
$bridgeDir = Join-Path $root 'src\bridge'
$serverDir = Join-Path $root 'server'

if (-not $Locale) {
    $Locale = 'eng_us'
    $settingsPath = Join-Path $root 'local.settings.json'
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            if ($settings.locale) { $Locale = [string]$settings.locale }
        } catch {
            Write-Warning ("Could not read locale from local.settings.json; using eng_us: {0}" -f $_.Exception.Message)
        }
    }
}

if (-not $SecretsDirectory) {
    $SecretsDirectory = if ($env:FUT13_REDIRECTOR_CERT) {
        Split-Path -Parent $env:FUT13_REDIRECTOR_CERT
    } else {
        Join-Path $bridgeDir 'secrets'
    }
}
if (-not $LogDirectory) { $LogDirectory = Join-Path $root 'logs' }
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

$dimePs1 = Join-Path $serverDir 'fut13-dime-server.ps1'
$rs4Ps1  = Join-Path $serverDir 'fut13-rs4-server.ps1'
$easwPs1 = Join-Path $serverDir 'fut13-easw-server.ps1'
$powPs1  = Join-Path $serverDir 'fut13-pow-server.ps1'
$fullClubCatalogPath = [System.IO.Path]::GetFullPath((Join-Path $root 'data\fifa13-full-player-catalog.json'))
$env:FUT13_FULL_CLUB_CATALOG = $fullClubCatalogPath
$itemCatalogPath = [System.IO.Path]::GetFullPath((Join-Path $root 'data\fifa13-native-item-catalog.json'))
$savePath = [System.IO.Path]::GetFullPath((Join-Path $root 'save\fut13-local.sqlite3'))
$pythonPath = $null
try {
    $runtimeSettingsPath = Join-Path $root 'local.settings.json'
    if (Test-Path -LiteralPath $runtimeSettingsPath) {
        $runtimeSettings = Get-Content -LiteralPath $runtimeSettingsPath -Raw | ConvertFrom-Json
        if ($runtimeSettings.python) { $pythonPath = [string]$runtimeSettings.python }
    }
} catch {}
if (-not $pythonPath) {
    $pythonCmd = Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pythonCmd) { $pythonCmd = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($pythonCmd) { $pythonPath = [string]$pythonCmd.Source }
}
if (-not $pythonPath) { throw 'Python could not be resolved for the SQLite FUT save.' }
foreach ($p in @($dimePs1, $rs4Ps1, $easwPs1, $powPs1)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Not found: $p" }
}

$bridgeExe = Find-BuildOutput -ProjectDirectory $bridgeDir -FileName 'Fut13Local.Bridge.exe' `
    -BuildCommand 'dotnet publish src/bridge/Fut13Local.Bridge.csproj -c Release -o src/bridge/out'
$proxyScript = Join-Path $root 'tools\trace_proxy.py'
if (-not (Test-Path -LiteralPath $proxyScript)) { throw "Python trace proxy is missing: $proxyScript" }

# The bridge rebuilds its TLS certificate from the DER + PEM pair at startup and
# throws when either is missing. Check here instead: a bridge that dies one
# second after launch leaves nothing on screen, only a line in a log file nobody
# is watching yet.
foreach ($material in @('gosredirector.protossl.der', 'gosredirector.key')) {
    $path = Join-Path $SecretsDirectory $material
    if (-not (Test-Path -LiteralPath $path)) {
        throw ("Missing certificate material: {0}`r`nThe bridge needs the ProtoSSL redirector certificate (DER) and its PEM key in that directory. Run INSTALL_PREREQUISITES.cmd to generate them, or point -SecretsDirectory at the folder that holds them." -f $path)
    }
}

$runtimePath = Join-Path $root 'runtime\processes.json'
if (Test-Path -LiteralPath $runtimePath) {
    $previous = Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json
    foreach ($entry in @($previous.processes)) {
        $process = Get-Process -Id ([int]$entry.pid) -ErrorAction SilentlyContinue
        if (-not $process) { continue }
        # PID reuse is possible. Only stop a process whose creation time still
        # matches the manifest written by this build.
        try {
            $previousStartedUtc = $process.StartTime.ToUniversalTime().ToString('o')
        } catch {
            # If Windows will not expose StartTime for a stale manifest entry, do
            # not risk killing an unrelated reused PID. The port-owner pass below
            # will still identify stale FUT13 listeners safely.
            continue
        }
        if ($previousStartedUtc -eq $entry.startedUtc) {
            Stop-Process -Id $process.Id -Force
        }
    }
}

# Clean up stale listeners from previous copies of this FUT13 stack. Closing a
# launcher window does not always terminate its hidden .NET/PowerShell children;
# that produced SocketException 10048 on DIME/proxy while the old launcher still
# printed READY. Only processes whose command line/path clearly belongs to a
# FIFA13 local build are killed automatically. An unrelated owner is reported
# and left untouched.
$requiredPorts = @($DimePort, $Rs4Port, $BlazePort, $TraceProxyPort, $RedirectorPort, $EaswFutPort, $EaswAuthPort, $EaswReqPort, $EaswEventPort, $EaswMediaPort, $EaswGfPort, $EaswRosterPort, $PowPort, $PowNucleusPort, $PowContentPort, $PowMmmPort)
foreach ($port in $requiredPorts) {
    $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    foreach ($listener in $listeners) {
        $pidValue = [int]$listener.OwningProcess
        $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        $procInfo = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $pidValue) -ErrorAction SilentlyContinue
        $commandLine = if ($procInfo) { [string]$procInfo.CommandLine } else { '' }
        $exePath = try { [string]$proc.Path } catch { '' }
        $identity = ($exePath + ' ' + $commandLine).ToLowerInvariant()
        $isOurOldStack = ($identity -match 'fifa13-fut-revival|fifa13-local-fut|fut13local\.bridge|fut13local\.traceproxy|fut13-rs4-server|fut13-dime-server|fut13-easw-server|fut13-easw-auth-server|fut13-pow-server')
        if ($isOurOldStack) {
            Write-Host ("Stopping stale FUT13 listener on port {0}: PID {1} ({2})" -f $port, $pidValue, $proc.ProcessName) -ForegroundColor Yellow
            Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 250
        } else {
            throw ("Port {0} is already owned by unrelated process PID {1} ({2}). Close that program or free the port; it was not terminated automatically." -f $port, $pidValue, $proc.ProcessName)
        }
    }
}

Start-Sleep -Milliseconds 900

$stamp = if ($SessionId) { $SessionId } else { Get-Date -Format 'yyyyMMdd-HHmmss' }
$env:FUT13_TRACE_SESSION      = $stamp
$env:FUT13_REDIRECTOR_CERT     = Join-Path $SecretsDirectory 'gosredirector.ea.com.pfx'
$env:FUT13_REDIRECTOR_PORT     = "$RedirectorPort"
$env:FUT13_BLAZE_PORT          = "$BlazePort"
$env:FUT13_TRACE_LISTEN_PORT   = "$TraceProxyPort"
$env:FUT13_TRACE_TARGET_PORT   = "$RedirectorPort"

# Codex can inherit both a mixed-case `Path` and uppercase `PATH` entry. Windows
# PowerShell's Start-Process copies them into a case-insensitive dictionary and
# throws before creating the child. Both entries contain the same value here;
# remove only the duplicate uppercase spelling and retain the normal Path.
$pathKeys = @([Environment]::GetEnvironmentVariables().Keys |
    Where-Object { $_ -cmatch '^(Path|PATH)$' })
if ($pathKeys -contains 'Path' -and $pathKeys -contains 'PATH') {
    [Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
}

$rs4ScriptArg = Quote-ChildArgument $rs4Ps1
$dimeScriptArg = Quote-ChildArgument $dimePs1
$easwScriptArg = Quote-ChildArgument $easwPs1
$powScriptArg = Quote-ChildArgument $powPs1

$bridgeProcess = Start-Process -FilePath $bridgeExe -WorkingDirectory (Split-Path -Parent $SecretsDirectory) `
    -RedirectStandardOutput (Join-Path $LogDirectory "bridge-$stamp.out.log") `
    -RedirectStandardError  (Join-Path $LogDirectory "bridge-$stamp.err.log") -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 1500

# v0.14.1.5: the public v0.14.1.4 package accidentally shipped a framework-
# dependent .NET 8 trace proxy while calling it self-contained. That helper exits
# immediately on PCs without Microsoft.NETCore.App 8.x. Use the already-required
# Python runtime instead; this proxy is standard-library only and owns the same
# listening socket/PID that the health checks expect.
$proxyOutLog = Join-Path $LogDirectory "proxy-$stamp.out.log"
$proxyErrLog = Join-Path $LogDirectory "proxy-$stamp.err.log"
$proxyScriptArg = '"' + $proxyScript + '"'
$proxyProcess = Start-Process -FilePath $pythonPath -WorkingDirectory $root `
    -ArgumentList '-u', $proxyScriptArg `
    -RedirectStandardOutput $proxyOutLog `
    -RedirectStandardError  $proxyErrLog -WindowStyle Hidden -PassThru

$rs4CatalogArg = '"' + $fullClubCatalogPath + '"'
$rs4ItemCatalogArg = '"' + $itemCatalogPath + '"'
$rs4SaveArg = '"' + $savePath + '"'
$rs4PythonArg = '"' + $pythonPath + '"'
$rs4OutLog = Join-Path $LogDirectory "rs4-$stamp.out.log"
$rs4ErrLog = Join-Path $LogDirectory "rs4-$stamp.err.log"
$rs4Process = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $rs4ScriptArg, '-Port', "$Rs4Port", `
        '-FullClubCatalogPath', $rs4CatalogArg, '-ItemCatalogPath', $rs4ItemCatalogArg, `
        '-PythonPath', $rs4PythonArg, '-SavePath', $rs4SaveArg `
    -RedirectStandardOutput $rs4OutLog `
    -RedirectStandardError  $rs4ErrLog -WindowStyle Hidden -PassThru

$dimeProcess = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dimeScriptArg, '-Port', "$DimePort", '-Locale', $Locale `
    -RedirectStandardOutput (Join-Path $LogDirectory "dime-$stamp.out.log") `
    -RedirectStandardError  (Join-Path $LogDirectory "dime-$stamp.err.log") -WindowStyle Hidden -PassThru

# v0.13.17: run the complete seven-key EASW surface from the working donor.
# v0.13.15 exposed AUTH alone; fifa13.exe never activated it. One port per key
# makes the resulting trace unambiguous while the temporary CardsDLL credential
# shim remains available only as a fallback for FUT entry.
$easwFutProcess = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $easwScriptArg, '-Port', "$EaswFutPort", '-Label', 'FUT_URI' `
    -RedirectStandardOutput (Join-Path $LogDirectory "easw01-$stamp.out.log") `
    -RedirectStandardError  (Join-Path $LogDirectory "easw01-$stamp.err.log") -WindowStyle Hidden -PassThru
$easwAuthProcess = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $easwScriptArg, '-Port', "$EaswAuthPort", '-Label', 'OSDK_EASW_AUTH_URL' `
    -RedirectStandardOutput (Join-Path $LogDirectory "easw02-$stamp.out.log") `
    -RedirectStandardError  (Join-Path $LogDirectory "easw02-$stamp.err.log") -WindowStyle Hidden -PassThru
$easwReqProcess = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $easwScriptArg, '-Port', "$EaswReqPort", '-Label', 'OSDK_EASW_REQ_URL' `
    -RedirectStandardOutput (Join-Path $LogDirectory "easw03-$stamp.out.log") `
    -RedirectStandardError  (Join-Path $LogDirectory "easw03-$stamp.err.log") -WindowStyle Hidden -PassThru
$easwEventProcess = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $easwScriptArg, '-Port', "$EaswEventPort", '-Label', 'OSDK_EASW_EVENT_URL' `
    -RedirectStandardOutput (Join-Path $LogDirectory "easw04-$stamp.out.log") `
    -RedirectStandardError  (Join-Path $LogDirectory "easw04-$stamp.err.log") -WindowStyle Hidden -PassThru
$easwMediaProcess = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $easwScriptArg, '-Port', "$EaswMediaPort", '-Label', 'OSDK_EASW_MEDIA_URL' `
    -RedirectStandardOutput (Join-Path $LogDirectory "easw05-$stamp.out.log") `
    -RedirectStandardError  (Join-Path $LogDirectory "easw05-$stamp.err.log") -WindowStyle Hidden -PassThru
$easwGfProcess = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $easwScriptArg, '-Port', "$EaswGfPort", '-Label', 'OSDK_EASW_GF_FILE_URL' `
    -RedirectStandardOutput (Join-Path $LogDirectory "easw06-$stamp.out.log") `
    -RedirectStandardError  (Join-Path $LogDirectory "easw06-$stamp.err.log") -WindowStyle Hidden -PassThru
$easwRosterProcess = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $easwScriptArg, '-Port', "$EaswRosterPort", '-Label', 'FUT/ROSTERUPDATE_URL' `
    -RedirectStandardOutput (Join-Path $LogDirectory "easw07-$stamp.out.log") `
    -RedirectStandardError  (Join-Path $LogDirectory "easw07-$stamp.err.log") -WindowStyle Hidden -PassThru

$powProcess = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $powScriptArg, '-Port', "$PowPort", '-Label', 'FIFA_POW_URL' `
    -RedirectStandardOutput (Join-Path $LogDirectory "pow12-$stamp.out.log") `
    -RedirectStandardError  (Join-Path $LogDirectory "pow12-$stamp.err.log") -WindowStyle Hidden -PassThru

$powNucleusProcess = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $powScriptArg, '-Port', "$PowNucleusPort", '-Label', 'FIFA_POW_NUCLEUS_PROXY_URL' `
    -RedirectStandardOutput (Join-Path $LogDirectory "pow13-$stamp.out.log") `
    -RedirectStandardError  (Join-Path $LogDirectory "pow13-$stamp.err.log") -WindowStyle Hidden -PassThru

$powContentProcess = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $powScriptArg, '-Port', "$PowContentPort", '-Label', 'FIFA_POW_CONTENT_SERVER_URL' `
    -RedirectStandardOutput (Join-Path $LogDirectory "pow14-$stamp.out.log") `
    -RedirectStandardError  (Join-Path $LogDirectory "pow14-$stamp.err.log") -WindowStyle Hidden -PassThru

$powMmmProcess = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $powScriptArg, '-Port', "$PowMmmPort", '-Label', 'FIFA_POW_MMM_URI' `
    -RedirectStandardOutput (Join-Path $LogDirectory "pow15-$stamp.out.log") `
    -RedirectStandardError  (Join-Path $LogDirectory "pow15-$stamp.err.log") -WindowStyle Hidden -PassThru

$runtimeDirectory = Split-Path -Parent $runtimePath
New-Item -ItemType Directory -Force -Path $runtimeDirectory | Out-Null
$processEntries = @(
    (New-TrackedProcessEntry -Name 'bridge' -Process $bridgeProcess)
    (New-TrackedProcessEntry -Name 'proxy'  -Process $proxyProcess -ErrorLog $proxyErrLog)
    (New-TrackedProcessEntry -Name 'rs4'    -Process $rs4Process -ErrorLog $rs4ErrLog)
    (New-TrackedProcessEntry -Name 'dime'   -Process $dimeProcess)
    (New-TrackedProcessEntry -Name 'easw01' -Process $easwFutProcess)
    (New-TrackedProcessEntry -Name 'easw02' -Process $easwAuthProcess)
    (New-TrackedProcessEntry -Name 'easw03' -Process $easwReqProcess)
    (New-TrackedProcessEntry -Name 'easw04' -Process $easwEventProcess)
    (New-TrackedProcessEntry -Name 'easw05' -Process $easwMediaProcess)
    (New-TrackedProcessEntry -Name 'easw06' -Process $easwGfProcess)
    (New-TrackedProcessEntry -Name 'easw07' -Process $easwRosterProcess)
    (New-TrackedProcessEntry -Name 'pow12'  -Process $powProcess)
    (New-TrackedProcessEntry -Name 'pow13'  -Process $powNucleusProcess)
    (New-TrackedProcessEntry -Name 'pow14'  -Process $powContentProcess)
    (New-TrackedProcessEntry -Name 'pow15'  -Process $powMmmProcess)
)
@{ startedUtc = [DateTime]::UtcNow.ToString('o'); processes = $processEntries } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $runtimePath -Encoding UTF8
Start-Sleep -Seconds 2

# A plain hashtable, not [ordered]: an OrderedDictionary indexed by an integer
# treats it as a positional index rather than a key, and every port here is an
# integer. Display order comes from Sort-Object below.
$expected = @{
    $DimePort       = 'DIME'
    $Rs4Port        = 'FUT RS4'
    $BlazePort      = 'Blaze'
    $TraceProxyPort = 'trace proxy'
    $RedirectorPort = 'redirector'
    $EaswFutPort    = 'EASW FUT_URI'
    $EaswAuthPort   = 'EASW auth'
    $EaswReqPort    = 'EASW req'
    $EaswEventPort  = 'EASW event'
    $EaswMediaPort  = 'EASW media'
    $EaswGfPort     = 'EASW GF'
    $EaswRosterPort = 'EASW roster'
    $PowPort        = 'POW'
    $PowNucleusPort = 'POW nucleus proxy'
    $PowContentPort = 'POW content'
    $PowMmmPort     = 'POW MMM'
}

$expectedOwners = @{
    $DimePort       = @{ name = 'DIME';        pid = $dimeProcess.Id }
    $Rs4Port        = @{ name = 'FUT RS4';     pid = $rs4Process.Id }
    $BlazePort      = @{ name = 'Blaze';       pid = $bridgeProcess.Id }
    $TraceProxyPort = @{ name = 'trace proxy'; pid = $proxyProcess.Id }
    $RedirectorPort = @{ name = 'redirector';  pid = $bridgeProcess.Id }
    $EaswFutPort    = @{ name = 'EASW FUT_URI'; pid = $easwFutProcess.Id }
    $EaswAuthPort   = @{ name = 'EASW auth';    pid = $easwAuthProcess.Id }
    $EaswReqPort    = @{ name = 'EASW req';     pid = $easwReqProcess.Id }
    $EaswEventPort  = @{ name = 'EASW event';   pid = $easwEventProcess.Id }
    $EaswMediaPort  = @{ name = 'EASW media';   pid = $easwMediaProcess.Id }
    $EaswGfPort     = @{ name = 'EASW GF';      pid = $easwGfProcess.Id }
    $EaswRosterPort = @{ name = 'EASW roster';  pid = $easwRosterProcess.Id }
    $PowPort        = @{ name = 'POW';          pid = $powProcess.Id }
    $PowNucleusPort = @{ name = 'POW nucleus';  pid = $powNucleusProcess.Id }
    $PowContentPort = @{ name = 'POW content';  pid = $powContentProcess.Id }
    $PowMmmPort     = @{ name = 'POW MMM';      pid = $powMmmProcess.Id }
}

# v0.13.17 may parse/build 12k native club rows before RS4 begins listening.
# Give Windows PowerShell enough time for that one-time load; READY still means
# every socket is owned by this exact launcher, never a stale process.
$deadline = (Get-Date).AddSeconds(30)
do {
    $allReady = $true
    foreach ($port in $expectedOwners.Keys) {
        $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $conn -or [int]$conn.OwningProcess -ne [int]$expectedOwners[$port].pid) { $allReady = $false; break }
    }
    if (-not $allReady) { Start-Sleep -Milliseconds 250 }
} while (-not $allReady -and (Get-Date) -lt $deadline)

$failures = @()
foreach ($port in ($expectedOwners.Keys | Sort-Object)) {
    $entry = $expectedOwners[$port]
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    $ok = ($conn -and [int]$conn.OwningProcess -eq [int]$entry.pid)
    $colour = if ($ok) { 'Green' } else { 'Red' }
    $stateText = if ($ok) { 'listening (owned by this build)' } elseif ($conn) { "WRONG OWNER PID $($conn.OwningProcess)" } else { 'MISSING' }
    Write-Host ("  {0,6}  {1,-16} {2}" -f $port, $entry.name, $stateText) -ForegroundColor $colour
    if (-not $ok) { $failures += ("{0} port {1}: {2}" -f $entry.name, $port, $stateText) }
}

foreach ($name in @('bridge', 'proxy', 'rs4', 'dime', 'easw01', 'easw02', 'easw03', 'easw04', 'easw05', 'easw06', 'easw07', 'pow12', 'pow13', 'pow14', 'pow15')) {
    $errLog = Join-Path $LogDirectory "$name-$stamp.err.log"
    if ((Test-Path -LiteralPath $errLog) -and (Get-Item -LiteralPath $errLog).Length -gt 0) {
        $errText = (Get-Content -LiteralPath $errLog -TotalCount 12 | Out-String).Trim()
        if ($errText) { $failures += ("Startup error from {0}: {1}" -f $name, $errText) }
    }
}

foreach ($entry in $processEntries) {
    if (-not (Get-Process -Id ([int]$entry.pid) -ErrorAction SilentlyContinue)) {
        $failures += ("{0} process exited during startup (PID {1})" -f $entry.name, $entry.pid)
    }
}

if ($failures.Count -gt 0) {
    # Stop the partial stack so a failed launch cannot poison the next run.
    foreach ($entry in $processEntries) { Stop-Process -Id ([int]$entry.pid) -Force -ErrorAction SilentlyContinue }
    throw ("FIFA 13 local service startup failed:`r`n - " + ($failures -join "`r`n - "))
}

Write-Host 'All sixteen required local sockets are healthy and owned by this build.' -ForegroundColor Green

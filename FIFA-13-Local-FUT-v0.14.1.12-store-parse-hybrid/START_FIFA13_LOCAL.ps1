[CmdletBinding()]
param(
    [switch]$SkipPreflight,
    [switch]$NoAutoAttach,
    [string]$SessionId
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
foreach ($relativeDirectory in @('runtime', 'logs', 'artifacts')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $root $relativeDirectory) | Out-Null
}
$settings = Get-Content -LiteralPath (Join-Path $root 'local.settings.json') -Raw | ConvertFrom-Json
if ($null -eq $settings) { throw 'local.settings.json parsed as null.' }
if ([string]::IsNullOrWhiteSpace([string]$settings.python)) { throw 'local.settings.json does not contain a Python executable path.' }
if ([string]::IsNullOrWhiteSpace([string]$settings.fridaSitePackages)) { throw 'local.settings.json does not contain the Frida package path.' }

function Get-StartedUtc {
    param([System.Diagnostics.Process]$Process, [string]$Name)
    if ($null -eq $Process) { throw ("{0} failed to return a process object." -f $Name) }
    try {
        $Process.Refresh()
        if ($Process.HasExited) {
            $exitCode = '?'
            try { $exitCode = $Process.ExitCode } catch { }
            throw ("process exited immediately (exit code {0})" -f $exitCode)
        }
        $started = $Process.StartTime
        if ($null -ne $started) { return $started.ToUniversalTime().ToString('o') }
    } catch {
        $stillAlive = Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
        if (-not $stillAlive) {
            throw ("{0} exited during startup (PID {1}): {2}" -f $Name,$Process.Id,$_.Exception.Message)
        }
    }
    Write-Host ("{0}: StartTime unavailable for PID {1}; tracking by PID and launcher health checks instead." -f $Name,$Process.Id) -ForegroundColor DarkYellow
    return $null
}

$hostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
if (-not (Select-String -LiteralPath $hostsPath -SimpleMatch '127.0.0.1 gosredirector.ea.com' -Quiet)) {
    throw 'Local DNS redirect is missing. Run .\SETUP_FIFA13_HOSTS.ps1 once as Administrator.'
}

if (-not $SkipPreflight) {
    & (Join-Path $root 'TEST_FIFA13_LOCAL.ps1')
}

if (-not $SessionId) { $SessionId = Get-Date -Format 'yyyyMMdd-HHmmss' }
& (Join-Path $root 'tools\restart_bridge.ps1') -SessionId $SessionId

if (-not $NoAutoAttach) {
    $fridaPackages = if ([System.IO.Path]::IsPathRooted([string]$settings.fridaSitePackages)) {
        [string]$settings.fridaSitePackages
    } else {
        Join-Path $root ([string]$settings.fridaSitePackages)
    }
    $previousPythonPath = $env:PYTHONPATH
    $env:PYTHONPATH = if ($previousPythonPath) { "$fridaPackages;$previousPythonPath" } else { $fridaPackages }
    $autoLog = Join-Path $root ("logs\autoattach-$SessionId.out.log")
    $autoErr = Join-Path $root ("logs\autoattach-$SessionId.err.log")
    try {
        # v0.14.1.9: autoattach is now Python, not a nested powershell.exe.
        # Multiple public PCs produced StackOverflowException inside the old
        # PowerShell helper before Frida could attach. Python is already a hard
        # prerequisite and gives us one deterministic runtime for build pairing,
        # DLL verification and tracer launch.
        function Quote-ChildArg([string]$Value) {
            return '"' + $Value.Replace('"','\"') + '"'
        }
        $autoScriptArg = Quote-ChildArg (Join-Path $root 'tools\autoattach.py')
        $autoRootArg = Quote-ChildArg $root
        $autoLogDirArg = Quote-ChildArg (Join-Path $root 'logs')
        $autoRuntimeArg = Quote-ChildArg (Join-Path $root 'runtime\processes.json')
        $auto = Start-Process -FilePath ([string]$settings.python) -ArgumentList @(
            $autoScriptArg,
            '--root', $autoRootArg,
            '--log-directory', $autoLogDirArg,
            '--runtime-path', $autoRuntimeArg,
            '--session-id', $SessionId,
            '--timeout', '600') `
            -RedirectStandardOutput $autoLog -RedirectStandardError $autoErr `
            -WindowStyle Hidden -PassThru
    }
    finally { $env:PYTHONPATH = $previousPythonPath }

    $runtimePath = Join-Path $root 'runtime\processes.json'
    if (-not (Test-Path -LiteralPath $runtimePath)) { throw "Service runtime manifest was not created: $runtimePath" }
    $runtime = Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json
    if ($null -eq $runtime) { throw "Service runtime manifest parsed as null: $runtimePath" }
    $autoStartedUtc = Get-StartedUtc -Process $auto -Name 'autoattach helper'
    $entries = @($runtime.processes) + [pscustomobject]@{
        name = 'autoattach'
        pid = $auto.Id
        startedUtc = $autoStartedUtc
    }
    @{ startedUtc = $runtime.startedUtc; processes = $entries } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $runtimePath -Encoding UTF8
}
Write-Host ''
Write-Host 'FIFA 13 local services are ready.' -ForegroundColor Green
Write-Host "Launch FIFA 13 normally from this installation: $($settings.gameDirectory)\fifa13.exe"
Write-Host 'The helper will attach only after the local Blaze login reaches the main-menu stage.'
Write-Host ("Reverse-engineering trace session: {0}" -f $SessionId) -ForegroundColor Cyan
Write-Host 'Use .\STOP_FIFA13_LOCAL.ps1 when finished.'

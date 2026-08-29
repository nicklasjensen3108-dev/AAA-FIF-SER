[CmdletBinding()]
param(
    [int]$StartupTimeoutSeconds = 15,
    [int]$ClientTimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bridgeDirectory = Join-Path $root 'src\bridge'
$bridgeExe = Join-Path $bridgeDirectory 'out\Fut13Local.Bridge.exe'
$certificate = Join-Path $bridgeDirectory 'secrets\gosredirector.ea.com.pfx'

if (-not (Test-Path -LiteralPath $bridgeExe)) {
    throw "Bridge executable is missing: $bridgeExe"
}
if (-not (Test-Path -LiteralPath $certificate)) {
    throw "ProtoSSL certificate is missing: $certificate"
}

function Test-LocalPort {
    param([int]$Port)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        return $task.Wait(250) -and $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Invoke-BridgeClient {
    param([string]$Argument)

    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $bridgeExe
    $info.WorkingDirectory = $bridgeDirectory
    $info.Arguments = $Argument
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true

    $client = [System.Diagnostics.Process]::Start($info)
    if (-not $client.WaitForExit($ClientTimeoutSeconds * 1000)) {
        $client.Kill()
        $client.WaitForExit()
        throw "$Argument timed out after $ClientTimeoutSeconds seconds."
    }

    $stdout = $client.StandardOutput.ReadToEnd().Trim()
    $stderr = $client.StandardError.ReadToEnd().Trim()
    if ($stdout) { Write-Host $stdout }
    if ($stderr) { Write-Warning $stderr }
    if ($client.ExitCode -ne 0) {
        throw "$Argument failed with exit code $($client.ExitCode)."
    }
}

$serverInfo = [System.Diagnostics.ProcessStartInfo]::new()
$serverInfo.FileName = $bridgeExe
$serverInfo.WorkingDirectory = $bridgeDirectory
$serverInfo.UseShellExecute = $false
$serverInfo.CreateNoWindow = $true
# Do not leave redirected pipes unread. PreAuth logging is large enough to fill
# a Windows anonymous pipe, which blocks the server before it can send its
# response and makes a healthy bridge look like a protocol timeout.
$serverInfo.RedirectStandardOutput = $false
$serverInfo.RedirectStandardError = $false

$previousLogLevel = $env:FUT13_LOG_LEVEL
$env:FUT13_LOG_LEVEL = 'Info'
$server = [System.Diagnostics.Process]::Start($serverInfo)
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    do {
        if ($server.HasExited) {
            throw "Bridge exited during startup with code $($server.ExitCode)."
        }
        $redirectorReady = Test-LocalPort 44125
        $gameReady = Test-LocalPort 10092
        if ($redirectorReady -and $gameReady) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)

    if (-not ($redirectorReady -and $gameReady)) {
        throw 'Bridge did not open both loopback ports before the startup timeout.'
    }

    Write-Host "Bridge ready on 127.0.0.1:44125 and 127.0.0.1:10092 (PID $($server.Id))."
    Invoke-BridgeClient '--self-test'
    Invoke-BridgeClient '--self-test-game'
    Write-Host 'OFFLINE BRIDGE TESTS PASSED'
}
finally {
    if (-not $server.HasExited) {
        $server.Kill()
        $server.WaitForExit()
    }
    $env:FUT13_LOG_LEVEL = $previousLogLevel
}

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$runtimePath = Join-Path $PSScriptRoot 'runtime\processes.json'
if (-not (Test-Path -LiteralPath $runtimePath)) {
    Write-Host 'No FIFA 13 local runtime manifest exists.'
    return
}

$runtime = Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json
$rootIdentity = $PSScriptRoot.ToLowerInvariant()
foreach ($entry in @($runtime.processes)) {
    $process = Get-Process -Id ([int]$entry.pid) -ErrorAction SilentlyContinue
    if (-not $process) { continue }

    $safeToStop = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$entry.startedUtc)) {
        try {
            $actualStartedUtc = $process.StartTime.ToUniversalTime().ToString('o')
            $safeToStop = ($actualStartedUtc -eq [string]$entry.startedUtc)
        } catch {
            $safeToStop = $false
        }
    }

    # If Windows never exposed StartTime when the service was launched, verify
    # that this PID's executable/command line still belongs to this checkout.
    if (-not $safeToStop -and [string]::IsNullOrWhiteSpace([string]$entry.startedUtc)) {
        $procInfo = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $process.Id) -ErrorAction SilentlyContinue
        $commandLine = if ($procInfo) { [string]$procInfo.CommandLine } else { '' }
        $exePath = try { [string]$process.Path } catch { '' }
        $identity = ($exePath + ' ' + $commandLine).ToLowerInvariant()
        $safeToStop = $identity.Contains($rootIdentity) -or
            ($identity -match 'fut13local\.bridge|fut13local\.traceproxy|fut13-rs4-server|fut13-dime-server|fut13-easw-server|fut13-pow-server|trace_fifa13_futgate')
    }

    if (-not $safeToStop) {
        Write-Warning "PID $($entry.pid) could not be safely matched to this launcher (possibly PID reuse); leaving it untouched."
        continue
    }
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    Write-Host "Stopped $($entry.name) (PID $($entry.pid))."
}
Remove-Item -LiteralPath $runtimePath -Force

[CmdletBinding()]
param(
    [string]$SessionId,
    [string]$SessionStartUtc
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
foreach ($relativeDirectory in @('runtime', 'logs', 'reports', 'artifacts')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $root $relativeDirectory) | Out-Null
}
$settings = Get-Content -LiteralPath (Join-Path $root 'local.settings.json') -Raw | ConvertFrom-Json
$sessionPath = Join-Path $root 'runtime\trace-session.json'
if ((-not $SessionId -or -not $SessionStartUtc) -and (Test-Path -LiteralPath $sessionPath)) {
    $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
    if (-not $SessionId) { $SessionId = [string]$session.sessionId }
    if (-not $SessionStartUtc) { $SessionStartUtc = [string]$session.startedUtc }
}
if (-not $SessionId) { throw 'No trace session id is available.' }
if (-not $settings.python) { throw 'local.settings.json does not contain a Python path.' }
$collector = Join-Path $root 'tools\collect_trace_report.py'
& ([string]$settings.python) $collector --root $root --session $SessionId --start-utc $SessionStartUtc
if ($LASTEXITCODE -ne 0) { throw "Trace collector failed with exit code $LASTEXITCODE." }

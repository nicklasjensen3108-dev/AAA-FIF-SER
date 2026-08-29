[CmdletBinding()]
param([Parameter(Position=0)][string]$Label)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
New-Item -ItemType Directory -Force -Path (Join-Path $root 'runtime'), (Join-Path $root 'logs') | Out-Null
if (-not $Label) { $Label = Read-Host 'Trace marker label (for example club-search, chemistry, store)' }
if (-not $Label) { exit 0 }
$sessionId = 'unknown-session'
$sessionPath = Join-Path $root 'runtime\trace-session.json'
if (Test-Path -LiteralPath $sessionPath) {
    try { $sessionId = [string]((Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json).sessionId) } catch {}
}
$log = Join-Path $root 'logs\trace-markers.log'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
$line = "[{0:yyyy-MM-dd HH:mm:ss.fff}] MARK {1} session={2}" -f (Get-Date), $Label, $sessionId
Add-Content -LiteralPath $log -Value $line
Write-Host $line -ForegroundColor Green

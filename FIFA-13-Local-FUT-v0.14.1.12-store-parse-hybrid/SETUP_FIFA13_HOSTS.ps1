[CmdletBinding()]
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this one-time setup from an Administrator PowerShell window.'
}

$hostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
$begin = '# FIFA13 FUT LOCAL BEGIN'
$end = '# FIFA13 FUT LOCAL END'
$lines = [System.Collections.Generic.List[string]]::new()
$inside = $false
foreach ($line in [System.IO.File]::ReadAllLines($hostsPath)) {
    if ($line.Trim() -eq $begin) { $inside = $true; continue }
    if ($line.Trim() -eq $end) { $inside = $false; continue }
    if (-not $inside) { $lines.Add($line) }
}

if (-not $Remove) {
    $backupDir = Join-Path $PSScriptRoot 'backups'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $backup = Join-Path $backupDir ("hosts-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $hostsPath -Destination $backup
    $lines.Add($begin)
    # CardsDLL hard-codes the content host; POW_CONTENT_SERVER_URL does not
    # redirect that separate content client. Do not redirect gosca.ea.com here:
    # this portable stack does not yet run the donor's dedicated SSLv3 gosca
    # responder, so adding that host would turn an unrelated optional lookup
    # into a guaranteed local connection failure.
    $lines.Add('127.0.0.1 gosredirector.ea.com')
    $lines.Add('127.0.0.1 content.lt.easfc.ea.com')
    $lines.Add($end)
    Write-Host "Hosts backup: $backup"
}

[System.IO.File]::WriteAllLines($hostsPath, $lines, [System.Text.UTF8Encoding]::new($false))
Clear-DnsClientCache
Write-Host $(if ($Remove) { 'Removed FIFA 13 local redirect.' } else { 'Enabled FIFA 13 local redirect.' })

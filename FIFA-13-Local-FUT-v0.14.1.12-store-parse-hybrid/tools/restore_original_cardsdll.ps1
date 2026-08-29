[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
function Test-Administrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if(-not (Test-Administrator)){
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"')|Out-Null
    exit 0
}
if(Get-Process fifa13 -ErrorAction SilentlyContinue){throw 'Close FIFA 13 before restoring the backed-up DLL.'}
$stop=Join-Path $root 'STOP_FIFA13_LOCAL.ps1';if(Test-Path -LiteralPath $stop){& $stop}
$game='C:\Program Files\EA Games\FIFA 13\Game'
try{$settings=Get-Content -LiteralPath (Join-Path $root 'local.settings.json') -Raw|ConvertFrom-Json;if($settings.gameDirectory){$game=[string]$settings.gameDirectory}}catch{}
$target=Join-Path $game 'dlc\dlc_CardsDLL\dlc\CardsDLLzf.dll'
$backupDir=Join-Path $root 'backups\game-files'
$backup=Get-ChildItem -LiteralPath $backupDir -Filter 'CardsDLLzf.*.dll' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
if(-not $backup){throw "No CardsDLL backup was found under $backupDir. The launcher only creates one when it performs a swap."}
Copy-Item -LiteralPath $backup.FullName -Destination $target -Force
$hash=(Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash
Write-Host ('Restored: {0}' -f $backup.FullName) -ForegroundColor Green
Write-Host ('To:       {0}' -f $target)
Write-Host ('SHA-256:  {0}' -f $hash)

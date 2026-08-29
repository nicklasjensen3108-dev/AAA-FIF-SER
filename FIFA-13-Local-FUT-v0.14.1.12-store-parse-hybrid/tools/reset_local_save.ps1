[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if (Get-Process fifa13 -ErrorAction SilentlyContinue) { throw 'Close FIFA 13 before resetting the local save.' }
$stop=Join-Path $root 'STOP_FIFA13_LOCAL.ps1'
if (Test-Path -LiteralPath $stop) { & $stop }
$python=$null
$cache=Join-Path $root '.runtime_python_path.txt'
if(Test-Path -LiteralPath $cache){$python=(Get-Content -LiteralPath $cache|Select-Object -First 1)}
if(-not $python){
    try{$settings=Get-Content -LiteralPath (Join-Path $root 'local.settings.json') -Raw|ConvertFrom-Json;if($settings.python){$python=[string]$settings.python}}catch{}
}
if(-not $python -or -not (Test-Path -LiteralPath $python)){
    $cmd=Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
    if(-not $cmd){$cmd=Get-Command python -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1}
    if($cmd){$python=$cmd.Source}
}
if(-not $python){throw 'Python could not be resolved. Run INSTALL_PREREQUISITES.cmd first.'}
$db=Join-Path $root 'save\fut13-local.sqlite3'
& $python (Join-Path $root 'tools\fut13_save.py') --db $db reset
if($LASTEXITCODE -ne 0){throw 'Resetting the local SQLite save failed.'}
$preview=& $python (Join-Path $root 'tools\fut13_save.py') --db $db load
if($LASTEXITCODE -ne 0){throw 'The new save could not be verified.'}
Write-Host ''
Write-Host 'Fresh local FUT save created.' -ForegroundColor Green
Write-Host ('Database: {0}' -f $db)
Write-Host 'Club inventory: empty' -ForegroundColor Green
Write-Host 'Starting coins: 100,000,000' -ForegroundColor Green

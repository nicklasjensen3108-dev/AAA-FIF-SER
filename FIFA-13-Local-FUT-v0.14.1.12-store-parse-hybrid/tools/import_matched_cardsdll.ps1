param([string]$Source)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$hash129='35BDAC6BB2F37F4E3F674C5BB979BCB607FEB11CD09105631796D566590FFC06'
$hash121='7D8A7EEAAAFEDF41EA407D497042C79E168D391D6AF5A2F692F870372284E089'
if(-not $Source){$Source=Read-Host 'Enter the full path to a legally obtained supported CardsDLLzf.dll (CL1298564 or CL1217703)'}
$Source=$Source.Trim('"')
if(-not(Test-Path -LiteralPath $Source)){throw "File not found: $Source"}
$hash=(Get-FileHash -Algorithm SHA256 -LiteralPath $Source).Hash
if($hash -eq $hash129){$build='1298564'}elseif($hash -eq $hash121){$build='1217703'}else{throw "Unsupported CardsDLL hash: $hash. Nothing was copied."}
$required=Join-Path $root 'required'; New-Item -ItemType Directory -Force -Path $required|Out-Null
$dest=Join-Path $required ("CardsDLLzf.cl{0}.dll" -f $build)
Copy-Item -LiteralPath $Source -Destination $dest -Force
$verify=(Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash
if($verify -ne $hash){throw 'Imported copy failed SHA-256 verification.'}
Write-Host ("Imported CL{0} CardsDLL to: {1}" -f $build,$dest) -ForegroundColor Green
Write-Host 'RUN_LOCAL_FUT13.cmd will choose it only when the running FIFA build matches.' -ForegroundColor Cyan

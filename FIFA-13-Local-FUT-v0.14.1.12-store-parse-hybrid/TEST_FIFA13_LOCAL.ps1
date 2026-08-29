[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$settingsPath = Join-Path $root 'local.settings.json'
if (-not (Test-Path -LiteralPath $settingsPath)) { throw "Missing $settingsPath" }
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json

$gameExe = Join-Path $settings.gameDirectory 'fifa13.exe'
$cardsDll = Join-Path $settings.gameDirectory 'dlc\dlc_CardsDLL\dlc\CardsDLLzf.dll'
foreach ($path in @($gameExe, $cardsDll, $settings.python)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required file is missing: $path" }
}

$dllHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $cardsDll).Hash
$supportedCards = @('35BDAC6BB2F37F4E3F674C5BB979BCB607FEB11CD09105631796D566590FFC06','7D8A7EEAAAFEDF41EA407D497042C79E168D391D6AF5A2F692F870372284E089')
if ($supportedCards -contains $dllHash) {
    Write-Host 'PASS fifa13.exe present + installed CardsDLL is a measured profile' -ForegroundColor Green
} else {
    Write-Host ("WARN installed CardsDLL is not a measured profile yet: {0}. Runtime pairing may replace it after Blaze login." -f $dllHash) -ForegroundColor Yellow
}

$fridaPackages = if ([System.IO.Path]::IsPathRooted([string]$settings.fridaSitePackages)) {
    [string]$settings.fridaSitePackages
} else {
    Join-Path $root ([string]$settings.fridaSitePackages)
}
if (-not (Test-Path -LiteralPath $fridaPackages)) { throw "Frida package directory is missing: $fridaPackages" }
$previousPythonPath = $env:PYTHONPATH
$env:PYTHONPATH = if ($previousPythonPath) { "$fridaPackages;$previousPythonPath" } else { $fridaPackages }
try {
    $runtimeChecker = Join-Path $root 'tools\check_python_runtime.py'
    $fridaCheck = & $settings.python $runtimeChecker --modules frida --show-frida-version 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("Frida import failed: {0}" -f (($fridaCheck | Out-String).Trim())) }
    $fridaLine = @($fridaCheck | Where-Object { [string]$_ -like 'Frida *' } | Select-Object -First 1)
    Write-Host ("PASS {0}" -f ([string]$fridaLine).Trim()) -ForegroundColor Green
}
finally { $env:PYTHONPATH = $previousPythonPath }


$bridgeDll = Join-Path $root 'src\bridge\out\Fut13Local.Bridge.dll'
if (-not (Test-Path -LiteralPath $bridgeDll)) { throw "Prebuilt Blaze bridge DLL is missing: $bridgeDll" }
$bridgeText = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes($bridgeDll))
if ($bridgeText -notlike '*FUT/STORE_USE_TRANSACTION*') {
    throw 'Prebuilt Blaze bridge is stale: FUT/STORE_USE_TRANSACTION is missing. This would make Store behavior depend on a game-exe hook.'
}
Write-Host 'PASS prebuilt Blaze bridge contains Store transaction config' -ForegroundColor Green

$autoAttachPy = Join-Path $root 'tools\autoattach.py'
if (-not (Test-Path -LiteralPath $autoAttachPy)) { throw "Python autoattach helper is missing: $autoAttachPy" }
& $settings.python -m py_compile $autoAttachPy
if ($LASTEXITCODE -ne 0) { throw 'Python autoattach helper failed to compile.' }
Write-Host 'PASS Python autoattach helper compiles' -ForegroundColor Green

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\test_bridge_offline.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Offline Blaze bridge tests failed.' }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\test_http_offline.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Offline HTTP tests failed.' }

$proxyScript = Join-Path $root 'tools\trace_proxy.py'
if (-not (Test-Path -LiteralPath $proxyScript)) { throw "Python trace proxy is missing: $proxyScript" }
& $settings.python -m py_compile $proxyScript
if ($LASTEXITCODE -ne 0) { throw 'Python trace proxy failed to compile.' }
Write-Host 'PASS Python trace proxy present (no .NET 8 runtime required)' -ForegroundColor Green
Write-Host 'ALL FIFA 13 LOCAL PREFLIGHT TESTS PASSED' -ForegroundColor Green

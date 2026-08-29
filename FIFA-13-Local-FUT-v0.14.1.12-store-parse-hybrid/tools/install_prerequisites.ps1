[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Write-Stage([string]$Text) {
    Write-Host ''
    Write-Host ('=== {0} ===' -f $Text) -ForegroundColor Cyan
}

function Resolve-Python {
    $candidates = New-Object System.Collections.Generic.List[string]
    $cache = Join-Path $root '.runtime_python_path.txt'
    if (Test-Path -LiteralPath $cache) {
        $cached = Get-Content -LiteralPath $cache -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cached) { $candidates.Add(([string]$cached).Trim().Trim('"')) }
    }
    foreach ($name in @('python.exe','python','python3.exe','python3')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source) { $candidates.Add([string]$cmd.Source) }
    }
    foreach ($path in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python310\python.exe')
    )) {
        if ($path) { $candidates.Add($path) }
    }
    foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $version = & $candidate --version 2>&1
        if ($LASTEXITCODE -ne 0) { continue }
        $text = ([string]($version | Select-Object -First 1)).Trim()
        if ($text -match '^Python\s+(\d+)\.(\d+)') {
            if ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 10) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }
    return $null
}

function Resolve-OpenSsl {
    $cmd = Get-Command openssl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) { return [string]$cmd.Source }
    foreach ($candidate in @(
        'C:\Program Files\Git\usr\bin\openssl.exe',
        'C:\Program Files\Git\mingw64\bin\openssl.exe',
        'C:\Program Files (x86)\Git\usr\bin\openssl.exe'
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

Write-Host '============================================================' -ForegroundColor DarkCyan
Write-Host ' FIFA 13 LOCAL FUT - PREREQUISITES' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor DarkCyan
Write-Host 'Installs/checks Python 3.10+, Git/OpenSSL, Python packages, and local certificates.'

Write-Stage 'Python 3.10+'
$python = Resolve-Python
if (-not $python) {
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) {
        throw 'Python 3.10+ was not found and winget is unavailable. Install Python 3.10+ from python.org, then run this again.'
    }
    Write-Host 'Python 3.10+ was not found. Installing Python 3.12 with winget...' -ForegroundColor Yellow
    & $winget.Source install --id Python.Python.3.12 -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw 'winget could not install Python 3.12.' }
    $python = Resolve-Python
    if (-not $python) {
        # A per-user install may not be visible in the current PATH yet.
        $direct = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
        if (Test-Path -LiteralPath $direct) { $python = $direct }
    }
}
if (-not $python) { throw 'Python 3.10+ is installed but could not be resolved. Sign out/in or reopen the terminal and retry.' }
Write-Host ('Python: {0}' -f $python) -ForegroundColor Green
Set-Content -LiteralPath (Join-Path $root '.runtime_python_path.txt') -Value $python -Encoding ASCII

$versionOutput = & $python --version 2>&1
$versionText = ([string]($versionOutput | Select-Object -First 1)).Trim()
if ($versionText -notmatch '^Python\s+(\d+)\.(\d+)') { throw "Could not parse Python version: $versionText" }
$major = [int]$Matches[1]; $minor = [int]$Matches[2]

Write-Stage 'Python packages'
& $python -m pip --version 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    & $python -m ensurepip --upgrade
    if ($LASTEXITCODE -ne 0) { throw 'pip could not be initialized.' }
}
$pyDeps = Join-Path $env:LOCALAPPDATA ("FUT13-Local\pydeps\python-{0}.{1}" -f $major,$minor)
New-Item -ItemType Directory -Force -Path $pyDeps | Out-Null
& $python -m pip install --disable-pip-version-check --upgrade --target $pyDeps -r (Join-Path $root 'tools\requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Installing Frida/capstone/pefile failed.' }
$oldPythonPath = $env:PYTHONPATH
try {
    $env:PYTHONPATH = if ($oldPythonPath) { "$pyDeps;$oldPythonPath" } else { $pyDeps }
    & $python (Join-Path $root 'tools\check_python_runtime.py') --modules frida capstone pefile --show-frida-version
    if ($LASTEXITCODE -ne 0) { throw 'Python package verification failed.' }
} finally {
    $env:PYTHONPATH = $oldPythonPath
}
Write-Host ('Shared package cache: {0}' -f $pyDeps) -ForegroundColor Green

Write-Stage 'Git / OpenSSL'
$openssl = Resolve-OpenSsl
if (-not $openssl) {
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) { throw 'OpenSSL was not found. Install Git for Windows or OpenSSL, then retry.' }
    Write-Host 'OpenSSL was not found. Installing Git for Windows (includes OpenSSL)...' -ForegroundColor Yellow
    & $winget.Source install --id Git.Git -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw 'winget could not install Git for Windows.' }
    $openssl = Resolve-OpenSsl
}
if (-not $openssl) { throw 'Git/OpenSSL installed but openssl.exe could not be resolved. Reopen the terminal and retry.' }
Write-Host ('OpenSSL: {0}' -f $openssl) -ForegroundColor Green
& $openssl version
if ($LASTEXITCODE -ne 0) { throw 'OpenSSL did not run successfully.' }

Write-Stage 'Local ProtoSSL certificate'
$secrets = Join-Path $root 'src\bridge\secrets'
$certFiles = @(
    (Join-Path $secrets 'gosredirector.protossl.der'),
    (Join-Path $secrets 'gosredirector.key'),
    (Join-Path $secrets 'gosredirector.ea.com.pfx')
)
$missing = @($certFiles | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missing.Count -gt 0) {
    & $python (Join-Path $root 'tools\make_certs.py') --out $secrets --openssl $openssl --force
    if ($LASTEXITCODE -ne 0) { throw 'Local ProtoSSL certificate generation failed.' }
}
foreach ($file in $certFiles) {
    if (-not (Test-Path -LiteralPath $file)) { throw "Certificate generation did not create: $file" }
}
Write-Host 'Local certificate material: OK' -ForegroundColor Green

Write-Stage 'Bundled runtime'
$bridge = Join-Path $root 'src\bridge\out\Fut13Local.Bridge.exe'
$proxy = Join-Path $root 'tools\trace_proxy.py'
if (-not (Test-Path -LiteralPath $bridge)) { throw "Bundled bridge runtime is missing: $bridge" }
if (-not (Test-Path -LiteralPath $proxy)) { throw "Python trace proxy is missing: $proxy" }
& $python -m py_compile $proxy
if ($LASTEXITCODE -ne 0) { throw 'Python trace proxy failed to compile.' }
Write-Host 'Self-contained Blaze bridge + Python trace proxy: OK (no .NET runtime/SDK required for normal use).' -ForegroundColor Green

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host ' PREREQUISITES READY' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Write-Host 'Next: run RUN_LOCAL_FUT13.cmd.' -ForegroundColor White

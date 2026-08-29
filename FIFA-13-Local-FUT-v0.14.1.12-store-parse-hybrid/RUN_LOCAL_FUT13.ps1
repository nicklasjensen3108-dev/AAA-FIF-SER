[CmdletBinding()]
param(
    [string]$PythonPath
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# Fresh ZIP extractions do not preserve empty directories reliably. Create every
# mutable runtime folder before any script attempts to write a session, log,
# report, artifact or backup file.
foreach ($relativeDirectory in @('runtime', 'logs', 'reports', 'artifacts', 'backups')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $root $relativeDirectory) | Out-Null
}
$cardsHash1298564 = '35BDAC6BB2F37F4E3F674C5BB979BCB607FEB11CD09105631796D566590FFC06'
$cardsHash1217703 = '7D8A7EEAAAFEDF41EA407D497042C79E168D391D6AF5A2F692F870372284E089'
$defaultGameDirectory = 'C:\Program Files\EA Games\FIFA 13\Game'

function Write-Stage([string]$Text) {
    Write-Host ''
    Write-Host ('=== {0} ===' -f $Text) -ForegroundColor Cyan
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$pythonCachePath = Join-Path $root '.runtime_python_path.txt'

function Get-ResolvedPythonPath {
    param([string]$PreferredPath)

    # RUN_LOCAL_FUT13.cmd resolves sys.executable BEFORE UAC. Once we have that
    # concrete path, do not run a second Python "detection" probe just to decide
    # whether Python exists. That redundant probe caused valid per-user installs
    # to be rejected from an elevated PowerShell process.
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($PreferredPath) { $candidates.Add($PreferredPath) }

    if (Test-Path -LiteralPath $pythonCachePath) {
        $cached = Get-Content -LiteralPath $pythonCachePath -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cached) { $candidates.Add([string]$cached) }
    }

    # Straight filesystem/PATH fallbacks. These only resolve a path; they do not
    # execute Python. The real execution check happens later and reports the real
    # error if Windows genuinely cannot run the interpreter.
    foreach ($name in @('python.exe', 'python', 'python3.exe', 'python3')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source) { $candidates.Add([string]$cmd.Source) }
    }

    foreach ($candidateRaw in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        $candidate = ([string]$candidateRaw).Trim().Trim('"')
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw @'
Python executable path was not found.
RUN_LOCAL_FUT13.cmd should cache the exact sys.executable path before UAC. If this appears, run the CMD normally (not the PS1 directly) and check .runtime_python_path.txt.
'@
}

try {
    # Resolve Python BEFORE UAC.  A newly installed per-user Python can be
    # visible here while an elevated process still has an older/stale PATH.
    if (-not (Test-Administrator)) {
        Write-Host 'Detecting Python before requesting Administrator permission...' -ForegroundColor DarkGray
        $preElevationPython = Get-ResolvedPythonPath -PreferredPath $PythonPath
        Set-Content -LiteralPath $pythonCachePath -Value $preElevationPython -Encoding ASCII
        Write-Host ('Python path cached: {0}' -f $preElevationPython) -ForegroundColor Green
        Write-Host 'Administrator permission is required for the hosts redirect, port 80 and Frida attach.' -ForegroundColor Yellow
        Write-Host 'Requesting elevation...' -ForegroundColor Yellow
        # $PSCommandPath is normally populated for -File launches, but some shell/
        # shortcut wrappers can leave it null. Never call a method on it blindly.
        $scriptPathForElevation = [string]$PSCommandPath
        if ([string]::IsNullOrWhiteSpace($scriptPathForElevation)) {
            $scriptPathForElevation = Join-Path $PSScriptRoot 'RUN_LOCAL_FUT13.ps1'
        }
        if (-not (Test-Path -LiteralPath $scriptPathForElevation -PathType Leaf)) {
            throw "Could not resolve the launcher script path for Administrator relaunch: $scriptPathForElevation"
        }
        $preElevationPython = [string]$preElevationPython
        if ([string]::IsNullOrWhiteSpace($preElevationPython)) {
            throw 'Python was resolved before UAC but the resolved path was unexpectedly empty.'
        }
        $escapedScript = $scriptPathForElevation.Replace('"','\"')
        $escapedPython = $preElevationPython.Replace('"','\"')
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$escapedScript`" -PythonPath `"$escapedPython`""
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments | Out-Null
        exit 0
    }

    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ' FIFA 13 LOCAL FUT - WORKING CARDS DLL LAUNCHER' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ('Package: {0}' -f $root)

    if (Get-Process fifa13 -ErrorAction SilentlyContinue) {
        throw 'FIFA 13 is already running. Close the game completely, then run this launcher again.'
    }

    Write-Stage 'FIFA 13 installation'
    $gameDirectory = $defaultGameDirectory
    if (-not (Test-Path -LiteralPath (Join-Path $gameDirectory 'fifa13.exe'))) {
        $fallbacks = @(
            'C:\Program Files (x86)\Origin Games\FIFA 13\Game',
            'C:\Program Files\Origin Games\FIFA 13\Game'
        )
        foreach ($candidate in $fallbacks) {
            if (Test-Path -LiteralPath (Join-Path $candidate 'fifa13.exe')) {
                $gameDirectory = $candidate
                break
            }
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $gameDirectory 'fifa13.exe'))) {
        $manual = Read-Host 'FIFA 13 was not found automatically. Enter the full Game directory'
        if ($manual) { $gameDirectory = $manual.Trim('"') }
    }

    $gameExe = Join-Path $gameDirectory 'fifa13.exe'
    if (-not (Test-Path -LiteralPath $gameExe)) {
        throw "fifa13.exe was not found in: $gameDirectory"
    }
    Write-Host ('Game directory: {0}' -f $gameDirectory) -ForegroundColor Green
    Write-Host 'fifa13.exe found. No executable SHA-256 allow-list is enforced by this release.' -ForegroundColor Green

    $cardsPath = Join-Path $gameDirectory 'dlc\dlc_CardsDLL\dlc\CardsDLLzf.dll'
    if (-not (Test-Path -LiteralPath $cardsPath -PathType Leaf)) { throw "Installed CardsDLL was not found: $cardsPath" }

    Write-Stage 'CardsDLL compatibility staging'
    if (-not (Test-Path -LiteralPath $cardsPath)) { throw "Installed CardsDLL was not found: $cardsPath" }

    # Do NOT force one CardsDLL before FIFA starts. Two retail PC revisions are
    # now supported and Windows file-version metadata is not trustworthy on all
    # repacks. The real runtime build is read from FIFA's Blaze redirect request
    # at the main menu, before CardsDLL is loaded. tools\autoattach.py then pairs:
    #   1298564 -> 35BD...FFC06
    #   1217703 -> 7D8A...E089
    # and may restore/import the matching DLL while FIFA is still at the menu.
    $supportedCards = @{
        '1298564' = $cardsHash1298564
        '1217703' = $cardsHash1217703
    }
    $installedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $cardsPath).Hash
    Write-Host ('Installed CardsDLL SHA-256: {0}' -f $installedHash)
    if ($installedHash -eq $cardsHash1298564) {
        Write-Host 'Detected CL1298564 CardsDLL. Runtime pairing will be verified after Blaze login.' -ForegroundColor Green
    } elseif ($installedHash -eq $cardsHash1217703) {
        Write-Host 'Detected CL1217703 CardsDLL. Runtime pairing will be verified after Blaze login.' -ForegroundColor Green
    } else {
        Write-Host 'Installed CardsDLL is not one of the two measured profiles.' -ForegroundColor Yellow
        Write-Host 'The runtime matcher will look for a compatible imported/backup DLL after FIFA reveals its build.' -ForegroundColor Yellow
    }

    # Validate any optional user-supplied payloads now, but never copy one until
    # the running game has identified itself. The public repo contains none.
    $requiredDir = Join-Path $root 'required'
    foreach ($candidateName in @('CardsDLLzf.dll','CardsDLLzf.cl1298564.dll','CardsDLLzf.cl1217703.dll')) {
        $candidate = Join-Path $requiredDir $candidateName
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $candidateHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $candidate).Hash
        if ($candidateHash -ne $cardsHash1298564 -and $candidateHash -ne $cardsHash1217703) {
            throw ("{0} is present but is not a supported CardsDLL. SHA-256: {1}" -f $candidate,$candidateHash)
        }
        Write-Host ("Validated optional CardsDLL payload: {0}" -f $candidateName) -ForegroundColor DarkGreen
    }

    Write-Stage 'Python / Frida runtime'
    $pythonExe = Get-ResolvedPythonPath -PreferredPath $PythonPath
    Set-Content -LiteralPath $pythonCachePath -Value $pythonExe -Encoding ASCII
    Write-Host ('Using cached Python: {0}' -f $pythonExe) -ForegroundColor Green

    # Execute the resolved interpreter without inline `python -c` code. Windows
    # PowerShell 5.1 can mangle nested quote characters when serializing native
    # arguments, which previously turned a valid version probe into SyntaxError.
    $pythonVersionOutput = & $pythonExe --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("Python exists at '{0}' but Windows could not execute it. Output: {1}" -f $pythonExe, (($pythonVersionOutput | Out-String).Trim()))
    }
    $pythonVersionText = ([string]($pythonVersionOutput | Select-Object -First 1)).Trim()
    if ($pythonVersionText -notmatch '^Python\s+(\d+)\.(\d+)(?:\.(\d+))?') {
        throw ("Could not parse Python version output from '{0}': {1}" -f $pythonExe, $pythonVersionText)
    }
    $pythonMajor = [int]$Matches[1]
    $pythonMinor = [int]$Matches[2]
    if ($pythonMajor -ne 3 -or $pythonMinor -lt 10) {
        throw ("Python 3.10+ is required. '{0}' reports {1}." -f $pythonExe, $pythonVersionText)
    }
    Write-Host ('Python version: {0}' -f $pythonVersionText) -ForegroundColor Green

    # Keep the heavy Frida/capstone wheels in one shared per-user cache instead
    # of copying 100+ MB into every test build. Key it by Python major/minor so a
    # later interpreter upgrade cannot accidentally import an incompatible pyd.
    $pyDeps = Join-Path $env:LOCALAPPDATA ("FUT13-Local\pydeps\python-{0}.{1}" -f $pythonMajor, $pythonMinor)
    New-Item -ItemType Directory -Force -Path $pyDeps | Out-Null

    $previousPythonPath = $env:PYTHONPATH
    $env:PYTHONPATH = if ($previousPythonPath) { "$pyDeps;$previousPythonPath" } else { $pyDeps }
    $runtimeChecker = Join-Path $root 'tools\check_python_runtime.py'
    if (-not (Test-Path -LiteralPath $runtimeChecker)) { throw "Missing Python runtime checker: $runtimeChecker" }
    try {
        & $pythonExe $runtimeChecker --modules frida capstone pefile --show-frida-version 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host ('Installing shared FUT13 Python packages (one-time cache: {0})...' -f $pyDeps) -ForegroundColor Yellow
            & $pythonExe -m pip --version 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                & $pythonExe -m ensurepip --upgrade
                if ($LASTEXITCODE -ne 0) { throw 'Python pip could not be initialized.' }
            }
            & $pythonExe -m pip install --disable-pip-version-check --upgrade --target $pyDeps -r (Join-Path $root 'tools\requirements.txt')
            if ($LASTEXITCODE -ne 0) { throw 'Installing Frida/capstone/pefile failed.' }
            & $pythonExe $runtimeChecker --modules frida capstone pefile --show-frida-version
            if ($LASTEXITCODE -ne 0) { throw 'Python dependencies installed but still cannot be imported.' }
        }
        Write-Host 'Python dependencies: Frida / capstone / pefile OK' -ForegroundColor Green
    }
    finally {
        $env:PYTHONPATH = $previousPythonPath
    }

    Write-Stage 'Local redirector certificate'
    $secretsDirectory = Join-Path $root 'src\bridge\secrets'
    $requiredCertificateFiles = @(
        (Join-Path $secretsDirectory 'gosredirector.protossl.der'),
        (Join-Path $secretsDirectory 'gosredirector.key'),
        (Join-Path $secretsDirectory 'gosredirector.ea.com.pfx')
    )
    $missingCertificateFiles = @($requiredCertificateFiles | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missingCertificateFiles.Count -gt 0) {
        $opensslPath = $null
        $opensslCommand = Get-Command openssl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($opensslCommand -and $opensslCommand.Source) { $opensslPath = [string]$opensslCommand.Source }
        if (-not $opensslPath) {
            foreach ($candidate in @(
                'C:\Program Files\Git\usr\bin\openssl.exe',
                'C:\Program Files\Git\mingw64\bin\openssl.exe',
                'C:\Program Files (x86)\Git\usr\bin\openssl.exe'
            )) {
                if (Test-Path -LiteralPath $candidate) { $opensslPath = $candidate; break }
            }
        }
        if (-not $opensslPath) {
            throw 'Local certificate material is missing and OpenSSL was not found. Run INSTALL_PREREQUISITES.cmd first.'
        }
        $makeCerts = Join-Path $root 'tools\make_certs.py'
        if (-not (Test-Path -LiteralPath $makeCerts)) { throw "Certificate generator is missing: $makeCerts" }
        Write-Host 'Generating localhost-only ProtoSSL certificate material...' -ForegroundColor Yellow
        & $pythonExe $makeCerts --out $secretsDirectory --openssl $opensslPath --force
        if ($LASTEXITCODE -ne 0) { throw 'Generating the local ProtoSSL certificate failed.' }
    }
    foreach ($certificateFile in $requiredCertificateFiles) {
        if (-not (Test-Path -LiteralPath $certificateFile)) { throw "Required local certificate file is missing: $certificateFile" }
    }
    Write-Host 'Local redirector certificate: OK' -ForegroundColor Green

    Write-Stage 'Native FIFA 13 FUT card pools'
    $fullClubBuilder = Join-Path $root 'tools\build_fifa13_full_club_catalog.py'
    $fullClubCatalog = Join-Path $root 'data\fifa13-full-player-catalog.json'
    if (Test-Path -LiteralPath $fullClubBuilder) {
        Write-Host 'Reading the native FUT card database from your installed cards0.big...' -ForegroundColor Cyan
        & $pythonExe $fullClubBuilder --game-dir $gameDirectory --out $fullClubCatalog
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $fullClubCatalog)) {
            try {
                $fullClubInfo = Get-Content -LiteralPath $fullClubCatalog -Raw | ConvertFrom-Json
                if ([int]$fullClubInfo.specialCardCount -le 0) { throw 'Special-card import produced zero cards; refusing to start a base-only catalogue.' }
                Write-Host ("Player draw pool ready: {0} base + {1} special = {2} FIFA 13 player cards." -f [int]$fullClubInfo.basePlayerCount,[int]$fullClubInfo.specialCardCount,[int]$fullClubInfo.playerCount) -ForegroundColor Green
                if ($fullClubInfo.specialReport -and $fullClubInfo.specialReport.specialTypes) {
                    $specialTypes = @($fullClubInfo.specialReport.specialTypes.psobject.Properties | ForEach-Object { "{0}={1}" -f $_.Name,$_.Value }) -join ", "
                    Write-Host ("Special treatments: {0}" -f $specialTypes) -ForegroundColor DarkCyan
                }
            } catch {
                throw ("Generated full-club catalogue could not be validated: {0}" -f $_.Exception.Message)
            }
        } else {
            throw 'Could not build the full base+special player catalogue. Refusing to launch a hidden base-only/23-player fallback.'
        }
    }

    $itemBuilder = Join-Path $root 'tools\build_fifa13_item_catalog.py'
    $itemCatalog = Join-Path $root 'data\fifa13-native-item-catalog.json'
    if (-not (Test-Path -LiteralPath $itemBuilder)) { throw "Missing native item-pool builder: $itemBuilder" }
    Write-Host 'Reading consumables, staff, kits, badges, stadiums, balls and managers from cards0.big...' -ForegroundColor Cyan
    & $pythonExe $itemBuilder --game-dir $gameDirectory --out $itemCatalog
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $itemCatalog)) { throw 'Could not build the native non-player FUT item catalogue.' }
    $itemInfo = Get-Content -LiteralPath $itemCatalog -Raw | ConvertFrom-Json
    if ([int]$itemInfo.itemCount -lt 100) { throw ("Native item pool is unexpectedly small: {0}" -f [int]$itemInfo.itemCount) }
    Write-Host ("Native item draw pool ready: {0} consumables/staff/club items." -f [int]$itemInfo.itemCount) -ForegroundColor Green

    Write-Stage 'SQLite local save'
    $savePath = Join-Path $root 'save\fut13-local.sqlite3'
    $saveHelper = Join-Path $root 'tools\fut13_save.py'
    $savePreviewRaw = & $pythonExe $saveHelper --db $savePath load
    if ($LASTEXITCODE -ne 0) { throw 'Could not create/read the SQLite FUT save.' }
    $savePreview = (($savePreviewRaw | Out-String).Trim() | ConvertFrom-Json)
    Write-Host ("Save: {0}" -f $savePath) -ForegroundColor Green
    Write-Host ("Owned club items: {0} | Unassigned: {1} | Coins: {2:N0}" -f @($savePreview.items | Where-Object { $_.pile -eq 'club' }).Count,@($savePreview.items | Where-Object { $_.pile -eq 'unassigned' }).Count,[int64]$savePreview.club.coins) -ForegroundColor Green

    Write-Stage 'Local build configuration'
    $settingsPath = Join-Path $root 'local.settings.json'
    $settingsExamplePath = Join-Path $root 'local.settings.json.example'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        if (-not (Test-Path -LiteralPath $settingsExamplePath)) { throw "Missing settings template: $settingsExamplePath" }
        Copy-Item -LiteralPath $settingsExamplePath -Destination $settingsPath -Force
        Write-Host 'Created local.settings.json for this PC.' -ForegroundColor Green
    }
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    if ($null -eq $settings) { throw "local.settings.json parsed as null: $settingsPath" }
    $settings.gameDirectory = $gameDirectory
    $settings.gameVersion = 'runtime-detected'
    if ($settings.PSObject.Properties.Name -contains 'gameRuntimeVersion') {
        $settings.gameRuntimeVersion = ''
    } else {
        $settings | Add-Member -NotePropertyName gameRuntimeVersion -NotePropertyValue ''
    }
    # TEST_FIFA13_LOCAL.ps1 validates against this setting. Record the exact
    # compatible executable actually present rather than forcing the older hash.
    $settings.cardsDllSha256 = $installedHash
    $settings.python = $pythonExe
    $settings.fridaSitePackages = $pyDeps
    $settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    Write-Host 'local.settings.json updated for this PC.' -ForegroundColor Green

    Write-Stage 'Hosts redirect'
    $hostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
    $requiredHostRedirects = @(
        '127.0.0.1 gosredirector.ea.com',
        '127.0.0.1 content.lt.easfc.ea.com'
    )
    $missingHostRedirects = @($requiredHostRedirects | Where-Object {
        -not (Select-String -LiteralPath $hostsPath -SimpleMatch $_ -Quiet)
    })
    if ($missingHostRedirects.Count -gt 0) {
        Write-Host 'Adding/updating the FIFA 13 localhost redirects (a hosts backup is created first)...' -ForegroundColor Yellow
        & (Join-Path $root 'SETUP_FIFA13_HOSTS.ps1')
        $stillMissing = @($requiredHostRedirects | Where-Object {
            -not (Select-String -LiteralPath $hostsPath -SimpleMatch $_ -Quiet)
        })
        if ($stillMissing.Count -gt 0) { throw ("Hosts setup returned but these redirects are still missing: {0}" -f ($stillMissing -join ', ')) }
    } else {
        Write-Host 'All FIFA 13 localhost redirects are already present.' -ForegroundColor Green
    }

    Write-Stage 'Starting ALWAYS-ON reverse-engineering trace'
    $sessionId = Get-Date -Format 'yyyyMMdd-HHmmss'
    $sessionStartUtc = [DateTime]::UtcNow.ToString('o')
    $runtimeDirectory = Join-Path $root 'runtime'
    $logDirectory = Join-Path $root 'logs'
    New-Item -ItemType Directory -Force -Path $runtimeDirectory, $logDirectory | Out-Null
    $traceSessionPath = Join-Path $runtimeDirectory 'trace-session.json'
    @{ sessionId = $sessionId; startedUtc = $sessionStartUtc } |
        ConvertTo-Json | Set-Content -LiteralPath $traceSessionPath -Encoding UTF8
    Add-Content -LiteralPath (Join-Path $root 'logs\trace-markers.log') `
        -Value ("[{0:yyyy-MM-dd HH:mm:ss.fff}] SESSION_START {1}" -f (Get-Date), $sessionId)
    Write-Host ("Always-on trace session: {0}" -f $sessionId) -ForegroundColor Cyan

    Write-Stage 'Starting original FUT revival stack'
    & (Join-Path $root 'START_FIFA13_LOCAL.ps1') -SkipPreflight -SessionId $sessionId

    # v0.13.16.1: version-flexible RS4 catalogue confirmation. The previous launcher only proved that Python generated the
    # catalogue; the hidden RS4 process then failed to load it and silently used
    # 23 players. Do not print READY until RS4 itself confirms the full pool.
    if (Test-Path -LiteralPath $fullClubCatalog) {
        $rs4Out = Join-Path $root ("logs\rs4-{0}.out.log" -f $sessionId)
        $rs4Deadline = (Get-Date).AddSeconds(8)
        $rs4FullClubLine = $null
        while ((Get-Date) -lt $rs4Deadline) {
            if (Test-Path -LiteralPath $rs4Out) {
                $rs4FullClubLine = Get-Content -LiteralPath $rs4Out -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match 'FULL CLUB v0\.(?:13|14)\.\d+(?:\.\d+)?: loaded \d+ player cards \(base=\d+, special=[1-9]\d*\)' } |
                    Select-Object -Last 1
                if ($rs4FullClubLine) { break }
                $rs4LoadError = Get-Content -LiteralPath $rs4Out -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match 'FULL CLUB LOAD ERROR v0\.(?:13|14)\.\d+(?:\.\d+)?|native catalogue unavailable' } |
                    Select-Object -Last 1
                if ($rs4LoadError) { throw ("RS4 player-pool load failed: {0}" -f $rs4LoadError) }
            }
            Start-Sleep -Milliseconds 250
        }
        if (-not $rs4FullClubLine) {
            throw 'RS4 did not confirm the generated player draw pool. Refusing to launch with an incomplete card pool.'
        }
        Write-Host ("RS4 CONFIRMED: {0}" -f $rs4FullClubLine) -ForegroundColor Green

        $rs4SecondaryDeadline = (Get-Date).AddSeconds(5)
        $rs4ItemLine = $null
        $rs4SaveLine = $null
        while ((Get-Date) -lt $rs4SecondaryDeadline) {
            if (Test-Path -LiteralPath $rs4Out) {
                $lines = Get-Content -LiteralPath $rs4Out -ErrorAction SilentlyContinue
                $rs4ItemLine = $lines | Where-Object { $_ -match 'ITEM POOL v0\.(?:13|14)\.\d+(?:\.\d+)? CONFIRMED: [1-9]\d* usable native' } | Select-Object -Last 1
                $rs4SaveLine = $lines | Where-Object { $_ -match 'SAVE v0\.(?:13|14)\.\d+(?:\.\d+)? CONFIRMED: club=\d+; unassigned=\d+; trade=\d+; coins=\d+;' } | Select-Object -Last 1
                $rs4ItemError = $lines | Where-Object { $_ -match 'ITEM POOL (?:LOAD )?ERROR v0\.(?:13|14)\.\d+(?:\.\d+)?' } | Select-Object -Last 1
                if ($rs4ItemError) { throw ("RS4 native item-pool load failed: {0}" -f $rs4ItemError) }
                if ($rs4ItemLine -and $rs4SaveLine) { break }
            }
            Start-Sleep -Milliseconds 200
        }
        if (-not $rs4ItemLine) { throw 'RS4 did not confirm the native consumable/staff/club item pool.' }
        if (-not $rs4SaveLine) { throw 'RS4 did not confirm the SQLite save state.' }
        Write-Host ("RS4 CONFIRMED: {0}" -f $rs4ItemLine) -ForegroundColor Green
        Write-Host ("RS4 CONFIRMED: {0}" -f $rs4SaveLine) -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host ' LOCAL FUT13 READY' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host 'Now launch FIFA 13 THROUGH THE EA APP. WAIT for the green RE TRACE ALWAYS ON line before entering Ultimate Team.' -ForegroundColor White
    Write-Host 'Do not run fifa13.exe directly.' -ForegroundColor Yellow
    Write-Host 'Leave this window open. v0.14.1.9 detects the running FIFA build at Blaze login and pairs the matching CardsDLL before FUT loads.' -ForegroundColor White
    Write-Host 'TRACE ALWAYS ON: network + CardsDLL events are recorded for the whole session; compatible game builds also include screen events.' -ForegroundColor Cyan
    Write-Host 'When FIFA closes or crashes, the report ZIP is created automatically. No marker commands are needed.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Waiting for FIFA 13 to start...' -ForegroundColor Cyan

    while (-not (Get-Process fifa13 -ErrorAction SilentlyContinue)) {
        Start-Sleep -Seconds 1
    }
    $game = Get-Process fifa13 -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Host ("FIFA 13 detected (PID {0}). Local services will remain active until the game closes." -f $game.Id) -ForegroundColor Green

    # Surface the hidden autoattach state in this console. The trace still runs
    # detached, but the user can now tell whether it actually attached before
    # reproducing a feature bug.
    $autoAttachOut = Join-Path $root ("logs\autoattach-$sessionId.out.log")
    $autoAttachErr = Join-Path $root ("logs\autoattach-$sessionId.err.log")
    # v0.14.1.9: the native helper is part of the FUT compatibility path, not an
    # optional diagnostic. Do not print a one-time 60-second warning and then
    # silently let users enter FUT. Keep watching until it is attached or there
    # is a concrete failure. Slower EA App launches get four minutes after the
    # fifa13.exe process itself appears.
    $attachDeadline = (Get-Date).AddSeconds(240)
    $attachReported = $false
    $sessionStagePrinted = $false
    while ((Get-Date) -lt $attachDeadline -and (Get-Process fifa13 -ErrorAction SilentlyContinue)) {
        if ((Test-Path -LiteralPath $autoAttachOut) -and
            (Select-String -LiteralPath $autoAttachOut -SimpleMatch 'Tracer running, detached' -Quiet -ErrorAction SilentlyContinue)) {
            Write-Host 'RE TRACE ALWAYS ON: FUT compatibility helper + CardsDLL/HTTP trace attached.' -ForegroundColor Green
            $attachReported = $true
            break
        }
        if (-not $sessionStagePrinted -and (Test-Path -LiteralPath $autoAttachOut) -and
            (Select-String -LiteralPath $autoAttachOut -SimpleMatch 'Session established.' -Quiet -ErrorAction SilentlyContinue)) {
            Write-Host 'RE TRACE: Blaze session detected; pairing CardsDLL and attaching native helper...' -ForegroundColor Cyan
            $sessionStagePrinted = $true
        }
        if ((Test-Path -LiteralPath $autoAttachErr) -and (Get-Item -LiteralPath $autoAttachErr).Length -gt 0) {
            $autoAttachErrorText = (Get-Content -LiteralPath $autoAttachErr -Raw -ErrorAction SilentlyContinue).Trim()
            if ([string]::IsNullOrWhiteSpace($autoAttachErrorText)) { $autoAttachErrorText = 'autoattach exited before the tracer could attach.' }
            throw ("FUT compatibility helper failed before FUT entry.`r`n{0}`r`nDO NOT enter Ultimate Team until this is resolved." -f $autoAttachErrorText)
        }
        Start-Sleep -Seconds 1
    }
    if (-not $attachReported -and (Get-Process fifa13 -ErrorAction SilentlyContinue)) {
        $autoAttachTail = ''
        if (Test-Path -LiteralPath $autoAttachOut) {
            $autoAttachTail = ((Get-Content -LiteralPath $autoAttachOut -Tail 20 -ErrorAction SilentlyContinue) -join "`r`n").Trim()
        }
        throw ("RE TRACE did not attach within 240 seconds after FIFA started.`r`n{0}`r`nDO NOT enter Ultimate Team until this is resolved." -f $autoAttachTail)
    }

    while (Get-Process fifa13 -ErrorAction SilentlyContinue) {
        Start-Sleep -Seconds 2
    }

    Write-Stage 'FIFA 13 closed - stopping local services'
    & (Join-Path $root 'STOP_FIFA13_LOCAL.ps1')

    Write-Stage 'Packaging reverse-engineering trace'
    $collector = Join-Path $root 'COLLECT_FUT13_TRACE.ps1'
    if (Test-Path -LiteralPath $collector) {
        & $collector -SessionId $sessionId -SessionStartUtc $sessionStartUtc
    } else {
        Write-Host 'Trace collector missing; raw logs are still in logs/, server/ and artifacts/.' -ForegroundColor Yellow
    }
    Write-Host 'Done. Run RUN_LOCAL_FUT13.cmd again for the next session.' -ForegroundColor Green
    exit 0
}
catch {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host ' LOCAL FUT13 LAUNCH FAILED' -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    $failureScript = [string]$_.InvocationInfo.ScriptName
    $failureLine = [int]$_.InvocationInfo.ScriptLineNumber
    if (-not [string]::IsNullOrWhiteSpace($failureScript)) {
        Write-Host ("Script: {0}" -f $failureScript) -ForegroundColor DarkYellow
    }
    if ($failureLine -gt 0) {
        Write-Host ("Line:   {0}" -f $failureLine) -ForegroundColor DarkYellow
    }
    if ($_.ScriptStackTrace) {
        Write-Host 'PowerShell stack:' -ForegroundColor DarkGray
        Write-Host ([string]$_.ScriptStackTrace) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host 'Nothing will be guessed. Fix the item above and run RUN_LOCAL_FUT13.cmd again.' -ForegroundColor Yellow
    Read-Host 'Press ENTER to close'
    exit 1
}

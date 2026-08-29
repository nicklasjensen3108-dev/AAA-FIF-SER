[CmdletBinding()]
param(
    [string]$RemoteUrl,
    [string]$CommitMessage = 'FIFA 13 Local FUT v0.14.1'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root

$git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $git) { $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
if (-not $git) { throw 'Git was not found. Install Git for Windows, then run PUBLISH_TO_GITHUB.cmd again.' }

# Public-release guardrails are checked against Git's STAGED set below.
# Generated local files are allowed to exist after testing; .gitignore must keep
# them out of the public commit.

if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
    & $git.Source init -b main
    if ($LASTEXITCODE -ne 0) { throw 'git init failed.' }
}

& $git.Source add --all
if ($LASTEXITCODE -ne 0) { throw 'git add failed.' }

$forbidden = @(
    'required/CardsDLLzf.dll',
    'local.settings.json',
    'save/fut13-local.sqlite3',
    'data/fifa13-full-player-catalog.json',
    'data/fifa13-native-item-catalog.json',
    'src/bridge/secrets/gosredirector.key',
    'src/bridge/secrets/gosredirector.ea.com.pfx',
    'src/bridge/secrets/gosredirector.protossl.der'
)
$staged = @(& $git.Source diff --cached --name-only)
foreach ($relative in $forbidden) {
    if ($staged -contains $relative) { throw "Public publish blocked: proprietary/generated file is staged: $relative" }
}

Write-Host ''
Write-Host 'Files staged for the public repository:' -ForegroundColor Cyan
& $git.Source status --short
if ($LASTEXITCODE -ne 0) { throw 'git status failed.' }

Write-Host ''
$answer = Read-Host 'Commit exactly the staged files above? Type YES to continue'
if ($answer -cne 'YES') {
    Write-Host 'Cancelled. Nothing was committed or pushed.' -ForegroundColor Yellow
    exit 0
}

& $git.Source diff --cached --quiet
$hasChanges = ($LASTEXITCODE -ne 0)
if ($hasChanges) {
    & $git.Source commit -m $CommitMessage
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed. Configure your Git name/email if Git asks you to.' }
} else {
    Write-Host 'No new staged changes to commit.' -ForegroundColor Yellow
}

if (-not $RemoteUrl) {
    $RemoteUrl = Read-Host 'Paste the GitHub repository URL to push now, or press ENTER to stop after the local commit'
}
if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
    Write-Host 'Local repository is ready. No remote push was attempted.' -ForegroundColor Green
    exit 0
}

$existing = (& $git.Source remote get-url origin 2>$null)
if ($LASTEXITCODE -eq 0 -and $existing) {
    & $git.Source remote set-url origin $RemoteUrl
} else {
    & $git.Source remote add origin $RemoteUrl
}
if ($LASTEXITCODE -ne 0) { throw 'Could not configure the origin remote.' }

& $git.Source branch -M main
if ($LASTEXITCODE -ne 0) { throw 'Could not set the main branch.' }
& $git.Source push -u origin main
if ($LASTEXITCODE -ne 0) { throw 'git push failed. Check GitHub authentication and repository permissions.' }
Write-Host 'Published to GitHub.' -ForegroundColor Green

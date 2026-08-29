# One-time PostgreSQL setup for the FUT 13 local backend.
#
# Run this yourself in an interactive PowerShell window: psql prompts for the
# postgres password you chose at install time, you type it, and it never passes
# through this project -- no password in the repository, in an environment
# variable, or in a log.
#
#   powershell -ExecutionPolicy Bypass -File server\setup-postgres.ps1
#
# It creates the fut13 database, applies server\schema\fut13-schema.sql, and then
# offers to write libpq's password file (%APPDATA%\postgresql\pgpass.conf) so the
# RS4 server can connect unattended. That file is libpq's standard mechanism and
# lives in your Windows profile, outside this project.

param(
    [string] $Database = 'fut13',
    [string] $DbUser   = 'postgres',
    [string] $DbHost   = '127.0.0.1',
    [int]    $DbPort   = 5432
)

$ErrorActionPreference = 'Stop'

# The Windows installer does not put psql on the PATH of already-running shells,
# so look in the standard install location too rather than declaring PostgreSQL
# absent when it is merely unlisted.
function Resolve-Psql {
    $onPath = Get-Command psql -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $candidates = Get-ChildItem 'C:\Program Files\PostgreSQL' -Directory -ErrorAction SilentlyContinue |
                  Sort-Object Name -Descending
    foreach ($dir in $candidates) {
        $exe = Join-Path $dir.FullName 'bin\psql.exe'
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

$psql = Resolve-Psql
if (-not $psql) { throw "psql not found. Is PostgreSQL installed?" }
Write-Host "psql: $psql" -ForegroundColor Cyan

$schema = Join-Path $PSScriptRoot 'schema\fut13-schema.sql'
if (-not (Test-Path $schema)) { throw "Schema not found: $schema" }

# CREATE DATABASE cannot run inside a transaction, and re-running this script must
# be harmless, so the "already exists" case is checked rather than caught.
Write-Host "`npsql will ask for the postgres password (this script never reads it)." -ForegroundColor Yellow
$exists = & $psql -U $DbUser -h $DbHost -p $DbPort -d postgres -t -A `
                  -c "SELECT 1 FROM pg_database WHERE datname = '$Database'"
if ($LASTEXITCODE -ne 0) { throw "Connection refused. Wrong password, or is the service down?" }

if ($exists -match '1') {
    Write-Host "Database '$Database' already present." -ForegroundColor Green
} else {
    & $psql -U $DbUser -h $DbHost -p $DbPort -d postgres -c "CREATE DATABASE $Database"
    if ($LASTEXITCODE -ne 0) { throw "Database creation failed." }
    Write-Host "Database '$Database' created." -ForegroundColor Green
}

& $psql -U $DbUser -h $DbHost -p $DbPort -d $Database -v ON_ERROR_STOP=1 -f $schema
if ($LASTEXITCODE -ne 0) { throw "Applying the schema failed." }
Write-Host "Schema applied." -ForegroundColor Green

$counts = & $psql -U $DbUser -h $DbHost -p $DbPort -d $Database -t -A -c @"
SELECT 'persona=' || (SELECT count(*) FROM persona)
    || ' squad=' || (SELECT count(*) FROM squad)
    || ' slots=' || (SELECT count(*) FROM squad_player)
"@
Write-Host "Contents: $counts" -ForegroundColor Green

# pgpass.conf lets the unattended server authenticate without the password ever
# being stored in the project. Format: host:port:database:user:password
$pgpassDir = Join-Path $env:APPDATA 'postgresql'
$pgpass = Join-Path $pgpassDir 'pgpass.conf'
if (Test-Path $pgpass) {
    Write-Host "`npgpass.conf already exists: $pgpass" -ForegroundColor Green
} else {
    Write-Host "`nThe RS4 server runs with no console attached and cannot answer a prompt."
    Write-Host "So that it can connect on its own, create libpq's password file:"
    Write-Host ""
    Write-Host "  New-Item -ItemType Directory -Force '$pgpassDir' | Out-Null" -ForegroundColor Cyan
    Write-Host "  Set-Content '$pgpass' '${DbHost}:${DbPort}:${Database}:${DbUser}:YOUR_PASSWORD' -Encoding ascii" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Without it, the RS4 server falls back to its static responses -- which"
    Write-Host "works, but keeps nothing from one session to the next."
}

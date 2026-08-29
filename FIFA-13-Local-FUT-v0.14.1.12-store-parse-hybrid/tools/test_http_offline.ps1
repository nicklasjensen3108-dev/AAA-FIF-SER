[CmdletBinding()]
param(
    [int]$DimePort = 18080,
    [int]$Rs4Port = 18099,
    [int]$StartupTimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dimeScript = Join-Path $root 'server\fut13-dime-server.ps1'
$rs4Script = Join-Path $root 'server\fut13-rs4-server.ps1'
$configRoot = Join-Path $root 'server\config'

function Start-LocalServer {
    param([string]$Script, [string]$Arguments)
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = 'powershell.exe'
    $info.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Script`" $Arguments"
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($info)
}

function Test-LocalPort {
    param([int]$Port)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        return $task.Wait(250) -and $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Wait-LocalPort {
    param([System.Diagnostics.Process]$Process, [int]$Port)
    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    do {
        if ($Process.HasExited) { throw "Server for port $Port exited with code $($Process.ExitCode)." }
        if (Test-LocalPort $Port) { return }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Port $Port did not open before the startup timeout."
}

function Invoke-LocalRequest {
    param([string]$Method, [string]$Url)
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = $Method
    $request.Timeout = 5000
    $request.AllowAutoRedirect = $false
    if ($Method -ne 'GET') {
        $request.ContentLength = 0
        $request.ContentType = 'application/json'
    }
    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
    }
    catch [System.Net.WebException] {
        if (-not $_.Exception.Response) { throw }
        $response = [System.Net.HttpWebResponse]$_.Exception.Response
    }
    try {
        $reader = [System.IO.StreamReader]::new($response.GetResponseStream())
        try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $body }
    }
    finally { $response.Dispose() }
}

function Assert-Response {
    param([string]$Name, [object]$Response, [int]$Status, [string]$Contains)
    if ($Response.Status -ne $Status) {
        throw "$Name returned HTTP $($Response.Status), expected $Status."
    }
    if ($Contains -and $Response.Body -notlike "*$Contains*") {
        throw "$Name did not contain '$Contains'. Body: $($Response.Body)"
    }
    Write-Host ("PASS {0,-28} HTTP {1}" -f $Name, $Response.Status)
}

$dime = Start-LocalServer $dimeScript "-Port $DimePort -Root `"$configRoot`" -Locale eng_us"
$rs4 = Start-LocalServer $rs4Script "-Port $Rs4Port"
try {
    Wait-LocalPort $dime $DimePort
    Wait-LocalPort $rs4 $Rs4Port

    $dimeBase = "http://127.0.0.1:$DimePort"
    $rs4Base = "http://127.0.0.1:$Rs4Port"
    Assert-Response 'futBoot.xml' (Invoke-LocalRequest GET "$dimeBase/futBoot.xml") 200 '<FutCfg>'
    Assert-Response 'dimecfg donor optional' (Invoke-LocalRequest GET "$dimeBase/dime/dimecfglocal.xml") 404 ''
    Assert-Response 'storecfg donor optional' (Invoke-LocalRequest GET "$dimeBase/dime/storecfglocal.xml") 404 ''
    Assert-Response 'storedesc donor optional' (Invoke-LocalRequest GET "$dimeBase/dime/storedesc-eng_us.xml") 404 ''
    Assert-Response 'packdesc donor fallback' (Invoke-LocalRequest GET "$dimeBase/fut/packs/loc/storepackdescriptions.en_us.xml") 200 '{}'
    Assert-Response 'POST /ut/auth' (Invoke-LocalRequest POST "$rs4Base/ut/auth") 200 'FUT13-LOCAL-SID'
    Assert-Response 'account info' (Invoke-LocalRequest GET "$rs4Base/ut/game/fifa13/user/accountinfo") 200 'personaId'
    # Retail uses two distinct schemas: compact metadata from /list and one
    # direct, populated SquadDetails object from /active.
    Assert-Response 'squad list' (Invoke-LocalRequest GET "$rs4Base/ut/game/fifa13/squad/list") 200 '"squad"'
    Assert-Response 'active squad detail' (Invoke-LocalRequest GET "$rs4Base/ut/game/fifa13/squad/active?active=true") 200 'preferredPosition'
    Assert-Response 'store transaction donor' (Invoke-LocalRequest GET "$rs4Base/ut/game/fifa13/store/transaction") 200 '{}'
    Assert-Response 'store catalogue' (Invoke-LocalRequest GET "$rs4Base/ut/game/fifa13/store/purchasegroup/all") 200 'Bronze Pack'
    Assert-Response 'purchase local pack' (Invoke-LocalRequest POST "$rs4Base/ut/game/fifa13/store/items/1") 200 'purchasedPackId'
    Assert-Response 'purchased pack items' (Invoke-LocalRequest GET "$rs4Base/ut/game/fifa13/purchased/items") 200 'preferredPosition'
    Assert-Response 'updated coin balance' (Invoke-LocalRequest GET "$rs4Base/ut/game/fifa13/user/credits") 200 '99999600'
    Assert-Response 'unknown route guard' (Invoke-LocalRequest GET "$rs4Base/ut/game/fifa13/not-implemented") 404 '{}'
    Write-Host 'OFFLINE HTTP TESTS PASSED'
}
finally {
    foreach ($process in @($dime, $rs4)) {
        if ($process -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
    }
}

# FIFA 13 POW HTTP endpoint.
#
# powdllzf.dll is a separate service client from CardsDLL's FUT RS4 client.
# The working donor build advertises four local URLs (19512..19515). Most POW
# schemas are still unknown there too, so the donor intentionally answers a
# well-framed 200 text/json {} for unrecognised routes. This server mirrors that
# behaviour and logs every request so the next trace reveals which POW route is
# load-bearing for Store construction.

param(
    [string] $BindAddress = '127.0.0.1',
    [int]    $Port = 19512,
    [string] $Label = 'FIFA_POW_URL'
)

$ErrorActionPreference = 'Stop'
$traceSession = $env:FUT13_TRACE_SESSION
$logName = if ($traceSession) { "fut13-pow-$Port-$traceSession.log" } else { "fut13-pow-$Port.log" }
$logPath = Join-Path $PSScriptRoot $logName

function Write-Log([string] $Message) {
    $line = '[{0:yyyy-MM-dd HH:mm:ss.fff}] [{1} {2}] {3}' -f (Get-Date), $Port, $Label, $Message
    [Console]::WriteLine($line)
    Add-Content -LiteralPath $logPath -Value $line
}

function Find-HeaderBoundary([byte[]] $Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return $null }
    $patterns = @(
        [byte[]](13,10,13,10), # CRLF CRLF
        [byte[]](10,13,10),    # LF CRLF (ProtoHttp observed form)
        [byte[]](13,10,10),    # CRLF LF
        [byte[]](10,10)        # LF LF
    )
    $bestIndex = [int]::MaxValue
    $bestLength = 0
    foreach ($pattern in $patterns) {
        for ($i = 0; $i -le ($Bytes.Length - $pattern.Length); $i++) {
            $match = $true
            for ($j = 0; $j -lt $pattern.Length; $j++) {
                if ($Bytes[$i + $j] -ne $pattern[$j]) { $match = $false; break }
            }
            if ($match -and $i -lt $bestIndex) {
                $bestIndex = $i
                $bestLength = $pattern.Length
                break
            }
        }
    }
    if ($bestIndex -eq [int]::MaxValue) { return $null }
    return [pscustomobject]@{ Index = $bestIndex; Length = $bestLength }
}

function Get-ContentLength([string] $HeaderText) {
    $m = [regex]::Match($HeaderText, '(?im)^Content-Length\s*:\s*(\d+)\s*$')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}

function Read-Request([System.Net.Sockets.NetworkStream] $Stream) {
    # A readiness probe may connect and send no bytes. Keep that cheap while
    # allowing the actual game plenty of time to complete a request.
    $Stream.ReadTimeout = 300000
    $buffer = New-Object byte[] 4096
    $bytes = New-Object System.Collections.Generic.List[byte]
    $boundary = $null
    while ($null -eq $boundary -and $bytes.Count -lt 262144) {
        $n = $Stream.Read($buffer, 0, $buffer.Length)
        if ($n -le 0) { break }
        for ($i=0; $i -lt $n; $i++) { $bytes.Add($buffer[$i]) }
        $boundary = Find-HeaderBoundary $bytes.ToArray()
    }
    if ($bytes.Count -eq 0) { return $null }

    $all = $bytes.ToArray()
    if ($null -eq $boundary) {
        return [pscustomobject]@{ Raw=$all; Header=''; Body=[byte[]]@(); Line='' }
    }

    $headerBytes = $all[0..($boundary.Index-1)]
    $headerText = [Text.Encoding]::ASCII.GetString($headerBytes)
    $contentLength = Get-ContentLength $headerText
    $bodyStart = $boundary.Index + $boundary.Length
    while (($all.Length - $bodyStart) -lt $contentLength -and $all.Length -lt 1048576) {
        $n = $Stream.Read($buffer, 0, $buffer.Length)
        if ($n -le 0) { break }
        for ($i=0; $i -lt $n; $i++) { $bytes.Add($buffer[$i]) }
        $all = $bytes.ToArray()
    }
    $bodyLength = [Math]::Min($contentLength, [Math]::Max(0, $all.Length - $bodyStart))
    $body = if ($bodyLength -gt 0) { [byte[]]$all[$bodyStart..($bodyStart+$bodyLength-1)] } else { [byte[]]@() }
    $line = (($headerText -split '\r?\n')[0]).Trim()
    return [pscustomobject]@{ Raw=$all; Header=$headerText; Body=$body; Line=$line }
}

function Send-JsonEmpty([System.Net.Sockets.NetworkStream] $Stream) {
    $payload = [Text.Encoding]::UTF8.GetBytes('{}')
    $head = "HTTP/1.1 200 OK`r`nContent-Type: text/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
    $header = [Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($header,0,$header.Length)
    $Stream.Write($payload,0,$payload.Length)
    $Stream.Flush()
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse($BindAddress), $Port)
$listener.Start()
Write-Log ("POW listener ready on http://{0}:{1}/" -f $BindAddress,$Port)

while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $request = Read-Request $stream
        if ($null -eq $request) {
            Write-Log 'accepted health/idle connection with no request bytes'
            continue
        }
        $bodyText = if ($request.Body.Length -gt 0) {
            try { [Text.Encoding]::UTF8.GetString($request.Body) } catch { '<binary>' }
        } else { '' }
        if ($bodyText.Length -gt 1000) { $bodyText = $bodyText.Substring(0,1000) + '...<truncated>' }
        Write-Log ("REQUEST {0} body={1}" -f $request.Line, $bodyText)
        Send-JsonEmpty $stream
        Write-Log 'RESPONSE 200 text/json {} (donor catch-all)'
    }
    catch {
        Write-Log ("ERROR {0}" -f $_.Exception.Message)
    }
    finally {
        try { $client.Close() } catch {}
    }
}

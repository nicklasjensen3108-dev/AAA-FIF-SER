[CmdletBinding()]
param(
    [string] $BindAddress = '127.0.0.1',
    [Parameter(Mandatory=$true)] [int] $Port,
    [Parameter(Mandatory=$true)] [string] $Label
)

$ErrorActionPreference = 'Stop'
$traceSession = $env:FUT13_TRACE_SESSION
$logName = if ($traceSession) { "fut13-easw-$Port-$traceSession.log" } else { "fut13-easw-$Port.log" }
$logPath = Join-Path $PSScriptRoot $logName

function Write-Log([string] $Message) {
    $line = '[{0:yyyy-MM-dd HH:mm:ss.fff}] [{1} {2}] {3}' -f (Get-Date), $Port, $Label, $Message
    [Console]::WriteLine($line)
    Add-Content -LiteralPath $logPath -Value $line
}

function Write-Response {
    param(
        [System.Net.Sockets.NetworkStream] $Stream,
        [string] $Status = '200 OK',
        [string] $ContentType = 'text/json',
        [byte[]] $Body,
        [string[]] $ExtraHeaders = @()
    )
    $head = "HTTP/1.1 $Status`r`n"
    foreach ($line in $ExtraHeaders) { $head += "$line`r`n" }
    $head += "Content-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nConnection: close`r`n`r`n"
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($headBytes, 0, $headBytes.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse($BindAddress), $Port)
$listener.Start()
Write-Log ("listener ready on http://{0}:{1}/" -f $BindAddress, $Port)

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 2000
            $buffer = New-Object byte[] 262144
            $read = 0
            $lineEnd = -1
            $headerEnd = -1

            # Route as soon as request line is complete. Old DirtySock/ProtoHttp
            # can wait for a response before emitting a conventional CRLFCRLF.
            while ($read -lt $buffer.Length -and $lineEnd -lt 0) {
                $got = $stream.Read($buffer, $read, $buffer.Length - $read)
                if ($got -le 0) { break }
                $read += $got
                $ascii = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
                $lineEnd = $ascii.IndexOf("`r`n")
                if ($lineEnd -lt 0) { $lineEnd = $ascii.IndexOf("`n") }
            }
            if ($read -le 0 -or $lineEnd -lt 0) { continue }

            $ascii = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
            $line0 = ($ascii -split "`r?`n")[0]
            Write-Log ("REQ {0}" -f $line0)

            # Read a little more opportunistically for diagnostics, but never
            # block the client waiting for a body that this local stub does not
            # need to formulate its response.
            try {
                $stream.ReadTimeout = 20
                while ($stream.DataAvailable -and $read -lt $buffer.Length) {
                    $got = $stream.Read($buffer, $read, $buffer.Length - $read)
                    if ($got -le 0) { break }
                    $read += $got
                }
            } catch {}
            $requestText = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
            foreach ($header in ($requestText -split "`r?`n")) {
                if ($header -match '^(EASW-|Content-|User-Agent|Accept|Cookie|X-UT-)') {
                    Write-Log ("HDR {0}" -f $header)
                }
            }

            if ($Port -eq 19502 -and $line0 -match '/v2/authentication') {
                # Exact response-header mechanism recovered in the donor build
                # from fifa13.exe!0x6f33a0..0x6f354b. These values are stored in
                # FIFA's native EASW object and are what CardsDLL later requests.
                $xml = '<?xml version="1.0" encoding="UTF-8"?>' + "`n" +
                       '<authentication><status>SUCCESS</status></authentication>'
                $body = [System.Text.Encoding]::UTF8.GetBytes($xml)
                Write-Response -Stream $stream -ContentType 'text/xml' -Body $body -ExtraHeaders @(
                    'EASW-Token: ZAMBONI3LOCALTOKEN00000000001',
                    'EASW-Nucleus-Persona: FUT13 Local',
                    'EASW-Session: ZAMBONI3LOCALSESSION0000000001',
                    'EASW-Userid: 1000001'
                )
                Write-Log 'RESP 200 native EASW session headers'
            } else {
                # The six surrounding EASW/FUT surfaces are primarily here to
                # let the retail state machine complete and to reveal any exact
                # routes it needs next. The donor intentionally advances unknown
                # calls with a minimal parse-safe response.
                $body = [System.Text.Encoding]::UTF8.GetBytes('{}')
                Write-Response -Stream $stream -ContentType 'text/json' -Body $body
                Write-Log 'RESP 200 {}'
            }
        } catch {
            Write-Log ("ERR {0}" -f $_.Exception.Message)
        } finally {
            $client.Dispose()
        }
    }
} finally {
    $listener.Stop()
    Write-Log 'listener stopped'
}

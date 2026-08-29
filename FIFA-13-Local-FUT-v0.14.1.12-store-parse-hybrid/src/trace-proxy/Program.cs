using System.Net;
using System.Net.Sockets;

var listenPort = ReadPort("FUT13_TRACE_LISTEN_PORT", 42127);
var targetPort = ReadPort("FUT13_TRACE_TARGET_PORT", 42128);

using var shutdown = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) =>
{
    eventArgs.Cancel = true;
    shutdown.Cancel();
};

var listener = new TcpListener(IPAddress.Loopback, listenPort);
listener.Start();
Console.WriteLine($"FUT13 trace proxy: 127.0.0.1:{listenPort} -> 127.0.0.1:{targetPort}");

try
{
    while (!shutdown.IsCancellationRequested)
    {
        TcpClient client;
        try
        {
            client = await listener.AcceptTcpClientAsync(shutdown.Token);
        }
        catch (OperationCanceledException)
        {
            break;
        }

        _ = RelayAsync(client, targetPort, shutdown.Token);
    }
}
finally
{
    listener.Stop();
}

static async Task RelayAsync(TcpClient client, int targetPort, CancellationToken cancellationToken)
{
    var id = Guid.NewGuid().ToString("N")[..8];
    var remote = client.Client.RemoteEndPoint;
    Console.WriteLine($"[{id}] CONNECT client={remote}");

    try
    {
        using (client)
        {
            using var upstream = new TcpClient();
            await upstream.ConnectAsync(IPAddress.Loopback, targetPort, cancellationToken);
            Console.WriteLine($"[{id}] UPSTREAM connected");

            using var clientStream = client.GetStream();
            using var upstreamStream = upstream.GetStream();

            var clientToServer = PumpAsync(id, "C->S", clientStream, upstream, upstreamStream, cancellationToken);
            var serverToClient = PumpAsync(id, "S->C", upstreamStream, client, clientStream, cancellationToken);
            await Task.WhenAll(clientToServer, serverToClient);
        }
    }
    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
    {
        Console.WriteLine($"[{id}] STOPPED");
    }
    catch (SocketException exception)
    {
        Console.WriteLine($"[{id}] SOCKET {exception.SocketErrorCode}: {exception.Message}");
    }
    catch (IOException exception)
    {
        Console.WriteLine($"[{id}] IO {exception.Message}");
    }
    catch (Exception exception)
    {
        Console.WriteLine($"[{id}] ERROR {exception.GetType().Name}: {exception.Message}");
    }
    finally
    {
        Console.WriteLine($"[{id}] DISCONNECT");
    }
}

static async Task PumpAsync(
    string id,
    string direction,
    NetworkStream source,
    TcpClient destination,
    NetworkStream destinationStream,
    CancellationToken cancellationToken)
{
    var buffer = new byte[32 * 1024];
    try
    {
        while (true)
        {
            var read = await source.ReadAsync(buffer, cancellationToken);
            if (read == 0)
            {
                Console.WriteLine($"[{id}] {direction} EOF");
                TryShutdownSend(destination);
                return;
            }

            Console.WriteLine($"[{id}] {direction} {DescribeTlsRecords(buffer.AsSpan(0, read))}");
            await destinationStream.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
            await destinationStream.FlushAsync(cancellationToken);
        }
    }
    catch (IOException exception)
    {
        Console.WriteLine($"[{id}] {direction} IO {exception.Message}");
        TryShutdownSend(destination);
    }
}

static string DescribeTlsRecords(ReadOnlySpan<byte> bytes)
{
    var records = new List<string>();
    var offset = 0;
    while (offset + 5 <= bytes.Length)
    {
        var type = bytes[offset] switch
        {
            20 => "ChangeCipherSpec",
            21 => "Alert",
            22 => "Handshake",
            23 => "ApplicationData",
            _ => "Raw"
        };
        var version = $"{bytes[offset + 1]:X2}{bytes[offset + 2]:X2}";
        var length = (bytes[offset + 3] << 8) | bytes[offset + 4];
        var available = Math.Min(length, bytes.Length - offset - 5);
        var detail = bytes[offset] == 22
            ? DescribeHandshakeMessages(bytes.Slice(offset + 5, available))
            : string.Empty;
        records.Add($"{type}/v{version}/len={length}{detail}");
        if (offset + 5 + length > bytes.Length)
        {
            records.Add("fragmented");
            break;
        }
        offset += 5 + length;
    }

    if (records.Count == 0 || offset < bytes.Length)
        records.Add("bytes=" + Convert.ToHexString(bytes[..Math.Min(bytes.Length, 32)]));

    return $"read={bytes.Length} [{string.Join(", ", records)}]";
}

static string DescribeHandshakeMessages(ReadOnlySpan<byte> payload)
{
    var messages = new List<string>();
    var offset = 0;
    while (offset + 4 <= payload.Length)
    {
        var type = payload[offset];
        var length = (payload[offset + 1] << 16) | (payload[offset + 2] << 8) | payload[offset + 3];
        var name = type switch
        {
            1 => "ClientHello",
            2 => "ServerHello",
            11 => "Certificate",
            14 => "ServerHelloDone",
            16 => "ClientKeyExchange",
            20 => "Finished",
            _ => $"Handshake{type}"
        };

        if (type == 2 && offset + 39 <= payload.Length)
        {
            var sessionLength = payload[offset + 38];
            var cipherOffset = offset + 39 + sessionLength;
            if (cipherOffset + 2 <= payload.Length)
                name += $"(cipher=0x{payload[cipherOffset]:X2}{payload[cipherOffset + 1]:X2})";
        }
        messages.Add($"{name}:{length}");
        if (offset + 4 + length > payload.Length)
        {
            messages.Add("fragmented");
            break;
        }
        offset += 4 + length;
    }

    return messages.Count == 0 ? string.Empty : $" [{string.Join("+", messages)}]";
}

static void TryShutdownSend(TcpClient client)
{
    try { client.Client.Shutdown(SocketShutdown.Send); }
    catch (SocketException) { }
    catch (ObjectDisposedException) { }
}

static int ReadPort(string name, int fallback) =>
    int.TryParse(Environment.GetEnvironmentVariable(name), out var value) && value is > 0 and <= 65535
        ? value
        : fallback;

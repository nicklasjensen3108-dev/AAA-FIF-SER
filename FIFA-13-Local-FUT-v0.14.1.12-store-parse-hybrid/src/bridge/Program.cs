using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Blaze3SDK;
using Blaze3SDK.Blaze;
using Blaze3SDK.Blaze.Authentication;
using Blaze3SDK.Blaze.Redirector;
using Blaze3SDK.Blaze.Util;
using Blaze3SDK.Components;
using BlazeCommon;
using Fut13Local.Bridge;
using NLog;
using NLog.Layouts;

var configuredLogLevel = Environment.GetEnvironmentVariable("FUT13_LOG_LEVEL");
var minimumLogLevel = string.IsNullOrWhiteSpace(configuredLogLevel)
    ? LogLevel.Debug
    : LogLevel.FromString(configuredLogLevel);

LogManager.Setup().LoadConfiguration(configuration =>
    configuration.ForLogger()
        .FilterMinLevel(minimumLogLevel)
        .WriteToConsole(new SimpleLayout("[${longdate}][${level:uppercase=true}] ${message:withexception=true}")));

AppDomain.CurrentDomain.FirstChanceException += (_, eventArgs) =>
{
    var type = eventArgs.Exception.GetType().FullName ?? string.Empty;
    if (type.StartsWith("Org.Mentalis.Security.Ssl", StringComparison.Ordinal))
        Console.Error.WriteLine($"[TLS first-chance] {type}: {eventArgs.Exception.Message}");
};

if (args.Contains("--self-test", StringComparer.OrdinalIgnoreCase))
{
    RunSelfTest();
    return;
}
if (args.Contains("--self-test-game", StringComparer.OrdinalIgnoreCase))
{
    await RunGameSelfTestAsync();
    return;
}

var certificatePath = Environment.GetEnvironmentVariable("FUT13_REDIRECTOR_CERT")
    ?? Path.Combine(Directory.GetCurrentDirectory(), "secrets", "gosredirector.ea.com.pfx");
var redirectorPort = ReadPort("FUT13_REDIRECTOR_PORT", 44125);
var blazePort = ReadPort("FUT13_BLAZE_PORT", 10092);
var advertisedHost = Environment.GetEnvironmentVariable("FUT13_ADVERTISED_HOST") ?? "127.0.0.1";

using var certificate = LoadLegacyCertificate(
    certificatePath,
    Environment.GetEnvironmentVariable("FUT13_REDIRECTOR_CERT_PASSWORD") ?? string.Empty);

var redirector = Blaze3.CreateBlazeServer(
    "gosredirector.ea.com",
    new IPEndPoint(IPAddress.Loopback, redirectorPort),
    certificate);
redirector.AddComponent<Fut13RedirectorComponent>();

// The game endpoint intentionally starts as a protocol discovery server. Every
// unknown command is logged by BlazeSDK, which lets us implement FIFA 13's exact
// component dialect without guessing or modifying the game executable.
var game = Blaze3.CreateBlazeServer(
    "fifa-13-pc",
    new IPEndPoint(IPAddress.Loopback, blazePort),
    certificate: null,
    forceSsl: false,
    onRequest: (_, packet, unhandled) =>
    {
        if (!unhandled)
            return;
        Console.WriteLine(
            "BLAZE REQUEST component={0} command={1} message={2}",
            packet.Frame.Component,
            packet.Frame.Command,
            packet.Frame.MsgNum);
    });
game.AddComponent<Fut13UtilComponent>();
game.AddComponent<Fut13AuthenticationComponent>();
game.AddComponent<Fut13UserSessionsComponent>();
game.AddComponent<Fut13StatsComponent>();
game.AddComponent<Fut13CensusDataComponent>();
game.AddComponent<Fut13AssociationListsComponent>();
game.AddComponent<Fut13MessagingComponent>();
game.AddComponent<Fut13RoomsComponent>();
game.AddComponent<Fut13ClubsComponent>();
game.AddComponent<Fut13OsdkSettingsComponent>();

Console.WriteLine($"FUT13 bridge: redirector TLS 127.0.0.1:{redirectorPort} -> {advertisedHost}:{blazePort}");
Console.WriteLine($"FUT13 bridge: Blaze discovery 127.0.0.1:{blazePort}");

using var shutdown = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) =>
{
    eventArgs.Cancel = true;
    shutdown.Cancel();
    redirector.Stop();
    game.Stop();
};

var redirectorTask = redirector.Start(128);
var gameTask = game.Start(128);
try
{
    await Task.Delay(Timeout.Infinite, shutdown.Token);
}
catch (OperationCanceledException) { }
await Task.WhenAll(redirectorTask, gameTask);

static int ReadPort(string name, int fallback) =>
    int.TryParse(Environment.GetEnvironmentVariable(name), out var value) && value is > 0 and <= 65535
        ? value
        : fallback;

static X509Certificate2 LoadLegacyCertificate(string path, string password)
{
    var certificateDirectory = Path.GetDirectoryName(path)
        ?? throw new InvalidOperationException("The local certificate path has no directory.");
    var derPath = Path.Combine(certificateDirectory, "gosredirector.protossl.der");
    var keyPath = Path.Combine(certificateDirectory, "gosredirector.key");
    if (!File.Exists(derPath) || !File.Exists(keyPath))
        throw new InvalidOperationException("The local ProtoSSL DER certificate and PEM key are required.");

    using var source = new X509Certificate2(derPath);
    using var sourceKey = RSA.Create();
    sourceKey.ImportFromPem(File.ReadAllText(keyPath));

    // Keep the key ephemeral. A named CryptoAPI key container makes startup
    // depend on the user's legacy CSP profile directory and fails on otherwise
    // healthy Windows installs with ERROR_FILE_NOT_FOUND. FixedSsl converts
    // this key to the provider it needs when the handshake begins.
    return source.CopyWithPrivateKey(sourceKey);
}

static void RunSelfTest()
{
    var loopback = BitConverter.ToUInt32(IPAddress.Loopback.GetAddressBytes());
    var connection = ProtoFireConnection.ConnectSsl3(loopback, ReadPort("FUT13_REDIRECTOR_PORT", 44125))
        ?? throw new InvalidOperationException("Could not establish the legacy TLS connection.");
    var blaze = Blaze3.CreateBlazeClientConnection(connection);
    var redirector = new RedirectorComponentBase.Client(blaze);
    var response = redirector.GetServerInstance(new ServerInstanceRequest
    {
        mBlazeSDKBuildDate = "FUT13 local self-test",
        mBlazeSDKVersion = "3",
        mClientLocale = 0x656E5553,
        mClientName = "fifa13",
        mClientSkuId = "pc",
        mClientType = ClientType.CLIENT_TYPE_GAMEPLAY_USER,
        mClientVersion = "13.7.1217703",
        mConnectionProfile = "standardSecure_v3",
        mDirtySDKVersion = "3",
        mEnvironment = "prod",
        mFirstPartyId = new FirstPartyId(),
        mName = "fifa-13-pc",
        mPlatform = "Windows"
    });
    Console.WriteLine($"SELF-TEST OK: {response.mAddress.IpAddress?.mHostname}:{response.mAddress.IpAddress?.mPort}");
    connection.Disconnect();
}

static async Task RunGameSelfTestAsync()
{
    var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
    await socket.ConnectAsync(IPAddress.Loopback, ReadPort("FUT13_BLAZE_PORT", 10092));
    var connection = new ProtoFireConnection(socket);
    connection.SetStream(new NetworkStream(socket, ownsSocket: true));
    var blaze = Blaze3.CreateBlazeClientConnection(connection);
    var util = new UtilComponentBase.Client(blaze);
    var auth = new AuthenticationComponentBase.Client(blaze);
    var preAuth = await util.PreAuthAsync(new PreAuthRequest
    {
        mClientData = new ClientData
        {
            mClientType = ClientType.CLIENT_TYPE_GAMEPLAY_USER,
            mIgnoreInactivityTimeout = false,
            mLocale = 0x656E5553,
            mServiceName = "fifa-13-pc"
        },
        mClientInfo = new ClientInfo
        {
            mBlazeSDKBuildDate = "FUT13 local self-test",
            mBlazeSDKVersion = "3",
            mClientLocale = 0x656E5553,
            mClientName = "fifa13",
            mClientSkuId = "pc",
            mClientVersion = "13.7.1217703",
            mDirtySDKVersion = "3",
            mEnvironment = "prod",
            mMacAddress = "00:00:00:00:00:00",
            mPlatform = "Windows"
        },
        mFetchClientConfig = new FetchClientConfigRequest { mConfigSection = "FIFA13_PC" }
    });
    var login = await auth.ExpressLoginAsync(new ExpressLoginRequest
    {
        mEmail = "fut13@local.invalid",
        mPassword = string.Empty,
        mPersonaName = Fut13BridgeSettings.PersonaName
    });
    Console.WriteLine(
        "GAME SELF-TEST OK: components={0}, persona={1}, backend={2}",
        preAuth.mComponentIds.Count,
        login.mSessionInfo.mPersonaDetails.mDisplayName,
        preAuth.mConfig.mConfig["FUT_RS4_BASE_URL"]);
    connection.Disconnect();
}

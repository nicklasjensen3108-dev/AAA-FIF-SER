using System.Net;
using Blaze3SDK.Blaze.Redirector;
using Blaze3SDK.Components;
using BlazeCommon;

namespace Fut13Local.Bridge;

internal sealed class Fut13RedirectorComponent : RedirectorComponentBase.Server
{
    public override Task<ServerInstanceInfo> GetServerInstanceAsync(ServerInstanceRequest request, BlazeRpcContext context)
    {
        var host = Environment.GetEnvironmentVariable("FUT13_ADVERTISED_HOST") ?? "127.0.0.1";
        var port = ushort.TryParse(Environment.GetEnvironmentVariable("FUT13_BLAZE_PORT"), out var configuredPort)
            ? configuredPort
            : (ushort)10092;
        Console.WriteLine(
            "FIFA 13 redirect request: service={0}, client={1}, version={2}, sdk={3}, platform={4}",
            request.mName,
            request.mClientName,
            request.mClientVersion,
            request.mBlazeSDKVersion,
            request.mPlatform);

        var address = IPAddress.Parse(host);
        var bytes = address.GetAddressBytes();
        if (bytes.Length != 4)
            throw new InvalidOperationException("FIFA 13 expects an IPv4 Blaze endpoint.");
        var numericAddress = (uint)(bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]);

        return Task.FromResult(new ServerInstanceInfo
        {
            mAddress = new ServerAddress
            {
                IpAddress = new IpAddress
                {
                    mHostname = host,
                    mIp = numericAddress,
                    mPort = port
                }
            },
            mAddressRemaps = [],
            mMessages = ["FUT 13 Local Solo"],
            mNameRemaps = [],
            mSecure = false,
            mDefaultDnsAddress = 0
        });
    }
}

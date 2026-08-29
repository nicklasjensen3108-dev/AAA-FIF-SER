namespace Fut13Local.Bridge;

internal static class Fut13BridgeSettings
{
    public const long UserId = 1000001;
    public const long PersonaId = 2000001;
    public const string PersonaName = "FUT13 Local";
    public const string SessionKey = "fut13-local-session";
    public const string AuthToken = "fut13-local-auth";

    // Effective default for every FUT / RS4 base key: a bare origin on port
    // 8099, with NO path and with a trailing slash. The comment above the
    // FUT_URI / FUT_RS4_* group below records the measurements behind both
    // halves of that; do not change this constant without reading it.
    public const string DefaultRs4BaseUrl = "http://127.0.0.1:8099/";

    // FUT13_RS4_BASE_URL moves the FUT / RS4 base off the default, for the case
    // where the RS4 server is reachable somewhere other than loopback:8099.
    // The value is normalised to exactly one trailing slash, because CardsDLL
    // concatenates its own route without adding one. It must remain a bare
    // origin: a path here is silently fatal, see below.
    public static string Rs4BaseUrl
    {
        get
        {
            var value = Environment.GetEnvironmentVariable("FUT13_RS4_BASE_URL");
            return string.IsNullOrWhiteSpace(value)
                ? DefaultRs4BaseUrl
                : value.TrimEnd('/') + "/";
        }
    }

    public static SortedDictionary<string, string> ClientConfig(string section)
    {
        var rs4Base = Rs4BaseUrl;
        var config = new SortedDictionary<string, string>(StringComparer.Ordinal)
        {
        ["CARDS/DIRECTED_BLAZEENV"] = "prod",
        ["FCC/FUT_DEPLOY_LANGUAGE"] = "en_US",
        ["FUT_ENABLE_MENU"] = "1",
        // Donor FIFA 13 client-config invariants. The portable build also
        // applies these exact values at runtime to the bundled prebuilt bridge;
        // keeping source parity prevents a future bridge rebuild regressing them.
        ["OSDK_EASW_ALLOWED_LOCALES"] = "****",
        ["OSDK_EASW_AUTH_URL"] = "http://127.0.0.1:19502/easw/auth",
        ["OSDK_EASW_REQ_URL"] = "http://127.0.0.1:19503/easw/req",
        ["OSDK_EASW_EVENT_URL"] = "http://127.0.0.1:19504/easw/event",
        ["OSDK_EASW_MEDIA_URL"] = "http://127.0.0.1:19505/easw/media",
        ["OSDK_EASW_GF_FILE_URL"] = "http://127.0.0.1:19506/easw/gf",
        ["FUT/ROSTERUPDATE_URL"] = "http://127.0.0.1:19507/fut/roster",
        ["OSDK_EASW_CONNECT_RETRY_PERIOD"] = "30",
        ["FUT/DAY60_FIX_ENABLED"] = "0",
        ["FUT/STORE_USE_TRANSACTION"] = "0",
        ["FIFA_POW_URL"] = "http://127.0.0.1:19512/",
        ["FIFA_POW_NUCLEUS_PROXY_URL"] = "http://127.0.0.1:19513/",
        ["FIFA_POW_CONTENT_SERVER_URL"] = "http://127.0.0.1:19514/",
        ["FIFA_POW_MMM_URI"] = "http://127.0.0.1:19515/",
        ["ONLINE/NO_AUTO_SQUAD"] = "0",
        ["FUT/CONFIG_SECTION"] = section,

        // ROOT CAUSE of cfgFileOk = 0.
        //
        // The FUT dynamic-messages downloads are named "fut-locstrings" and
        // "fut-tutorial", so they are exactly the "fut*" transfers the completion
        // callback at 0x008ec320 handles. Their base URL defaults to the hardcoded
        // dead address http://89.234.41.144:8080/onlineAssets/2012/fut
        // (FUTDYNAMICMESSAGES_URL_BASE, VA 0x0244a54c), so every attempt fails and
        // the failure path at 0x008ec343 sets [obj+0x14f] = 1 - the error byte that
        // makes cfgFileOk unreachable for the rest of the session. Measured on the
        // live object: [+0x14f] = 1, [+0x14d] = 0.
        //
        // Redirecting the base at the local server lets those transfers succeed;
        // the parser then runs and sets [obj+0x14d] = 1 on entry (0x0097ff1e).
        // NB: the value must NOT carry the scheme. When the key is set, the client
        // formats it with "http://%s" (snprintf at 0x010f294a, format string at
        // 0x02427c04), so a value starting with "http://" produces the malformed
        // "http://http://..." and no request is ever emitted - observed once.
        ["ONLINE/FUTDYNAMICMESSAGES_CUSTOMURL"] = "127.0.0.1:8080/fut",
        ["ONLINE/FUTDYNAMICMESSAGES_CUSTOMGETMESSAGESURI"] = "/messages",
        ["ONLINE/FUTDYNAMICMESSAGES_TUTORIAL_MSG_URL"] = "/tutorials",

        // Setting only the ONLINE/* override above produced no request at all, so
        // also set the internal variables directly. These are the names the client
        // registers itself (FUTDYNAMICMESSAGES_URL_BASE at VA 0x0244a530 with the
        // dead default, _URL_GET_MESSAGES at 0x0244a4d0, _TUTORIAL_MSG_URL at
        // 0x0244a474) and all five exist verbatim in this fifa13.exe.
        //
        // Cross-checked against the FIFA 14 revival project, which drives the same
        // retail CardsDLL and sets these exact keys rather than the ONLINE/ ones.
        // Its note is explicit: the client appends "/fut/" itself, so the base
        // carries the scheme and NO trailing slash. FIFA 13 agrees - it holds the
        // literal "/fut/loc/" (VA 0x0244a418) that it concatenates.
        // ROOT CAUSE, measured on 6 August.
        //
        // The trace showed the callback invoked with (success=0, name="fut",
        // buffer=NULL, length=0) and NO network attempt at all. The calling code
        // (0x00b77b30) is a cancellation function: it looks the transfer up by
        // name, notifies the failure with a hardcoded flag (push 0 at
        // 0x00b77bec), then erases it. That is the path which sets
        // [object+0x14f] = 1.
        //
        // Nothing resolved the "fut" service. The client reads this key
        // (0x00b7ea99) and, if it is EMPTY, skips loading the routing table
        // (test eax,eax / je 0xb7eb4c) - and no cfgrouting.xml exists in the
        // installation. So the table stayed empty.
        // NB: this is the COMPLETE URL of the file, not a base directory. Set to
        // ".../routing/", the client emitted exactly "GET /routing/" (404). It
        // therefore appends no file name, unlike DIME_FILES_PATH.
        // THE key that resolves the "fut" service.
        //
        // EA's genuine routing table, dumped from the game's memory
        // (analysis/extracted/ea-cfgrouting.xml), states it in black and white:
        //     <file service="fut" type="network"
        //           osdkVar="FUTBOOTCFGFILE_URL" defaultFile="futBoot.xml"/>
        //
        // This key had been dismissed that evening on bad reasoning: the string
        // "FUTBOOTCFGFILE_URL" is absent from fifa13.exe, hence the conclusion
        // that it did not exist on FIFA 13. In reality the variable name lives
        // in the data file, not in the binary - and the FIFA 14 project was
        // already serving it for the same reason.
        //
        // Without it the "fut" service has no URL, its transfer is cancelled
        // (0x00B77B30, hardcoded failure flag) and [object+0x14f] goes to 1,
        // which makes cfgFileOk unreachable for the whole session.
        ["FUTBOOTCFGFILE_URL"] = "http://127.0.0.1:8080/futBoot.xml",

        // The FUT / RS4 base. One assignment per key, all derived from
        // Rs4BaseUrl (FUT13_RS4_BASE_URL, default http://127.0.0.1:8099/).
        // These five keys used to be assigned twice in this initialiser - once
        // from an environment-driven value, once from a literal - so the
        // literal won and the environment variable was documented but dead.
        //
        // Keys read by CardsDLLzf.dll once the plug-in is loaded. They do NOT
        // exist in fifa13.exe - they live in the DLL (same names, with
        // %s = platform). Looking a key up in the exe and concluding it is
        // absent is the mistake that got FUTBOOTCFGFILE_URL dismissed for
        // hours; do not repeat it here.
        //
        // The built-in defaults are dead: http://easw.easports.com:8099/ and
        // http://content.lt.easfc.ea.com:8080/onlineAssets/2012/fut/.
        //
        // Pointed at the local server, which logs every request and answers 404
        // while tracing the name: that is how the routes really called
        // (ut/%s/user, ut/%s/club, ut/%s/squad...) get discovered rather than
        // guessed from FIFA 14.
        //
        // PORT 8099, not 80. CardsDLL's own built-in base is
        // http://easw.easports.com:8099/ and its whole URL setup is gated on
        // HasKey("FUT_RS4_BASE_URL") at RVA 0x53E51 - if the key is missing the
        // function returns without building any URL and no socket is ever opened,
        // which is exactly what "RetrieveTrustedConsoleListResult FAIL with no
        // HTTP anywhere" looked like. The FIFA 14 revival project serves these
        // same keys on 8099 and only under OSDK_CLIENT; webapi/fut13-rs4-server.ps1
        // listens there.
        //
        // A BARE ORIGIN, not a path. Aligned on the FIFA 14 revival project's
        // OSDK_CLIENT profile: a bare origin on 8099, not a path on 8080.
        // CardsDLL appends the route itself (its table is ut/%s/... with
        // %s = game/fifa13), so a base carrying a path would produce
        // ut/game/fifa13/ut/game/fifa13/... and no request is emitted at all.
        // Measured.
        ["FUT_URI"] = "http://127.0.0.1:19501/fut",
        ["FUT_RS4_BASE_URL"] = rs4Base,
        ["FUT_RS4_URL_PC"] = rs4Base,
        ["FUT_RS4_APIURL_PC"] = rs4Base,
        ["FUT/MODULE_BASEURL_PC"] = rs4Base,
        ["FUT/SINGLE_BASEURL_PC"] = rs4Base,

        // DELIBERATELY DISABLED.
        //
        // Measured: loading the table over the NETWORK is precisely what cancels
        // the "fut" service. The cancellation callback lands in the SAME
        // millisecond as the start of parsing (0x00B7E1B0), before a single entry
        // is read, and parsing ends with 0 rejections: our entries are valid, but
        // the load flushes the pending transfers first.
        //
        // A local cfgrouting.xml (chunkzip format) is now dropped in the game
        // folder; it is meant to populate the table at startup via 0x00B7E9E0, a
        // path that calls the parser WITHOUT cancelling. Leaving the key empty
        // suppresses the network reload - hence the cancellation - and tests that
        // route on its own.
        //
        // To re-enable: "http://127.0.0.1/routing/cfgrouting.xml" (the COMPLETE
        // URL of the file, not a base directory).
        ////["ROUTINGCFGFILE_URL"] = "http://127.0.0.1/routing/cfgrouting.xml",

        ["FUTDYNAMICMESSAGES_URL_BASE"] = "http://127.0.0.1:8080",
        ["FUTDYNAMICMESSAGES_URL_GET_MESSAGES"] = "/messages",
        ["FUTDYNAMICMESSAGES_TUTORIAL_MSG_URL"] = "/tutorials",
        ["FUTDYNAMICMESSAGES_REQUEST_TIMEOUT"] = "5000",
        ["FUTDYNAMICMESSAGES_REFRESH_INTERVAL"] = "300000",

        // The DIME config files gate cfgFileOk. The client builds their URL as
        // DIME_FILES_PATH + "dimecfg.xml" (format strings at VA 0x02443e6c,
        // registered as config variables at 0x01096692). Point them at the local
        // capture endpoint so the exact request becomes visible; the trailing
        // slash matters because the client concatenates without one.
        ["DIME_FILES_PATH"] = "http://127.0.0.1:8080/dime/",
        ["DIME_IMG_FILES_PATH"] = "http://127.0.0.1:8080/dime/images/",

        // Donor keeps this disabled: request the normal network-name DIME/Store
        // groups. Those optional groups are deliberately allowed to fail/retry
        // rather than feeding hand-authored XML into the retail parsers.
        ["USE_LOCAL_CFGFILES"] = "0",

        // The installed FUT DLC declares fut_version = 1 (see
        // Game\dlc\dlc_CardsDLL\info.dlc: DLC id FUTDLC01, fut_dll = CardsDLL).
        // The native launcher compares the required version against that value;
        // a mismatch yields updateRequired / !requiredVersionAvailable and the
        // "try again later" refusal. This key is carried by the retail client.
        ["FUT/OVERRIDE_VERSION"] = "1",

        // Diagnostics only: the shipped client carries these three keys
        // (verified present in fifa13.exe next to "osdkdebugmanager.ini" /
        // "osdkDebugLogFile.txt"). Enabling them makes the client write its own
        // OSDK trace to disk, so the native FUT launcher's decision line
        //   "%s->futStatus %x owned[] installed[] updateRequired[] ...
        //    requiredVersionAvailable[] cfgFileOk[] futNotAvailable[]"
        // can be read without an attached debugger.
        ["ONLINE/OSDK_LOGGING"] = "1",
        ["ONLINE/OSDK_LOGGING_HDD"] = "1",
        ["ONLINE/USE_OSDKDEBUG_FILE"] = "1"
        };

        // The retired asset host must not gate native FUT startup. FIFA requests
        // this specifically through OSDK_CLIENT before the FUT frontend loads.
        if (string.Equals(section, "OSDK_CLIENT", StringComparison.Ordinal))
            config["ONLINE/NO_ASSET_UPDATE"] = "1";

        return config;
    }
}

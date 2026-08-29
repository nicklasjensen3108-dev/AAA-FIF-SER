using Blaze3SDK.Blaze;
using Blaze3SDK.Blaze.Util;
using Blaze3SDK.Components;
using BlazeCommon;

namespace Fut13Local.Bridge;

internal sealed class Fut13UtilComponent : UtilComponentBase.Server
{
    // The local account is already provisioned by the bridge.  FIFA writes 0
    // when its one-time account wizard completes; returning 1 on every boot
    // incorrectly restarts that wizard instead of entering the existing profile.
    private static string _firstTimeFlag = "0";
    public override Task<PreAuthResponse> PreAuthAsync(PreAuthRequest request, BlazeRpcContext context) =>
        Task.FromResult(new PreAuthResponse
        {
            mAnonymousChildAccountsEnabled = false,
            mAuthenticationSource = "300001",
            mComponentIds = [
                AuthenticationComponentBase.Id,
                StatsComponentBase.Id,
                UtilComponentBase.Id,
                CensusDataComponentBase.Id,
                ClubsComponentBase.Id,
                MessagingComponentBase.Id,
                RoomsComponentBase.Id,
                AssociationListsComponentBase.Id,
                // FUT advertises these legacy services during bootstrap.  The
                // bridge logs any subsequent command so it can be implemented
                // from the retail client's actual request rather than guessed.
                2076, // Sponsored Events
                2148, // CardHouse
                2249,
                2268, // OSDK Online Pass
                UserSessionsBase.Id
            ],
            mConfig = Config(request.mFetchClientConfig.mConfigSection),
            mInstanceName = "fut13-local",
            mLegalDocGameIdentifier = "FIFA13",
            mParentalConsentEntitlementGroupName = string.Empty,
            mParentalConsentEntitlementTag = string.Empty,
            mPersonaNamespace = "cem_ea_id",
            mPlatform = "pc",
            mQosSettings = EmptyQos(),
            mRegistrationSource = "FIFA13",
            mServerVersion = "Blaze 3.0/FUT13 Local",
            mUnderageSupported = false
        });

    public override Task<FetchConfigResponse> FetchClientConfigAsync(FetchClientConfigRequest request, BlazeRpcContext context) =>
        Task.FromResult(Config(request.mConfigSection));

    public override Task<PingResponse> PingAsync(NullStruct request, BlazeRpcContext context) =>
        Task.FromResult(new PingResponse { mServerTime = (uint)DateTimeOffset.UtcNow.ToUnixTimeSeconds() });

    public override Task<NullStruct> SetClientDataAsync(ClientData request, BlazeRpcContext context) =>
        Task.FromResult(new NullStruct());

    public override Task<LocalizeStringsResponse> LocalizeStringsAsync(LocalizeStringsRequest request, BlazeRpcContext context) =>
        Task.FromResult(new LocalizeStringsResponse
        {
            mLocalizedStrings = new SortedDictionary<string, string>(
                (request.mStringIds ?? []).ToDictionary(id => id, LocalText))
        });

    public override Task<NullStruct> SetClientMetricsAsync(ClientMetrics request, BlazeRpcContext context) =>
        Task.FromResult(new NullStruct());

    public override Task<NullStruct> SetConnectionStateAsync(SetConnectionStateRequest request, BlazeRpcContext context) =>
        Task.FromResult(new NullStruct());

    public override Task<QosConfigInfo> FetchQosConfigAsync(NullStruct request, BlazeRpcContext context) =>
        Task.FromResult(EmptyQos());

    public override Task<GetTelemetryServerResponse> GetTelemetryServerAsync(GetTelemetryServerRequest request, BlazeRpcContext context) =>
        Task.FromResult(EmptyTelemetry());

    public override Task<GetTickerServerResponse> GetTickerServerAsync(NullStruct request, BlazeRpcContext context) =>
        Task.FromResult(new GetTickerServerResponse { mAddress = string.Empty, mKey = string.Empty, mPort = 0 });

    public override Task<PostAuthResponse> PostAuthAsync(NullStruct request, BlazeRpcContext context) =>
        Task.FromResult(new PostAuthResponse
        {
            mPssConfig = EmptyPss(),
            mTelemetryServer = EmptyTelemetry(),
            mTickerServer = new GetTickerServerResponse { mAddress = string.Empty, mKey = string.Empty, mPort = 0 },
            mUserOptions = new UserOptions { mTelemetryOpt = TelemetryOpt.TELEMETRY_OPT_OUT, mUserId = Fut13BridgeSettings.UserId }
        });

    public override Task<UserSettingsResponse> UserSettingsLoadAsync(UserSettingsLoadRequest request, BlazeRpcContext context) =>
        Task.FromResult(new UserSettingsResponse
        {
            mData = request.mKey == "FirstTimeFlag" ? _firstTimeFlag : string.Empty,
            mKey = request.mKey
        });

    public override Task<UserSettingsLoadAllResponse> UserSettingsLoadAllAsync(UserSettingsLoadAllRequest request, BlazeRpcContext context) =>
        Task.FromResult(new UserSettingsLoadAllResponse { mDataMap = new SortedDictionary<string, string>() });

    public override Task<NullStruct> UserSettingsSaveAsync(UserSettingsSaveRequest request, BlazeRpcContext context)
    {
        if (request.mKey == "FirstTimeFlag")
            _firstTimeFlag = request.mData;
        return Task.FromResult(new NullStruct());
    }

    private static FetchConfigResponse Config(string? section) => new()
    {
        mConfig = Fut13BridgeSettings.ClientConfig(section ?? string.Empty)
    };

    private static QosConfigInfo EmptyQos() => new()
    {
        mBandwidthPingSiteInfo = new QosPingSiteInfo { mAddress = "127.0.0.1", mPort = 0, mSiteName = "local" },
        mNumLatencyProbes = 0,
        mPingSiteInfoByAliasMap = new SortedDictionary<string, QosPingSiteInfo>(),
        mServiceId = 0
    };

    private static GetTelemetryServerResponse EmptyTelemetry() => new()
    {
        mAddress = string.Empty,
        mDisable = "1",
        mFilter = string.Empty,
        mIsAnonymous = true,
        mKey = string.Empty,
        mLocale = 0,
        mNoToggleOk = "1",
        mPort = 0,
        mSendDelay = 0,
        mSendPercentage = 0,
        mSessionID = Fut13BridgeSettings.SessionKey,
        mUseServerTime = "1"
    };

    private static PssConfig EmptyPss() => new()
    {
        mAddress = string.Empty,
        mInitialReportTypes = 0,
        mNpCommSignature = [],
        mOfferIds = [],
        mPort = 0,
        mProjectId = "FIFA13",
        mTitleId = 0
    };

    // Text the client renders on screen, keyed by the Blaze string id it asked
    // for through LocalizeStrings.  An id we do not know is echoed back
    // unchanged, so a missing entry shows up in-game as the raw id.
    //
    // These are English, while the account itself is hardcoded to a French
    // locale elsewhere: Fut13AuthenticationComponent.cs sets mCountry "FR",
    // mLanguage "fr_FR" and mAccountLocale 0x66724652 ("frFR").  Nothing here
    // looks at the session locale, so the two deliberately disagree for now.
    // Making both follow the locale the client actually asks for - one string
    // table per locale, and an account locale derived from it - is an open
    // improvement, not a decision.
    private static string LocalText(string id) => id switch
    {
        "SDB_ORIGIN_ACCT_WELCOME_BACK_HEADER" => "FUT13 local account",
        "SDB_ORIGIN_ACCT_WELCOME_BACK_BODY" => "Your local profile is ready.",
        "SDB_EMAIL_ADD" => "Local address",
        "SDB_ORIGIN_ACCT_UPDATE_EMAIL_PASS" => "No EA account is used.",
        "SDB_CONTINUE" => "Continue",
        "SDB_BACK" => "Back",
        "SDB_ORIGIN_ACCT_OPTIN_HEADER" => "Local preferences",
        "SDB_ORIGIN_ACCT_OPTIN_BODY" => "Services are emulated locally.",
        "SDB_ORIGIN_ACCT_SIGNUP_FOR_EA_INFO" => "Do not contact EA",
        "SDB_INFO_SHARING" => "No data shared",
        "SDB_ORIGIN_ACCOUNT_CREATION_SUCCESS" => "Local profile created",
        "SDB_ORIGIN_ACCT_INFO_TO_SHARE" => "Data kept on this PC",
        "SDB_ORIGIN_ACCT_SIGNUP_FOR_ORIGIN_INFO" => "No Origin account required",
        "SDB_ORIGIN_ACCT_SIGNUP_FOR_PARTNER_INFO" => "No partner contacted",
        _ => id
    };
}

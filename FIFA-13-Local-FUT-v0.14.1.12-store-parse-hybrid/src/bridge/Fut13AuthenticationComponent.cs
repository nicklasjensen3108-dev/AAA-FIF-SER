using Blaze3SDK.Blaze;
using Blaze3SDK.Blaze.Authentication;
using Blaze3SDK.Components;
using BlazeCommon;

namespace Fut13Local.Bridge;

internal sealed class Fut13AuthenticationComponent : AuthenticationComponentBase.Server
{
    // FIFA 13's native startup first presents its locally supplied auth token
    // to the legacy login command (0x28), rather than ExpressLogin.
    public override Task<LoginResponse> LoginAsync(LoginRequest request, BlazeRpcContext context)
    {
        context.State = CreateSession();
        return Task.FromResult(new LoginResponse
        {
            mIsOfLegalContactAge = true,
            mLegalDocHost = string.Empty,
            mNeedsLegalDoc = false,
            mPCLoginToken = Fut13BridgeSettings.AuthToken,
            mPersonaDetailsList = [CreatePersona()],
            mPrivacyPolicyUri = string.Empty,
            mSessionKey = Fut13BridgeSettings.SessionKey,
            mTermsOfServiceUri = string.Empty,
            mTosHost = string.Empty,
            mTosUri = string.Empty,
            mUserId = Fut13BridgeSettings.UserId
        });
    }

    public override Task<FullLoginResponse> OriginLoginAsync(OriginLoginRequest request, BlazeRpcContext context) => Login(context);
    public override Task<FullLoginResponse> ExpressLoginAsync(ExpressLoginRequest request, BlazeRpcContext context) => Login(context);
    public override Task<FullLoginResponse> SilentLoginAsync(SilentLoginRequest request, BlazeRpcContext context) => Login(context);
    public override Task<SessionInfo> LoginPersonaAsync(LoginPersonaRequest request, BlazeRpcContext context)
    {
        context.State = CreateSession();
        var extendedData = CreateExtendedData();

        // Legacy Blaze clients wait for their own UserSessions notifications
        // immediately after selecting the persona.
        _ = context.BlazeConnection.NotifyAsync(UserSessionsBase.Id, 8,
            new Fut13UserAuthenticatedNotification
            {
                mSUBS = true,
                mBlazeUserId = Fut13BridgeSettings.UserId
            }, true);
        _ = UserSessionsBase.Server.NotifyUserAddedAsync(context.BlazeConnection, new NotifyUserAdded
        {
            mExtendedData = extendedData,
            mUserInfo = CreateUserIdentification()
        });
        _ = UserSessionsBase.Server.NotifyUserSessionExtendedDataUpdateAsync(context.BlazeConnection,
            new UserSessionExtendedDataUpdate
            {
                mExtendedData = extendedData,
                mUserId = Fut13BridgeSettings.UserId
            });

        return Task.FromResult(CreateSession());
    }
    public override Task<GetAuthTokenResponse> GetAuthTokenAsync(NullStruct request, BlazeRpcContext context) =>
        Task.FromResult(new GetAuthTokenResponse { mAuthToken = Fut13BridgeSettings.AuthToken });
    public override Task<ListPersonasResponse> ListPersonasAsync(NullStruct request, BlazeRpcContext context) =>
        Task.FromResult(new ListPersonasResponse { mList = [CreatePersona()] });
    public override Task<NullStruct> HasEntitlementAsync(HasEntitlementRequest request, BlazeRpcContext context) =>
        Task.FromResult(new NullStruct());
    public override Task<AccountInfo> GetAccountAsync(NullStruct request, BlazeRpcContext context) =>
        Task.FromResult(new AccountInfo
        {
            mAnonymousUser = false,
            mAuthenticationSource = "300001",
            mCountry = "FR",
            mDOB = "1990-01-01",
            mDateCreated = "2012-09-01T00:00:00Z",
            mEmail = "fut13@local.invalid",
            mEmailStatus = EmailStatus.VERIFIED,
            mGlobalOptin = 0,
            mLanguage = "fr_FR",
            mLastAuth = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString(),
            mParentalEmail = string.Empty,
            mReasonCode = StatusReason.NONE,
            mStatus = AccountStatus.ACTIVE,
            mThirdPartyOptin = 0,
            mTosVersion = "local",
            mUnderageUser = false,
            mUserId = Fut13BridgeSettings.UserId
        });
    public override Task<UpdateAccountResponse> UpdateAccountAsync(UpdateAccountRequest request, BlazeRpcContext context) =>
        Task.FromResult(new UpdateAccountResponse { mPCLoginToken = Fut13BridgeSettings.AuthToken });
    public override Task<NullStruct> AcceptTosAsync(AcceptTosRequest request, BlazeRpcContext context) =>
        Task.FromResult(new NullStruct());
    public override Task<GetTosInfoResponse> GetTosInfoAsync(GetTosInfoRequest request, BlazeRpcContext context) =>
        Task.FromResult(new GetTosInfoResponse
        {
            mEaMayContact = 0,
            mPartnersMayContact = 0,
            mPrivacyPolicyUri = string.Empty,
            mTosHost = string.Empty,
            mTosUri = string.Empty
        });
    public override Task<GetLegalDocsInfoResponse> GetLegalDocsInfoAsync(GetLegalDocsInfoRequest request, BlazeRpcContext context) =>
        Task.FromResult(new GetLegalDocsInfoResponse
        {
            mEaMayContact = 0,
            mLegalDocHost = string.Empty,
            mPartnersMayContact = 0,
            mPrivacyPolicyUri = string.Empty,
            mTermsOfServiceUri = string.Empty
        });
    public override Task<Entitlements> ListUserEntitlements2Async(ListUserEntitlements2Request request, BlazeRpcContext context) =>
        Task.FromResult(CreateEntitlements());
    public override Task<Entitlements> ListEntitlementsAsync(ListEntitlementsRequest request, BlazeRpcContext context) =>
        Task.FromResult(CreateEntitlements());
    public override Task<NullStruct> LogoutAsync(NullStruct request, BlazeRpcContext context) => Task.FromResult(new NullStruct());
    public override Task<NullStruct> LogoutPersonaAsync(NullStruct request, BlazeRpcContext context) => Task.FromResult(new NullStruct());

    private static Task<FullLoginResponse> Login(BlazeRpcContext context)
    {
        context.State = CreateSession();
        return Task.FromResult(new FullLoginResponse
        {
            mCanAgeUp = false,
            mIsOfLegalContactAge = true,
            mLegalDocHost = string.Empty,
            mNeedsLegalDoc = false,
            mPCLoginToken = Fut13BridgeSettings.AuthToken,
            mPrivacyPolicyUri = string.Empty,
            mSessionInfo = CreateSession(),
            mTermsOfServiceUri = string.Empty,
            mTosHost = string.Empty,
            mTosUri = string.Empty
        });
    }

    private static SessionInfo CreateSession() => new()
    {
        mBlazeUserId = Fut13BridgeSettings.UserId,
        mEmail = "fut13@local.invalid",
        mIsFirstLogin = false,
        mLastLoginDateTime = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
        mPersonaDetails = CreatePersona(),
        mSessionKey = Fut13BridgeSettings.SessionKey,
        mUserId = Fut13BridgeSettings.UserId
    };

    private static PersonaDetails CreatePersona() => new()
    {
        mDisplayName = Fut13BridgeSettings.PersonaName,
        mExtId = 0,
        mExtType = ExternalRefType.BLAZE_EXTERNAL_REF_TYPE_LEGACYPROFILEID,
        mLastAuthenticated = (uint)DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
        mPersonaId = Fut13BridgeSettings.PersonaId,
        mStatus = PersonaStatus.ACTIVE
    };

    private static UserIdentification CreateUserIdentification() => new()
    {
        mAccountId = Fut13BridgeSettings.UserId,
        mAccountLocale = 0x66724652, // frFR
        mBlazeId = Fut13BridgeSettings.UserId,
        mExternalBlob = [],
        mExternalId = 0,
        mName = Fut13BridgeSettings.PersonaName
    };

    private static UserSessionExtendedData CreateExtendedData() => new()
    {
        mBestPingSiteAlias = "local",
        mBlazeObjectIdList = [],
        mClientAttributes = new SortedDictionary<uint, int>(),
        mCountry = "FR",
        mDataMap = new SortedDictionary<uint, long>(),
        mLatencyList = []
    };

    private static Entitlements CreateEntitlements() => new()
    {
        mEntitlements =
        [
            // This is the entitlement filter requested by the retail FIFA 13
            // client immediately before it enters FUT.
            new Entitlement
            {
                mDeviceUri = string.Empty,
                mEntitlementTag = "ONLINE_ACCESS",
                mEntitlementType = EntitlementType.ONLINE_ACCESS,
                mGrantDate = "2012-09-01T00:00:00Z",
                mGroupName = "FIFA13PCBoxContent",
                mId = 1,
                mIsConsumable = false,
                mPersonaId = Fut13BridgeSettings.PersonaId,
                mProductCatalog = ProductCatalog.OFB,
                mProductId = "fifa13_pc",
                mProjectId = "FIFA13",
                mStatus = EntitlementStatus.ACTIVE,
                mStatusReasonCode = StatusReason.NONE,
                mTerminationDate = string.Empty,
                mUseCount = 0,
                mVersion = 1
            },
            new Entitlement
            {
                mDeviceUri = string.Empty,
                mEntitlementTag = "FIFA13PCFUTContentUnlocks",
                mEntitlementType = EntitlementType.ONLINE_ACCESS,
                mGrantDate = "2012-09-01T00:00:00Z",
                mGroupName = "FIFA13PC",
                mId = 2,
                mIsConsumable = false,
                mPersonaId = Fut13BridgeSettings.PersonaId,
                mProductCatalog = ProductCatalog.OFB,
                mProductId = "fifa13_pc",
                mProjectId = "FIFA13",
                mStatus = EntitlementStatus.ACTIVE,
                mStatusReasonCode = StatusReason.NONE,
                mTerminationDate = string.Empty,
                mUseCount = 0,
                mVersion = 1
            }
        ]
    };
}

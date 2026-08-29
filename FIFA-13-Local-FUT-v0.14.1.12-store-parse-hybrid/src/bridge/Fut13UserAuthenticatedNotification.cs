using Tdf;

namespace Fut13Local.Bridge;

// UserSessions::UserAuthenticated (notification 8) is used by the legacy
// client to transition its selected persona into an authenticated session.
[TdfStruct]
internal struct Fut13UserAuthenticatedNotification
{
    [TdfMember("SUBS")]
    public bool mSUBS;

    [TdfMember("BUID")]
    public long mBlazeUserId;
}

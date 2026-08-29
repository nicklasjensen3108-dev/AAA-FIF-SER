using Blaze3SDK.Blaze;
using Blaze3SDK.Blaze.Association;
using Blaze3SDK.Blaze.Stats;
using Blaze3SDK.Components;
using BlazeCommon;

namespace Fut13Local.Bridge;

// These are local, empty implementations of optional social-service calls
// issued while FIFA 13 initializes its online shell.
internal sealed class Fut13CensusDataComponent : CensusDataComponentBase.Server
{
    public override Task<NullStruct> SubscribeToCensusDataAsync(NullStruct request, BlazeRpcContext context) => Empty();
    public override Task<NullStruct> UnsubscribeFromCensusDataAsync(NullStruct request, BlazeRpcContext context) => Empty();
    private static Task<NullStruct> Empty() => Task.FromResult(new NullStruct());
}

internal sealed class Fut13AssociationListsComponent : AssociationListsComponentBase.Server
{
    public override Task<Lists> GetListsAsync(GetListsRequest request, BlazeRpcContext context) =>
        Task.FromResult(new Lists { mListMembersVector = [] });
}

internal sealed class Fut13StatsComponent : StatsComponentBase.Server
{
    public override Task<KeyScopes> GetKeyScopesMapAsync(NullStruct request, BlazeRpcContext context) =>
        Task.FromResult(new KeyScopes { mKeyScopesMap = new SortedDictionary<string, KeyScopeItem>() });

    public override Task<StatGroupList> GetStatGroupListAsync(NullStruct request, BlazeRpcContext context) =>
        Task.FromResult(new StatGroupList { mGroups = [] });

    public override Task<PeriodIds> GetPeriodIdsAsync(NullStruct request, BlazeRpcContext context) =>
        Task.FromResult(new PeriodIds
        {
            mCurrentDailyPeriodId = 0,
            mCurrentMonthlyPeriodId = 0,
            mCurrentWeeklyPeriodId = 0,
            mDailyBuffer = 0,
            mDailyHour = 0,
            mDailyRetention = 0,
            mMonthlyBuffer = 0,
            mMonthlyDay = 0,
            mMonthlyHour = 0,
            mMonthlyRetention = 0,
            mWeeklyBuffer = 0,
            mWeeklyDay = 0,
            mWeeklyHour = 0,
            mWeeklyRetention = 0
        });
}

internal sealed class Fut13MessagingComponent : MessagingComponentBase.Server
{
    public override Task<NullStruct> FetchMessagesAsync(NullStruct request, BlazeRpcContext context) =>
        Task.FromResult(new NullStruct());
}

internal sealed class Fut13RoomsComponent : RoomsComponentBase.Server
{
    public override Task<NullStruct> SelectViewUpdatesAsync(NullStruct request, BlazeRpcContext context) => Empty();
    public override Task<NullStruct> SelectCategoryUpdatesAsync(NullStruct request, BlazeRpcContext context) => Empty();
    public override Task<NullStruct> ToggleJoinedRoomNotificationsAsync(NullStruct request, BlazeRpcContext context) => Empty();
    private static Task<NullStruct> Empty() => Task.FromResult(new NullStruct());
}

internal sealed class Fut13ClubsComponent : ClubsComponentBase.Server
{
    public override Task<NullStruct> GetClubsComponentSettingsAsync(NullStruct request, BlazeRpcContext context) =>
        Task.FromResult(new NullStruct());
    public override Task<NullStruct> GetInvitationsAsync(NullStruct request, BlazeRpcContext context) =>
        Task.FromResult(new NullStruct());
}

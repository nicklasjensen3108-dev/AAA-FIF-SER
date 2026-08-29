using Blaze3SDK.Blaze;
using Blaze3SDK.Components;
using BlazeCommon;

namespace Fut13Local.Bridge;

internal sealed class Fut13UserSessionsComponent : UserSessionsBase.Server
{
    public override Task<NullStruct> FetchExtendedDataAsync(NullStruct request, BlazeRpcContext context) => Empty();
    public override Task<NullStruct> UpdateExtendedDataAttributeAsync(NullStruct request, BlazeRpcContext context) => Empty();
    public override Task<NullStruct> UpdateHardwareFlagsAsync(UpdateHardwareFlagsRequest request, BlazeRpcContext context) => Empty();
    public override Task<NullStruct> UpdateNetworkInfoAsync(NetworkInfo request, BlazeRpcContext context) => Empty();
    public override Task<NullStruct> UpdateUserSessionClientDataAsync(NullStruct request, BlazeRpcContext context) => Empty();
    public override Task<NullStruct> SetUserInfoAttributeAsync(NullStruct request, BlazeRpcContext context) => Empty();
    public override Task<NullStruct> ResumeSessionAsync(NullStruct request, BlazeRpcContext context) => Empty();
    public override Task<UserDataResponse> LookupUsersAsync(LookupUsersRequest request, BlazeRpcContext context) =>
        Task.FromResult(new UserDataResponse { mUserDataList = [] });

    private static Task<NullStruct> Empty() => Task.FromResult(new NullStruct());
}

using Blaze3SDK.Blaze;
using BlazeCommon;
using Tdf;

namespace Fut13Local.Bridge;

// FIFA 13 requests this private OSDK component after the generic online-shell
// services are ready. The two ticker settings below match the legacy OSDK
// bootstrap schema and remain entirely local.
internal sealed class Fut13OsdkSettingsComponent :
    BlazeServerComponent<Fut13OsdkSettingsCommand, Fut13OsdkSettingsNotification, Fut13OsdkSettingsError>
{
    public Fut13OsdkSettingsComponent() : base(2249, "OsdkSettings") { }

    [BlazeCommand((ushort)Fut13OsdkSettingsCommand.FetchSettings)]
    public Task<Fut13OsdkSettingsResponse> FetchSettingsAsync(NullStruct request, BlazeRpcContext context) =>
        Task.FromResult(new Fut13OsdkSettingsResponse
        {
            mSettings =
            [
                new Fut13OsdkSetting { mId = "O_TKfilter", mLocaleFlag = 0, mToggle = 0 }
            ]
        });

    [BlazeCommand((ushort)Fut13OsdkSettingsCommand.FetchGroups)]
    public Task<Fut13OsdkSettingGroupsResponse> FetchGroupsAsync(NullStruct request, BlazeRpcContext context) =>
        Task.FromResult(new Fut13OsdkSettingGroupsResponse
        {
            mGroups =
            [
                new Fut13OsdkSettingGroup { mId = "O_SG_TCKR", mSettings = ["O_TKfilter"] }
            ]
        });

    public override Type GetCommandRequestType(Fut13OsdkSettingsCommand command) => typeof(NullStruct);
    public override Type GetCommandResponseType(Fut13OsdkSettingsCommand command) => command switch
    {
        Fut13OsdkSettingsCommand.FetchSettings => typeof(Fut13OsdkSettingsResponse),
        Fut13OsdkSettingsCommand.FetchGroups => typeof(Fut13OsdkSettingGroupsResponse),
        _ => typeof(NullStruct)
    };
    public override Type GetCommandErrorResponseType(Fut13OsdkSettingsCommand command) => typeof(NullStruct);
    public override Type GetNotificationType(Fut13OsdkSettingsNotification notification) => typeof(NullStruct);
}

internal enum Fut13OsdkSettingsCommand : ushort { FetchSettings = 1, FetchGroups = 2 }
internal enum Fut13OsdkSettingsNotification : ushort { None = 0 }
internal enum Fut13OsdkSettingsError : ushort { None = 0 }

[TdfStruct]
public struct Fut13OsdkSetting
{
    [TdfMember("ID")] public string mId;
    [TdfMember("LOCF")] public uint mLocaleFlag;
    [TdfMember("TOGG")] public uint mToggle;
}

[TdfStruct]
public struct Fut13OsdkSettingsResponse
{
    [TdfMember("LSST")] public List<Fut13OsdkSetting> mSettings;
}

[TdfStruct]
public struct Fut13OsdkSettingGroup
{
    [TdfMember("ID")] public string mId;
    [TdfMember("LSET")] public List<string> mSettings;
}

[TdfStruct]
public struct Fut13OsdkSettingGroupsResponse
{
    [TdfMember("LGRP")] public List<Fut13OsdkSettingGroup> mGroups;
}

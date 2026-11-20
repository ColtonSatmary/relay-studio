# Player control protocol evidence

Inspected read-only from installed ViPlex Express 3.0.5.1501 on 2026-11-18. This document contains no board credentials or authentication tokens. Research did not contact a player. Live compatibility must be established separately for the selected device and firmware.

Primary evidence:

- `C:\Program Files (x86)\Nova Star\ViPlex Express\Bin\Novc.Platform.DAL.Player.Access.dll`: reflection-only inspection of method IL, parameter classes, and JSON serialization attributes. Setters below use the HTTPS branch selected by port 16674.
- `Novc.ViPlex.Express.ScreenCtrl.dll`: UI view-model IL establishes mosaic direction/mode/ranges and the three color-temperature presets.
- `%ProgramData%\ViPlexExpress\Config\LogFile\2025-11-10\Nv.running_log.log` and logs for 2026-11-15/16: request/response shapes and successful native writes. Only relevant non-secret control records were inspected.

Authentication, serial checks, and certificate binding are identical to the publisher in `network-protocol.md`. A response is an envelope `{code:0,data:...,message:""}`. The adapter's `ReadControl` returns only serialized `data` and throws on envelope/HTTP errors. Do not infer success from HTTP status alone. A successful setter may omit `data` entirely.

## Endpoints

All paths below are under `/terminal/core/v1/`.

| Control | Read | Write | Data/body |
|---|---|---|---|
| Brightness | GET `brightness` | POST `brightness` | `{ratio:50.0}`; ratio is a percentage, not a 0..1 fraction |
| Brightness mode | GET `brightness/mode` | POST `brightness/mode` | `{source:{type:1,platform:2},type:"SCREEN_BRIGHTNESS",mode:"MANUALLY"}`; alternative mode `AUTO` |
| Color temperature | GET `colorTemperature` | POST `colorTemperature` | `{colorTemperature:6500}` |
| Multi-screen mosaic | GET `splice/hdmi` | POST `splice/hdmi` | `{enable:true,info:{direction:0,mode:0,totalLength:1920}}` |
| Clock/time zone | GET `time` | PUT `time` | See clock section below |
| Automatic time | GET `time/net/config` | POST `time/net/config` | See automatic-time section below |
| Ethernet | GET `net/ethernet/info` | POST `net/ethernet/info` | `{ethernets:[...]}` |
| Wi-Fi station enable | GET `wifi/station/state` | POST `wifi/station/state` | `{state:1}` enabled, `{state:0}` disabled |
| Wi-Fi nearby networks | GET `wifi/station/list` | — | `{result:[...]}` |
| Wi-Fi connect | — | POST `wifi/station/connect` | `{ssid,password,hiddenSSID:boolean,security}` |
| Wi-Fi AP enable | GET `wifi/ap/switch` | POST `wifi/ap/switch` | `{enable:boolean}` |

The initial Relay UI treats Wi-Fi as read-only. The write contract is evidenced but has not been tested in Relay; changing the station or AP can disconnect the only control path.

## Brightness and color

Recorded brightness read data: `{brightness:178,ratio:69.8,solidity:true,orderId:-1}`. Recorded write body: `{ratio:50.0}`. This is a scalar command: send only the requested ratio, never the previous raw brightness, order ID, solidity, or other read-only GET fields. Configuration preservation rules for mosaic/Ethernet do not apply to this scalar setter. A manual slider must explicitly select `MANUALLY` before applying a ratio if automatic brightness is enabled; otherwise a policy may immediately override the value. The mode write also uses the native source/type/mode command rather than copying a GET response.

Native successful control setters commonly return `{code:0}` without a `data` property. Relay accepts this only for its allowlisted control writes; reads, login, transfer preparation, and uploads still require their expected data. A control acknowledgment is followed by a readback. Brightness verifies both the ratio and, when supplied, the numeric 0..255 raw output within one unit of `255 * ratio / 100`. The live test T50 returned raw output 128 with ratio 50; older native logs show raw 127 for the same ratio. Malformed ratio values and an unchanged raw output cannot be reported as verified.

`UC_ColorTemperatureViewModel.SwitchIsChecked` compares exactly **4700**, **6500**, **9300** and maps them to neutral white, standard white, and cool white respectively. These three presets are supported by the initial adapter; a general arbitrary Kelvin range was not established. Read and write data use the same `colorTemperature` property.

## Multi-screen mosaic

`AutoSpliceViewModel.SetInterfaceInfo` establishes:

- `direction:0` means left to right; `1` means right to left.
- `mode:0` means number of screens; `1` means total width.
- In count mode, `totalLength = selectedPlayerOutputWidth * screenCount`.
- In width mode, `totalLength` is the entered width; native UI clamps width at **4096** pixels.
- Maximum screen count comes from `info.spliceHdmiConfig.autoSpliceHdmiConfig.maxNum` when present. A T50 log reports 10. Do not assume 10 for every firmware.

Read example:

```json
{"enable":false,"info":{"direction":1,"mode":0,"spliceHdmiConfig":{"autoSpliceHdmiConfig":{"maxNum":10}},"totalLength":640}}
```

The installed managed serializer names the nested field `autospliceHdmiConfig` (lowercase `s`), while real GET responses use `autoSpliceHdmiConfig`. Preserve the original JSON spelling/unknown nested fields; do not reconstruct the whole object using the managed model. This control is the native automatic HDMI mosaic control, not a general independent x/y crop editor.

## Clock/time zone

Recorded GET data:

```json
{"currentTime":"2025-11-10 13:31:50","isTimeOffsetEnable":false,"timeOffsetValue":0,"timeZone":"America/Los_Angeles","utcTimeMillis":1762810310026,"orderId":-1}
```

The installed `Sysset.TimeAndZone` model serializes these properties: `utcTimeMillis` (int64 milliseconds since Unix epoch), `timeZone` (IANA zone string), `gmt` (string), `isTimeOffsetEnable` (boolean), `beginTime` and `endTime` (strings), `timeOffsetValue` (int64). It additionally has public `zoneOffset` (string) and `dstEnable` (boolean) fields. Treat custom-offset/DST data as opaque unless the user explicitly edits it.

Native UTC correction sample:

```json
{"utcTimeMillis":1762810512000,"isTimeOffsetEnable":false,"timeOffsetValue":0}
```

Native zone-only sample:

```json
{"utcTimeMillis":0,"timeZone":"America/Los_Angeles","gmt":"GTM-08:00","isTimeOffsetEnable":false,"timeOffsetValue":0}
```

The zero UTC value is the installed setter's leave-clock-alone sentinel for zone-only changes. Do not resend an old read timestamp for such an edit. The native `gmt` prefix is spelled `GTM` in these logs. Existing custom-offset/DST settings should survive ordinary UTC corrections; blindly constructing the native model with defaults would clear them.

Relay validates the IANA zone against the installed `NodaTime.dll` 2.4.18 time-zone database and derives `gmt` from `GetZoneInterval(instant).StandardOffset` (not the daylight-saving wall offset). This is a local pure date/time-library call, not vendor session code or a hardware request. Zone-only edits use the player read timestamp as reference; simultaneous clock-and-zone edits use the requested timestamp. Fractional-hour offsets are preserved. Missing time-zone data or an unknown ID prevents the write.

Read DST information: GET `time/day/light?timeZone=<URL-encoded IANA zone>`, response data `{isUseDayLightTime:false,timeOffsetValue:0}`. This reports zone/daylight information; it is not an instruction to reset the player's custom-offset settings.

### Automatic time

Relay's **Sync from browser** sends both a fresh `utcTimeMillis` and the browser's resolved IANA `timeZone`; it does not reuse a previously selected player zone. The server still validates the zone with NodaTime and computes the native `gmt` value. Bulk clock synchronization obtains a fresh UTC timestamp as each queued board starts, rather than copying one stale batch-start time. Time-zone-only changes omit `utcTimeMillis` from the requested values so the backend uses the native leave-clock-alone sentinel.

The single-player UI exposes every control section in one scrollable view. Bulk controls expose brightness, color temperature, automatic multi-mosaic, manual date/time, browser clock+zone sync, and time-zone-only actions together. Each Apply button creates an immutable selected-setting snapshot; two independent per-board jobs run concurrently through the existing authenticated controls API. Every recipient and mosaic geometry is validated before the first write. Each board's current configuration is reread on the worker before editing, preserving fields such as mosaic position and interface identity. Network addressing remains per-board.

Bulk controls retain operation IDs and sanitized results in browser memory, with no password persistence beyond the existing protected default-password store. The tab must remain open until all queued controls start and finish. An interrupted response is marked unconfirmed; checking known operation IDs only reads status and never automatically replays a write. A job is displayed as verified only when the worker's setting readback reports `verified:true`. These bulk-queue behaviors are covered by `bulk-controls.test.cjs` with synthetic jobs; no hardware changes are made by those tests.

`time/net/config` GET data can contain:

```json
{
  "compatibility":{"supportLoraInfo":true},
  "enable":false,
  "gps":{"enable":false},
  "lora":{"address":1,"channel":23,"enable":false,"groupId":"","interval":600,"mode":"MASTER","regulation":{"brightnessEnable":false,"environmentalMonitoring":false,"timeEnable":false,"volumeEnable":false},"retryCount":2,"orderId":-1},
  "ntp":{"enable":false,"ntpDeviceSN":"","ntpLocal":false,"ntpLocalPort":16672,"server":"","orderId":-1},
  "orderId":-1
}
```

Do not rebuild this object from the incomplete managed model: doing so drops radio regulation/interval/retry/port fields. The initial Relay adapter does not edit automatic-time configuration. It refuses manual clock changes when top-level `enable` or an `ntp/gps/lora.enable` flag is true, and refuses if synchronization mode cannot be read. Time-zone-only changes remain possible.

`TimeManager.GetNTPInfo/SetNTPInfo` use GET/POST `time/ntp/config`; the common command helper unwraps the task payload for HTTPS. NTP server configuration is a separate endpoint seen in native logs, `time/ntp/server/config`. These do not justify editing NTP server behavior without checking returned capability/configuration.

## Ethernet and Wi-Fi

Ethernet data/body:

```json
{"ethernets":[{"dhcp":true,"dns":["192.168.99.1","0.0.0.0"],"gateWay":"192.168.99.1","ip":"192.168.99.20","mask":"255.255.255.0","name":"eth0","scopeId":-1}]}
```

Interface identity is `name` plus returned `scopeId`. Preserve untouched interfaces and unknown properties. Gateway spelling is **`gateWay`**. DNS is an array. The native log uses `0.0.0.0` for an unused DNS slot. DHCP may change reported addresses after a write; static address/mask/gateway must describe a usable host on the subnet. A write that loses the session is uncertain, not automatically safe to retry. Read back or reconnect at the new address and verify the same serial.

Wi-Fi list data:

```json
{"result":[{"ssid":"Example","bssid":"example-bssid","frequency":2412,"level":4,"security":"PSK:WPA2","state":5}]}
```

Other native security value observed: `NONE`. Use the scanned security value; do not invent constants. Station connection state enum: 0 Idle, 1 Configured, 2 Connecting, 3 Authoring, 4 ObtainingIpAddress, 5 Connected, 6 PasswordError, 7 OtherFailed, 8 Disconnected, 9 Disconnecting. The `wifi/station/state` top-level radio enable integer is a different meaning from the per-network `state` enum.

`WifiManager.TryConnect` confirms the connect POST body has `ssid`, raw Wi-Fi `password`, `hiddenSSID` boolean, and `security`. The credentials belong only in the TLS request and transient server memory; never include them in response/UI diagnostics. `wifi/ap/ap/account` responses also contain credentials and are not included in Relay's read inventory.

The legacy `GetWifiIPConfig/SetWifiIPConfig` methods use a binary business-session command, with no HTTPS branch in this installed DAL. Their `ssid/password/isStaticIp/hiddenSSID/security/gateWay/ip/mask/dns` model does not prove an HTTPS static-Wi-Fi endpoint. Do not guess one.

## Read-only publication verification

### Output geometry during UDP failure

GET `monitor/receivercard/info` is confirmed by `MonitorInfoDAL.GetReceiveCardRegionInfo` and native traffic to the live test player's IP on 2026-11-18 at 10:44:19.924. Response data has `receiveCardRegionInfo`, an array of receiver regions with uppercase `X`/`Y` and lowercase `width`/`height` plus port/connection metadata. The recorded six regions each measure 320 by 180, with X=0 and Y=0,180,360,540,720,900, producing extents 320 by 1080. This provides a read-only geometry source after authenticated HTTPS identity checking when UDP discovery fails; validate region numbers and extents before trusting them. Do not confuse GET `video/source/inside/current/resolution/get` (`{value:"1920x1080p-60"}` in logs) with physical LED output geometry: that endpoint describes the internal source canvas. The legacy `GetPlayconfigInfo` method has no HTTPS branch in the installed DAL, so its existence does not establish another HTTPS resolution URL.

`PlaySolutionManager.GetAllPlaySolutionDiscriptions` confirms GET `play/program/list`. Data contains `programInfos`, each with `identifier`, `name`, `statusCode`, `thumbnailUrl`, `type`, `source`, and possibly `isSupportMd5Checkout`. The callback assigns `ReadSolutionlData.statusCode` directly to `SolutionDiscription.PlayState`: 0 Stopped, 1 Paused, 2 Playing, 3 Stopped2. Matching the staged identifier and status 2 gives independent device-reported playback evidence; merely finding the name is insufficient.

These labels are the installed SDK's interpretation, not direct visual evidence. In the current session the user reported visible playback while the program list reported status 1; preserve that distinction and do not reject a successful completion response solely because this status is 1.

`Publisher.OnSucessTransfer` handles final publication responses as follows: a null `result.t` calls `OnAllCompleted`; a non-null `EndTransferSuccessInfo` with `errorType == 0` also completes; nonzero `errorType` becomes a `RequestError` whose error code is that numeric value and description is `errorStr`. No enum defining every remote end-transfer error value was found. `ProgramRunningErrorType` (-1 through -8) belongs to a separate program-running error flow and should not be guessed as the end-transfer mapping. Native success with omitted/null `data` therefore exists in the SDK semantics, even though local successful end-transfer logs sampled here returned `{errorType:0,errorStr:"SUCCESS"}` explicitly.

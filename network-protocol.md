# Network publishing evidence

The adapter targets the HTTPS protocol used by the installed ViPlex Express 3.0.5.1501 with the remembered NovaStar T50 players. It was validated against the live test T50 on November 18, 2026; this is not a claim of compatibility with every NovaStar firmware.

## Live validation and connection recovery

The operator authorized tests on a live T50. A final upload returned a successful playback acknowledgment, and the operator confirmed the visible switch between two distinct test solutions. The receipt recorded 20,559 program bytes uploaded and one existing media file reused. Device identifiers and private media names are omitted from this public record.

Observed failures included intermittent TCP resets, UDP discovery failing while HTTPS remained reachable, and Relay reporting an unconfirmed playback response. Reviewing the native SDK also exposed a null completion case Relay had been rejecting. The transport now uses TLS 1.2, an isolated persistent connection group per session, bounded connection-reset recovery for login and GET, and 120-second file-transfer timeouts. Mutating requests are not replayed. Tests verify each transfer start/end, file upload, and control write is sent once when its response is reset. The .NET Framework may internally replay a GET, so one application retry can produce up to four read attempts.

Discovery queries repeat within their time budget. When initial UDP discovery times out, a GET to the fixed `/terminal/core/v1/version` HTTPS endpoint obtains `sn`, `aliasName`, and `productName`, capturing the certificate before credentials are sent. An expected serial mismatch stops login. The following login uses that certificate pin and verifies the serial again. GET `/terminal/core/v1/monitor/receivercard/info` supplies output geometry from `receiveCardRegionInfo`; it must not be confused with the internal video canvas. Subsequent operations use the server-owned checked identity and pin without requiring UDP discovery again.

The native publisher accepts a successful outer response with null completion data. Relay now accepts that case too; a non-null completion object must contain `errorType:0`. Malformed objects and nonzero statuses remain errors. Player-list status was not used as proof of physical playback because the observed status conflicted with the operator's visual confirmation.

## Local evidence

- Remembered devices: `%ProgramData%\ViPlexExpress\Config\DB.SQLite`, table `nova_screenproto`. Read only `Sn`, `Alias`, `Ip`, `Width`, `Height`, and `ProductName`. The table also contains credentials, which must never be selected for the inventory API.
- Successful traffic: `Config\LogFile\2026-11-16\Nv.running_log.log` and `Nv.PublishLog.log`. The publisher used HTTPS port **16674**, even though the database retains legacy business/FTP ports.
- Discovery observations: `Nv.SearchLog.log` starts UDP listeners on **16600** and **16610**. Remembered addresses do not establish current reachability. Several different serials share `192.168.41.1`, the address used for earlier direct connections.
- Successful sequence: transfer start, required media uploads, program/thumbnail uploads, transfer end, then the publisher's `AllComplete` event.

## Authentication

The HTTPS login body has `sn`, `username`, `password`, `clientId` (32 hexadecimal characters), `clientName`, `loginType: 9`, and `source: {type: 0, platform: 2, platformVersion: "3.0.5"}`. The installed application sends the password in its original string form over HTTPS.

A successful response has `code: 0` and data containing `logined`, `sn`, `token`, `validation`, and the legacy spelling `validition`. It also contains credential fields: never log or forward the complete response. Verify the returned serial against the explicitly selected player. Managed SDK inspection confirms the `Authorization` header contains the returned token directly, without a `Bearer ` prefix.

## Transfer start

`PUT /terminal/core/v1/play/transfer/start` takes the following shape. `solutions` is a **single object**, not an array.

```json
{
  "deviceIdentifier": "publishing-client-name",
  "totalSize": 12345,
  "type": "DEFAULT",
  "local": false,
  "source": 0,
  "solutions": {"name": "Program name", "identifier": "planlist-file-md5"},
  "totalMediaSize": 2345678,
  "judgeForDevice": true,
  "checkFiles": ["media-md5.mp4"]
}
```

A successful response has `code: 0` and data with:

- `appliedInfos: {statusCode: 0, uploadUrl, identifier, name}` (single object).
- `canTranster: true` (the misspelling is part of the wire protocol), `errorCode: 0`.
- `checkFiles`: the media filenames that still need to be uploaded. A recorded request named eleven media files, the response named ten, and the subsequent publisher uploaded exactly those ten.
- `uploadMediaUrl` and `mediaInfo: {type: "LOCAL", uploadMediaUrl}`.
- `directoryInfos`, including `availableSize`, `totalSize`, `directoryUrl`, `reserveSize`, `criticalSize`, and `type`.

The returned destinations in observed sessions are relative player paths beneath `sdcard/nova/viplex_terminal/`. The program upload path is a temporary directory supplied by the player. Do not build a destination from a user-entered directory or accept arbitrary remote URLs.

## File uploads

The installed app uses its `HttpUploadOneFile2Async` method against `/terminal/tools/v1/file/uploadUseBinary?targetDir=...&fileName=...`. Each successful response has `code: 0`, `data.path`, and `message: "upload success"`. HTTP verb, content type, and token-header details come from managed SDK inspection; the log alone does not expose those headers.

Upload missing content-hashed media to the returned media directory. Upload the manifest, playlists, constraints, relations, cover thumbnail, and page thumbnails to the returned program directory. Schedules generated for USB place page thumbnails in sibling solution directories; `Export-StudioNetworkProgram` supplies a flattened, checksum-verified file list for the network destination.

## Completion

`PUT /terminal/core/v1/play/transfer/end` takes:

```json
{
  "confirmedInfos": {
    "identifier": "planlist-file-md5",
    "name": "Program name",
    "planListUrl": "returned-program-directory/planlist.json",
    "thumbnailUrl": "returned-program-directory/cover.png",
    "type": "DEFAULT"
  },
  "source": {"type": 1, "platform": 2},
  "delayTime": 0,
  "playTime": 0,
  "playImmediately": true,
  "isSupportMd5Checkout": true
}
```

Success is `code: 0` with `data: {errorStr: "SUCCESS", errorType: 0}`. The observed requests use `playImmediately: true`, so completion can change active playback. Merely finishing the file uploads is not successful publication. An upload failure is recorded as publisher error **39 / fileTransferError**; do not invoke completion after a failed upload.

No cancellation endpoint or successful upload-only (`playImmediately: false`) example was found in the local logs. Duplicate-name replacement semantics are not established by these records alone.

## Staging contract

`Export-StudioNetworkProgram` uses the existing solution/schedule manifest writers without writing `command.json`. It returns `programInfo`, `programDirectory`, `mediaDirectory`, `programFiles`, `pageThumbnailFiles`, `mediaFiles`, `totalSize`, `totalMediaSize`, dimensions, and content counts. File entries contain `fileName`, local `path`, `size`, and `md5`.

The content canvas and the player’s reported output dimensions are separate values. A player may render one tile of a larger mosaic canvas, so a size difference is informational and does not block publication. Relay does not infer that mosaic mode is configured, resize the content, or change player mosaic settings. Connection checks still bind publication to the checked serial and TLS certificate; resolution is not a device identity check.

`network-staging.test.ps1` checks remembered-device whitelisting and identity, then stages a native solution and timed schedule into temporary directories. It verifies checksums and thumbnail coverage and never contacts a player or writes the ViPlex database.

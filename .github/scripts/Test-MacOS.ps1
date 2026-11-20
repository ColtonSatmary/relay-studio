# Mac runtime integration. All media and credentials are synthetic; player
# transport is compiled/parsed but no physical player or USB is contacted.
param([switch]$CompileOnly, [switch]$DiskImage, [string]$AppRoot)
$ErrorActionPreference = 'Stop'
$repoRoot = if ($AppRoot) { [IO.Path]::GetFullPath($AppRoot) } else { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')) }
if ($PSVersionTable.PSEdition -ne 'Core') { throw 'Use PowerShell 7 for the macOS checks.' }
Write-Host ('PowerShell {0}; .NET {1}; {2}; architecture {3}' -f $PSVersionTable.PSVersion,[Environment]::Version,[Runtime.InteropServices.RuntimeInformation]::OSDescription,[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)
if ([Environment]::Version.Major -lt 9) { throw 'Use PowerShell 7.5 or newer on .NET 9 or newer for the macOS transport checks.' }
if (-not $CompileOnly -and -not $IsMacOS) { throw 'The runtime checks must run on macOS. -CompileOnly is available on other platforms.' }
if ($DiskImage -and $env:GITHUB_ACTIONS -cne 'true') { throw 'Disposable disk-image tests run only on an ephemeral GitHub Actions Mac runner.' }
function Assert-Mac([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-MacThrows([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Mac $rejected $Message
}

Push-Location -LiteralPath $repoRoot
try {
    . ./StudioNetwork.ps1
    Initialize-StudioNetworkTransport
    Add-Type -Path ./macos/StudioMacKeychain.cs
    Add-Type -Path ./macos/StudioMacUsbFiles.cs
    Add-Type -Path ./StudioPreviewStream.cs
    $json = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $value = $json.DeserializeObject('{"integer":42,"large":1795000000000,"items":[true,null,"sample"],"nested":{"ratio":50.5}}')
    Assert-Mac ($value['integer'] -eq 42 -and $value['large'] -eq 1795000000000L -and $value['items'][0]) 'The Core JSON adapter changed native protocol values.'
    $roundtrip = $json.DeserializeObject($json.Serialize($value))
    Assert-Mac ($roundtrip['nested']['ratio'] -eq 50.5 -and $roundtrip['items'].Count -eq 3) 'Native JSON serialization lost nested values.'
    $json.MaxJsonLength = 5
    Assert-MacThrows { $json.DeserializeObject('{"long":true}') } 'The native JSON response limit was ignored.'
    Write-Host 'Core transport, JSON adapter, Keychain, USB and preview helpers compiled.'
    if ($CompileOnly) { return }
    # Interface enumeration is read-only: do not initiate discovery broadcasts.
    $null = [RelayPlayerDiscovery]::GetNetworks()

    foreach ($test in @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.test.cjs' -File | Sort-Object Name)) {
        & node $test.FullName
        if ($LASTEXITCODE -ne 0) { throw ($test.Name + ' failed.') }
    }
    . ./StudioProject.ps1
    . ./StudioCatalog.ps1
    . ./StudioMedia.ps1
    . ./StudioSettings.ps1
    . ./StudioPlayerPreview.ps1
    . ./Viplex.ps1
    . ./ViplexUsb.ps1
    . ./StudioNetworkCatalog.ps1
    . ./StudioUsb.ps1

    # Pure metadata checks exercise the physical-USB boundary without touching
    # any real disk. Missing fields, internal disks and changed IDs fail closed.
    $diskInfo = @{Internal=$false;BusProtocol='USB';VirtualOrPhysical='Physical';Writable=$true;Whole=$true;DeviceIdentifier='disk99'}
    $volumeInfo = @{Internal=$false;Writable=$true;Mounted=$true;MountPoint='/Volumes/Fixture';DeviceIdentifier='disk99s1';ParentWholeDisk='disk99';DeviceNode='/dev/disk99s1';VolumeUUID='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';FilesystemType='msdos'}
    Assert-Mac (Test-StudioMacUsbInfo $volumeInfo $diskInfo) 'A valid synthetic USB identity was rejected.'
    foreach ($field in @('Internal','Writable','Mounted','MountPoint','DeviceIdentifier','ParentWholeDisk','DeviceNode','VolumeUUID','FilesystemType')) {
        $incomplete = $volumeInfo.Clone(); $incomplete.Remove($field)
        Assert-Mac (-not (Test-StudioMacUsbInfo $incomplete $diskInfo)) ('USB eligibility accepted missing ' + $field)
    }
    foreach ($change in @(@{Internal=$true},@{BusProtocol='SATA'},@{VirtualOrPhysical='Virtual'},@{Writable=$false},@{Whole=$false},@{DeviceIdentifier='disk98'})) {
        $unsafe = $diskInfo.Clone(); foreach ($key in $change.Keys) { $unsafe[$key] = $change[$key] }
        Assert-Mac (-not (Test-StudioMacUsbInfo $volumeInfo $unsafe)) 'USB eligibility accepted an internal, virtual, read-only or different disk.'
    }
    & {
        function Get-StudioMacUsbDrives { [pscustomobject]@{root='/Volumes/Fixture';id='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/disk99s1'} }
        $null = Get-StudioMacUsbTarget '/Volumes/Fixture' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/disk99s1'
        Assert-MacThrows { Get-StudioMacUsbTarget '/Volumes/Fixture' 'bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee/disk99s1' } 'A replacement volume UUID was accepted.'
        Assert-MacThrows { Get-StudioMacUsbTarget '/Volumes/Other' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/disk99s1' } 'A different USB mount point was accepted.'
    }

    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $fixtureLeaf = 'RelayMacCI-' + [guid]::NewGuid().ToString('N')
    $fixture = [IO.Directory]::CreateDirectory((Join-Path $tempParent $fixtureLeaf)).FullName
    $WorkspaceDirectory = [IO.Directory]::CreateDirectory((Join-Path $fixture 'workspace')).FullName
    $mediaRoot = Join-Path $WorkspaceDirectory 'Media'
    $configRoot = [IO.Directory]::CreateDirectory((Join-Path $fixture 'native-config')).FullName
    $server = $null; $volume = $null; $attachedDevice = $null; $keychainAccount = $null; $keychainCreated = $false; $imageAttached = $false
    try {
        $ffmpeg = Get-StudioMacFfmpegPath
        $jpeg = Join-Path $fixture 'Welcome.jpg'
        $png = Join-Path $fixture 'Still.png'
        $video = Join-Path $fixture 'Loop.mp4'
        foreach ($item in @(@($jpeg,'mjpeg'),@($png,'png'))) {
            $made = Invoke-StudioMacTool $ffmpeg @('-hide_banner','-nostdin','-f','lavfi','-i','color=c=orange:s=640x360','-frames:v','1','-threads','1','-c:v',$item[1],'-f','image2',$item[0])
            Assert-Mac ($made.code -eq 0 -and [IO.File]::Exists($item[0])) 'FFmpeg could not generate a still-image fixture.'
        }
        $made = Invoke-StudioMacTool $ffmpeg @('-hide_banner','-nostdin','-f','lavfi','-i','color=c=blue:s=320x180:r=10','-t','1','-threads','1','-c:v','libx264','-pix_fmt','yuv420p',$video)
        Assert-Mac ($made.code -eq 0 -and [IO.File]::Exists($video)) 'FFmpeg could not generate a video fixture.'

        # Use a unique workspace-scoped account, then delete only that account.
        $keychainAccount = Get-StudioMacPasswordAccount
        Assert-Mac ([RelayMacKeychain]::Read($keychainAccount) -ceq '') 'The disposable Keychain account unexpectedly already exists.'
        $syntheticPassword = 'CI fixture ' + [char]0x00E9 + [guid]::NewGuid().ToString('N')
        Set-StudioDefaultPlayerPassword $syntheticPassword
        $keychainCreated = $true
        Assert-Mac ((Get-StudioDefaultPlayerPassword) -ceq $syntheticPassword) 'macOS Keychain password round trip failed.'
        Assert-Mac (-not [IO.File]::Exists((Join-Path $WorkspaceDirectory 'player-settings.json'))) 'macOS wrote a password settings file instead of using Keychain.'
        Set-StudioDefaultPlayerPassword ''
        Assert-Mac ((Get-StudioDefaultPlayerPassword) -ceq '') 'Clearing the synthetic Keychain password failed.'
        $syntheticPassword = $null

        # The native SQLite binding is exercised against a newly created DB.
        $database = Join-Path $configRoot 'fixture.sqlite'
        $sqlite = Invoke-StudioMacTool '/usr/bin/sqlite3' @($database,'CREATE TABLE fixture (id INTEGER, name TEXT); INSERT INTO fixture VALUES (7, ''Generated'');')
        Assert-Mac ($sqlite.code -eq 0) 'Could not create the disposable SQLite fixture.'
        $rows = @(Read-StudioRows $database 'SELECT id, name FROM fixture')
        Assert-Mac ($rows.Count -eq 1 -and $rows[0].id -eq 7 -and $rows[0].name -ceq 'Generated') 'Native macOS SQLite import binding failed.'

        $winter = [DateTimeOffset]::Parse('2026-01-10T12:00:00Z').ToUnixTimeMilliseconds()
        $summer = [DateTimeOffset]::Parse('2026-07-10T12:00:00Z').ToUnixTimeMilliseconds()
        Assert-Mac ((Get-StudioMacBoardTimeZone 'America/Los_Angeles' $winter).gmt -ceq 'GTM-08:00') 'Winter player time-zone offset was incorrect.'
        Assert-Mac ((Get-StudioMacBoardTimeZone 'America/Los_Angeles' $summer).gmt -ceq 'GTM-08:00') 'DST was incorrectly added to the player standard offset.'
        Assert-MacThrows { Get-StudioMacBoardTimeZone '../../private' $winter } 'An invalid IANA zone was accepted.'

        $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
        $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
        $origin = 'http://127.0.0.1:' + $port
        $processInfo = [Diagnostics.ProcessStartInfo]::new()
        $processInfo.FileName = (Get-Process -Id $PID).Path
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardOutput = $true; $processInfo.RedirectStandardError = $true
        foreach ($argument in @('-NoLogo','-NoProfile','-File',(Join-Path $repoRoot 'Start-Studio.ps1'),'-NoBrowser','-WorkspaceDirectory',$WorkspaceDirectory,'-ExportRoot',(Join-Path $fixture 'exports'),'-Port',[string]$port)) { $processInfo.ArgumentList.Add($argument) }
        $server = [Diagnostics.Process]::Start($processInfo)
        $serverOutput = $server.StandardOutput.ReadToEndAsync(); $serverError = $server.StandardError.ReadToEndAsync()
        $session = $null
        for ($attempt = 0; $attempt -lt 150; $attempt++) {
            try { $session = Invoke-RestMethod ($origin + '/api/session') -TimeoutSec 2; break } catch {}
            if ($server.HasExited) { throw ('Mac service exited during startup: ' + $serverError.GetAwaiter().GetResult()) }
            Start-Sleep -Milliseconds 100
        }
        Assert-Mac ($null -ne $session -and $session.exportToken) 'The Mac HTTP service did not start.'
        $headers = @{Origin=$origin; 'X-Studio-Token'=$session.exportToken}
        $solutions = @()
        foreach ($path in @($jpeg,$png,$video)) {
            $name = [Uri]::EscapeDataString([IO.Path]::GetFileName($path))
            $result = Invoke-RestMethod ($origin + '/api/media?name=' + $name) -Method Post -Headers $headers -ContentType 'application/octet-stream' -InFile $path
            Assert-Mac ($result.solution.id -and $result.solution.name -ceq [IO.Path]::GetFileNameWithoutExtension($path)) 'HTTP media import lost the filename or solution identity.'
            $solutions += $result.solution
            $detail = Invoke-RestMethod ($origin + '/api/solutions/' + $result.solution.id)
            Assert-Mac ($detail.items.Count -eq 1 -and $detail.items[0].url -and $detail.width -gt 0) 'The imported solution preview detail was incomplete.'
            $download = Invoke-WebRequest ($origin + $detail.items[0].url) -Method Head
            Assert-Mac ([long]$download.Headers['Content-Length'][0] -gt 0) 'Imported media was not available from its preview URL.'
            $range = Invoke-WebRequest ($origin + $detail.items[0].url) -Headers @{Range='bytes=0-7'}
            Assert-Mac ($range.StatusCode -eq 206 -and $range.RawContentLength -eq 8) 'The preview route failed a bounded byte-range request.'
        }
        Assert-MacThrows { Invoke-RestMethod ($origin + '/api/media?name=Denied.jpg') -Method Post -ContentType 'image/jpeg' -InFile $jpeg } 'HTTP media import accepted a request without the session token.'
        $screen = [pscustomobject]@{id='ci-schedule';name='Generated schedule';width=1920;height=1080}
        $project = [pscustomobject]@{version=1;solutions=$solutions;screens=@($screen);cues=@([pscustomobject]@{id='ci-cue';screenId=$screen.id;solutionId=$solutions[0].id;startDate='2026-11-19';endDate='2026-11-19';start='09:00';end='09:15';days=@(4)})}
        $saved = Invoke-RestMethod ($origin + '/api/project') -Method Post -Headers $headers -ContentType 'application/json' -Body (@{baseRevision=$null;project=$project} | ConvertTo-Json -Depth 15)
        $loaded = Invoke-RestMethod ($origin + '/api/project')
        Assert-Mac ([IO.File]::Exists((Join-Path $WorkspaceDirectory 'workspace.json')) -and $loaded.project.cues[0].id -ceq 'ci-cue' -and $loaded.revision -ceq $saved.revision) 'The Mac service did not persist the schedule.'

        # Real native package generation, with all outputs inside the fixture.
        foreach ($type in @('solution','schedule')) {
            $id = if ($type -eq 'solution') { $solutions[0].id } else { $screen.id }
            $usbFolder = [IO.Directory]::CreateDirectory((Join-Path $fixture ('usb-' + $type))).FullName
            $receipt = Export-ViplexUsbPlayback -ConfigRoot $configRoot -Project $project -ProgramType $type -ProgramId $id -PlayerPassword 'synthetic-package-password' -OutputDirectory $usbFolder
            $nova = Join-Path $usbFolder 'nova'
            $package = Get-StudioUsbPackage $nova
            Assert-Mac ($package.files.Count -gt 0) 'USB staging did not validate its package.'
            $command = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([IO.File]::ReadAllText((Join-Path $nova 'command.json')))) | ConvertFrom-Json
            Assert-Mac ($command.programInfos[0].isImport -and $command.programInfos[0].isOverride) 'Default USB copy-and-play/overwrite settings changed.'
            $networkFolder = [IO.Directory]::CreateDirectory((Join-Path $fixture ('network-' + $type))).FullName
            $network = Export-StudioNetworkProgram -ConfigRoot $configRoot -Project $project -ProgramType $type -ProgramId $id -OutputDirectory $networkFolder
            Assert-Mac ($network.mediaCount -ge 1 -and $network.totalSize -gt 0) 'Network package staging failed.'
        }
        $preview = Convert-StudioPlayerPreview ([IO.File]::ReadAllBytes($jpeg)) $fixture
        Assert-Mac ($preview.width -eq 480 -and $preview.height -eq 270 -and $preview.imageDataUrl.StartsWith('data:image/jpeg;base64,')) 'macOS board snapshot resizing failed.'
        Assert-MacThrows { Convert-StudioPlayerPreview ([byte[]](1,2,3)) $fixture } 'A corrupt board screenshot was accepted.'

        if ($DiskImage) {
            # FAT volume labels are at most 11 uppercase characters. Keep the
            # requested label and actual mount name identical on both Macs.
            $volumeName = 'RLY' + [guid]::NewGuid().ToString('N').Substring(0,8).ToUpperInvariant()
            $expectedMount = '/Volumes/' + $volumeName
            $image = Join-Path $fixture ($volumeName + '.dmg')
            $created = Invoke-StudioMacTool '/usr/bin/hdiutil' @('create','-size','64m','-fs','MS-DOS','-volname',$volumeName,$image) 60000
            Assert-Mac ($created.code -eq 0) 'Could not create the disposable FAT image.'
            $attached = Invoke-StudioMacTool '/usr/bin/hdiutil' @('attach','-nobrowse','-plist','-mountpoint',$expectedMount,$image) 30000
            Assert-Mac ($attached.code -eq 0) 'Could not mount the disposable FAT image.'
            $imageAttached = $true
            $converted = Invoke-StudioMacTool '/usr/bin/plutil' @('-convert','json','-o','-','-') 10000 $attached.output
            Assert-Mac ($converted.code -eq 0) 'Could not parse the disposable image mount record.'
            $mounts = ($converted.output | ConvertFrom-Json).'system-entities'
            Write-Host ('Disposable image attachment: ' + ($mounts | Select-Object 'dev-entry','mount-point' | ConvertTo-Json -Compress))
            $imageRoots = @($mounts | Where-Object { $_.'dev-entry' -match '^/dev/disk\d+$' })
            if ($imageRoots.Count -eq 1) { $attachedDevice = $imageRoots[0].'dev-entry' }
            $mounted = @($mounts | Where-Object { $_.'mount-point' -ceq $expectedMount })
            Assert-Mac ($mounted.Count -eq 1 -and $mounted[0].'dev-entry' -match '^/dev/disk\d+(?:s\d+)?$' -and $attachedDevice) 'The disposable image returned an unexpected mount identity.'
            $volume = [RelayMacUsbVolume]::new($mounted[0].'mount-point',$mounted[0].'dev-entry')
            $volume.EnsureDirectory('fixture/deep')
            $hash = (Get-FileHash -LiteralPath $jpeg -Algorithm SHA256).Hash.ToLowerInvariant()
            $volume.CopyFile($jpeg,'fixture/deep/image.jpg',$hash)
            Assert-Mac ($volume.Hash('fixture/deep/image.jpg') -ceq $hash) 'Native descriptor-relative copy verification failed.'
            $first = @($volume.List('')); $second = @($volume.List(''))
            Assert-Mac ($first -contains 'fixture' -and $second -contains 'fixture') 'Repeated native enumeration lost directory entries.'
            Assert-MacThrows { $volume.EnsureDirectory('../outside') } 'The native USB helper accepted path traversal.'
            Assert-MacThrows { $volume.CopyFile($jpeg,'fixture/deep/image.jpg',$hash) } 'Native copy overwrote an existing file.'
            $volume.Move('fixture/deep/image.jpg','fixture/moved.jpg')
            Assert-Mac ($volume.Exists('fixture/moved.jpg') -and -not $volume.Exists('fixture/deep/image.jpg')) 'Native USB move failed.'
            $volume.Delete('fixture')
            Assert-Mac (-not $volume.Exists('fixture')) 'Native recursive cleanup failed inside the disposable volume.'
            $volume.Dispose(); $volume = $null
        }
        Write-Host 'macOS startup, Keychain, SQLite, image/video imports, preview streaming, schedule persistence, package staging and snapshot conversion passed.'
        if ($DiskImage) { Write-Host 'Native USB filesystem checks passed on a disposable disk image. No physical device was used.' }
        # Source checkouts include loopback transport fixtures. Run them after
        # native/runtime checks so a transport failure retains those diagnostics.
        # Packages omit test source, but run the same runtime checks above.
        $transportTest = Join-Path $repoRoot 'network-transport.test.ps1'
        if ([IO.File]::Exists($transportTest)) {
            & (Get-Process -Id $PID).Path -NoLogo -NoProfile -File $transportTest
            if ($LASTEXITCODE -ne 0) { throw 'Core loopback network transport checks failed.' }
        }
    } finally {
        if ($volume) { $volume.Dispose() }
        if ($attachedDevice) {
            $detached = Invoke-StudioMacTool '/usr/bin/hdiutil' @('detach',$attachedDevice) 30000
            if ($detached.code -ne 0) { Write-Warning 'The disposable disk image could not detach; its fixture files are retained.' }
            else { $attachedDevice = $null; $imageAttached = $false }
        }
        if ($server) { if (-not $server.HasExited) { $server.Kill($true); $server.WaitForExit() }; $server.Dispose() }
        if ($keychainCreated) { [RelayMacKeychain]::Write($keychainAccount,'') }
        $expected = [IO.Path]::GetFullPath((Join-Path $tempParent $fixtureLeaf))
        if (-not $imageAttached -and $fixture -ceq $expected -and $fixtureLeaf -match '^RelayMacCI-[a-f0-9]{32}$' -and [IO.Path]::GetDirectoryName($fixture) -ceq $tempParent.TrimEnd('/')) {
            [IO.Directory]::Delete($fixture,$true)
        }
    }
} finally { Pop-Location }

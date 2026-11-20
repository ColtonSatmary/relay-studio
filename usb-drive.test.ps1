# Run with powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\usb-drive.test.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StudioUsb.ps1')
Initialize-StudioUsbFiles
function Assert-UsbTest([bool]$Condition,[string]$Description) {
    if (-not $Condition) { throw "Test failed: $Description" }
}
function New-TestDirectory([string]$Parent,[string]$Leaf) {
    $path = [RelayUsbFiles]::Child($Parent,$Leaf)
    [void][IO.Directory]::CreateDirectory($path)
    $path
}
function Add-TestFile([string]$Parent,[string]$Leaf,[string]$Text) {
    $path = [RelayUsbFiles]::Child($Parent,$Leaf)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path,$Text,[Text.UTF8Encoding]::new($false))
    $path
}
function Get-TestTarget([string]$Path,[long]$Free=10000000) {
    [pscustomobject]@{root=$Path;label='Temporary test volume';id='simulated';fileSystem='FAT32';allocationUnit=4096L;freeBytes=$Free;totalBytes=1000000000L}
}

$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempLeaf = 'RelayUsbUnit-'+[guid]::NewGuid().ToString('N')
$testRoot = New-TestDirectory $tempParent $tempLeaf
try {
    $src = New-TestDirectory $testRoot 'source'
    $mediaFile = Add-TestFile $src 'media\example.mp4' 'fixture media'
    $playlistFile = Add-TestFile $src 'program\Example\playlist0.json' '{"name":"Example"}'
    $plan = @{name='Example';playlists=@(@{fileName='playlist0.json';md5=[RelayUsbFiles]::Hash($playlistFile,'MD5')})
        resources=@(@{fileName='example.mp4';md5=[RelayUsbFiles]::Hash($mediaFile,'MD5')})}
    $planPath = Add-TestFile $src 'program\Example\planlist.json' ($plan | ConvertTo-Json -Depth 6 -Compress)
    $cmd = @{programInfos=@(@{isPlay=$true;name='Example';url='Example';identifier=[RelayUsbFiles]::Hash($planPath,'MD5')})} | ConvertTo-Json -Depth 5 -Compress
    $null = Add-TestFile $src 'command.json' ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cmd)))
    $package = Get-StudioUsbPackage $src
    $noop = {}
    $alias = New-Item -ItemType Junction -Path (Join-Path $testRoot 'staging-alias') -Target $src
    $held = [RelayUsbFiles]::HoldDirectory($alias.FullName)
    try {
        $resolved = [RelayUsbFiles]::PhysicalPath($held)
        Assert-UsbTest ($resolved.EndsWith('\source') -and $resolved -match '^\\\\\?\\Volume\{([a-f\d-]{36})\}\\') 'resolved physical staging directory through junction'
        $volumeGuid = [regex]::Match($resolved,'(?i)Volume\{([a-f\d-]{36})\}').Groups[1].Value
        Assert-UsbTest (-not (Test-StudioUsbSeparateVolume $resolved ($volumeGuid+'/1234ABCD'))) 'selected destination volume forbidden as source'
        Assert-UsbTest (Test-StudioUsbSeparateVolume $resolved ('00000000-0000-0000-0000-000000000000/1234ABCD')) 'different volume accepted as staging'
        $physicalPackage = Get-StudioUsbPackage $resolved
        Assert-UsbTest ($physicalPackage.files.Count -eq $package.files.Count) 'validated manifests through physical volume path'
    } finally { $held.Dispose() }

    $merge = New-TestDirectory $testRoot 'merge'
    $outside = Add-TestFile $merge 'user.txt' 'keep'
    $terminal = Add-TestFile $merge 'nova\viplex_terminal\status' 'keep-terminal'
    $oldMedia = Add-TestFile $merge 'nova\media\old.mp4' 'keep-media'
    $oldCommand = Add-TestFile $merge 'nova\command.json' 'old command'
    $result = Invoke-StudioUsbInstall (Get-TestTarget $merge) $merge $package $false $noop
    Assert-UsbTest ([IO.File]::ReadAllText($terminal) -eq 'keep-terminal') 'device metadata kept at original path'
    Assert-UsbTest ([IO.File]::Exists($oldMedia) -and [IO.File]::Exists($outside)) 'unrelated media and root files kept'
    Assert-UsbTest ([IO.File]::ReadAllText([IO.Path]::Combine($result.backupPath,'nova','command.json')) -eq 'old command') 'old command recoverable'
    Assert-UsbTest ([RelayUsbFiles]::Hash($oldCommand,'SHA256') -eq [RelayUsbFiles]::Hash((Join-Path $src 'command.json'),'SHA256')) 'new command active'
    $unchanged = Invoke-StudioUsbInstall (Get-TestTarget $merge 0) $merge $package $false $noop
    Assert-UsbTest (-not $unchanged.backupPath) 'identical re-export on a full volume needs no backup or free space'
    $null = Add-TestFile $merge 'nova\command.json' 'another old command'
    $delta = Invoke-StudioUsbInstall (Get-TestTarget $merge 12288) $merge $package $false $noop
    Assert-UsbTest ($delta.backupPath -and [IO.File]::ReadAllText($outside) -eq 'keep') 'near-full volume can replace only a changed command'

    $clear = New-TestDirectory $testRoot 'clear'
    $protected = Add-TestFile $clear 'System Volume Information\index' 'system'
    $oldFile = Add-TestFile $clear 'old\hidden.txt' 'test'
    [IO.File]::SetAttributes($oldFile,([IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Hidden))
    $external = New-TestDirectory $testRoot 'outside'
    $sentinel = Add-TestFile $external 'preserved.txt' 'external'
    $junction = Join-Path $clear 'old\junction'
    $null = New-Item -ItemType Junction -Path $junction -Target $external
    $result = Invoke-StudioUsbInstall (Get-TestTarget $clear) $clear $package $true $noop
    Assert-UsbTest ($result.cleared -and -not [IO.Directory]::Exists((Join-Path $clear 'old'))) 'old contents including read-only + junction removed'
    Assert-UsbTest ([IO.File]::ReadAllText($sentinel) -eq 'external' -and [IO.File]::Exists($protected)) 'junction destination and OS metadata preserved'
    Assert-UsbTest ([IO.File]::Exists((Join-Path $clear 'nova\command.json'))) 'checked export installed'

    $blocked = New-TestDirectory $testRoot 'blocked'
    $oldFile = Add-TestFile $blocked 'precious.txt' 'unmodified'
    $null = New-TestDirectory $blocked 'nova'
    $null = New-Item -ItemType Junction -Path (Join-Path $blocked 'nova\media') -Target $external
    $failed = $false
    try { $null = Invoke-StudioUsbInstall (Get-TestTarget $blocked) $blocked $package $false $noop }
    catch { $failed = $_.Exception.Message -like '*link*' }
    Assert-UsbTest ($failed -and -not [IO.File]::Exists((Join-Path $external 'example.mp4'))) 'merge rejects junction escape'
    Assert-UsbTest ([IO.File]::Exists($oldFile)) 'rejected merge keeps original data'
    $failed = $false
    try { $null = Invoke-StudioUsbInstall (Get-TestTarget $blocked 0) $blocked $package $true $noop }
    catch { $failed = $_.Exception.Message -like '*will not fit*' }
    Assert-UsbTest ($failed -and [IO.File]::Exists($oldFile)) 'insufficient reclaimable space refuses clear'

    $full = New-TestDirectory $testRoot 'full'
    $discard = Add-TestFile $full 'old.bin' ('z'*65536)
    $result = Invoke-StudioUsbInstall (Get-TestTarget $full 0) $full $package $true $noop
    Assert-UsbTest ($result.cleared -and -not [IO.File]::Exists($discard) -and [IO.File]::Exists((Join-Path $full 'nova\command.json'))) 'clear can publish on a full volume'

    $rollback = New-TestDirectory $testRoot 'rollback'
    $original = Add-TestFile $rollback 'original.txt' 'original data'
    $linkTarget = New-TestDirectory $testRoot 'link-target'
    $dangling = Join-Path $rollback 'disconnected-link'
    $null = New-Item -ItemType Junction -Path $dangling -Target $linkTarget
    [IO.Directory]::Delete($linkTarget,$false)
    $state = @{calls=0}; $recheck = { $state.calls++; if ($state.calls -eq 3) { throw 'test drive identity changed before commit' } }.GetNewClosure()
    $failed = $false
    try { $null = Invoke-StudioUsbInstall (Get-TestTarget $rollback) $rollback $package $true $recheck }
    catch { $failed = $_.Exception.Message -like '*identity changed*' }
    Assert-UsbTest ($failed -and [IO.File]::ReadAllText($original) -eq 'original data') 'restore moved files if identity confirmation fails'
    Assert-UsbTest ([bool]([IO.File]::GetAttributes($dangling) -band [IO.FileAttributes]::ReparsePoint)) 'rollback restores a dangling link itself'
    Assert-UsbTest ([IO.Directory]::GetFileSystemEntries($rollback).Count -eq 2) 'failed transaction removed test staging'

    $bad = $false
    [IO.File]::WriteAllText($mediaFile,'corrupted')
    try { $null = Get-StudioUsbPackage $src } catch { $bad = $_.Exception.Message -like '*failed validation*' }
    Assert-UsbTest $bad 'local checksum mismatch caught before touching destination'
    'USB deployment checks passed (temporary fixtures only).'
} finally {
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($testRoot)) -eq $tempParent.TrimEnd('\') -and
        [IO.Path]::GetFileName($testRoot) -ceq $tempLeaf) {
        [RelayUsbFiles]::RemoveChild($tempParent,$tempLeaf)
    }
}


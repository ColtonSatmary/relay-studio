# diskutil is read-only except the explicit Eject button. Destination writes use
# the held-device C# adapter, never recursive shell deletion or mount path reuse.
function Invoke-StudioMacDiskutil([string[]]$Arguments) {
    $result=Invoke-StudioMacTool '/usr/sbin/diskutil' $Arguments 20000
    if($result.code -ne 0){throw 'macOS could not inspect that disk. Refresh the USB list.'}
    $converted=Invoke-StudioMacTool '/usr/bin/plutil' @('-convert','json','-o','-','-') 10000 $result.output
    if($converted.code -ne 0){throw 'macOS returned unreadable disk information.'}
    return $converted.output | ConvertFrom-Json -Depth 32
}

function Test-StudioMacUsbInfo($Volume,$Disk) {
    # Missing metadata fails closed. A mount merely living in /Volumes is not
    # enough: require physical, external, writable, USB-backed storage.
    return ($Disk.Internal -eq $false -and $Disk.BusProtocol -ceq 'USB' -and
        $Disk.VirtualOrPhysical -ceq 'Physical' -and $Disk.Writable -eq $true -and
        $Disk.Whole -eq $true -and $Disk.DeviceIdentifier -cmatch '^disk[0-9]+$' -and
        $Volume.Internal -eq $false -and $Volume.Writable -eq $true -and
        $Volume.Mounted -eq $true -and $Volume.MountPoint -is [string] -and
        $Volume.MountPoint -cmatch '^/Volumes/[^/]+$' -and
        $Volume.MountPoint -cnotin @('/Volumes/.','/Volumes/..') -and
        $Volume.DeviceIdentifier -cmatch '^disk[0-9]+(?:s[0-9]+)?$' -and
        ($Volume.ParentWholeDisk -ceq $Disk.DeviceIdentifier -or ($Volume.Whole -eq $true -and $Volume.DeviceIdentifier -ceq $Disk.DeviceIdentifier)) -and
        $Volume.DeviceNode -ceq ('/dev/'+$Volume.DeviceIdentifier) -and
        $Volume.VolumeUUID -cmatch '^[A-Fa-f0-9-]{36}$' -and
        $Volume.FilesystemType -cin @('msdos','exfat'))
}

function Get-StudioMacUsbDrives {
    $inventory=Invoke-StudioMacDiskutil @('list','-plist','external','physical')
    foreach($entry in @($inventory.AllDisksAndPartitions)) {
        if($entry.DeviceIdentifier -cnotmatch '^disk[0-9]+$'){continue}
        try {$disk=Invoke-StudioMacDiskutil @('info','-plist',[string]$entry.DeviceIdentifier)}catch{continue}
        foreach($partition in @($entry)+@($entry.Partitions)) {
            if($partition.DeviceIdentifier -cnotmatch '^disk[0-9]+(?:s[0-9]+)?$'){continue}
            try {
                $volume=Invoke-StudioMacDiskutil @('info','-plist',[string]$partition.DeviceIdentifier)
                if(-not (Test-StudioMacUsbInfo $volume $disk)){continue}
                $uuid=([guid]$volume.VolumeUUID).ToString('D')
                $total=if($volume.VolumeTotalSpace){[long]$volume.VolumeTotalSpace}else{[long]$volume.TotalSize}
                $free=if($null -ne $volume.VolumeFreeSpace){[long]$volume.VolumeFreeSpace}else{[long]$volume.FreeSpace}
                if($total -lt 1 -or $free -lt 0 -or $free -gt $total){continue}
                [pscustomobject]@{root=[string]$volume.MountPoint;id=$uuid+'/'+$volume.DeviceIdentifier
                    label=[string]$volume.VolumeName;freeBytes=$free;totalBytes=$total
                    fileSystem=$(if($volume.FilesystemType -ceq 'msdos'){'FAT32'}else{'exFAT'})
                    allocationUnit=[math]::Max(4096,[long]$volume.AllocationBlockSize)
                    hasNova=[IO.Directory]::Exists((Join-Path $volume.MountPoint 'nova'))
                    deviceNode=[string]$volume.DeviceNode;wholeDisk=[string]$disk.DeviceIdentifier}
            }catch{continue}
        }
    }
}

function Get-StudioMacUsbTarget([string]$DriveRoot,[string]$VolumeId) {
    if($DriveRoot -cnotmatch '^/Volumes/[^/]+$' -or $DriveRoot -cin @('/Volumes/.','/Volumes/..') -or $VolumeId -cnotmatch '^[a-f0-9-]{36}/disk[0-9]+(?:s[0-9]+)?$'){throw 'Choose a connected USB drive from the drive list.'}
    $matches=@(Get-StudioMacUsbDrives | Where-Object {$_.root -ceq $DriveRoot -and $_.id -ceq $VolumeId})
    if($matches.Count -ne 1){throw 'The selected USB drive changed or was removed. Refresh the drive list.'}
    return $matches[0]
}

function Initialize-StudioMacUsbFiles {
    if(-not ('RelayMacUsbVolume' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'StudioMacUsbFiles.cs')}
}

function Get-StudioMacUsbStagingParent([string]$VolumeId) {
    Initialize-StudioMacUsbFiles
    $target=@(Get-StudioMacUsbDrives | Where-Object id -CEQ $VolumeId)
    if($target.Count -ne 1){throw 'The selected USB drive changed or was removed.'}
    $device=[RelayMacUsbVolume]::DirectoryDevice($target[0].root)
    foreach($candidate in @([IO.Path]::GetTempPath(),$WorkspaceDirectory)){
        if(-not $candidate -or -not [IO.Directory]::Exists($candidate)){continue}
        $canonical=[RelayMacUsbVolume]::CanonicalPath($candidate)
        if([RelayMacUsbVolume]::DirectoryDevice($canonical) -ne $device){return $canonical}
    }
    throw 'Relay needs a local staging folder on a different volume from the USB drive.'
}

function Get-StudioMacUsbPlayerPassword($Drive) {
    $volume=$null
    try {
        Initialize-StudioMacUsbFiles
        $current=Get-StudioMacUsbTarget $Drive.root $Drive.id
        $volume=[RelayMacUsbVolume]::new($current.root,$current.deviceNode)
        $encoded=[Text.Encoding]::ASCII.GetString($volume.ReadBytes('nova/command.json',1MB))
        $command=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
        $accounts=@($command.authenticUserInfos | Where-Object {$_.userName -ceq 'admin' -and $_.password -is [string] -and $_.password.Length -gt 0 -and $_.password.Length -le 256})
        if($accounts.Count -eq 1){return $accounts[0].password}
    }catch{return}finally{if($volume){$volume.Dispose()}}
}

function Get-StudioMacUsbUserEntries($Volume,[string]$WorkName) {
    foreach($entry in $Volume.List('')) {
        # macOS creates these protected housekeeping directories automatically.
        if($entry -cnotin @($WorkName,'.Spotlight-V100','.fseventsd','.Trashes','System Volume Information','$RECYCLE.BIN')){$entry}
    }
}

function Publish-StudioMacUsb([string]$StagedNova,[string]$DriveRoot,[string]$VolumeId,[bool]$ClearDrive) {
    Initialize-StudioMacUsbFiles
    $target=Get-StudioMacUsbTarget $DriveRoot $VolumeId
    $mutex=[Threading.Mutex]::new($false,'RelayStudioUsb-'+$target.id.Split('/')[0]);$locked=$false;$volume=$null
    $work='.relay-staging-'+[guid]::NewGuid().ToString('N');$backup='Relay previous USB files '+(Get-Date -Format 'yyyy-MM-dd HHmmss')+' '+[guid]::NewGuid().ToString('N').Substring(0,8)
    $moved=[Collections.Generic.List[string]]::new();$installed=[Collections.Generic.List[string]]::new();$replaced=[Collections.Generic.List[string]]::new()
    $purged=$false;$committed=$false;$retain=$false;$warning=$null;$backupDisplay=$null
    try {
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw 'Another export is already using this USB drive.'}
        $source=[RelayMacUsbVolume]::CanonicalPath($StagedNova)
        if([RelayMacUsbVolume]::DirectoryDevice($source) -eq [RelayMacUsbVolume]::DirectoryDevice($target.root)){throw 'Stage the playback package on a different local volume.'}
        $package=Get-StudioUsbPackage $source
        $target=Get-StudioMacUsbTarget $DriveRoot $VolumeId
        $volume=[RelayMacUsbVolume]::new($target.root,$target.deviceNode)
        $required=[long](($package.directories.Count+4)*$target.allocationUnit)
        foreach($file in $package.files){
            if($target.fileSystem -ceq 'FAT32' -and $file.size -gt 4294967295L){throw 'FAT32 cannot store a file larger than 4 GB.'}
            $required+=[long]([math]::Ceiling($file.size/[double]$target.allocationUnit)*$target.allocationUnit)
        }
        if($required -gt $target.freeBytes){
            if(-not $ClearDrive){throw 'The USB drive has too little free space. Select another drive or enable clearing this drive.'}
            $available=[long]$target.freeBytes
            foreach($entry in @(Get-StudioMacUsbUserEntries $volume $work)){$available+=$volume.Reclaimable($entry)}
            if($available -lt $required){throw 'The playback package will not fit even after clearing the USB files.'}
            $null=Get-StudioMacUsbTarget $DriveRoot $VolumeId
            $purged=$true
            foreach($entry in @(Get-StudioMacUsbUserEntries $volume $work)){$volume.Delete($entry)}
        }
        $volume.EnsureDirectory($work+'/nova')
        foreach($dir in $package.directories){$volume.EnsureDirectory($work+'/nova/'+$dir.Replace('\','/'))}
        foreach($file in $package.files){$volume.CopyFile($file.source,$work+'/nova/'+$file.relative.Replace('\','/'),$file.hash)}
        $null=Get-StudioMacUsbTarget $DriveRoot $VolumeId
        if($ClearDrive){
            $volume.EnsureDirectory($work+'/previous')
            foreach($entry in @(Get-StudioMacUsbUserEntries $volume $work)){$volume.Move($entry,$work+'/previous/'+$entry);$moved.Add($entry)}
            $volume.Move($work+'/nova','nova')
        }else{
            $volume.EnsureDirectory('nova')
            foreach($dir in $package.directories){$volume.EnsureDirectory('nova/'+$dir.Replace('\','/'))}
            foreach($file in @($package.files | Sort-Object {$_.relative -ceq 'command.json'})){
                $relative=$file.relative.Replace('\','/');$destination='nova/'+$relative
                if($volume.Exists($destination)){
                    if($volume.Hash($destination) -ceq $file.hash){continue}
                    $volume.Move($destination,$backup+'/nova/'+$relative);$replaced.Add($relative)
                }
                $volume.Move($work+'/nova/'+$relative,$destination);$installed.Add($destination)
            }
            if($replaced.Count){$backupDisplay=Join-Path $DriveRoot $backup}
        }
        $committed=$true
    }catch{
        $reason=$_.Exception.Message
        if($volume){
            try{
                if(-not $committed){
                    for($i=$installed.Count-1;$i -ge 0;$i--){$volume.Delete($installed[$i])}
                    for($i=$replaced.Count-1;$i -ge 0;$i--){$volume.Move($backup+'/nova/'+$replaced[$i],'nova/'+$replaced[$i])}
                    for($i=$moved.Count-1;$i -ge 0;$i--){$volume.Move($work+'/previous/'+$moved[$i],$moved[$i])}
                }
            }catch{$retain=$true;throw "USB export stopped during rollback. Previous files remain in '$work/previous' or '$backup' on this USB. $reason"}
        }
        if($purged){throw "USB export failed after file clearing began. Earlier USB files may have been erased. $reason"}
        throw $reason
    }finally{
        if($volume){
            if(-not $retain -and $volume.Exists($work)){try{$volume.Delete($work)}catch{if($committed){$warning="Playback installed; cleanup remains in '$work' on the USB."}}}
            $volume.Dispose()
        }
        if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()
    }
    return [pscustomobject]@{path=(Join-Path $DriveRoot 'nova');root=$DriveRoot;volumeLabel=$target.label;backupPath=$backupDisplay;cleared=($ClearDrive -and -not $warning);warning=$warning}
}

function Invoke-StudioMacUsbEject($Request,$Response) {
    $payload=Read-StudioJsonRequest $Request $Response
    if($null -eq $payload){return}
    $mutex=$null;$locked=$false
    try{
        if($payload.driveRoot -isnot [string] -or $payload.volumeId -isnot [string]){throw 'Choose the USB drive used for this export.'}
        $target=Get-StudioMacUsbTarget $payload.driveRoot $payload.volumeId
        $mutex=[Threading.Mutex]::new($false,'RelayStudioUsb-'+$target.id.Split('/')[0])
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw 'An export is still using this drive. Wait for it to finish, then eject.'}
        # Do not eject an enclosure containing another mounted partition.
        $inventory=Invoke-StudioMacDiskutil @('list','-plist',$target.wholeDisk)
        if(@($inventory.AllDisksAndPartitions).Count -ne 1 -or $inventory.AllDisksAndPartitions[0].DeviceIdentifier -cne $target.wholeDisk){throw 'The USB disk layout could not be verified. Eject it in Finder.'}
        foreach($disk in @($inventory.AllDisksAndPartitions)){
            foreach($part in @($disk)+@($disk.Partitions)){
                if($part.DeviceIdentifier -cnotmatch '^disk[0-9]+(?:s[0-9]+)?$'){throw 'The USB disk layout could not be verified.'}
                if($part.DeviceIdentifier -cne $target.wholeDisk -and $part.DeviceIdentifier -cne $target.id.Split('/')[1] -and $part.Content -cne 'EFI'){throw 'This USB disk has another data partition. Eject the whole disk in Finder.'}
                $info=Invoke-StudioMacDiskutil @('info','-plist',[string]$part.DeviceIdentifier)
                if($info.Mounted -eq $true -and $info.DeviceIdentifier -cne $target.id.Split('/')[1]){throw 'This USB disk has another mounted volume. Eject the disk in Finder.'}
            }
        }
        $null=Get-StudioMacUsbTarget $payload.driveRoot $payload.volumeId
        $result=Invoke-StudioMacTool '/usr/sbin/diskutil' @('eject','/dev/'+$target.wholeDisk) 30000
        if($result.code -ne 0){throw 'macOS could not eject the USB drive. Close files using it and try again, or eject it in Finder.'}
        Write-StudioJson $Response @{ejected=$true;root=$target.root;label=$target.label}
    }catch{Write-StudioJson $Response @{error=$_.Exception.Message} 409}
    finally{if($locked){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
}

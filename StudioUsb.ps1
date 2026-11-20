# Operations on the destination use its volume GUID path. A different stick
# acquiring the same drive letter cannot redirect a pending copy or cleanup.
function Get-StudioUsbDrives {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { return Get-StudioMacUsbDrives }
    $letters = @{}
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if ($drive.IsReady -and $drive.DriveType -in 'Removable','Fixed') { $letters[$drive.Name] = $drive }
    }
    foreach ($disk in @(Get-Disk -ErrorAction Stop | Where-Object { $_.BusType -eq 'USB' -and -not $_.IsBoot -and -not $_.IsSystem -and -not $_.IsReadOnly -and -not $_.IsOffline })) {
        foreach ($part in @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)) {
            if (-not $part.DriveLetter -or $part.IsBoot -or $part.IsSystem -or $part.IsReadOnly) { continue }
            $root = "$($part.DriveLetter):\"
            $drive = $letters[$root]
            if (-not $drive -or $root -eq ([IO.Path]::GetPathRoot($env:SystemRoot))) { continue }
            try {
                $volume = Get-Volume -DriveLetter $part.DriveLetter -ErrorAction Stop
                if ($volume.UniqueId -notmatch '^\\\\\?\\Volume\{([a-f\d-]{36})\}\\$') { continue }
                $guid = ([guid]$Matches[1]).ToString('D')
                $logical = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($root.Substring(0,2))'" -ErrorAction Stop
                if ($logical.VolumeSerialNumber -notmatch '^[a-f\d]{8}$') { continue }
                [pscustomobject]@{
                    root=$root; id=($guid + '/' + $logical.VolumeSerialNumber.ToUpperInvariant())
                    label=$drive.VolumeLabel; freeBytes=$drive.AvailableFreeSpace; totalBytes=$drive.TotalSize
                    fileSystem=$drive.DriveFormat; allocationUnit=[long]$volume.AllocationUnitSize
                    hasNova=[IO.Directory]::Exists([IO.Path]::Combine($volume.UniqueId,'nova'))
                }
            } catch { continue } # The drive may have been ejected during discovery.
        }
    }
}

function Get-StudioUsbTarget([string]$DriveRoot, [string]$VolumeId) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { return Get-StudioMacUsbTarget $DriveRoot $VolumeId }
    if ($DriveRoot -cnotmatch '^[A-Za-z]:\\$' -or $VolumeId -notmatch '^[a-f\d-]{36}/[a-f\d]{8}$') {
        throw 'Choose a connected USB drive from the drive list.'
    }
    $matched = @(Get-StudioUsbDrives | Where-Object { $_.root -eq $DriveRoot -and $_.id -ceq $VolumeId })
    if ($matched.Count -ne 1) { throw 'The selected USB drive changed or was removed. Refresh the drive list.' }
    $matched[0]
}

function Initialize-StudioUsbFiles {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { Initialize-StudioMacUsbFiles; return }
    if ('RelayUsbFiles' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.ComponentModel;
using System.Security.Cryptography;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class RelayUsbFiles {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern SafeFileHandle CreateFile(string path, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfoNative info);
    [StructLayout(LayoutKind.Sequential)]
    private struct FileInfoNative {
        public uint attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME creation, access, write;
        public uint serial, sizeHigh, sizeLow, links, idHigh, idLow;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern uint GetCompressedFileSize(string path, out uint high);
    [DllImport("kernel32.dll")]
    private static extern void SetLastError(uint error);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint size, uint flags);

    public static SafeFileHandle HoldDirectory(string path) {
        // Follow mounts and junctions to the actual directory. No delete
        // sharing keeps this directory in place while its files are used.
        var handle=CreateFile(path,0x80,3,IntPtr.Zero,3,0x2000000,IntPtr.Zero);
        if (handle.IsInvalid) {
            int error=Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error);
        }
        return handle;
    }
    public static string PhysicalPath(SafeFileHandle handle) {
        const uint volumeGuid=1;
        var result=new StringBuilder(512);
        uint length=GetFinalPathNameByHandle(handle,result,(uint)result.Capacity,volumeGuid);
        if (length>=result.Capacity) {
            result=new StringBuilder(checked((int)length+1));
            length=GetFinalPathNameByHandle(handle,result,(uint)result.Capacity,volumeGuid);
        }
        if (length==0) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (length>=result.Capacity) throw new IOException("The staging path could not be resolved.");
        return result.ToString();
    }

    // Keep each ordinary directory in place during traversal. Open the link
    // itself and check its attributes before examining any children.
    private static SafeFileHandle Hold(string path, out FileInfoNative info) {
        const uint readAttributes=0x80, shareReadWrite=3, openExisting=3;
        const uint openReparsePoint=0x200000, backupSemantics=0x2000000;
        var h=CreateFile(path,readAttributes,shareReadWrite,IntPtr.Zero,openExisting,
                         openReparsePoint|backupSemantics,IntPtr.Zero);
        if (h.IsInvalid) { int error=Marshal.GetLastWin32Error(); h.Dispose(); throw new Win32Exception(error); }
        if (!GetFileInformationByHandle(h,out info)) {
            int error=Marshal.GetLastWin32Error(); h.Dispose(); throw new Win32Exception(error);
        }
        return h;
    }
    public static SafeFileHandle HoldOrdinaryDirectory(string path) {
        FileInfoNative info;
        var handle=Hold(path,out info);
        var flags=(FileAttributes)info.attributes;
        if ((flags&(FileAttributes.Directory|FileAttributes.ReparsePoint))!=FileAttributes.Directory) {
            handle.Dispose();
            throw new IOException("A USB destination directory is a link or changed during export.");
        }
        return handle;
    }
    public static string Child(string root, string relative) {
        if (String.IsNullOrEmpty(relative) || Path.IsPathRooted(relative)) throw new IOException("Invalid USB path.");
        string prefix=Path.GetFullPath(root).TrimEnd('\\')+"\\";
        string path=Path.GetFullPath(Path.Combine(prefix,relative));
        if (!path.StartsWith(prefix,StringComparison.OrdinalIgnoreCase) || path.Length<=prefix.Length)
            throw new IOException("A USB path is outside the selected directory.");
        return path;
    }
    public static string Hash(string path, string algorithm) {
        using(var input=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read))
        using(var digest=HashAlgorithm.Create(algorithm)) {
            return BitConverter.ToString(digest.ComputeHash(input)).Replace("-","").ToLowerInvariant();
        }
    }
    public static long Reclaimable(string path, long cluster) {
        FileInfoNative info;
        using(Hold(path,out info)) {
            var attr=(FileAttributes)info.attributes;
            if ((attr&FileAttributes.ReparsePoint)!=0) return 0;
            if ((attr&FileAttributes.Directory)!=0) {
                long bytes=0;
                foreach(string child in Directory.GetFileSystemEntries(path)) bytes+=Reclaimable(child,cluster);
                return bytes;
            }
            // Never count bytes also reachable through another hard link.
            if(info.links>1) return 0;
            uint high;
            SetLastError(0);
            uint low=GetCompressedFileSize(path,out high);
            if(low==UInt32.MaxValue && Marshal.GetLastWin32Error()!=0) return 0;
            long allocated=((long)high<<32)|low;
            return (allocated/cluster+(allocated%cluster>0?1:0))*cluster;
        }
    }
    public static void RemoveChild(string parent, string leaf) {
        if (leaf!=Path.GetFileName(leaf) || leaf=="." || leaf=="..") throw new IOException("Invalid cleanup entry.");
        string path=Child(parent,leaf);
        FileInfoNative info;
        FileAttributes attr;
        using(Hold(path,out info)) {
            attr=(FileAttributes)info.attributes;
            if ((attr&(FileAttributes.Directory|FileAttributes.ReparsePoint))==FileAttributes.Directory) {
                foreach(string child in Directory.GetFileSystemEntries(path))
                    RemoveChild(path,Path.GetFileName(child));
            }
            if ((attr&(FileAttributes.ReadOnly|FileAttributes.ReparsePoint))==FileAttributes.ReadOnly)
                File.SetAttributes(path,attr&~FileAttributes.ReadOnly);
        }
        if ((attr&FileAttributes.Directory)!=0) Directory.Delete(path,false);
        else File.Delete(path);
    }
}
'@
}

function Test-StudioUsbSeparateVolume([string]$PhysicalPath,[string]$VolumeId) {
    if ($VolumeId -notmatch '^[a-f\d-]{36}/[a-f\d]{8}$') { return $false }
    if ($PhysicalPath -notmatch '^\\\\\?\\Volume\{([a-f\d-]{36})\}\\') { return $false }
    return $Matches[1] -ne $VolumeId.Split('/')[0]
}

function Get-StudioUsbStagingParent([string]$VolumeId) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { return Get-StudioMacUsbStagingParent $VolumeId }
    Initialize-StudioUsbFiles
    foreach ($candidate in @([IO.Path]::GetTempPath(),$env:LOCALAPPDATA)) {
        if (-not $candidate -or -not [IO.Directory]::Exists($candidate)) { continue }
        $handle = $null
        try {
            $handle = [RelayUsbFiles]::HoldDirectory($candidate)
            if (Test-StudioUsbSeparateVolume ([RelayUsbFiles]::PhysicalPath($handle)) $VolumeId) {
                return [IO.Path]::GetFullPath($candidate)
            }
        } catch { continue }
        finally { if ($null -ne $handle) { $handle.Dispose() } }
    }
    throw 'Studio needs a local staging folder on a different volume from the USB drive.'
}

function Get-StudioUsbPackage([string]$StagedNova) {
    $source = [IO.Path]::GetFullPath($StagedNova).TrimEnd('\')
    if (-not [IO.Directory]::Exists($source) -or (([IO.File]::GetAttributes($source) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'The local playback package is missing or points outside its staging directory.'
    }
    $stack = [Collections.Generic.Stack[string]]::new()
    $stack.Push($source)
    $files = [Collections.Generic.List[object]]::new()
    $dirs = [Collections.Generic.List[string]]::new()
    $names = @{}
    while ($stack.Count) {
        $dir = $stack.Pop()
        foreach ($entry in [IO.Directory]::GetFileSystemEntries($dir)) {
            $relative = $entry.Substring($source.Length+1)
            $attributes = [IO.File]::GetAttributes($entry)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A link was found inside the local USB package.' }
            if ($attributes -band [IO.FileAttributes]::Directory) {
                $dirs.Add($relative)
                $stack.Push($entry)
            } else {
                $record = [pscustomobject]@{ relative=$relative; source=$entry; size=[IO.FileInfo]::new($entry).Length; hash=[RelayUsbFiles]::Hash($entry,'SHA256') }
                $files.Add($record)
                $names[$relative.Replace('\','/')] = $record
            }
        }
    }
    # Independently check the native index before allowing a clear operation.
    # Authentication material in command.json must never be printed on failure.
    try {
        $commandBytes = [Convert]::FromBase64String([IO.File]::ReadAllText($names['command.json'].source))
        $command = [Text.Encoding]::UTF8.GetString($commandBytes) | ConvertFrom-Json -ErrorAction Stop
        if (-not @($command.programInfos | Where-Object { $_.isPlay -eq $true }).Count) { throw 'No playback command.' }
        foreach ($program in $command.programInfos) {
            if (-not $program.url -or $program.url -ne [IO.Path]::GetFileName([string]$program.url)) { throw 'Bad program URL.' }
            $folder = 'program/' + $program.url + '/'
            $plan = $names[$folder+'planlist.json']
            if (-not $plan -or [RelayUsbFiles]::Hash($plan.source,'MD5') -ne $program.identifier) { throw 'Bad program index.' }
            $index = [IO.File]::ReadAllText($plan.source) | ConvertFrom-Json -ErrorAction Stop
            if (-not @($index.playlists).Count -or -not $index.playlists[0].fileName) { throw 'No playlists.' }
            foreach ($group in 'resources','playlists','playRelations','playSolutions','scheduleConstraints','medialists') {
                foreach ($reference in $index.$group) {
                    $base = if ($group -eq 'resources') { 'media/' } else { $folder }
                    if (-not $reference.fileName -or $reference.fileName -ne [IO.Path]::GetFileName([string]$reference.fileName)) { throw 'Bad package filename.' }
                    $file = $names[$base+$reference.fileName]
                    if (-not $file -or [RelayUsbFiles]::Hash($file.source,'MD5') -ne $reference.md5) { throw 'Package checksum mismatch.' }
                }
            }
        }
    } catch { throw 'The local USB playback package failed validation. The drive was left untouched.' }
    [pscustomobject]@{files=$files; directories=$dirs}
}

function Copy-StudioUsbPackage($Package, [string]$Destination) {
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($dir in $Package.directories) { [void][IO.Directory]::CreateDirectory([RelayUsbFiles]::Child($Destination,$dir)) }
    foreach ($file in $Package.files) {
        $out = [RelayUsbFiles]::Child($Destination,$file.relative)
        [IO.File]::Copy($file.source,$out)
        if ([RelayUsbFiles]::Hash($out,'SHA256') -cne $file.hash) { throw 'A copied USB file failed its checksum check.' }
    }
}

function Move-StudioUsbEntry([string]$Source,[string]$Destination) {
    if (([IO.File]::GetAttributes($Source) -band [IO.FileAttributes]::Directory) -ne 0) { [IO.Directory]::Move($Source,$Destination) }
    else { [IO.File]::Move($Source,$Destination) }
}

function Get-StudioUsbUserEntries([string]$VolumePath,[string]$WorkName) {
    foreach ($entry in [IO.Directory]::GetFileSystemEntries($VolumePath)) {
        $name = [IO.Path]::GetFileName($entry)
        if ($name -notin @('System Volume Information','$RECYCLE.BIN','RECYCLER','RECYCLED',$WorkName)) { $name }
    }
}

# Refuse to merge through an old junction or link anywhere along a new
# program's path. Other preexisting entries need no reads or modifications.
function Assert-StudioUsbMergePath([string]$Root,[string]$Relative,[bool]$IsDirectory) {
    $path = $Root
    $parts = $Relative.Split('\')
    for ($i=0;$i -lt $parts.Count;$i++) {
        $path = [RelayUsbFiles]::Child($path,$parts[$i])
        try { $a = [IO.File]::GetAttributes($path) }
        catch [IO.FileNotFoundException] { return }
        catch [IO.DirectoryNotFoundException] { return }
        if ($a -band [IO.FileAttributes]::ReparsePoint) { throw 'A USB playback path is a link. Choose another drive or clear this one.' }
        if (($i -lt $parts.Count-1 -or $IsDirectory) -ne [bool]($a -band [IO.FileAttributes]::Directory)) {
            throw 'An existing file or directory conflicts with a USB playback package path.'
        }
    }
}

function Install-StudioUsbMerge($Package,[string]$VolumePath,[string]$Staged,[string]$Backup,[bool]$WasPresent) {
    $existing = [RelayUsbFiles]::Child($VolumePath,'nova')
    Assert-StudioUsbMergePath $VolumePath 'nova' $true
    if (-not [IO.Directory]::Exists($existing)) {
        if ($WasPresent) { throw 'The existing playback folder changed during export. Retry the export.' }
        [IO.Directory]::Move($Staged,$existing)
        return $false
    }
    $createdDirs = [Collections.Generic.List[string]]::new()
    $installed = [Collections.Generic.List[string]]::new()
    $replaced = [Collections.Generic.List[string]]::new()
    $heldDirs = [Collections.Generic.List[IDisposable]]::new()
    try {
        $heldDirs.Add([RelayUsbFiles]::HoldOrdinaryDirectory($existing))
        foreach ($dir in $Package.directories) { Assert-StudioUsbMergePath $existing $dir $true }
        foreach ($file in $Package.files) { Assert-StudioUsbMergePath $existing $file.relative $false }
        foreach ($dir in @($Package.directories | Sort-Object Length)) {
            $path = [RelayUsbFiles]::Child($existing,$dir)
            if (-not [IO.Directory]::Exists($path)) {
                [void][IO.Directory]::CreateDirectory($path)
                $createdDirs.Add($path)
            }
            $heldDirs.Add([RelayUsbFiles]::HoldOrdinaryDirectory($path))
        }
        # Switch playback last, after every program/media file is installed.
        foreach ($file in @($Package.files | Sort-Object { $_.relative -eq 'command.json' })) {
            $dst = [RelayUsbFiles]::Child($existing,$file.relative)
            $new = [RelayUsbFiles]::Child($Staged,$file.relative)
            Assert-StudioUsbMergePath $existing $file.relative $false
            if ([IO.File]::Exists($dst)) {
                if ([RelayUsbFiles]::Hash($dst,'SHA256') -ceq $file.hash) { continue }
                if (-not [IO.File]::Exists($new)) { throw 'A previously matched USB file changed. Retry the export.' }
                $old = [RelayUsbFiles]::Child($Backup,('nova\'+$file.relative))
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($old))
                [IO.File]::Move($dst,$old)
                $replaced.Add($file.relative)
            }
            [IO.File]::Move($new,$dst)
            $installed.Add($dst)
        }
    } catch {
        $originalError = $_.Exception.Message
        try {
            for ($i=$installed.Count-1;$i -ge 0;$i--) { [IO.File]::Delete($installed[$i]) }
            for ($i=$replaced.Count-1;$i -ge 0;$i--) {
                $old = [RelayUsbFiles]::Child($Backup,('nova\'+$replaced[$i]))
                [IO.File]::Move($old,[RelayUsbFiles]::Child($existing,$replaced[$i]))
            }
            foreach ($handle in $heldDirs) { $handle.Dispose() }
            for ($i=$createdDirs.Count-1;$i -ge 0;$i--) { [IO.Directory]::Delete($createdDirs[$i],$false) }
        } catch { throw "USB merge stopped during rollback. Previous files are in '$([IO.Path]::GetFileName($Backup))'. $originalError" }
        throw $originalError
    } finally { foreach ($handle in $heldDirs) { $handle.Dispose() } }
    return ($replaced.Count -gt 0)
}

function Invoke-StudioUsbInstall($Target,[string]$VolumePath,$Package,[bool]$ClearDrive,[scriptblock]$Recheck) {
    $toStage = $Package
    $existing = [RelayUsbFiles]::Child($VolumePath,'nova')
    $mergeExisting = -not $ClearDrive -and [IO.Directory]::Exists($existing)
    if ($mergeExisting) {
        Assert-StudioUsbMergePath $VolumePath 'nova' $true
        $changed = [Collections.Generic.List[object]]::new()
        $partialDirs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $needDirectory = $false
        foreach ($dir in $Package.directories) {
            Assert-StudioUsbMergePath $existing $dir $true
            if (-not [IO.Directory]::Exists([RelayUsbFiles]::Child($existing,$dir))) { $needDirectory = $true }
        }
        foreach ($file in $Package.files) {
            Assert-StudioUsbMergePath $existing $file.relative $false
            $dst = [RelayUsbFiles]::Child($existing,$file.relative)
            if ([IO.File]::Exists($dst) -and [RelayUsbFiles]::Hash($dst,'SHA256') -ceq $file.hash) { continue }
            $changed.Add($file)
            $folder = [IO.Path]::GetDirectoryName($file.relative)
            while ($folder -and $partialDirs.Add($folder)) { $folder=[IO.Path]::GetDirectoryName($folder) }
        }
        if (-not $changed.Count -and -not $needDirectory) {
            & $Recheck
            return [pscustomobject]@{path=[IO.Path]::Combine($Target.root,'nova');root=$Target.root;volumeLabel=$Target.label
                backupPath=$null;cleared=$false;warning=$null}
        }
        $toStage = [pscustomobject]@{files=$changed; directories=$partialDirs}
    }
    $cluster = [math]::Max([long]1,[long]$Target.allocationUnit)
    $required = [long](($toStage.directories.Count+2)*$cluster)
    foreach ($file in $toStage.files) {
        if ($Target.fileSystem -eq 'FAT32' -and $file.size -gt 4294967295L) { throw 'FAT32 cannot store a file larger than 4 GB. Choose another USB filesystem.' }
        $required += [long]([math]::Ceiling($file.size/[double]$cluster)*$cluster)
    }
    $lowSpace = $required -gt $Target.freeBytes
    if ($lowSpace -and -not $ClearDrive) { throw 'The USB drive has too little free space. Select another drive or enable clearing this drive.' }
    $unique = [guid]::NewGuid().ToString('N')
    $workName = '.relay-staging-'+$unique
    $work = [RelayUsbFiles]::Child($VolumePath,$workName)
    $staged = [RelayUsbFiles]::Child($work,'nova')
    $holding = [RelayUsbFiles]::Child($work,'previous')
    $backupName = 'Relay previous USB files '+(Get-Date -Format 'yyyy-MM-dd HHmmss')+' '+$unique.Substring(0,6)
    $backup = [RelayUsbFiles]::Child($VolumePath,$backupName)
    $backupDisplay = $null
    if ($lowSpace) {
        if ($required -gt $Target.totalBytes) { throw 'The playback package is larger than the USB drive.' }
        $available = [long]$Target.freeBytes
        foreach ($leaf in (Get-StudioUsbUserEntries $VolumePath $workName)) {
            $available += [RelayUsbFiles]::Reclaimable([RelayUsbFiles]::Child($VolumePath,$leaf),$cluster)
            if ($available -ge $required) { break }
        }
        if ($available -lt $required) { throw 'The playback package will not fit even after clearing the USB files.' }
    }
    & $Recheck
    if ([IO.Directory]::Exists($work) -or [IO.Directory]::Exists($backup)) { throw 'A USB staging name is already in use. Retry the export.' }
    $moved = [Collections.Generic.List[string]]::new()
    $active = $false
    $beganPurging = $false
    $warning = $null
    $retainWork = $false
    try {
        if ($lowSpace) {
            # A completely full FAT volume cannot allocate even a staging
            # directory. The user opted to clear it and the complete local
            # package and reclaimable space were verified above.
            $beganPurging = $true
            foreach ($leaf in @(Get-StudioUsbUserEntries $VolumePath $workName)) {
                [RelayUsbFiles]::RemoveChild($VolumePath,$leaf)
            }
            & $Recheck
        }
        [void][IO.Directory]::CreateDirectory($work)
        Copy-StudioUsbPackage $toStage $staged
        & $Recheck
        if ($ClearDrive) {
            if (-not $lowSpace) {
                [void][IO.Directory]::CreateDirectory($holding)
                foreach ($leaf in @(Get-StudioUsbUserEntries $VolumePath $workName)) {
                    Move-StudioUsbEntry ([RelayUsbFiles]::Child($VolumePath,$leaf)) ([RelayUsbFiles]::Child($holding,$leaf))
                    $moved.Add($leaf)
                }
            }
            & $Recheck
            [IO.Directory]::Move($staged,[RelayUsbFiles]::Child($VolumePath,'nova'))
        } else {
            if (Install-StudioUsbMerge $Package $VolumePath $staged $backup $mergeExisting) {
                $backupDisplay = [IO.Path]::Combine($Target.root,$backupName)
            }
        }
        $active = $true
    } catch {
        $reason = $_.Exception.Message
        if ($ClearDrive -and $moved.Count) {
            try {
                for ($i=$moved.Count-1;$i -ge 0;$i--) {
                    $name = $moved[$i]; $old = [RelayUsbFiles]::Child($holding,$name)
                    # A moved dangling link still needs to be restored. Exists
                    # can also return false for a temporarily disconnected USB.
                    Move-StudioUsbEntry $old ([RelayUsbFiles]::Child($VolumePath,$name))
                }
            } catch { $retainWork = $true; throw "USB export stopped. Recover remaining files from '$workName\previous' on the selected USB. $reason" }
        }
        if ($beganPurging) { throw "USB export failed after file clearing began. Earlier USB files may have been erased. $reason" }
        throw $reason
    } finally {
        if (-not $retainWork -and [IO.Directory]::Exists($work)) {
            try { [RelayUsbFiles]::RemoveChild($VolumePath,$workName) }
            catch {
                if ($active) { $warning = "Playback was installed, but cleanup could not finish. Remaining files are in '$workName' on the USB drive." }
            }
        }
    }
    [pscustomobject]@{path=[IO.Path]::Combine($Target.root,'nova'); root=$Target.root; volumeLabel=$Target.label
        backupPath=$backupDisplay; cleared=($ClearDrive -and -not $warning); warning=$warning}
}

function Publish-StudioUsb([string]$StagedNova,[string]$DriveRoot,[string]$VolumeId,[bool]$ClearDrive=$false) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { return Publish-StudioMacUsb $StagedNova $DriveRoot $VolumeId $ClearDrive }
    Initialize-StudioUsbFiles
    $target = Get-StudioUsbTarget $DriveRoot $VolumeId
    $guid = $target.id.Split('/')[0]
    $volumePath = '\\?\Volume{'+$guid+'}\'
    $mutex = [Threading.Mutex]::new($false,'Global\RelayStudioUsb-'+$guid)
    $locked = $false
    $sourceHandle = $null
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another export is already using this USB drive.' }
        $sourceHandle = [RelayUsbFiles]::HoldDirectory([IO.Path]::GetFullPath($StagedNova))
        $source = [RelayUsbFiles]::PhysicalPath($sourceHandle)
        if (-not (Test-StudioUsbSeparateVolume $source $VolumeId)) {
            throw 'The playback package must be staged on a different local volume from the USB drive.'
        }
        $package = Get-StudioUsbPackage $source
        $target = Get-StudioUsbTarget $DriveRoot $VolumeId
        Invoke-StudioUsbInstall $target $volumePath $package $ClearDrive { $null = Get-StudioUsbTarget $DriveRoot $VolumeId }
    } finally {
        if ($null -ne $sourceHandle) { $sourceHandle.Dispose() }
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}


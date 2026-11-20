# Safe removal uses the Windows PnP manager, which can veto removal while files are open.
# https://learn.microsoft.com/windows/win32/api/cfgmgr32/nf-cfgmgr32-cm_request_device_ejectw
function Initialize-StudioUsbEject {
    if ('RelayUsbEject' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public sealed class RelayUsbDeviceNode {
    public string Id;
    public string ParentId;
    public string Service;
    public bool Removable;
}

public static class RelayUsbEject {
    const uint CM_DRP_SERVICE = 0x00000005;
    const uint CM_DRP_CAPABILITIES = 0x00000010;
    const uint CM_DEVCAP_REMOVABLE = 0x00000004;
    [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    static extern uint CM_Locate_DevNodeW(out uint node, string id, uint flags);
    [DllImport("cfgmgr32.dll", ExactSpelling=true)]
    static extern uint CM_Get_Parent(out uint parent, uint node, uint flags);
    [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    static extern uint CM_Get_Device_IDW(uint node, StringBuilder id, uint length, uint flags);
    [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    static extern uint CM_Get_DevNode_Registry_PropertyW(uint node, uint property,
        out uint type, [Out] byte[] buffer, ref uint size, uint flags);
    [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    static extern uint CM_Request_Device_EjectW(uint node, out uint veto,
        StringBuilder vetoName, uint length, uint flags);

    static uint Locate(string id) {
        uint node;
        if (String.IsNullOrWhiteSpace(id) || CM_Locate_DevNodeW(out node, id, 0) != 0)
            throw new InvalidOperationException("The USB device changed or was removed. Refresh the drive list.");
        return node;
    }
    static string DeviceId(uint node) {
        var value = new StringBuilder(1024);
        if (CM_Get_Device_IDW(node, value, (uint)value.Capacity, 0) != 0)
            throw new InvalidOperationException("Windows could not identify the USB device safely.");
        return value.ToString();
    }
    public static RelayUsbDeviceNode ReadNode(string id) {
        uint node = Locate(id), parent, type, length = 1024;
        byte[] data = new byte[length];
        uint result = CM_Get_DevNode_Registry_PropertyW(node, CM_DRP_SERVICE, out type, data, ref length, 0);
        string service = result == 0 && type == 1 ? Encoding.Unicode.GetString(data, 0, (int)length).TrimEnd('\0') : "";
        length = 4;
        data = new byte[4];
        result = CM_Get_DevNode_Registry_PropertyW(node, CM_DRP_CAPABILITIES, out type, data, ref length, 0);
        bool removable = result == 0 && type == 4 && length == 4 && (BitConverter.ToUInt32(data, 0) & CM_DEVCAP_REMOVABLE) != 0;
        uint parentResult = CM_Get_Parent(out parent, node, 0);
        if (parentResult != 0 && parentResult != 13) // CR_NO_SUCH_DEVNODE means the root has no parent.
            throw new InvalidOperationException("Windows could not identify the USB device safely.");
        return new RelayUsbDeviceNode {
            Id = DeviceId(node), Service = service, Removable = removable,
            ParentId = parentResult == 0 ? DeviceId(parent) : null
        };
    }
    public static void Request(string id) {
        uint veto;
        // Supplying a veto buffer avoids an additional Windows dialog. Never force a vetoed removal.
        var vetoName = new StringBuilder(260);
        uint result = CM_Request_Device_EjectW(Locate(id), out veto, vetoName, (uint)vetoName.Capacity, 0);
        if (result == 0) return;
        if (veto >= 2 && veto <= 5)
            throw new InvalidOperationException("Windows says this USB drive is still in use. Close files and apps using it, then try Eject again.");
        if (veto == 12)
            throw new InvalidOperationException("Windows did not allow safe removal in this session. Use Windows Safely Remove Hardware to eject the drive.");
        if (veto == 13)
            throw new InvalidOperationException("The USB device changed or was removed. Refresh the drive list.");
        throw new InvalidOperationException("Windows could not safely eject this USB drive (code " + result + "). Try Windows Safely Remove Hardware.");
    }
}
'@
}

function Get-StudioUsbDeviceNode([string]$DeviceId) {
    Initialize-StudioUsbEject
    [RelayUsbEject]::ReadNode($DeviceId)
}

function Find-StudioUsbRemovalDevice([string]$DiskId, [string[]]$AllDiskIds) {
    $node = Get-StudioUsbDeviceNode $DiskId
    for ($depth = 0; $depth -lt 8; $depth++) {
        # Stop before a USB composite device, hub, controller, or any non-storage parent.
        $storageDisk = $node.Id -match '^(USBSTOR|SCSI)\\' -and $node.Service -eq 'disk'
        $usbStorage = $node.Id -match '^USB\\VID_' -and $node.Service -in 'USBSTOR','UASPStor'
        if (-not ($storageDisk -or $usbStorage)) { break }
        if ($usbStorage -and $node.Removable) {
            foreach ($otherId in $AllDiskIds) {
                if ($otherId -eq $DiskId) { continue }
                $other = Get-StudioUsbDeviceNode $otherId
                for ($level = 0; $level -lt 32; $level++) {
                    if ($other.Id -eq $node.Id) {
                        throw 'This USB enclosure contains more than one disk. Use Windows Safely Remove Hardware to choose what to eject.'
                    }
                    if (-not $other.ParentId) { break }
                    $other = Get-StudioUsbDeviceNode $other.ParentId
                }
                if ($level -eq 32) { throw 'Windows could not verify the USB device safely.' }
            }
            return $node.Id
        }
        if (-not $node.ParentId) { break }
        $node = Get-StudioUsbDeviceNode $node.ParentId
    }
    throw 'Windows could not identify a removable USB storage device. Use Windows Safely Remove Hardware.'
}

function Get-StudioUsbRemovalDevice($Target) {
    $volumePath = '\\?\Volume{' + $Target.id.Split('/')[0] + '}\'
    $volumes = @(Get-Volume -UniqueId $volumePath -ErrorAction Stop)
    if ($volumes.Count -ne 1) { throw 'The selected USB volume changed or was removed.' }
    $parts = @(Get-Partition -Volume $volumes[0] -ErrorAction Stop)
    if ($parts.Count -ne 1 -or $parts[0].DriveLetter -ne $Target.root.Substring(0,1) -or
        $parts[0].IsBoot -or $parts[0].IsSystem) { throw 'The selected USB volume changed or was removed.' }
    $disks = @(Get-Disk -Number $parts[0].DiskNumber -ErrorAction Stop)
    if ($disks.Count -ne 1 -or $disks[0].BusType -ne 'USB' -or $disks[0].IsBoot -or
        $disks[0].IsSystem -or $disks[0].IsOffline) { throw 'Only a connected USB storage drive can be ejected.' }
    # Export locks are per volume; do not remove a sibling volume another export could be using.
    $mounted = @(Get-Partition -DiskNumber $disks[0].Number -ErrorAction Stop | Where-Object {
        $_.DriveLetter -or @($_.AccessPaths | Where-Object { $_ -and $_ -notmatch '^\\\\\?\\Volume\{[a-f\d-]{36}\}\\$' }).Count
    })
    if ($mounted.Count -ne 1) {
        throw 'This USB device contains several mounted volumes. Use Windows Safely Remove Hardware to eject the whole device.'
    }
    $physical = @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop)
    $selected = @($physical | Where-Object { $_.Index -eq $disks[0].Number })
    if ($selected.Count -ne 1 -or -not $selected[0].PNPDeviceID -or
        @($physical | Where-Object { -not $_.PNPDeviceID }).Count) {
        throw 'Windows could not identify the USB disk safely.'
    }
    Find-StudioUsbRemovalDevice $selected[0].PNPDeviceID @($physical | ForEach-Object { $_.PNPDeviceID })
}

function Request-StudioUsbDeviceEject([string]$DeviceId) {
    Initialize-StudioUsbEject
    [RelayUsbEject]::Request($DeviceId)
}

function Invoke-StudioUsbEject($Request, $Response) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { Invoke-StudioMacUsbEject $Request $Response; return }
    $payload = Read-StudioJsonRequest $Request $Response
    if ($null -eq $payload) { return }
    if ($payload.driveRoot -isnot [string] -or $payload.volumeId -isnot [string]) {
        Write-StudioJson $Response @{error='Choose the USB drive used for this export.'} 400
        return
    }
    $mutex = $null
    $locked = $false
    try {
        $target = Get-StudioUsbTarget $payload.driveRoot $payload.volumeId
        $mutex = [Threading.Mutex]::new($false,'Global\RelayStudioUsb-'+$target.id.Split('/')[0])
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'An export is still using this USB drive. Wait for it to finish, then try Eject again.' }
        $device = Get-StudioUsbRemovalDevice $target
        $target = Get-StudioUsbTarget $payload.driveRoot $payload.volumeId
        Request-StudioUsbDeviceEject $device
        Write-StudioJson $Response @{ejected=$true;root=$target.root;label=$target.label}
    } catch {
        $failure = $_.Exception
        while ($failure.InnerException) { $failure = $failure.InnerException }
        Write-StudioJson $Response @{error=$failure.Message} 409
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

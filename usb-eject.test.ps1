# All device discovery and removal below are mocked. No real USB device is ejected.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StudioUsbEject.ps1')
Initialize-StudioUsbEject
function Assert-EjectTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Test failed: $Message" }
}
function Assert-EjectThrows([scriptblock]$Action, [string]$Expected) {
    $message = ''
    try { & $Action } catch { $message = $_.Exception.Message }
    Assert-EjectTest ($message -like "*$Expected*") "Expected refusal: $Expected; got: $message"
}
function Get-StudioUsbDeviceNode([string]$DeviceId) {
    if (-not $script:nodes.ContainsKey($DeviceId)) { throw 'Mock device missing.' }
    $script:nodes[$DeviceId]
}
function New-EjectNode($Id,$Parent,$Service,$Removable) {
    [pscustomobject]@{Id=$Id;ParentId=$Parent;Service=$Service;Removable=$Removable}
}
$diskId = 'USBSTOR\DISK\fixture'
$usbId = 'USB\VID_1234&PID_5678\fixture'
$otherId = 'SCSI\DISK\internal'
$script:nodes = @{
    $diskId = (New-EjectNode $diskId $usbId 'disk' $true)
    $usbId = (New-EjectNode $usbId 'HUB' 'USBSTOR' $true)
    $otherId = (New-EjectNode $otherId 'PCI' 'disk' $false)
    'PCI' = (New-EjectNode 'PCI' 'ROOT' '' $false)
    'ROOT' = (New-EjectNode 'ROOT' $null '' $false)
    'HUB' = (New-EjectNode 'HUB' 'ROOT' 'USBHUB3' $true)
}
Assert-EjectTest ((Find-StudioUsbRemovalDevice $diskId @($diskId,$otherId)) -eq $usbId) 'selects storage transport without touching unrelated disks'
$script:nodes[$otherId].ParentId = $usbId
Assert-EjectThrows { Find-StudioUsbRemovalDevice $diskId @($diskId,$otherId) } 'more than one disk'
$script:nodes[$otherId].ParentId = 'PCI'
$script:nodes[$usbId].Service = 'USBHUB3'
Assert-EjectThrows { Find-StudioUsbRemovalDevice $diskId @($diskId) } 'removable USB storage'
$script:nodes[$usbId].Service = 'usbccgp'
Assert-EjectThrows { Find-StudioUsbRemovalDevice $diskId @($diskId) } 'removable USB storage'
$script:nodes[$usbId].Service = 'UASPStor'
Assert-EjectTest ((Find-StudioUsbRemovalDevice $diskId @($diskId)) -eq $usbId) 'accepts UASP storage transport'
$script:nodes[$usbId].Removable = $false
Assert-EjectThrows { Find-StudioUsbRemovalDevice $diskId @($diskId) } 'removable USB storage'
$script:nodes[$usbId].Removable = $true

# Map by immutable volume GUID, and reject other mounted volumes on the same USB.
$volumeId = [guid]::NewGuid().ToString('D') + '/1234ABCD'
$script:fixtureVolume = [pscustomobject]@{UniqueId=('\\?\Volume{'+$volumeId.Split('/')[0]+'}\')}
$script:fixturePart = [pscustomobject]@{DriveLetter='Z';DiskNumber=3;IsBoot=$false;IsSystem=$false;AccessPaths=@('Z:\',$script:fixtureVolume.UniqueId)}
$script:fixtureParts = @($script:fixturePart)
$script:fixtureDisk = [pscustomobject]@{Number=3;BusType='USB';IsBoot=$false;IsSystem=$false;IsOffline=$false}
function Get-Volume($UniqueId) {
    Assert-EjectTest ($UniqueId -eq $script:fixtureVolume.UniqueId) 'volume GUID used for mapping'
    $script:fixtureVolume
}
function Get-Partition($Volume,$DiskNumber) {
    if ($PSBoundParameters.ContainsKey('Volume')) { return $script:fixturePart }
    $script:fixtureParts
}
function Get-Disk($Number) { $script:fixtureDisk }
function Get-CimInstance($ClassName) { [pscustomobject]@{Index=3;PNPDeviceID=$diskId} }
$fixtureTarget = [pscustomobject]@{root='Z:\';id=$volumeId}
Assert-EjectTest ((Get-StudioUsbRemovalDevice $fixtureTarget) -eq $usbId) 'maps selected volume to exact USB storage device'
$script:fixtureParts += [pscustomobject]@{DriveLetter='';AccessPaths=@('C:\mounted-usb\')}
Assert-EjectThrows { Get-StudioUsbRemovalDevice $fixtureTarget } 'several mounted volumes'
$script:fixtureParts = @($script:fixturePart)
$script:fixtureDisk.BusType = 'SATA'
Assert-EjectThrows { Get-StudioUsbRemovalDevice $fixtureTarget } 'Only a connected USB'
$script:fixtureDisk.BusType = 'USB'
$script:fixturePart.DriveLetter = 'Y'
Assert-EjectThrows { Get-StudioUsbRemovalDevice $fixtureTarget } 'changed or was removed'
$script:fixturePart.DriveLetter = 'Z'

# The endpoint validates the immutable identity again immediately before removal.
$script:payload = [pscustomobject]@{driveRoot='Z:\';volumeId=$volumeId}
function Read-StudioJsonRequest($Request,$Response) { $script:payload }
function Write-StudioJson($Response,$Value,[int]$Status=200) { $script:result = @{status=$Status;body=$Value} }
function Get-StudioUsbTarget($DriveRoot,$VolumeId) {
    $script:checks++
    if ($script:changed -and $script:checks -eq 2) { throw 'The selected USB drive changed or was removed.' }
    [pscustomobject]@{root=$DriveRoot;id=$VolumeId;label='Fixture USB'}
}
function Get-StudioUsbRemovalDevice($Target) { $script:resolved++; 'USB\VID_1234&PID_5678\fixture' }
function Request-StudioUsbDeviceEject($DeviceId) {
    $script:requests++
    if ($script:veto) { throw 'Windows says this USB drive is still in use.' }
}
function Reset-EjectFixture {
    $script:checks=0; $script:requests=0; $script:resolved=0; $script:changed=$false; $script:veto=$false; $script:result=$null
}
Reset-EjectFixture
Invoke-StudioUsbEject $null $null
Assert-EjectTest ($script:result.status -eq 200 -and $script:result.body.ejected -and $script:requests -eq 1 -and $script:checks -eq 2) 'reports success only after removal and both identity checks'
Assert-EjectTest ($script:result.body.root -eq 'Z:\' -and $script:result.body.label -eq 'Fixture USB') 'returns original target label and root'
Reset-EjectFixture
$script:changed=$true
Invoke-StudioUsbEject $null $null
Assert-EjectTest ($script:result.status -eq 409 -and $script:requests -eq 0) 'changed volume refuses removal'
Reset-EjectFixture
$script:veto=$true
Invoke-StudioUsbEject $null $null
Assert-EjectTest ($script:result.status -eq 409 -and -not $script:result.body.ejected -and $script:result.body.error -like '*still in use*') 'veto keeps popup open with actionable error'
Reset-EjectFixture
Invoke-StudioUsbEject $null $null
Assert-EjectTest ($script:result.status -eq 200) 'veto releases the volume lock for retry'

# Hold the export mutex on another thread so the endpoint cannot recursively acquire it.
$ready = [Threading.ManualResetEvent]::new($false)
$release = [Threading.ManualResetEvent]::new($false)
$worker = [PowerShell]::Create()
$null = $worker.AddScript({param($Name,$Ready,$Release)
    $mutex = [Threading.Mutex]::new($false,$Name)
    try { $null=$mutex.WaitOne(); $null=$Ready.Set(); $null=$Release.WaitOne(15000) }
    finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}).AddArgument('Global\RelayStudioUsb-'+$volumeId.Split('/')[0]).AddArgument($ready).AddArgument($release)
$running = $worker.BeginInvoke()
try {
    Assert-EjectTest ($ready.WaitOne(10000)) 'export lock acquired by worker'
    Reset-EjectFixture
    Invoke-StudioUsbEject $null $null
    Assert-EjectTest ($script:result.status -eq 409 -and $script:requests -eq 0 -and $script:resolved -eq 0) 'active export prevents device resolution and ejection'
} finally {
    $null=$release.Set(); $null=$worker.EndInvoke($running)
    $worker.Dispose(); $ready.Dispose(); $release.Dispose()
}
Reset-EjectFixture
$script:payload = $null
Invoke-StudioUsbEject $null $null
Assert-EjectTest ($script:requests -eq 0 -and $script:checks -eq 0) 'rejected authentication/body never reaches device discovery'
$script:payload = [pscustomobject]@{driveRoot='Z:\'}
Invoke-StudioUsbEject $null $null
Assert-EjectTest ($script:result.status -eq 400 -and $script:requests -eq 0) 'missing immutable identity is rejected'
'USB eject tests passed (native declarations compiled; all device operations mocked).'

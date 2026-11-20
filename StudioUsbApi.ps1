# Endpoints are served only on Studio's authenticated local write origin.
# USB commands contain the player password. Only return its availability to
# the browser, and only reuse it from the volume the operator selected.
function Get-StudioUsbPlayerPassword($Drive) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { return Get-StudioMacUsbPlayerPassword $Drive }
    try {
        $volumeGuid = [guid]::Parse($Drive.id.Split('/')[0]).ToString('D')
        $root = '\\?\Volume{' + $volumeGuid + '}\'
        $nova = [IO.DirectoryInfo]::new([IO.Path]::Combine($root,'nova'))
        if (-not $nova.Exists -or ($nova.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
        $file = [IO.FileInfo]::new([IO.Path]::Combine($nova.FullName,'command.json'))
        if (-not $file.Exists -or $file.Length -gt 1MB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([IO.File]::ReadAllText($file.FullName)))
        $command = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        $accounts = @($command.authenticUserInfos | Where-Object { $_.userName -ceq 'admin' -and $_.password -is [string] -and $_.password.Length })
        if ($accounts.Count -eq 1) { return $accounts[0].password }
    } catch { return }
}

function Get-StudioUsbChoices {
    foreach ($drive in @(Get-StudioUsbDrives)) {
        [ordered]@{
            root=$drive.root; id=$drive.id; label=$drive.label
            freeBytes=$drive.freeBytes; totalBytes=$drive.totalBytes
            hasNova=$drive.hasNova
            hasPlayerPassword=[bool](Get-StudioUsbPlayerPassword $drive)
        }
    }
}

function Invoke-StudioUsbExport($Request, $Response) {
    $options = Read-StudioJsonRequest $Request $Response
    if ($null -eq $options) { return }
    $staging = $null
    try {
        if ($options.programType -cnotin @('solution','schedule') -or $options.programId -isnot [string] -or
            $options.playMode -cnotin @('copy','plug') -or $options.duplicatePolicy -cnotin @('keep','replace') -or
            $options.destination -cnotin @('drive','folder') -or $options.clearDrive -isnot [bool] -or
            $options.reuseDrivePassword -isnot [bool]) { throw 'Choose a program, play mode, and export destination.' }
        $project = $options.project
        if (-not (Test-StudioProject $project)) { throw 'Open a valid Studio workspace to export USB playback.' }
        $catalog = Get-StudioCachedCatalog
        $project.solutions = $catalog.data.solutions
        $items = if ($options.programType -ceq 'solution') { $project.solutions } else { $project.screens }
        $selected = @($items | Where-Object { $_.id -ceq $options.programId })
        if ($selected.Count -ne 1) { throw 'The selected program is unavailable. Refresh the library and choose again.' }

        $password = $options.playerPassword
        if ($options.destination -ceq 'drive') {
            if ($options.driveRoot -isnot [string] -or $options.volumeId -isnot [string]) { throw 'Select a connected USB drive.' }
            $drive = Get-StudioUsbTarget -DriveRoot $options.driveRoot -VolumeId $options.volumeId
            if ($options.clearDrive -and $options.eraseVolumeId -cne $drive.id) {
                throw 'Select the erase checkbox again for this USB drive.'
            }
            if ($options.reuseDrivePassword) {
                $password = Get-StudioUsbPlayerPassword $drive
                if (-not $password) { throw 'The saved USB player password is unavailable. Enter the player password.' }
            }
            $parent = Get-StudioUsbStagingParent -VolumeId $drive.id
        } else {
            if ($options.clearDrive -or $options.reuseDrivePassword -or $options.driveRoot -or $options.volumeId) {
                throw 'USB drive options require a connected USB destination.'
            }
            $parent = $ExportRoot
        }
        if ($password -isnot [string] -or $password.Length -eq 0) { throw 'Enter the player password.' }

        $identifier = [guid]::NewGuid().ToString('N')
        $parent = [IO.Path]::GetFullPath($parent).TrimEnd('\')
        [void][IO.Directory]::CreateDirectory($parent)
        $stageName = '.relay-usb-' + $identifier
        $staging = Join-Path $parent $stageName
        if ([IO.Directory]::Exists($staging)) { throw 'Could not reserve a temporary folder.' }
        [void][IO.Directory]::CreateDirectory($staging)
        $writer = @{
            ConfigRoot=$configRoot; Project=$project; ProgramType=$options.programType; ProgramId=$options.programId
            PlayMode=$options.playMode; DuplicatePolicy=$options.duplicatePolicy; PlayerPassword=$password
            OutputDirectory=$staging
        }
        $program = Export-ViplexUsbPlayback @writer
        $nova = Join-Path $staging 'nova'
        if (-not [IO.File]::Exists((Join-Path $nova 'command.json'))) { throw 'The USB package is incomplete.' }
        if ($options.destination -ceq 'drive') {
            $receipt = Publish-StudioUsb -StagedNova $nova -DriveRoot $drive.root -VolumeId $drive.id -ClearDrive $options.clearDrive
            $path = $drive.root
        } else {
            $label = Get-StudioExportLabel $selected[0].name
            $path = Join-Path $parent ('USB {0} {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HHmmss'),$label,$identifier.Substring(0,8))
            [IO.Directory]::Move($staging,$path)
            $receipt = $null
        }
        Write-StudioJson $Response ([ordered]@{path=$path; name=$program.name; destination=$options.destination
            cleared=[bool]$receipt.cleared; backupPath=$receipt.backupPath; warning=$receipt.warning}) 201
    } catch {
        Write-StudioJson $Response @{error=$_.Exception.Message} 422
    } finally {
        if ($staging -and [IO.Directory]::Exists($staging)) {
            $absolute = [IO.Path]::GetFullPath($staging)
            if ([IO.Path]::GetDirectoryName($absolute) -eq $parent -and [IO.Path]::GetFileName($absolute) -ceq $stageName) {
                [IO.Directory]::Delete($absolute, $true)
            }
        }
    }
}

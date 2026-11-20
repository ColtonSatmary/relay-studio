# Read remembered players without selecting credentials from the ViPlex database.
# These are last-known addresses; discovery/login must verify the serial before publishing.
function Get-StudioNetworkKnownPlayers([string]$ConfigRoot) {
    $database = Join-Path $ConfigRoot 'DB.SQLite'
    if (-not [IO.File]::Exists($database)) { return }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $query = 'SELECT Sn, Alias, Ip, Width, Height, ProductName FROM nova_screenproto ORDER BY rowid DESC'
    foreach ($row in @(Read-StudioRows $database $query)) {
        $serial = ([string]$row.Sn).Trim()
        if ($serial -notmatch '^[A-Za-z0-9_-]{1,128}$' -or -not $seen.Add($serial)) { continue }
        $name = ([string]$row.Alias).Trim()
        if (-not $name) { $name = $serial }
        $address = ([string]$row.Ip).Trim()
        $parsed = $null
        if ($address -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$' -or
            -not [Net.IPAddress]::TryParse($address, [ref]$parsed) -or
            $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { $address = '' }
        [pscustomobject]@{
            id=$serial; sn=$serial; name=$name; ip=$address
            model=[string]$row.ProductName; width=[int]$row.Width; height=[int]$row.Height
            source='ViPlex'; remembered=$true; httpsPort=16674
        }
    }
}

# Uses the existing manifest writers, not the USB command writer. Network login
# credentials never enter this directory or the metadata returned to the caller.
function Export-StudioNetworkProgram {
    param(
        [string]$ConfigRoot, $Project,
        [ValidateSet('solution','schedule')][string]$ProgramType,
        [string]$ProgramId, [string]$OutputDirectory
    )
    $stage = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($OutputDirectory))
    if (-not $stage.Exists -or ($stage.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        @(Get-ChildItem -LiteralPath $stage.FullName -Force).Count) {
        throw 'Network publishing requires a new, empty staging folder.'
    }
    $items = if ($ProgramType -ceq 'solution') { $Project.solutions } else { $Project.screens }
    $selected = @($items | Where-Object { $_.id -ceq $ProgramId })
    if ($selected.Count -ne 1 -or $selected[0].missing) { throw 'The selected solution or schedule is unavailable.' }
    if ([int]$selected[0].width -lt 1 -or [int]$selected[0].height -lt 1) {
        throw 'Set the canvas dimensions before publishing.'
    }
    $package = if ($ProgramType -ceq 'schedule') {
        Export-ViplexSchedule -ConfigRoot $ConfigRoot -Project $Project -ScreenId $ProgramId -OutputDirectory $stage.FullName -UsbPlayback
    } else {
        Export-ViplexUsbSolution -ConfigRoot $ConfigRoot -Solution $selected[0] -OutputDirectory $stage.FullName
    }
    $info = $package.programInfo
    Assert-ViplexName ([string]$info.name)
    $nova = Join-Path $stage.FullName 'nova'
    if ([IO.File]::Exists((Join-Path $nova 'command.json'))) { throw 'The network package unexpectedly contains a USB command.' }
    $programRoot = Join-Path $nova 'program'
    $programDirectory = Join-Path $programRoot ([string]$info.name)
    $mediaDirectory = Join-Path $nova 'media'
    if (-not [IO.Directory]::Exists($programDirectory) -or -not [IO.Directory]::Exists($mediaDirectory)) {
        throw 'The network package is incomplete.'
    }

    $programMap = [ordered]@{}
    $pageThumbnails = [Collections.ArrayList]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $programRoot -File -Recurse | Sort-Object FullName)) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The network package contains a linked file.' }
        $isMain = $file.DirectoryName -eq $programDirectory
        if (-not $isMain -and $file.Name -notmatch '^[a-f\d]{32}\.(?:png|jpe?g)$') {
            throw 'The network package contains an unexpected page thumbnail.'
        }
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm MD5).Hash.ToLowerInvariant()
        if (-not $isMain -and $hash -cne $file.BaseName) { throw 'A page thumbnail does not match its checksum.' }
        if ($programMap.Contains($file.Name)) {
            if ($programMap[$file.Name].md5 -cne $hash) { throw 'The network package contains conflicting file names.' }
            continue
        }
        $entry = [pscustomobject]@{fileName=$file.Name; path=$file.FullName; size=[long]$file.Length; md5=$hash}
        $programMap[$file.Name] = $entry
        if (-not $isMain) { [void]$pageThumbnails.Add($entry) }
    }
    if (-not $programMap.Contains('planlist.json') -or $programMap['planlist.json'].md5 -cne $info.identifier -or
        -not $programMap.Contains([string]$info.thumbnailName)) { throw 'The network manifest or cover thumbnail is incomplete.' }
    $mediaFiles = @(foreach ($file in @(Get-ChildItem -LiteralPath $mediaDirectory -File | Sort-Object Name)) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Name -notmatch '^([a-f\d]{32})\.[a-z0-9]+$') {
            throw 'The network package contains an invalid media file.'
        }
        $expected = $Matches[1]
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm MD5).Hash.ToLowerInvariant()
        if ($hash -cne $expected) { throw 'A network media file does not match its checksum.' }
        [pscustomobject]@{fileName=$file.Name; path=$file.FullName; size=[long]$file.Length; md5=$hash}
    })
    $programFiles = @($programMap.Values)
    [pscustomobject]@{
        name=[string]$info.name; programType=$ProgramType; programId=$ProgramId; programInfo=$info
        programDirectory=$programDirectory; mediaDirectory=$mediaDirectory
        programFiles=$programFiles; pageThumbnailFiles=@($pageThumbnails); mediaFiles=$mediaFiles
        totalSize=[long](($programFiles | Measure-Object size -Sum).Sum)
        totalMediaSize=[long](($mediaFiles | Measure-Object size -Sum).Sum)
        width=[int]$selected[0].width; height=[int]$selected[0].height
        ruleCount=$package.ruleCount; solutionCount=$package.solutionCount; mediaCount=$mediaFiles.Count
    }
}

function Assert-ViplexName([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 140 -or
        $Value.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $Value -match '[. ]$|^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
        throw "The name '$Value' cannot be used for a ViPlex program folder. Choose another name."
    }
}

function Get-ViplexExportDate([string]$Value) {
    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}$') { throw "Invalid schedule date '$Value'." }
    [datetime]::ParseExact($Value,'yyyy-MM-dd',[cultureinfo]::InvariantCulture)
}

function Get-ViplexExportMinute([string]$Clock, [switch]$End) {
    if ($End -and $Clock -eq '24:00') { return 1440 }
    if ($Clock -notmatch '^([01]\d|2[0-3]):([0-5]\d)$') { throw "Invalid schedule time '$Clock'." }
    60 * [int]$Matches[1] + [int]$Matches[2]
}

function ConvertTo-ViplexRules($Cue) {
    $from = Get-ViplexExportDate $Cue.startDate
    $until = if ($Cue.endDate) { Get-ViplexExportDate $Cue.endDate } else { [datetime]'4012-01-01' }
    if ($from -gt $until -or $from -ge [datetime]'4012-01-01' -or ($Cue.endDate -and $until -ge [datetime]'4012-01-01')) {
        throw 'The date range must end before the native ViPlex open-ended date in 4012.'
    }
    $begin = Get-ViplexExportMinute $Cue.start
    $end = Get-ViplexExportMinute $Cue.end -End
    if ($begin -eq $end) { throw 'Set different start and end times.' }
    if (-not @($Cue.days).Count) { throw 'A block needs at least one weekday.' }
    $days = @(foreach ($day in $Cue.days) {
        if ($null -eq $day -or ([string]$day) -notmatch '^[0-6]$') { throw 'Invalid schedule weekday.' }
        [int]$day
    }) | Sort-Object -Unique
    $days = @($days)
    if (-not $days.Count) { throw 'A block needs at least one weekday.' }
    $excluded = @(foreach ($date in $Cue.excludedDates) {
        $value = Get-ViplexExportDate $date
        if ($value -ge $from -and $value -le $until -and $days -contains [int]$value.DayOfWeek) { $value }
    }) | Sort-Object -Unique
    # Exceptions belong to the show's start date. Split into bounded date
    # ranges before splitting an overnight block into two native clock windows.
    $ranges = @(foreach ($cut in $excluded) {
        if ($from -lt $cut) { [pscustomobject]@{from=$from; until=$cut.AddDays(-1)} }
        $from = $cut.AddDays(1)
    }
    if ($from -le $until) { [pscustomobject]@{from=$from; until=$until} })
    foreach ($range in $ranges) {
        $duration = ($range.until - $range.from).Days
        $validDays = @($days | Where-Object { (($_ - [int]$range.from.DayOfWeek + 7) % 7) -le $duration })
        if (-not $validDays.Count) { continue }
        $overnight = $end -lt $begin
        [pscustomobject]@{
            from=$range.from; until=$range.until; days=$validDays; begin=$begin
            end=$(if ($overnight) { 1440 } else { $end }); solutionId=$Cue.solutionId
        }
        if ($overnight -and $end -gt 0) {
            [pscustomobject]@{
                from=$range.from.AddDays(1)
                until=$(if ($range.until -eq [datetime]'4012-01-01') { $range.until } else { $range.until.AddDays(1) })
                days=@($validDays | ForEach-Object { ($_+1) % 7 } | Sort-Object)
                begin=0; end=$end; solutionId=$Cue.solutionId
            }
        }
    }
}

function Write-ViplexJsonFile($Directory, $Name, $Value) {
    $file = Join-Path $Directory $Name
    $json = ConvertTo-Json -InputObject $Value -Depth 100 -Compress
    [IO.File]::WriteAllText($file, $json, [Text.UTF8Encoding]::new($false))
    [ordered]@{ fileName=$Name; md5=(Get-FileHash -LiteralPath $file -Algorithm MD5).Hash.ToLowerInvariant() }
}

function Assert-ViplexRuleTimes($Rules) {
    $sorted = @($Rules | Sort-Object begin)
    for ($i=0; $i -lt $sorted.Count; $i++) {
        $first = $sorted[$i]
        for ($j=$i+1; $j -lt $sorted.Count; $j++) {
            $next = $sorted[$j]
            if ($next.begin -ge $first.end) { break }
            $from = if ($first.from -gt $next.from) { $first.from } else { $next.from }
            $until = if ($first.until -lt $next.until) { $first.until } else { $next.until }
            $daysApart = ($until - $from).Days
            if ($daysApart -lt 0) { continue }
            foreach ($day in $first.days) {
                if ($next.days -contains $day -and (($day - [int]$from.DayOfWeek + 7) % 7) -le $daysApart) {
                    throw 'Two blocks overlap on this schedule. Adjust their times before exporting.'
                }
            }
        }
    }
}

function Get-ViplexOriginalMediaPaths($Node, $Map) {
    if ($Node -is [array]) {
        foreach ($child in $Node) { Get-ViplexOriginalMediaPaths $child $Map }
    } elseif ($Node -is [pscustomobject]) {
        if ($Node.dataSource -match '^[a-f\d]{32}\.[a-z0-9]+$') {
            $Map[[string]$Node.dataSource] = [string]$Node.originalDataSource
        }
        foreach ($property in $Node.psobject.Properties) {
            if ($property.Value -is [array] -or $property.Value -is [pscustomobject]) {
                Get-ViplexOriginalMediaPaths $property.Value $Map
            }
        }
    }
}

function Read-ViplexExportPlaylist([string]$ConfigRoot, $Solution) {
    $database = Join-Path $ConfigRoot 'DB.SQLite'
    if ([IO.File]::Exists($database) -and (Get-Command Get-ViplexDatabasePlaylist -CommandType Function -ErrorAction SilentlyContinue)) {
        $current = Get-ViplexDatabasePlaylist -ConfigRoot $ConfigRoot -Solution $Solution
        if ($null -ne $current) { return $current }
    }
    $snapshotReady = $Solution.source.snapshot -match '^\d+$' -and $Solution.source.playlist -match '^playlist\d+\.json$'
    if ($snapshotReady) {
        $directory = Join-Path (Join-Path $ConfigRoot 'Publish') $Solution.source.snapshot
        $file = Join-Path $directory $Solution.source.playlist
        $snapshotReady = [IO.File]::Exists($file)
        if ($snapshotReady -and $Solution.source.modified) {
            $lastEdit = [datetime]::Parse($Solution.source.modified, [cultureinfo]::InvariantCulture)
            $snapshotReady = $lastEdit -le [IO.File]::GetLastWriteTime($file)
        }
    }
    if (-not $snapshotReady) {
        throw "Export or publish the current version of '$($Solution.name)' in ViPlex to create its native playlist."
    }
    $list = [IO.File]::ReadAllText($file) | ConvertFrom-Json -ErrorAction Stop
    if ("viplex-$($list.uuid)" -ne $Solution.id) { throw "The native playlist for '$($Solution.name)' changed. Refresh the library." }
    $plan = [IO.File]::ReadAllText((Join-Path $directory 'planlist.json')) | ConvertFrom-Json -ErrorAction Stop
    $record = @($plan.playlists | Where-Object fileName -EQ $Solution.source.playlist)
    if ($record.Count -ne 1 -or (Get-FileHash -LiteralPath $file -Algorithm MD5).Hash -ne $record[0].md5) {
        throw "ViPlex is updating '$($Solution.name)'. Retry after the publish completes."
    }
    if ($plan.medialists.Count) { throw "This version cannot package the external media lists used by '$($Solution.name)'." }
    $json = ConvertTo-Json -InputObject $list -Depth 100 -Compress
    $resources = @($plan.resources | Where-Object { $json.IndexOf(('"' + $_.fileName + '"'), [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    $list.name = $Solution.name
    if ([IO.File]::Exists($database)) {
        $guidHex = [BitConverter]::ToString(([guid]$list.uuid).ToByteArray()).Replace('-','')
        $current = @(Read-StudioRows $database "SELECT thumbpath FROM nova_playlist WHERE uuid = x'$guidHex' AND coalesce(isdelete,0)=0")
        if ($current.Count -and $current[0].thumbpath) { $list.thumbpath = $current[0].thumbpath }
    }
    $mediaPaths = @{}
    Get-ViplexOriginalMediaPaths $list.sceneItems $mediaPaths
    foreach ($ref in $mediaPaths.Keys) {
        if ($resources.fileName -notcontains $ref) { throw "The media manifest for '$($Solution.name)' is incomplete. Export the solution in ViPlex again." }
    }
    [pscustomobject]@{playlist=$list; resources=$resources; mediaPaths=$mediaPaths}
}

function Set-ViplexPlaylistIndex($Playlist, [int]$Index) {
    $previous = [int]$Playlist.id
    if ($Index -eq $previous) { return }
    $container = @($Playlist.sceneItems[0].page.widgetContainers)
    $widgets = @($container[0].contents.widgets)
    if ($Playlist.sceneItems.Count -ne 1 -or $container.Count -ne 1 -or $widgets.Count -ne 1 -or
        $container[0].id -ne (2+$previous)*100000 -or $widgets[0].id -ne (1+$previous)*100000) {
        throw "The multi-region layout in '$($Playlist.name)' requires native ViPlex export."
    }
    $Playlist.id = $Index
    $widgets[0].id = (1+$Index)*100000
    $container[0].id = (2+$Index)*100000
}

function Copy-ViplexPlaylist($Playlist, [string]$Name, [string]$ConfigRoot) {
    # ViPlex imports each embedded solution into its library. Give the copy
    # its own name and object identities, also translating internal references.
    $json = ConvertTo-Json -InputObject $Playlist -Depth 100 -Compress
    $guid = '[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}'
    $identities = @{}
    foreach ($match in [regex]::Matches($json, ('"uuid"\s*:\s*"(' + $guid + ')"'), [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $key = $match.Groups[1].Value
        if (-not $identities.ContainsKey($key)) { $identities[$key] = [guid]::NewGuid().ToString('D') }
    }
    $json = [regex]::Replace($json, ('"(' + $guid + ')"'), {
        param($match)
        $key = $match.Groups[1].Value
        if ($identities.ContainsKey($key)) { return ('"' + $identities[$key] + '"') }
        return $match.Value
    })
    $copy = $json | ConvertFrom-Json -ErrorAction Stop
    $copy.name = $Name
    $copy.thumbpath = Join-Path $ConfigRoot ($copy.uuid + '.png')
    $copy
}

function Get-ViplexOccupiedNames([string]$ConfigRoot, $Solutions) {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($solution in $Solutions) {
        if ($solution.id -like 'viplex-*') { [void]$names.Add(($solution.name -replace '[-_ ]','')) }
    }
    $db = Join-Path $ConfigRoot 'DB.SQLite'
    if ([IO.File]::Exists($db)) {
        $query = @'
SELECT name FROM nova_schedule_constraint WHERE coalesce(isdelete,0)=0
UNION SELECT name FROM nova_playlist WHERE coalesce(isdelete,0)=0
UNION SELECT scheduleName AS name FROM nova_relation_schedule2playlist
'@
        foreach ($row in (Read-StudioRows $db $query)) {
            if ($row.name) { [void]$names.Add(($row.name -replace '[-_ ]','')) }
        }
    }
    return ,$names
}

function Get-ViplexProgramBundle([string]$ConfigRoot, $Solution, $Screen) {
    if ($Solution.source.kind -in @('localVideo','localImage')) {
        if ($Solution.source.assetId -notmatch '^[a-fA-F0-9]{64}$') { throw 'This solution has an invalid local media ID.' }
        $asset = Get-StudioMediaAsset -AssetId $Solution.source.assetId
        $assetAliases = @($asset.solutions | Where-Object id -CEQ $Solution.id)
        if ($assetAliases.Count -ne 1) { throw 'This solution is missing from the local media library.' }
        return Get-ViplexLocalMediaPlaylist -Solution $assetAliases[0] -Screen $Screen -Asset $asset
    }
    if ($Solution -and $Solution.id -match '^viplex-[a-fA-F0-9-]{36}$') {
        return Read-ViplexExportPlaylist $ConfigRoot $Solution
    }
    throw 'Choose a ViPlex solution or an imported local video or JPG image.'
}

function Copy-ViplexPageThumbnails([string]$ConfigRoot, $Bundle, [string]$SourceName, [string]$Destination) {
    if (-not $Bundle.thumbnailPath) { Assert-ViplexName $SourceName }
    foreach ($scene in $Bundle.playlist.sceneItems) {
        if (-not $scene.thumbnail) { continue }
        Assert-ViplexName $scene.thumbnail
        $src = if ($Bundle.thumbnailPath) { $Bundle.thumbnailPath } else {
            Join-Path (Join-Path (Join-Path $ConfigRoot 'ScenePageThumbnailPic') $SourceName) $scene.thumbnail
        }
        if (-not [IO.File]::Exists($src)) { throw "Missing page thumbnail in ViPlex for '$SourceName'. Export the solution in ViPlex and retry." }
        $dst = Join-Path $Destination $scene.thumbnail
        if (-not [IO.File]::Exists($dst)) { [IO.File]::Copy($src,$dst) }
    }
}

function Copy-ViplexProgramResources([string]$ConfigRoot, $Bundle, [string]$Name, [string]$Destination, $MediaFiles) {
    $bytes = 0L
    foreach ($resource in $Bundle.resources) {
        if ($resource.fileName -notmatch '^([0-9a-f]{32})\.[a-z0-9]+$' -or $resource.md5 -ne $Matches[1]) {
            throw "Unsupported native media reference in '$Name'."
        }
        $key = $resource.fileName
        $bytes += [long]$resource.size
        if ($MediaFiles.Contains($key)) { continue }
        $source = Join-Path (Join-Path $ConfigRoot 'Media') $key
        if (-not [IO.File]::Exists($source)) {
            # Both candidates originate in the local catalog. Verify the bytes
            # in the package against the original native manifest.
            $original = if ($Bundle.mediaPaths) { $Bundle.mediaPaths[$key] } else { $Bundle.mediaPath }
            if ($original -notmatch '^[A-Za-z]:[\\/]' -or -not [IO.File]::Exists($original)) {
                throw "The source media for '$Name' is missing. Restore the original file or refresh the solution in ViPlex."
            }
            $source = $original
        }
        $copy = Join-Path $Destination $key
        [IO.File]::Copy($source, $copy)
        if ([IO.FileInfo]::new($copy).Length -ne [long]$resource.size -or (Get-FileHash -LiteralPath $copy -Algorithm MD5).Hash -ne $resource.md5) {
            throw "The media checksum for '$Name' does not match its manifest."
        }
        $MediaFiles[$key] = $resource
    }
    return $bytes
}

function New-ViplexPlaySolution {
    $task = [ordered]@{
        id=1; name='local_net_program_task'; layout=[ordered]@{
            x='0%'; y='0%'; width='100%'; height='100%'; xNum=0.0; yNum=0.0; widthNum=100.0; heightNum=100.0
        }; zOrder=1
    }
    [ordered]@{
        version='1.0.0'; source=[ordered]@{type=1; platform=2}; uuid=([guid]::NewGuid().ToString('D'))
        items=@($task); target=@(-1); name='play_solution'; picktype='DEFAULT'; itemCount=1; id=0
    }
}

function Export-ViplexSchedule([string]$ConfigRoot, $Project, [string]$ScreenId, [string]$OutputDirectory, [string]$ScheduleName, [switch]$UsbPlayback) {
    if (-not [IO.Directory]::Exists($OutputDirectory) -or @(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count) {
        throw 'Choose an empty export folder.'
    }
    $screen = @($Project.screens | Where-Object id -CEQ $ScreenId)
    if ($screen.Count -ne 1) { throw 'Choose a schedule to export.' }
    $occupied = Get-ViplexOccupiedNames $ConfigRoot $Project.solutions
    $packageTag = [guid]::NewGuid().ToString('N').Substring(0,8).ToUpperInvariant()
    if ($UsbPlayback) {
        # The player applies the user's duplicate policy to this visible name.
        $name = [string]$screen[0].name
    } elseif ($PSBoundParameters.ContainsKey('ScheduleName')) {
        if ($ScheduleName -cnotmatch '^[A-Za-z0-9]+$') { throw 'Use only letters and numbers for the ViPlex schedule name.' }
        $name = $ScheduleName
    } else {
        $stem = ([string]$screen[0].name) -replace '[^A-Za-z0-9]',''
        $name = 'Relay' + $stem.Substring(0,[math]::Min(40,$stem.Length)) + 'V' + $packageTag
    }
    Assert-ViplexName $name
    if (-not $occupied.Add($name) -and -not $UsbPlayback) { throw "ViPlex already contains '$name'. Choose a new schedule name." }
    $cues = @($Project.cues | Where-Object screenId -CEQ $ScreenId)
    $rules = @(foreach ($cue in $cues) { ConvertTo-ViplexRules $cue })
    if (-not $rules.Count) { throw 'No playback blocks remain on this schedule.' }
    Assert-ViplexRuleTimes $rules

    $solutions = @{}
    foreach ($solution in $Project.solutions) { $solutions[$solution.id] = $solution }
    $used = @($rules | ForEach-Object solutionId | Select-Object -Unique)
    $nova = [IO.Directory]::CreateDirectory((Join-Path $OutputDirectory 'nova')).FullName
    $program = [IO.Directory]::CreateDirectory((Join-Path $nova 'program')).FullName
    $media = [IO.Directory]::CreateDirectory((Join-Path $nova 'media')).FullName
    $package = [IO.Directory]::CreateDirectory((Join-Path $program $name)).FullName
    $thumb = Join-Path $PSScriptRoot 'ScheduleThumb.png'
    [IO.File]::Copy($thumb, (Join-Path $package 'ScheduleThumb.png'))
    $catalog = @{}
    $mediaFiles = [ordered]@{}
    $playlistFiles = @(foreach ($solutionId in $used) {
        $solution = $solutions[$solutionId]
        $native = Get-ViplexProgramBundle $ConfigRoot $solution $screen[0]
        $sourceName = $solution.name
        # The native solution list shows this short title. Keep its original
        # label first, followed by a per-package tag and its playlist number.
        $label = $sourceName.Normalize([Text.NormalizationForm]::FormD) -replace '[^A-Za-z0-9]',''
        if (-not $label) { $label = 'Video' }
        $number = ($catalog.Count+1).ToString('D2')
        $label = $label.Substring(0,[math]::Min(17-$number.Length,$label.Length))
        $assetStem = 'Relay' + $label
        $assetName = $assetStem + $packageTag + $number
        while (-not $occupied.Add($assetName)) { $assetName = $assetStem + [guid]::NewGuid().ToString('N').Substring(0,8).ToUpperInvariant() + $number }
        $list = Copy-ViplexPlaylist $native.playlist $assetName $ConfigRoot
        $folder = [IO.Directory]::CreateDirectory((Join-Path $program $list.name)).FullName
        Copy-ViplexPageThumbnails $ConfigRoot $native $sourceName $folder
        Set-ViplexPlaylistIndex $list $catalog.Count
        $filename = "playlist$($list.id).json"
        $bytes = Copy-ViplexProgramResources $ConfigRoot $native $sourceName $media $mediaFiles
        $catalog[$solutionId] = @{id=$list.id; file=$filename; name=$list.name; size=$bytes}
        Write-ViplexJsonFile $package $filename $list
    })
    $sourceInfo = [ordered]@{type=1; platform=2}
    $solutionFile = Write-ViplexJsonFile $package 'play_solution.json' (New-ViplexPlaySolution)
    $constraints = [Collections.ArrayList]::new()
    $relations = [Collections.ArrayList]::new()
    $totalSize = 0L
    $allDays = 0..6
    # ViPlex exports a dormant entry for each solution in its Add Solution list.
    $placeholders = @(foreach ($id in $used) {
        [pscustomobject]@{solutionId=$id; from=[datetime]'1640-02-01'; until=[datetime]'1791-02-01'; begin=0; end=1440; days=$allDays}
    })
    foreach ($rule in ($placeholders + $rules)) {
        $item = $catalog[$rule.solutionId]
        $id = $constraints.Count
        $stop = [timespan]::FromSeconds(60 * $rule.end - 1)
        $begin = (Format-ViplexMinute $rule.begin) + ':00'
        # The native timestamp stores local wall time followed by its UTC offset.
        # Start and end can fall on opposite sides of a daylight-saving change.
        $beginWall = [datetime]::SpecifyKind($rule.from.AddMinutes($rule.begin), [DateTimeKind]::Unspecified)
        $endWall = [datetime]::SpecifyKind($rule.until.Add($stop), [DateTimeKind]::Unspecified)
        $zone = [TimeZoneInfo]::Local
        $beginOffset = [datetimeoffset]::new($beginWall, $zone.GetUtcOffset($beginWall)).ToString('zzz')
        $endOffset = [datetimeoffset]::new($endWall, $zone.GetUtcOffset($endWall)).ToString('zzz')
        $cron = ($rule.days | ForEach-Object { $_+1 }) -join ','
        $limited = $rule.from.Year -ne 1640 -and ($rule.from -ne [datetime]'1970-01-01' -or $rule.until -ne [datetime]'4012-01-01')
        [void]$constraints.Add([ordered]@{
            id=$id; priority=10000000L * ($id+1); name=$item.name
            startTime=$rule.from.ToString('yyyy-MM-dd') + 'T' + $begin + 'Z' + $beginOffset
            endTime=$rule.until.ToString('yyyy-MM-dd') + 'T' + $stop.ToString('hh\:mm\:ss') + 'Z' + $endOffset
            isNotForever=$limited; cron=@("0 0 0 ? * $cron")
        })
        $reference = [ordered]@{ playlistId=$item.id; playlistSource=$item.file }
        $binding = [ordered]@{constraintId=$id; constraintSource='schedule_constraint0.json'; playlists=@($reference)}
        [void]$relations.Add([ordered]@{taskId=1; scheduleConstraints=@($binding); playSolutionSource='play_solution.json'})
        $totalSize += $item.size
    }
    $constraintFile = Write-ViplexJsonFile $package 'schedule_constraint0.json' ([ordered]@{id=0; name='schedule_constraint0'; constraints=$constraints})
    $relationFile = Write-ViplexJsonFile $package 'playSolutionRelation.json' ([ordered]@{
        id=1; name='playSolutionRelation'; playSolutionSource='play_solution.json'; relations=$relations
    })
    $planFile = Write-ViplexJsonFile $package 'planlist.json' ([ordered]@{
        name=$name; source=$sourceInfo; playRelations=@($relationFile); playSolutions=@($solutionFile)
        playlists=$playlistFiles; scheduleConstraints=@($constraintFile); medialists=@(); resources=@($mediaFiles.Values); thumbnails=@()
    })
    $programInfo = [ordered]@{
        name=$name; url=$name; isPlay=$false; isImport=$true; thumbnailName='ScheduleThumb.png'
        identifier=$planFile.md5; version='2.0'; size=$totalSize; isOverride=$false
    }
    if ($UsbPlayback) {
        return [pscustomobject]@{programInfo=$programInfo; ruleCount=$rules.Count; solutionCount=$used.Count; mediaCount=$mediaFiles.Count}
    }
    $command = [ordered]@{programInfos=@($programInfo); authenticUserInfos=@()} | ConvertTo-Json -Depth 5 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($command))
    [IO.File]::WriteAllText((Join-Path $nova 'command.json'), $encoded, [Text.Encoding]::ASCII)
    [pscustomobject]@{scheduleName=$name; ruleCount=$rules.Count; solutionCount=$used.Count; mediaCount=$mediaFiles.Count}
}

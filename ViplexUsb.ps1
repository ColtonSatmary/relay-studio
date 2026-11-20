# Build in a new staging directory. The drive publisher handles installing
# this directory on the chosen USB volume after the entire package is ready.
function Export-ViplexUsbSolution([string]$ConfigRoot, $Solution, [string]$OutputDirectory) {
    $name = [string]$Solution.name
    Assert-ViplexName $name
    $bundle = Get-ViplexProgramBundle $ConfigRoot $Solution $Solution
    $playlist = $bundle.playlist
    Set-ViplexPlaylistIndex $playlist 0
    $nova = Join-Path $OutputDirectory 'nova'
    $program = [IO.Directory]::CreateDirectory((Join-Path (Join-Path $nova 'program') $name)).FullName
    $media = [IO.Directory]::CreateDirectory((Join-Path $nova 'media')).FullName
    $mediaFiles = [ordered]@{}
    $bytes = Copy-ViplexProgramResources $ConfigRoot $bundle $name $media $mediaFiles
    Copy-ViplexPageThumbnails $ConfigRoot $bundle $name $program

    $thumbnails = @(foreach ($fileName in @($playlist.sceneItems | ForEach-Object thumbnail | Where-Object { $_ } | Select-Object -Unique)) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $program $fileName) -Algorithm MD5).Hash.ToLowerInvariant()
        if ($fileName -match '^([0-9a-f]{32})\.' -and $hash -ne $Matches[1]) {
            throw "The page thumbnail for '$name' does not match its manifest."
        }
        # ViPlex records the filename and MD5 with a zero size for page images.
        [ordered]@{fileName=$fileName; size=0; md5=$hash}
    })
    $coverName = [IO.Path]::GetFileName([string]$playlist.thumbpath)
    $coverSource = $null
    if ($bundle.thumbnailPath) {
        $coverSource = $bundle.thumbnailPath
        $coverName = [string]$playlist.uuid + '.png'
    } elseif ($coverName -match '^[a-f0-9-]{32,36}\.(?:png|jpe?g)$') {
        $coverSource = Join-Path $ConfigRoot $coverName
    }
    if ($coverSource -and [IO.File]::Exists($coverSource)) {
        $destination = Join-Path $program $coverName
        if (-not [IO.File]::Exists($destination)) { [IO.File]::Copy($coverSource, $destination) }
    } elseif ($thumbnails.Count) {
        $coverName = $thumbnails[0].fileName
    } else {
        throw "The cover thumbnail for '$name' is missing. Refresh the original solution and retry."
    }

    # Standalone solution packages use one unnumbered, always-on constraint.
    # The scene and widget rules inside the playlist retain their own timing.
    $rule = [ordered]@{
        id=0; priority=1000; name='schedule_item'; startTime='1970-01-01T00:00:00Z+08:00'
        endTime='4012-01-01T23:59:59Z+08:00'; isNotForever=$false; cron=@('0 0 0 ? * 1,2,3,4,5,6,7')
    }
    $playlistFile = Write-ViplexJsonFile $program 'playlist0.json' $playlist
    $playFile = Write-ViplexJsonFile $program 'play_solution.json' (New-ViplexPlaySolution)
    $constraints = Write-ViplexJsonFile $program 'schedule_constraint.json' ([ordered]@{
        id=0; name='schedule_constraint'; constraints=@($rule)
    })
    $binding = [ordered]@{constraintId=0; constraintSource=$constraints.fileName; playlists=@([ordered]@{playlistId=0; playlistSource=$playlistFile.fileName})}
    $relations = Write-ViplexJsonFile $program 'playSolutionRelation.json' ([ordered]@{
        id=0; name='playSolutionRelation'; playSolutionSource=$playFile.fileName
        relations=@([ordered]@{taskId=1; scheduleConstraints=@($binding)})
    })
    $planFile = Write-ViplexJsonFile $program 'planlist.json' ([ordered]@{
        name=$name; source=[ordered]@{type=1; platform=2}; playRelations=@($relations); playSolutions=@($playFile)
        playlists=@($playlistFile); scheduleConstraints=@($constraints); medialists=@(); resources=@($mediaFiles.Values); thumbnails=$thumbnails
    })
    $programInfo = [ordered]@{
        name=$name; url=$name; isPlay=$true; isImport=$true; thumbnailName=$coverName
        identifier=$planFile.md5; version='2.0'; size=$bytes; isOverride=$false
    }
    [pscustomobject]@{programInfo=$programInfo; ruleCount=1; solutionCount=1; mediaCount=$mediaFiles.Count}
}

function Export-ViplexUsbPlayback {
    param(
        [string]$ConfigRoot, $Project,
        [ValidateSet('solution','schedule')][string]$ProgramType,
        [string]$ProgramId, [string]$PlayerPassword, [string]$OutputDirectory,
        [ValidateSet('copy','plug')][string]$PlayMode='copy',
        [ValidateSet('keep','replace')][string]$DuplicatePolicy='replace'
    )
    if ([string]::IsNullOrEmpty($PlayerPassword)) { throw 'Enter the player password for USB playback.' }
    if (-not [IO.Directory]::Exists($OutputDirectory) -or @(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count) {
        throw 'USB playback staging requires a new, empty folder.'
    }
    $package = if ($ProgramType -eq 'schedule') {
        Export-ViplexSchedule -ConfigRoot $ConfigRoot -Project $Project -ScreenId $ProgramId -OutputDirectory $OutputDirectory -UsbPlayback
    } elseif ($ProgramType -eq 'solution') {
        $selected = @($Project.solutions | Where-Object id -CEQ $ProgramId)
        if ($selected.Count -ne 1) { throw 'Choose an available solution for USB playback.' }
        Export-ViplexUsbSolution $ConfigRoot $selected[0] $OutputDirectory
    } else {
        throw 'Choose a solution or schedule for USB playback.'
    }
    $info = $package.programInfo
    $info.isPlay = $true
    $info.isImport = $PlayMode -eq 'copy'
    $info.isOverride = $DuplicatePolicy -eq 'replace'
    # Player firmware expects an admin entry in its Base64-encoded JSON
    # command. Do not include this value in any receipts or configuration.
    $command = [ordered]@{
        programInfos=@($info)
        authenticUserInfos=@([ordered]@{username='admin'; password=$PlayerPassword})
    } | ConvertTo-Json -Depth 6 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($command))
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'nova\command.json'),$encoded,[Text.Encoding]::ASCII)
    [pscustomobject]@{
        name=$info.name; programType=$ProgramType; playMode=$PlayMode; duplicatePolicy=$DuplicatePolicy
        ruleCount=$package.ruleCount; solutionCount=$package.solutionCount; mediaCount=$package.mediaCount
    }
}

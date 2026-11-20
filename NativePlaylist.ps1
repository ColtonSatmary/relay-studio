# Materialize the full-screen, single-media solution structure used by this
# library. Other page layouts require a retained native publish manifest.
function Read-ViplexBigEndian($Reader, [int]$Count) {
    $bytes = $Reader.ReadBytes($Count)
    if ($bytes.Length -ne $Count) { throw 'Incomplete MP4 header.' }
    [array]::Reverse($bytes)
    if ($Count -eq 4) { return [BitConverter]::ToUInt32($bytes,0) }
    [BitConverter]::ToUInt64($bytes,0)
}

function Get-ViplexMp4Milliseconds([string]$Path) {
    # Skip media payloads by box length. mvhd contains the presentation
    # duration, including the movie timescale and edit-list adjustments.
    $stream = [IO.File]::Open($Path,'Open','Read','Read')
    $reader = [IO.BinaryReader]::new($stream)
    try {
        $limit = $stream.Length
        $insideMovie = $false
        while ($stream.Position + 8 -le $limit) {
            $start = $stream.Position
            $size = [int64](Read-ViplexBigEndian $reader 4)
            $type = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
            if ($size -eq 1) { $size = [int64](Read-ViplexBigEndian $reader 8) }
            if ($size -eq 0) { $size = $limit - $start }
            if ($size -lt ($stream.Position - $start) -or $size -gt ($limit - $start)) { throw 'Invalid MP4 box length.' }
            if (-not $insideMovie -and $type -ceq 'moov') {
                $insideMovie = $true
                $limit = $start + $size
                continue
            }
            if ($insideMovie -and $type -ceq 'mvhd') {
                $version = $reader.ReadByte()
                if ($version -gt 1) { throw 'Unsupported movie header version.' }
                $durationBytes = 4 + 4 * $version
                $stream.Position += 3 + 2 * $durationBytes
                if ($stream.Position + 4 + $durationBytes -gt $start + $size) { throw 'Incomplete movie duration.' }
                $scale = Read-ViplexBigEndian $reader 4
                $ticks = Read-ViplexBigEndian $reader $durationBytes
                if (-not $scale -or -not $ticks) { throw 'Missing movie duration.' }
                return [int64]([math]::Round(100.0 * $ticks / $scale, [MidpointRounding]::AwayFromZero) * 10)
            }
            $stream.Position = $start + $size
        }
        throw 'Movie duration not found.'
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Get-ViplexPlaybackBorder([string]$Json) {
    $border = $Json | ConvertFrom-Json -ErrorAction Stop
    if ($border.AudioListData.audioList.Count -gt 0 -or $border.originalBorderSource -or $border.borderSource) {
        throw 'The video layout has an external audio or border asset.'
    }
    $result = [ordered]@{}
    foreach ($property in $border.PSObject.Properties) {
        if ($null -ne $property.Value -and $property.Name -ne 'AudioListData') { $result[$property.Name] = $property.Value }
    }
    return $result
}

function Get-ViplexVideoConstraints([string]$Json, [switch]$Scene) {
    $rules = @($Json | ConvertFrom-Json -ErrorAction Stop | ForEach-Object { $_ } | Where-Object { $_ })
    if ($rules.Count -gt 0 -and ((-not $Scene) -or $rules[0].isNotForever)) {
        foreach ($rule in $rules) {
            [ordered]@{startTime=$rule.startTime; endTime=$rule.endTime; cron=@($rule.cron)}
        }
    } elseif ($Scene) {
        [ordered]@{startTime='1970-01-01T00:00:00Z+08:00'; endTime='4012-01-01T24:00:00Z+08:00'; cron=@('0 0 0 ? * 1,2,3,4,5,6,7')}
    } else {
        [ordered]@{startTime='1970-01-01T00:00:00Z+8:00'; endTime='4012-01-01T23:59:59Z+8:00'; cron=@('0 0 0 ? * 1,2,3,4,5,6,7')}
    }
}

function Get-ViplexDatabasePlaylist([string]$ConfigRoot, $Solution) {
    $database = Join-Path $ConfigRoot 'DB.SQLite'
    if (-not [IO.File]::Exists($database)) { return $null }
    $uuid = [guid]$Solution.source.playlistUuid
    $key = [BitConverter]::ToString($uuid.ToByteArray()).Replace('-','')
    # One read statement snapshots the complete widget hierarchy. LEFT JOINs
    # expose extra/missing branches instead of silently discarding a layer.
    $sql = @"
SELECT l.name, l.width, l.height, l.thumbpath, l.ProgramModel, l.pickPolicy,
 hex(s.uuid) AS sceneId, s.name AS sceneName, s.thumbnail, s.type AS sceneType, s.rules, s.duration AS sceneDuration,
 s.repeatCount AS sceneRepeats, s.constraints AS sceneConstraints, s.backgroundColor AS sceneColor,
 s.backgroundMusic AS sceneMusic, s.backgroundDrawable AS sceneImage, s.enable AS sceneEnabled,
 hex(p.uuid) AS pageId, p.name AS pageName, p.border AS pageBorder, p.inAnimation AS pageIn, p.outAnimation AS pageOut,
 hex(c.uuid) AS boxId, c.name AS boxName, c.layout AS boxLayout, c.border AS boxBorder, c.WCtype, c.DuritionType,
 c.backgroundDrawable AS boxImage, c.backgroundColor AS boxColor, c.zOrder AS boxOrder, c.pickPolicy AS boxPolicy,
 hex(w.uuid) AS widgetId, w.name AS widgetName, w.type AS widgetType, w.duration AS widgetSeconds,
 w.repeatCount AS widgetRepeats, w.layout AS widgetLayout, w.inAnimation, w.outAnimation, w.border AS widgetBorder,
 w.constraints AS widgetConstraints, w.metadata, w.dataSource, w.originalDataSource, w.filesize, w.displayRatio,
 w.backgroundMusic AS widgetMusic, w.backgroundDrawable AS widgetImage, w.backgroundColor AS widgetColor, w.playByCount
FROM nova_playlist l
LEFT JOIN nova_relation_playlist2scene ls ON ls.playlistuuid=l.uuid
LEFT JOIN nova_scene s ON s.uuid=ls.sceneuuid AND coalesce(s.isdelete,0)=0
LEFT JOIN nova_relation_scene2page sp ON sp.sceneuuid=s.uuid
LEFT JOIN nova_page p ON p.uuid=sp.pageuuid AND coalesce(p.isdelete,0)=0
LEFT JOIN nova_relation_page2widget pc ON pc.pageuuid=p.uuid
LEFT JOIN nova_widgetContainer c ON c.uuid=pc.widgetContaineruuid AND coalesce(c.isdelete,0)=0
LEFT JOIN nova_relation_widgetContainer2widget cw ON cw.widgetContaineruuid=c.uuid
LEFT JOIN nova_widget w ON w.uuid=cw.widgetuuid AND coalesce(w.isdelete,0)=0
WHERE l.uuid=X'$key' AND coalesce(l.isdelete,0)=0
"@
    $rows = @(Read-StudioRows $database $sql)
    if ($rows.Count -ne 1) { return $null }
    $r = $rows[0]
    if ($r.WCtype -ne 'VIDEO' -or $r.widgetType -ne 'VIDEO' -or $r.ProgramModel -ne 0 -or
        $r.DuritionType -ne 0 -or $r.playByCount -or $r.sceneMusic -or $r.sceneImage -or $r.boxImage -or
        $r.widgetImage -or $r.widgetMusic -or $r.pageIn -notin @($null,'null') -or $r.pageOut -notin @($null,'null') -or
        $r.boxColor -or $r.sceneType -notin @($null,'PAGE') -or $r.rules -notin @($null,'TIMES')) { return $null }
    $layout = ConvertFrom-Json $r.boxLayout -ErrorAction Stop
    $widgetLayout = ConvertFrom-Json $r.widgetLayout -ErrorAction Stop
    if ($layout.xNum -ne 0 -or $layout.yNum -ne 0 -or $layout.widthNum -ne $r.width -or $layout.heightNum -ne $r.height) { return $null }
    if ($widgetLayout.widthNum -ne 'NaN' -and ($widgetLayout.xNum -ne 0 -or $widgetLayout.yNum -ne 0 -or
        $widgetLayout.widthNum -ne $r.width -or $widgetLayout.heightNum -ne $r.height)) { return $null }
    if ($r.dataSource -notmatch '^([a-f0-9]{32})\.mp4$') { return $null }
    $md5 = $Matches[1]
    $path = Join-Path (Join-Path $ConfigRoot 'Media') $r.dataSource
    if (-not [IO.File]::Exists($path)) { $path = $r.originalDataSource }
    if (-not $path -or $path -notmatch '^[A-Za-z]:[\\/]' -or -not [IO.File]::Exists($path)) {
        throw "The video for '$($r.name)' is missing from the ViPlex media cache and its original local path."
    }
    if ([IO.FileInfo]::new($path).Length -ne $r.filesize) { throw "The video file for '$($r.name)' has changed size." }
    $duration = Get-ViplexMp4Milliseconds $path
    if ([math]::Abs($duration / 1000.0 - $r.widgetSeconds) -ge 1) { return $null }
    New-ViplexSingleVideoBundle $r $uuid $duration $md5 $path
}

# Both editable ViPlex solutions and local media assets serialize to this
# native one-page/one-container structure. Durations are in milliseconds.
function New-ViplexSingleVideoBundle($r, [guid]$uuid, [long]$duration, [string]$md5, [string]$path,
    [ValidateSet('VIDEO','PICTURE')][string]$MediaType='VIDEO') {
    $full = [ordered]@{width='100%';height='100%';x='0%';y='0%';xNum=0;yNum=0;widthNum=100;heightNum=100}
    $widgetBorder = Get-ViplexPlaybackBorder $r.widgetBorder
    # New editor widgets carry the generic page border until ViPlex prepares
    # them for playback. An imported/player-format border already has a name.
    if (-not $widgetBorder.name) {
        if ($widgetBorder.width -ne 1 -or $widgetBorder.backgroundColor -ne '#FFFF0000' -or
            $widgetBorder.effects.speed -ne 60 -or $widgetBorder.style -ne 0) { return $null }
        $widgetBorder.name = 'border'; $widgetBorder.borderThickness = '0px,0px,0px,0px'; $widgetBorder.cornerRadius = '2%'
        $widgetBorder.backgroundColor = '#FF000000'; $widgetBorder.effects.speed = 3
    }
    $outAnimation = ConvertFrom-Json $r.outAnimation -ErrorAction Stop
    if ($outAnimation.type -eq 0 -and $outAnimation.duration -eq 0) { $outAnimation.duration = 1000 }
    $widget = [ordered]@{
        layout=$full; inAnimation=(ConvertFrom-Json $r.inAnimation); outAnimation=$outAnimation; border=$widgetBorder
        constraints=@(Get-ViplexVideoConstraints $r.widgetConstraints); metadata=(ConvertFrom-Json $r.metadata)
        widgetId=@{value=0}; displayRatio=if ($r.displayRatio) { $r.displayRatio } else { 'FULL' }
        filesize=[int64]$r.filesize; originalDataSource=$r.originalDataSource; zOrder=1; dataSource=$r.dataSource
        backgroundColor=if ($r.widgetColor) { $r.widgetColor } else { '#00000000' }
        backgroundDrawable=''; backgroundMusic=''; name=$r.widgetName; enable=$true; type=$MediaType
        duration=$duration; repeatCount=[int]$r.widgetRepeats; id=100000; uuid=(ConvertTo-StudioGuid $r.widgetId)
    }
    $container = [ordered]@{
        zOrder=[int]$r.boxOrder; layout=$full; border=(Get-ViplexPlaybackBorder $r.boxBorder)
        contents=[ordered]@{widgets=@($widget);widgetGroups=@();widgetContainer=@();enable=$false;zOrder=0;DuritionType=0;id=0;uuid=[guid]::NewGuid().ToString('D')}
        PCType=1; audioGroup=''; WCtype=$MediaType; DuritionType=0; winId=@{value=0}
        name=$r.boxName;enable=$true;pickPolicy=if ($r.boxPolicy) { $r.boxPolicy } else { 'ORDER' }
        id=200000; uuid=(ConvertTo-StudioGuid $r.boxId)
    }
    $page = [ordered]@{
        name=$r.pageName; border=(Get-ViplexPlaybackBorder $r.pageBorder); widgets=@(); widgetContainers=@($container)
        widgetGroups=@(); id=0; uuid=(ConvertTo-StudioGuid $r.pageId)
    }
    $scene = [ordered]@{
        constraints=@(Get-ViplexVideoConstraints $r.sceneConstraints -Scene); page=$page
        backgroundColor=if ($r.sceneColor) { $r.sceneColor } else { '#00000000' }
        backgroundDrawable=''; backgroundMusic=''; thumbnail=$r.thumbnail; name=$r.sceneName
        enable=$true; type='PAGE'; rules='TIMES'; duration=[int64]$r.sceneDuration; repeatCount=[int]$r.sceneRepeats
        id=0; uuid=(ConvertTo-StudioGuid $r.sceneId)
    }
    $playlist = [ordered]@{
        uuid=$uuid.ToString('D'); name=$r.name; sceneItems=@($scene); ProgramModel=0
        width=[double]$r.width; height=[double]$r.height; thumbpath=$r.thumbpath; pickPolicy=$r.pickPolicy; id=0
    }
    [pscustomobject]@{
        playlist=$playlist; resources=@([ordered]@{fileName=$r.dataSource;type=$MediaType;md5=$md5;size=[int64]$r.filesize}); mediaPath=$path
    }
}

function Get-ViplexLocalMediaPlaylist($Solution, $Screen, $Asset) {
    # The exporter obtains Asset and Solution from the local media store.
    # No project-supplied paths, checksums or durations are used here.
    $source = $Solution.source
    $ext = ([string]$source.extension).TrimStart('.').ToLowerInvariant()
    $isImage = $source.kind -ceq 'localImage'
    if ($source.kind -cnotin @('localVideo','localImage') -or $ext -notmatch '^[a-z0-9]{1,10}$' -or
        ($isImage -and $ext -cnotin @('jpg','jpeg')) -or
        $source.md5 -notmatch '^[0-9a-f]{32}$' -or $source.assetId -notmatch '^[0-9a-f]{64}$') {
        throw "The stored media record for '$($Solution.name)' is not supported."
    }
    if (-not [IO.File]::Exists($Asset.path) -or [IO.FileInfo]::new($Asset.path).Length -ne [long]$source.bytes) {
        throw "The stored media file for '$($Solution.name)' is missing or incomplete."
    }
    if (-not [IO.File]::Exists($Asset.thumbnailPath)) {
        throw "The preview for '$($Solution.name)' is missing. Import the media again."
    }
    if ($Screen.width -le 0 -or $Screen.height -le 0 -or $source.durationMs -le 0) {
        throw "Check the screen size and media duration for '$($Solution.name)'."
    }
    $thumb = (Get-FileHash -LiteralPath $Asset.thumbnailPath -Algorithm MD5).Hash.ToLowerInvariant() + '.png'
    $hash = ([string]$source.md5).ToLowerInvariant()
    $duration = [long][math]::Max(10, 10 * [math]::Round(([double]$source.durationMs / 10), [MidpointRounding]::AwayFromZero))
    # ViPlex's native PICTURE widgets use the same full-screen hierarchy and
    # generic borders as VIDEO, with null metadata. The enclosing playback
    # rule repeats this page for the entire schedule block or standalone run.
    # Imported source bytes remain intact (orientation is handled on import).
    $border = [ordered]@{
        aspectRatio=@{type=0;isLocked=$true}; foregroundColor='#FF008000'; width=1
        backgroundColor='#FFFF0000';style=0;styleForExpress=0
        effects=@{speed=60;animation='CLOCK_WISE';isHeadTail=$false;headTailSpacing='10';speedByPixelEnable=$false}
    }
    $pageBorder = ConvertTo-Json $border -Depth 6 -Compress
    $border.width = 0; $border.effects.speed = 2
    $boxBorder = ConvertTo-Json $border -Depth 6 -Compress
    $animation = '{"type":0,"duration":1000}'
    $row = [pscustomobject]@{
        name=$Solution.name;width=$Screen.width;height=$Screen.height;thumbpath=$Asset.thumbnailPath;pickPolicy='ORDER'
        sceneId=[guid]::NewGuid().ToString('D');sceneName='Preset';thumbnail=$thumb;sceneDuration=0;sceneRepeats=1
        sceneConstraints='[]';sceneColor='#00000000'
        pageId=[guid]::NewGuid().ToString('D');pageName='Page1';pageBorder=$pageBorder
        boxId=[guid]::NewGuid().ToString('D');boxName=if ($isImage) { 'Image1' } else { 'Video1' };boxBorder=$boxBorder;boxOrder=1;boxPolicy='ORDER'
        widgetId=[guid]::NewGuid().ToString('D');widgetName=$source.fileName;widgetRepeats=1
        inAnimation=$animation;outAnimation=$animation;widgetBorder=$pageBorder;widgetConstraints='[]'
        metadata=if ($isImage) { 'null' } else { '{"volume":100}' };displayRatio='FULL';filesize=[long]$source.bytes;originalDataSource=$Asset.path
        dataSource=($hash + '.' + $ext);widgetColor='#00000000'
    }
    $mediaType = if ($isImage) { 'PICTURE' } else { 'VIDEO' }
    $bundle = New-ViplexSingleVideoBundle $row ([guid]::NewGuid()) $duration $hash $Asset.path -MediaType $mediaType
    $bundle | Add-Member -NotePropertyName thumbnailPath -NotePropertyValue $Asset.thumbnailPath
    return $bundle
}

# Retain the existing helper for scripts that stage local videos directly.
function Get-ViplexLocalVideoPlaylist($Solution, $Screen, $Asset) {
    Get-ViplexLocalMediaPlaylist $Solution $Screen $Asset
}

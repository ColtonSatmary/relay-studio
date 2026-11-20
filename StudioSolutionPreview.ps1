# The browser identifies a catalog solution and an item number. Only this service
# resolves those identifiers to files registered in the ViPlex or Relay library.
$studioPreviewTypes = @{
    '.mp4'='video/mp4'; '.m4v'='video/mp4'; '.mov'='video/quicktime'; '.webm'='video/webm'
    '.mkv'='video/x-matroska'; '.avi'='video/x-msvideo'; '.wmv'='video/x-ms-wmv'; '.asf'='video/x-ms-asf'
    '.mpg'='video/mpeg'; '.mpeg'='video/mpeg'; '.mpe'='video/mpeg'; '.m2v'='video/mpeg'; '.vob'='video/mpeg'
    '.ts'='video/mp2t'; '.mts'='video/mp2t'; '.m2ts'='video/mp2t'; '.ogv'='video/ogg'; '.flv'='video/x-flv'
    '.3gp'='video/3gpp'; '.3g2'='video/3gpp2'; '.mxf'='application/mxf'
    '.jpg'='image/jpeg'; '.jpeg'='image/jpeg'; '.png'='image/png'; '.gif'='image/gif'
    '.webp'='image/webp'; '.bmp'='image/bmp'; '.avif'='image/avif'
}

function Get-StudioEditableItems([string]$Database, [guid]$Uuid) {
    $key = [BitConverter]::ToString($Uuid.ToByteArray()).Replace('-','')
    $query = @"
WITH parts AS (
    SELECT pc.pageuuid AS pageId, pc.rowid AS pageOrder, 0 AS itemOrder, pc.widgetuuid AS widget
      FROM nova_relation_page2widget pc
    UNION ALL
    SELECT pc.pageuuid, pc.rowid, cw.rowid, cw.widgetuuid
      FROM nova_relation_page2widget pc
      JOIN nova_widgetContainer c ON c.uuid=pc.widgetContaineruuid AND coalesce(c.isdelete,0)=0
      JOIN nova_relation_widgetContainer2widget cw ON cw.widgetContaineruuid=c.uuid
    UNION ALL
    SELECT pc.pageuuid, pc.rowid, gw.rowid, gw.widgetuuid
      FROM nova_relation_page2widget pc
      JOIN nova_widgetGroup g ON g.uuid=pc.widgetGroupuuid AND coalesce(g.isdelete,0)=0
      JOIN nova_relation_widgetGroup2widget gw ON gw.widgetGroupuuid=g.uuid
    UNION ALL
    SELECT pc.pageuuid, pc.rowid, gw.rowid, gw.widgetuuid
      FROM nova_relation_page2widget pc
      JOIN nova_widgetContainer c ON c.uuid=pc.widgetContaineruuid AND coalesce(c.isdelete,0)=0
      JOIN nova_relation_widgetContainer2widgetGroup cg ON cg.widgetContaineruuid=c.uuid
      JOIN nova_widgetGroup g ON g.uuid=cg.widgetGroupuuid AND coalesce(g.isdelete,0)=0
      JOIN nova_relation_widgetGroup2widget gw ON gw.widgetGroupuuid=g.uuid
)
SELECT w.name, w.type, w.duration*1000 AS durationMs, w.filesize AS bytes, w.dataSource,
       w.originalDataSource, s.name AS scene, w.repeatCount AS itemRepeats, s.repeatCount AS sceneRepeats
FROM nova_relation_playlist2scene ls
JOIN nova_scene s ON s.uuid=ls.sceneuuid AND coalesce(s.isdelete,0)=0
JOIN nova_relation_scene2page sp ON sp.sceneuuid=s.uuid
JOIN nova_page p ON p.uuid=sp.pageuuid AND coalesce(p.isdelete,0)=0
JOIN parts ON parts.pageId=p.uuid
JOIN nova_widget w ON w.uuid=parts.widget AND coalesce(w.isdelete,0)=0
WHERE ls.playlistuuid=X'$key'
ORDER BY coalesce(s.orderNumber,ls.rowid), ls.rowid, p.viewOrder, parts.pageOrder, parts.itemOrder
"@
    Read-StudioRows $Database $query
}

function Get-StudioPublishedItems($Node, $Scene) {
    if (-not $Node) { return }
    foreach ($widget in $Node.widgets) {
        if (-not $widget) { continue }
        [pscustomobject]@{name=$widget.name; type=$widget.type; scene=$Scene.name; durationMs=$widget.duration
            bytes=$widget.filesize; originalDataSource=$widget.originalDataSource; dataSource=$widget.dataSource
            itemRepeats=$widget.repeatCount; sceneRepeats=$Scene.repeatCount}
    }
    foreach ($field in 'widgetGroups','widgetContainers','widgetContainer') {
        foreach ($child in $Node.$field) { Get-StudioPublishedItems $child $Scene }
    }
    if ($Node.contents) { Get-StudioPublishedItems $Node.contents $Scene }
}

function Find-StudioPreviewFile($Row, [string]$ConfigRoot, [string]$Kind) {
    if ($Kind -notin 'video','image' -or $Row.dataSource -notmatch '^([a-f0-9]{32})(\.[a-z0-9]+)$') { return }
    $digest = $Matches[1]
    $extension = $Matches[2]
    $mime = $studioPreviewTypes[$extension]
    if (-not $mime -or ($mime.StartsWith('image/') -ne ($Kind -eq 'image'))) { return }
    $path = Join-Path (Join-Path $ConfigRoot 'Media') $Row.dataSource
    if (-not [IO.File]::Exists($path)) {
        # Never follow remote/UNC paths or use an unregistered filename.
        $path = [string]$Row.originalDataSource
        if ($path -notmatch '^[a-z]:[\\/][^:]*$' -or [IO.Path]::GetExtension($path) -ne $extension -or
            ([IO.DriveInfo]::new($path.Substring(0,1))).DriveType -notin 'Fixed','Removable' -or
            -not [IO.File]::Exists($path)) { return }
    }
    $bytes = [IO.FileInfo]::new($path).Length
    if ($bytes -le 0 -or ($Row.bytes -gt 0 -and $bytes -ne $Row.bytes)) { return }
    [pscustomobject]@{path=$path; mime=$mime; digest=$digest; bytes=$bytes}
}

function Get-StudioSolutionPreview([string]$ConfigRoot, $Solution) {
    $assets = [Collections.Generic.List[object]]::new()
    $items = [Collections.Generic.List[object]]::new()
    $duration = $null
    $source = $Solution.source
    $local = $source.kind -cin @('localVideo','localImage')
    $modified = $source.modified
    if ($local) {
        $asset = Get-StudioMediaAsset $source.assetId
        if (-not $asset -or $Solution.id -cnotin $asset.solutions.id) { return }
        $duration = [long]$source.durationMs
        $assets.Add(@{path=$asset.path; mime=$studioPreviewTypes[[IO.Path]::GetExtension($asset.path)]; digest=$null; bytes=$source.bytes})
        $kind=if($source.kind -ceq 'localImage'){'image'}else{'video'}
        $items.Add(@{name=$source.fileName; fileName=$source.fileName; type=$kind; scene=$null; durationMs=$duration
            bytes=$source.bytes; codec=$source.codec; url="/api/solutions/$($Solution.id)/media/0"})
    } else {
        $rows = $null
        $db = Join-Path $ConfigRoot 'DB.SQLite'
        if ([IO.File]::Exists($db)) {
            try { $rows = @(Get-StudioEditableItems $db $source.playlistUuid) }
            catch { Write-Verbose 'Current editable widget details could not be read.' }
        }
        if ($null -eq $rows -and $source.snapshot -match '^\d+$' -and $source.playlist -match '^playlist\d+\.json$') {
            $snapshot = Join-Path (Join-Path (Join-Path $ConfigRoot 'Publish') $source.snapshot) $source.playlist
            if ([IO.File]::Exists($snapshot)) {
                $list = [IO.File]::ReadAllText($snapshot) | ConvertFrom-Json -ErrorAction Stop
                if ($list.uuid -eq $source.playlistUuid) {
                    $rows = @(foreach ($scene in $list.sceneItems) { Get-StudioPublishedItems $scene.page $scene })
                }
            }
        }
        foreach ($row in $rows) {
            $kind = ([string]$row.type).ToLowerInvariant()
            if ($kind -in 'picture','image') { $kind = 'image' }
            $asset = Find-StudioPreviewFile $row $ConfigRoot $kind
            $url = if ($asset) { "/api/solutions/$($Solution.id)/media/$($items.Count)" } else { $null }
            $assets.Add($asset)
            $fileName = if ($row.name -match '\.[a-z0-9]{1,6}$') { [IO.Path]::GetFileName($row.name) }
                        elseif ($row.originalDataSource -match '^[a-z]:[\\/][^:]*$') { [IO.Path]::GetFileName($row.originalDataSource) } else { $null }
            $itemDuration = if ($row.durationMs -gt 0) { [long]$row.durationMs } else { $null }
            $items.Add(@{name=$row.name; type=$kind; fileName=$fileName; scene=$row.scene; durationMs=$itemDuration
                bytes=$(if ($row.bytes -gt 0) { [long]$row.bytes } elseif ($asset) { $asset.bytes } else { $null }); codec=$null; url=$url})
        }
        # Durations from simultaneous widgets cannot simply be added.
        if ($items.Count -eq 1 -and $rows[0].sceneRepeats -le 1 -and $rows[0].itemRepeats -le 1) { $duration = $items[0].durationMs }
    }
    @{assets=$assets; detail=@{id=$Solution.id; name=$Solution.name; width=$Solution.width; height=$Solution.height
        sourceKind=$(if ($local) {$source.kind} else {'viplex'}); thumbnail=$Solution.thumbnail; modified=$modified
        durationMs=$duration; items=$items}}
}

function Invoke-StudioSolutionPreview($Request, $Response, [string]$Id, [string]$Item, [ref]$Streaming) {
    $catalog = Get-StudioCachedCatalog
    $solution = $catalog.data.solutions | Where-Object id -CEQ $Id | Select-Object -First 1
    $preview = if ($solution) { Get-StudioSolutionPreview $configRoot $solution }
    if (-not $preview) { Write-StudioJson $Response @{error='This solution is unavailable in the local library.'} 404; return }
    if (-not $Item) { Write-StudioJson $Response $preview.detail; return }
    $index = 0
    if (-not [int]::TryParse($Item,[ref]$index) -or $index -ge $preview.assets.Count -or -not $preview.assets[$index]) {
        Write-StudioJson $Response @{error='This media item is unavailable.'} 404
        return
    }
    $asset = $preview.assets[$index]
    if (-not ('StudioPreviewStream' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'StudioPreviewStream.cs') }
    [StudioPreviewStream]::Send($Request, $Response, $asset.path, $asset.mime, $asset.digest, $asset.bytes)
    $Streaming.Value = $true
}

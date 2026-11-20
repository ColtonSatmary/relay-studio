# Real JPEG decoding and media-store fixtures only; no production library or board.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'StudioProject.ps1')
. (Join-Path $PSScriptRoot 'StudioMedia.ps1')
Add-Type -AssemblyName System.Drawing
function Assert-Image([bool]$Condition,[string]$Message){if(-not $Condition){throw "Test failed: $Message"}}
function Import-ImageBytes([byte[]]$Bytes,[string]$Name,[string]$SourceName=''){
    $input=[IO.MemoryStream]::new($Bytes,$false)
    try {Import-StudioMedia $input $Name $SourceName} finally {$input.Dispose()}
}
function Reject-Image([byte[]]$Bytes,[string]$Name,[string]$Expected){
    $failure='';try {$null=Import-ImageBytes $Bytes $Name} catch {$failure=$_.Exception.Message}
    Assert-Image ($failure -like "*$Expected*") "Expected $Expected; got $failure"
}
function With-ExifOrientation([byte[]]$Bytes,[byte]$Orientation){
    # A minimal little-endian TIFF orientation APP1 segment, before the JFIF APP0.
    [byte[]]$tag=@(255,225,0,34,69,120,105,102,0,0,73,73,42,0,8,0,0,0,1,0,18,1,3,0,1,0,0,0,$Orientation,0,0,0,0,0,0,0)
    return ,([byte[]]($Bytes[0..1]+$tag+$Bytes[2..($Bytes.Length-1)]))
}
$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$tempLeaf='RelayImageImportTest-'+[guid]::NewGuid().ToString('N')
$fixture=[IO.Directory]::CreateDirectory((Join-Path $tempParent $tempLeaf)).FullName
$mediaRoot=Join-Path $fixture 'Media'
try {
    $bitmap=[Drawing.Bitmap]::new(320,180)
    $g=[Drawing.Graphics]::FromImage($bitmap)
    $plainPath=Join-Path $fixture 'original.jpg'
    $pngPath=Join-Path $fixture 'not-jpeg.png'
    try {
        $g.Clear([Drawing.Color]::Red)
        $g.FillRectangle([Drawing.Brushes]::Blue,160,0,160,180)
        $bitmap.Save($plainPath,[Drawing.Imaging.ImageFormat]::Jpeg)
        $bitmap.Save($pngPath,[Drawing.Imaging.ImageFormat]::Png)
    } finally {$g.Dispose();$bitmap.Dispose()}
    $bytes=[IO.File]::ReadAllBytes($plainPath)
    $first=Import-ImageBytes $bytes 'Doors.Open.JPG'
    Assert-Image ($first.name -ceq 'Doors.Open' -and $first.source.fileName -ceq 'Doors.Open.JPG') 'Original title/filename not preserved.'
    Assert-Image ($first.id -cmatch '^image-[a-f0-9]{64}-[a-f0-9]{16}$' -and $first.source.kind -ceq 'localImage' -and $first.source.streamType -ceq 'image') 'Image identity or source type incorrect.'
    Assert-Image ($first.width -eq 320 -and $first.height -eq 180 -and $first.source.durationMs -eq 10000 -and $first.source.extension -ceq '.jpg') 'Dimensions/default duration/extension incorrect.'
    $asset=Get-StudioMediaAsset $first.source.assetId
    Assert-Image ((Get-FileHash $asset.path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $first.source.assetId) 'Stored SHA does not identify stored content.'
    Assert-Image ((Get-FileHash $asset.path -Algorithm MD5).Hash.ToLowerInvariant() -ceq $first.source.md5) 'Stored MD5 incorrect.'
    Assert-Image ([Convert]::ToBase64String([IO.File]::ReadAllBytes($asset.path)) -ceq [Convert]::ToBase64String($bytes)) 'Unrotated image bytes changed.'
    $same=Import-ImageBytes $bytes 'Doors.Open.JPEG'
    Assert-Image ($same.id -ceq $first.id) 'Equivalent JPG/JPEG import created duplicate solution.'
    $second=Import-ImageBytes $bytes 'Lobby.JPEG'
    Assert-Image ($second.id -cne $first.id -and $second.source.assetId -ceq $first.source.assetId) 'Different title failed to share the original media.'
    $asset=Get-StudioMediaAsset $first.source.assetId
    Assert-Image ($asset.solutions.Count -eq 2 -and @(Get-StudioMediaSolutions).Count -eq 2) 'Stored aliases did not survive a new library read.'

    # Repair same-length damaged bytes, retaining all solution names.
    $damaged=[byte[]]$bytes.Clone();$damaged[20]=$damaged[20] -bxor 1
    [IO.File]::WriteAllBytes($asset.path,$damaged)
    $repaired=Import-ImageBytes $bytes 'Doors.Open.JPG'
    $asset=Get-StudioMediaAsset $first.source.assetId
    Assert-Image ($repaired.id -ceq $first.id -and $asset.solutions.Count -eq 2 -and (Get-FileHash $asset.path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $first.source.assetId) 'Content repair lost identities or failed.'

    $portraitBytes=With-ExifOrientation $bytes 6
    $portrait=Import-ImageBytes $portraitBytes 'Portrait.JPEG'
    $portraitAgain=Import-ImageBytes $portraitBytes 'Portrait.JPG'
    Assert-Image ($portrait.id -ceq $portraitAgain.id -and $portrait.width -eq 180 -and $portrait.height -eq 320) 'EXIF rotation dimensions or deduplication incorrect.'
    $portraitAsset=Get-StudioMediaAsset $portrait.source.assetId
    Assert-Image ($portrait.source.assetId -cne (Get-StudioRevision $portraitBytes)) 'Rotated JPEG was not normalized before content addressing.'
    Assert-Image ((Get-FileHash $portraitAsset.path -Algorithm MD5).Hash.ToLowerInvariant() -ceq $portrait.source.md5 -and (Get-FileHash $portraitAsset.path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $portrait.source.assetId) 'Normalized JPEG hashes incorrect.'
    $stored=[Drawing.Bitmap]::new($portraitAsset.path)
    $preview=[Drawing.Bitmap]::new($portraitAsset.thumbnailPath)
    try {
        Assert-Image ($stored.Width -eq 180 -and $stored.Height -eq 320 -and $preview.Width -eq 180 -and $preview.Height -eq 320) 'Upright stored image/thumbnail mismatch.'
        Assert-Image (-not ($stored.PropertyIdList -contains 274)) 'Normalized image retained a second rotation flag.'
        Assert-Image ($stored.GetPixel(10,10).R -gt 180 -and $stored.GetPixel(10,300).B -gt 180) 'EXIF clockwise rotation did not rotate the actual pixels.'
    } finally {$stored.Dispose();$preview.Dispose()}
    $mirror=Import-ImageBytes (With-ExifOrientation $bytes 2) 'Mirrored.jpg'
    $mirrorAsset=Get-StudioMediaAsset $mirror.source.assetId
    $stored=[Drawing.Bitmap]::new($mirrorAsset.path)
    try {Assert-Image ($stored.GetPixel(10,10).B -gt 180 -and $stored.GetPixel(300,10).R -gt 180) 'EXIF mirrored orientation not applied.'} finally {$stored.Dispose()}

    $widePath=Join-Path $fixture 'wide.jpg'
    $wide=[Drawing.Bitmap]::new(1920,1080)
    try {$wide.Save($widePath,[Drawing.Imaging.ImageFormat]::Jpeg)} finally {$wide.Dispose()}
    $wideSolution=Import-ImageBytes ([IO.File]::ReadAllBytes($widePath)) 'Wide.jpg'
    $wideAsset=Get-StudioMediaAsset $wideSolution.source.assetId
    $widePreview=[Drawing.Bitmap]::new($wideAsset.thumbnailPath)
    try {Assert-Image ($widePreview.Width -eq 320 -and $widePreview.Height -eq 180) 'Large JPEG thumbnail was collapsed by integer scaling.'} finally {$widePreview.Dispose()}

    $before=@(Get-StudioMediaSolutions).Count
    Reject-Image ([byte[]]@()) 'Empty.jpg' 'empty'
    Reject-Image ([byte[]]@(1,2,3,4,5)) 'Broken.jpg' 'JPEG'
    Reject-Image ([byte[]]@(255,216,255)) 'Truncated.jpeg' 'incomplete'
    Reject-Image ([IO.File]::ReadAllBytes($pngPath)) 'Spoofed.JPG' 'contents do not match'
    Reject-Image $bytes 'Spoofed.png' 'contents do not match'
    Reject-Image $bytes '../Escape.jpg' 'valid filename'
    $large=[byte[]]$bytes.Clone()
    for($i=0;$i -lt $large.Length-8;$i++){if($large[$i] -eq 255 -and $large[$i+1] -eq 192){$large[$i+5]=255;$large[$i+6]=255;$large[$i+7]=255;$large[$i+8]=255;break}}
    Reject-Image $large 'Huge.jpg' 'too large'
    Assert-Image (@(Get-StudioMediaSolutions).Count -eq $before -and @(Get-ChildItem $mediaRoot -Directory -Filter '.upload-*').Count -eq 0) 'Rejected upload left solutions or staging files.'

    # Old video records omit mediaType. Their stable IDs and metadata remain valid.
    $videoBytes=[Text.Encoding]::UTF8.GetBytes('Legacy video asset fixture')
    $videoId=Get-StudioRevision $videoBytes
    $videoDir=[IO.Directory]::CreateDirectory((Join-Path $mediaRoot $videoId)).FullName
    [IO.File]::WriteAllBytes((Join-Path $videoDir 'content.mp4'),$videoBytes)
    Copy-Item -LiteralPath $asset.thumbnailPath -Destination (Join-Path $videoDir 'preview.png')
    $videoMd5=(Get-FileHash (Join-Path $videoDir 'content.mp4') -Algorithm MD5).Hash.ToLowerInvariant()
    $legacy=@{assetId=$videoId;md5=$videoMd5;extension='.mp4';width=320;height=180;durationMs=12000;codec='h264';bytes=$videoBytes.Length}
    [IO.File]::WriteAllText((Join-Path $videoDir 'asset.json'),($legacy|ConvertTo-Json -Compress))
    [IO.File]::WriteAllText((Join-Path $videoDir 'name-0123456789abcdef.json'),' {"fileName":"Legacy.mp4"}')
    $old=Get-StudioMediaAsset $videoId
    Assert-Image ($old.solution.id -ceq "video-$videoId-0123456789abcdef" -and $old.solution.source.kind -ceq 'localVideo' -and $old.solution.source.streamType -ceq 'video' -and $old.solution.source.durationMs -eq 12000) 'Old video record changed meaning or ID.'
    Reject-Image $videoBytes 'SpoofedKnownVideo.jpg' 'contents do not match'
    $wrong=$legacy.Clone();$wrong.mediaType='image'
    [IO.File]::WriteAllText((Join-Path $videoDir 'asset.json'),($wrong|ConvertTo-Json -Compress))
    $failure='';try {$null=Get-StudioMediaAsset $videoId}catch{$failure=$_.Exception.Message}
    Assert-Image ($failure -like '*metadata is damaged*') 'Mismatched image metadata accepted a video extension.'
    'Image import checks passed: real JPEG decode, original bytes, aliases, content repair, EXIF normalization, spoof/corruption/size rejection, and legacy video records.'
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture).TrimEnd('\')
    if([IO.Path]::GetDirectoryName($resolved) -ceq $tempParent -and [IO.Path]::GetFileName($resolved) -ceq $tempLeaf -and $tempLeaf -cmatch '^RelayImageImportTest-[a-f0-9]{32}$') {
        $linked=@(Get-ChildItem -LiteralPath $resolved -Force -Recurse|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint})
        if(-not $linked.Count){[IO.Directory]::Delete($resolved,$true)}
    }
}

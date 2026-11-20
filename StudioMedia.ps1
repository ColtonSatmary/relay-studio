# Paths inside the media library are derived from hashes. Keep original names
# only as solution labels, so importing a shared project cannot select a path.
$studioVideoFormats = @{
    '.mp4'='mov'; '.mov'='mov'; '.m4v'='mov'; '.3gp'='mov'; '.3g2'='mov'
    '.mkv'='matroska'; '.webm'='matroska'; '.avi'='avi'; '.wmv'='asf'; '.asf'='asf'
    '.mpg'='mpeg'; '.mpeg'='mpeg'; '.vob'='mpeg'; '.ts'='mpegts'; '.mts'='mpegts'; '.m2ts'='mpegts'; '.flv'='flv'
    '.mxf'='mxf'; '.m2v'='mpegvideo'; '.mpe'='mpeg'; '.ogv'='ogg'
}
. (Join-Path $PSScriptRoot 'StudioImageFormats.ps1')
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { . (Join-Path $PSScriptRoot 'macos/StudioMacPlatform.ps1') }

function Read-StudioJpegDimensions([string]$Path) {
    # Bound the decoded allocation before asking GDI+ to load untrusted pixels.
    $stream=[IO.File]::OpenRead($Path)
    $reader=[IO.BinaryReader]::new($stream)
    try {
        if($reader.ReadByte() -ne 255 -or $reader.ReadByte() -ne 216){throw 'Choose a JPEG image; the file contents do not match JPG/JPEG.'}
        while($stream.Position -lt $stream.Length -and $stream.Position -lt 16MB) {
            if($reader.ReadByte() -ne 255){throw 'The JPEG header is damaged.'}
            do {$marker=[int]$reader.ReadByte()} while($marker -eq 255)
            if($marker -in @(0,216,217,218)){throw 'The JPEG image dimensions could not be read.'}
            if($marker -eq 1 -or ($marker -ge 208 -and $marker -le 215)){continue}
            $length=([int]$reader.ReadByte()*256)+[int]$reader.ReadByte()
            if($length -lt 2 -or $stream.Position+$length-2 -gt $stream.Length){throw 'The JPEG file is incomplete.'}
            if($marker -in @(192,193,194,195,197,198,199,201,202,203,205,206,207)) {
                if($length -lt 8){throw 'The JPEG dimensions are damaged.'}
                $null=$reader.ReadByte()
                $height=([int]$reader.ReadByte()*256)+[int]$reader.ReadByte()
                $width=([int]$reader.ReadByte()*256)+[int]$reader.ReadByte()
                if($width -lt 1 -or $height -lt 1 -or $width -gt 32768 -or $height -gt 32768 -or [long]$width*$height -gt 64MB) {
                    throw 'This JPEG is too large. Resize it to at most 64 megapixels and 32768 pixels per side.'
                }
                return @{width=$width;height=$height}
            }
            $stream.Position += $length-2
        }
        throw 'The JPEG image dimensions could not be read.'
    } catch [IO.EndOfStreamException] {throw 'The JPEG file is incomplete.'}
    finally {$reader.Dispose()}
}

function Read-StudioImage([string]$Path,[string]$Preview) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { return Read-StudioMacImage $Path $Preview }
    $header=Read-StudioJpegDimensions $Path
    Add-Type -AssemblyName System.Drawing
    $stream=$null;$image=$null;$upright=$null;$thumbnail=$null;$graphics=$null;$parameters=$null
    $normalizedPath=$Path+'.upright.tmp'
    $normalized=$false
    try {
        $stream=[IO.File]::OpenRead($Path)
        try {$image=[Drawing.Image]::FromStream($stream,$true,$true)} catch {throw 'A readable JPEG image could not be decoded. Check that the file is complete.'}
        if($image.RawFormat.Guid -ne [Drawing.Imaging.ImageFormat]::Jpeg.Guid -or $image.Width -ne $header.width -or $image.Height -ne $header.height) {
            throw 'Choose a JPEG image; the file contents do not match JPG/JPEG.'
        }
        $orientation=1
        if($image.PropertyIdList -contains 274) {
            $tag=$image.GetPropertyItem(274)
            if($tag.Value.Length -lt 2){throw 'The JPEG orientation metadata is damaged. Save a new copy of the image and import it.'}
            $orientation=[int][BitConverter]::ToUInt16($tag.Value,0)
            if($orientation -lt 1 -or $orientation -gt 8){throw 'The JPEG orientation metadata is invalid. Save a new copy of the image and import it.'}
        }
        if($orientation -ne 1) {
            $rotations=@{2='RotateNoneFlipX';3='Rotate180FlipNone';4='Rotate180FlipX';5='Rotate90FlipX';6='Rotate90FlipNone';7='Rotate270FlipX';8='Rotate270FlipNone'}
            $image.RotateFlip([Drawing.RotateFlipType][Enum]::Parse([Drawing.RotateFlipType],$rotations[$orientation]))
            # Copy pixels into a fresh JPEG, removing the EXIF rotation so the
            # browser preview and LED player see the same upright image.
            $upright=[Drawing.Bitmap]::new($image.Width,$image.Height,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
            $graphics=[Drawing.Graphics]::FromImage($upright)
            $graphics.DrawImageUnscaled($image,0,0)
            $graphics.Dispose();$graphics=$null
            $encoder=[Drawing.Imaging.ImageCodecInfo]::GetImageEncoders()|Where-Object MimeType -EQ 'image/jpeg'|Select-Object -First 1
            $parameters=[Drawing.Imaging.EncoderParameters]::new(1)
            $parameters.Param[0]=[Drawing.Imaging.EncoderParameter]::new([Drawing.Imaging.Encoder]::Quality,95L)
            $upright.Save($normalizedPath,$encoder,$parameters)
            $normalized=$true
        }
        $width=$image.Width;$height=$image.Height
        $scale=[math]::Min(1.0,[math]::Min(320.0/$width,320.0/$height))
        $thumbnail=[Drawing.Bitmap]::new([math]::Max(1,[int][math]::Round($width*$scale)),[math]::Max(1,[int][math]::Round($height*$scale)))
        $graphics=[Drawing.Graphics]::FromImage($thumbnail)
        $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode=[Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($image,[Drawing.Rectangle]::new(0,0,$thumbnail.Width,$thumbnail.Height))
        $thumbnail.Save($Preview,[Drawing.Imaging.ImageFormat]::Png)
        $image.Dispose();$image=$null;$stream.Dispose();$stream=$null
        if($normalized){[IO.File]::Replace($normalizedPath,$Path,[Management.Automation.Language.NullString]::Value)}
        return @{mediaType='image';width=$width;height=$height;durationMs=10000;codec='jpeg';normalizedOrientation=$normalized}
    } finally {
        foreach($resource in @($graphics,$thumbnail,$upright,$image,$stream,$parameters)){if($null -ne $resource){$resource.Dispose()}}
        if([IO.File]::Exists($normalizedPath)){[IO.File]::Delete($normalizedPath)}
    }
}

function Invoke-StudioVideoTool([string]$Ffmpeg, [string[]]$Options, [int]$TimeoutMs) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { return Invoke-StudioMacTool $Ffmpeg @($Options | ForEach-Object { if ($_ -ceq 'NUL') { '/dev/null' } else { $_ } }) $TimeoutMs }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $ffmpeg
    $info.Arguments = ($Options | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardOutput = $true
    $proc = [Diagnostics.Process]::Start($info)
    try {
        $reading = $proc.StandardError.ReadToEndAsync()
        $output = $proc.StandardOutput.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            $proc.Kill()
            $proc.WaitForExit()
            throw 'Reading the video timed out. Check the video or convert it to an H.264 MP4.'
        }
        return @{code=$proc.ExitCode; log=$reading.GetAwaiter().GetResult(); output=$output.GetAwaiter().GetResult()}
    } finally { $proc.Dispose() }
}

function Get-StudioFfmpegPath {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { return Get-StudioMacFfmpegPath }
    $tool = Get-Command ffmpeg.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $ffmpeg = if ($tool) { $tool.Source } else { Join-Path ${env:ProgramFiles(x86)} 'Nova Star\ViPlex Express\Bin\VideoConverter\ffmpeg.exe' }
    if (-not [IO.File]::Exists($ffmpeg)) { throw 'Video import requires the video converter included with ViPlex Express or ffmpeg.exe on PATH.' }
    return $ffmpeg
}

function Read-StudioVideo([string]$Path, [string]$Demuxer, [string]$Preview) {
    $ffmpeg=Get-StudioFfmpegPath
    # Decode a real video frame. V:0 excludes album artwork. An explicit
    # container and file-only input keep playlists and network URLs out.
    $inputOptions = @('-hide_banner','-nostdin','-protocol_whitelist','file','-f',$Demuxer,'-i',$Path,'-map','0:V:0','-an','-sn','-dn')
    $frameOptions = $inputOptions + @('-vf','showinfo,scale=w=min(320\,iw):h=min(320\,ih):force_original_aspect_ratio=decrease',
        '-frames:v','1','-c:v','png','-f','image2',$Preview)
    $result = Invoke-StudioVideoTool $ffmpeg $frameOptions 60000
    if ($result.code -ne 0 -or -not [IO.File]::Exists($Preview)) {
            throw 'A playable video frame could not be read. Check that the file is complete and its extension matches its video format.'
    }
    $log = $result.log
    $dim = [regex]::Match($log,'(?m)^\[Parsed_showinfo_\d+[^\r\n]*?\bn:\s*0\b[^\r\n]*?\bs:(\d+)x(\d+)\b')
    $duration = [regex]::Match($log,'(?m)^\s*Duration:\s*(\d+):(\d{2}):(\d{2}(?:\.\d+)?),')
    $stream = [regex]::Match($log,'(?m)^\s*Stream #0:\d+(?:\[[^\]]+\])?(?:\([^)]*\))?: Video:\s*([\w-]+)(?![^\r\n]*\(attached pic\))')
    if (-not $dim.Success -or -not $stream.Success) { throw 'The video dimensions or codec could not be read. Try exporting the file as an H.264 MP4.' }
    if ($duration.Success) {
        $seconds = [double]::Parse($duration.Groups[3].Value,[cultureinfo]::InvariantCulture) + [int]$duration.Groups[2].Value * 60 + [long]$duration.Groups[1].Value * 3600
        $milliseconds = [long][math]::Round($seconds * 1000)
    } else {
        # Raw MPEG and some unindexed containers have no duration header.
        # Decode the selected track to a null output and measure its timestamps.
        $timing = @('-v','error','-progress','pipe:1') + $inputOptions + @('-vf','setpts=PTS-STARTPTS','-vsync','0','-f','null','NUL')
        $measured = Invoke-StudioVideoTool $ffmpeg $timing 300000
        $times = [regex]::Matches($measured.output,'(?m)^out_time=(\d+):(\d{2}):(\d{2}\.\d+)')
        if ($measured.code -ne 0 -or -not $times.Count) { throw 'The file has no readable playback duration. Try exporting it as an H.264 MP4.' }
        $last = $times[$times.Count-1]
        $seconds = [double]::Parse($last.Groups[3].Value,[cultureinfo]::InvariantCulture) + [int]$last.Groups[2].Value * 60 + [long]$last.Groups[1].Value * 3600
        $milliseconds = [long][math]::Round($seconds * 1000)
    }
    if ($milliseconds -le 0) { throw 'The video does not have a positive playback duration.' }
    return @{width=[int]$dim.Groups[1].Value; height=[int]$dim.Groups[2].Value; durationMs=$milliseconds; codec=$stream.Groups[1].Value}
}

function Get-StudioMediaAsset([string]$AssetId) {
    if ($AssetId -cnotmatch '^[0-9a-f]{64}$') { return }
    $directory = Join-Path $mediaRoot $AssetId
    $manifest = Join-Path $directory 'asset.json'
    if (-not [IO.File]::Exists($manifest)) { return }
    $meta = [IO.File]::ReadAllText($manifest) | ConvertFrom-Json -ErrorAction Stop
    $type=if($meta.mediaType){[string]$meta.mediaType}else{'video'}
    $isImage=$type -ceq 'image'
    $validFormat=if($isImage){$meta.extension -cin @('.jpg','.jpeg')}else{$type -ceq 'video' -and $studioVideoFormats.ContainsKey([string]$meta.extension)}
    if ($meta.assetId -cne $AssetId -or -not $validFormat -or
        $meta.md5 -cnotmatch '^[0-9a-f]{32}$' -or $meta.width -le 0 -or $meta.height -le 0 -or $meta.durationMs -le 0) {
        throw 'The stored media metadata is damaged. Reimport the file from its original folder.'
    }
    if($isImage -and ($meta.width -gt 32768 -or $meta.height -gt 32768 -or [long]$meta.width*$meta.height -gt 64MB)) {throw 'The stored image dimensions are damaged. Reimport the original image.'}
    $video = Join-Path $directory ('content' + $meta.extension)
    $preview = Join-Path $directory 'preview.png'
    if (-not [IO.File]::Exists($video) -or (Get-Item -LiteralPath $video).Length -ne $meta.bytes -or -not [IO.File]::Exists($preview)) {
        throw 'Stored media or its thumbnail is missing or incomplete. Reimport the original file.'
    }
    $solutions = @(foreach ($aliasPath in [IO.Directory]::EnumerateFiles($directory,'name-*.json')) {
        $leaf = [IO.Path]::GetFileName($aliasPath)
        if ($leaf -cnotmatch '^name-([a-f0-9]{16})\.json$') { continue }
        $suffix = $Matches[1]
        $entry = [IO.File]::ReadAllText($aliasPath) | ConvertFrom-Json -ErrorAction Stop
        $name = [IO.Path]::GetFileNameWithoutExtension([string]$entry.fileName)
        if (-not $name) { continue }
        [pscustomobject]@{
            id="$type-$AssetId-$suffix"; name=$name; width=[int]$meta.width; height=[int]$meta.height
            color='#3077a6'; thumbnail="/api/media-preview/$AssetId"
            source=[ordered]@{kind=$(if($isImage){'localImage'}else{'localVideo'}); assetId=$AssetId; md5=$meta.md5; mediaFingerprint=$meta.md5; aliases=@()
                extension=$meta.extension; bytes=[long]$meta.bytes; durationMs=[long]$meta.durationMs; codec=$meta.codec; streamType=$type; fileName=$entry.fileName
                modified=[IO.File]::GetLastWriteTime($aliasPath).ToString('s')}
        }
    })
    return [pscustomobject]@{solutions=$solutions; solution=$solutions | Select-Object -First 1; path=$video; thumbnailPath=$preview; md5=$meta.md5}
}

function Get-StudioMediaSolutions {
    if (-not [IO.Directory]::Exists($mediaRoot)) { return }
    foreach ($directory in [IO.Directory]::EnumerateDirectories($mediaRoot)) {
        $id = [IO.Path]::GetFileName($directory)
        if ($id -cnotmatch '^[a-f0-9]{64}$') { continue }
        try {
            $asset = Get-StudioMediaAsset $id
            foreach ($solution in $asset.solutions) { $solution }
        } catch { Write-Warning $_.Exception.Message }
    }
}

function Import-StudioMedia([IO.Stream]$InputStream, [string]$FileName, [string]$SourceName='') {
    if (-not $FileName -or $FileName.Length -gt 255 -or $FileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw 'Choose a media file with a valid filename.'
    }
    $extension = [IO.Path]::GetExtension($FileName).ToLowerInvariant()
    if($SourceName -and ($SourceName.Length -gt 255 -or $SourceName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0)) {throw 'Choose a media file with a valid original filename.'}
    # Browser rasterization is restricted to these two formats. The uploaded
    # PNG is still decoded/validated here; original names are display labels.
    if($SourceName -and ($extension -cne '.png' -or [IO.Path]::GetExtension($SourceName).ToLowerInvariant() -cnotin @('.svg','.avif'))) {throw 'Browser image conversion requires PNG pixels and an SVG or AVIF original filename.'}
    $displayName=if($SourceName){$SourceName}else{$FileName}
    $stem = [IO.Path]::GetFileNameWithoutExtension($displayName)
    $isImage=$extension -cin $studioImageFormats
    $type=if($isImage){'image'}else{'video'}
    if (-not $stem.Trim() -or (-not $isImage -and -not $studioVideoFormats.ContainsKey($extension))) {
        throw 'Choose a supported image or video. Common image formats include JPG, PNG, GIF, BMP, TIFF, WebP, AVIF, HEIC and SVG.'
    }
    $nameBytes = [Text.Encoding]::UTF8.GetBytes($stem.Normalize().ToUpperInvariant())
    $nameKey = (Get-StudioRevision $nameBytes).Substring(0,16)
    $aliasFile = "name-$nameKey.json"
    $utf8 = [Text.UTF8Encoding]::new($false)
    $aliasJson = ConvertTo-Json @{fileName=$displayName} -Compress
    [void][IO.Directory]::CreateDirectory($mediaRoot)
    $staging = Join-Path $mediaRoot ('.upload-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($staging)
    $video = Join-Path $staging ('content' + $extension)
    $preview = Join-Path $staging 'preview.png'
    $manifest = Join-Path $staging 'asset.json'
    $alias = Join-Path $staging $aliasFile
    $originalPath=$video
    $normalizedPath=Join-Path $staging 'normalized.jpg'
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        $md5 = [Security.Cryptography.MD5]::Create()
        $output = [IO.File]::Open($video,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $buffer = [byte[]]::new(1MB)
            while (($count = $InputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                $output.Write($buffer,0,$count)
                [void]$sha.TransformBlock($buffer,0,$count,$buffer,0)
                [void]$md5.TransformBlock($buffer,0,$count,$buffer,0)
            }
            if (-not $output.Length) { throw 'The selected file is empty.' }
            [void]$sha.TransformFinalBlock($buffer,0,0)
            [void]$md5.TransformFinalBlock($buffer,0,0)
            $assetId = [BitConverter]::ToString($sha.Hash).Replace('-','').ToLowerInvariant()
            $digest = [BitConverter]::ToString($md5.Hash).Replace('-','').ToLowerInvariant()
            $bytes = $output.Length
            $output.Flush($true)
        } finally { $output.Dispose(); $sha.Dispose(); $md5.Dispose() }
        $meta=$null
        if($isImage) {
            $converted=$extension -cnotin @('.jpg','.jpeg','.jpe','.jfif')
            if($converted) {
                Convert-StudioRasterImage $video $extension $normalizedPath
                [IO.File]::Delete($video)
                $extension='.jpg';$video=Join-Path $staging 'content.jpg'
                [IO.File]::Move($normalizedPath,$video)
            } elseif($extension -cin @('.jpe','.jfif')) {
                $extension='.jpg';$renamed=Join-Path $staging 'content.jpg'
                [IO.File]::Move($video,$renamed);$video=$renamed
            }
            $meta=Read-StudioImage $video $preview
            if($meta.normalizedOrientation -or $converted) {
                $assetId=(Get-FileHash -LiteralPath $video -Algorithm SHA256).Hash.ToLowerInvariant()
                $digest=(Get-FileHash -LiteralPath $video -Algorithm MD5).Hash.ToLowerInvariant()
                $bytes=([IO.FileInfo]::new($video)).Length
            }
        }
        [IO.File]::WriteAllText($alias,$aliasJson,$utf8)
        $directory = Join-Path $mediaRoot $assetId
        $repair = $false
        if ([IO.Directory]::Exists($directory)) {
            try {
                $existing = Get-StudioMediaAsset $assetId
                $repair = -not $existing -or (Get-FileHash -LiteralPath $existing.path -Algorithm SHA256).Hash -ne $assetId
            } catch { $repair = $true }
            if(-not $repair -and $existing.solution.source.streamType -cne $type){throw 'The file contents do not match the selected media format.'}
        }
        if ($repair -or -not [IO.Directory]::Exists($directory)) {
            if(-not $meta){$meta = Read-StudioVideo $video $studioVideoFormats[$extension] $preview;$meta.mediaType='video'}
            $meta.assetId = $assetId; $meta.md5 = $digest; $meta.bytes = $bytes; $meta.extension = $extension
            [IO.File]::WriteAllText($manifest,(ConvertTo-Json $meta -Compress),$utf8)
            if ($repair) {
                # Repair known content only and retain every separately named
                # solution that already references this media.
                foreach ($part in $video,$preview,$manifest) {
                    $dest = Join-Path $directory ([IO.Path]::GetFileName($part))
                    if ([IO.File]::Exists($dest)) { [IO.File]::Replace($part,$dest,[Management.Automation.Language.NullString]::Value) }
                    else { [IO.File]::Move($part,$dest) }
                }
            } else {
                try { [IO.Directory]::Move($staging,$directory) }
                catch [IO.IOException] { if (-not [IO.File]::Exists((Join-Path $directory 'asset.json'))) { throw } }
            }
        }
        $storedAlias = Join-Path $directory $aliasFile
        if (-not [IO.File]::Exists($storedAlias)) {
            try { [IO.File]::Move($alias,$storedAlias) } catch [IO.IOException] { if (-not [IO.File]::Exists($storedAlias)) { throw } }
        }
        $asset = Get-StudioMediaAsset $assetId
        return $asset.solutions | Where-Object { $_.id -ceq "$type-$assetId-$nameKey" } | Select-Object -First 1
    } finally {
        # Remove only the four private files allocated during this upload.
        foreach ($path in $video,$originalPath,$normalizedPath,$preview,$manifest,$alias) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
        if ([IO.Directory]::Exists($staging)) { [IO.Directory]::Delete($staging,$false) }
    }
}

# Keep older callers working while the route uses the media-neutral entry point.
function Import-StudioVideo([IO.Stream]$InputStream,[string]$FileName) {
    Import-StudioMedia $InputStream $FileName
}

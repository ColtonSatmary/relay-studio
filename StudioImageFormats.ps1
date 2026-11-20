# Imported stills are normalized to JPEG so every USB/network player receives
# the same format. Source names remain labels only, never paths.
$studioImageFormats = @('.jpg','.jpeg','.jpe','.jfif','.png','.apng','.gif','.bmp','.dib','.tif','.tiff','.webp','.ico','.avif','.heic','.heif','.svg','.psd','.tga','.j2k','.jp2','.jpf','.jpx','.exr','.dds','.pbm','.pgm','.ppm','.pnm','.dng','.cr2','.nef','.arw','.orf','.rw2','.jxr','.wdp')
$studioImageDemuxers = @{
    '.png'='png_pipe';'.apng'='apng';'.gif'='gif';'.bmp'='bmp_pipe';'.dib'='bmp_pipe';'.tif'='tiff_pipe';'.tiff'='tiff_pipe';'.webp'='webp_pipe';'.ico'='ico'
    '.psd'='psd_pipe';'.tga'='image2';'.j2k'='j2k_pipe';'.jp2'='j2k_pipe';'.jpf'='j2k_pipe';'.jpx'='j2k_pipe';'.exr'='exr_pipe';'.dds'='dds_pipe'
    '.pbm'='pbm_pipe';'.pgm'='pgm_pipe';'.ppm'='ppm_pipe';'.pnm'='image2'
}

function Assert-StudioImageDimensions([long]$Width,[long]$Height) {
    if($Width -lt 1 -or $Height -lt 1 -or $Width -gt 32768 -or $Height -gt 32768 -or $Width*$Height -gt 64MB) {
        throw 'This image is too large. Resize it to at most 64 megapixels and 32768 pixels per side.'
    }
}

function Convert-StudioRasterImage([string]$Path,[string]$Extension,[string]$Destination) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { return Convert-StudioMacRasterImage $Path $Extension $Destination }
    if(([IO.FileInfo]::new($Path)).Length -gt 256MB){throw 'This image file is too large. Export a copy smaller than 256 MB.'}
    if($Extension -in '.svg','.avif'){throw 'This image needs browser conversion. Import it through Choose files or drop it into Relay.'}
    $decodedPath=$Path+'.decoded.png'
    $stream=$null;$decoder=$null;$bitmap=$null;$source=$null;$graphics=$null;$parameters=$null
    $orientation=1;$decoded=$false;$wicError=$null
    try {
        # WIC uses the installed Windows image extensions (including HEIF and
        # camera RAW where available). Delay pixel decoding until after bounds.
        if($Extension -notin '.webp','.psd','.tga','.j2k','.jp2','.jpf','.jpx','.exr','.dds','.pbm','.pgm','.ppm','.pnm','.apng') {
            try {
                Add-Type -AssemblyName PresentationCore
                $stream=[IO.File]::OpenRead($Path)
                $decoder=[Windows.Media.Imaging.BitmapDecoder]::Create($stream,[Windows.Media.Imaging.BitmapCreateOptions]::DelayCreation,[Windows.Media.Imaging.BitmapCacheOption]::None)
                if(-not $decoder.Frames.Count){throw 'No image frame was found.'}
                $frame=$decoder.Frames[0]
                Assert-StudioImageDimensions $frame.PixelWidth $frame.PixelHeight
                # Reject misleading common extensions instead of accepting a
                # JPEG renamed .png (or an unrelated container by accident).
                $formats=@{'.png'=[Windows.Media.Imaging.PngBitmapDecoder];'.gif'=[Windows.Media.Imaging.GifBitmapDecoder];'.bmp'=[Windows.Media.Imaging.BmpBitmapDecoder];'.dib'=[Windows.Media.Imaging.BmpBitmapDecoder];'.tif'=[Windows.Media.Imaging.TiffBitmapDecoder];'.tiff'=[Windows.Media.Imaging.TiffBitmapDecoder];'.ico'=[Windows.Media.Imaging.IconBitmapDecoder]}
                if($formats.ContainsKey($Extension) -and -not $formats[$Extension].IsInstanceOfType($decoder)){throw 'The image contents do not match its filename extension.'}
                if($frame.Metadata -is [Windows.Media.Imaging.BitmapMetadata]) {
                    foreach($query in @('/app1/ifd/{ushort=274}','/ifd/{ushort=274}')) {
                        try {if($frame.Metadata.ContainsQuery($query)){$orientation=[int]$frame.Metadata.GetQuery($query);break}}catch{}
                    }
                }
                if($orientation -lt 1 -or $orientation -gt 8){throw 'The image orientation metadata is invalid.'}
                $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
                $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($frame))
                $target=[IO.File]::Open($decodedPath,[IO.FileMode]::CreateNew)
                try {$encoder.Save($target)}finally{$target.Dispose()}
                $decoded=$true
            } catch {
                $wicError=$_.Exception.Message
                if($wicError -like '*too large*' -or $wicError -like '*contents do not match*' -or $wicError -like '*orientation metadata*'){throw}
            } finally {if($stream){$stream.Dispose();$stream=$null};$decoder=$null}
        }
        if(-not $decoded) {
            $demuxer=$studioImageDemuxers[$Extension]
            if(-not $demuxer){throw "This $Extension image could not be decoded by the installed Windows image codecs. Export it as PNG, JPG or TIFF and try again."}
            if([IO.File]::Exists($decodedPath)){[IO.File]::Delete($decodedPath)}
            $ffmpeg=Get-StudioFfmpegPath
            $input=@('-hide_banner','-nostdin','-protocol_whitelist','file','-max_alloc','268435456','-threads','1','-f',$demuxer)
            if($demuxer -eq 'image2'){$input+=@('-pattern_type','none')}
            $input+=@('-i',$Path,'-map','0:v:0','-an','-sn','-dn')
            # Parse dimensions without decoding a frame, before pixel allocation.
            $probe=Invoke-StudioVideoTool $ffmpeg ($input+@('-frames:v','0','-f','null','NUL')) 20000
            $size=[regex]::Match($probe.log,'(?m)^\s*Stream #0:\d+[^\r\n]*?Video:[^\r\n]*?\b(\d{1,8})x(\d{1,8})\b')
            if(-not $size.Success){throw "This $Extension image could not be decoded. Check that its contents match the extension, or export it as PNG or JPG."}
            Assert-StudioImageDimensions ([long]$size.Groups[1].Value) ([long]$size.Groups[2].Value)
            $result=Invoke-StudioVideoTool $ffmpeg ($input+@('-frames:v','1','-threads','1','-c:v','png','-f','image2',$decodedPath)) 60000
            if($result.code -ne 0 -or -not [IO.File]::Exists($decodedPath)){throw "This $Extension image could not be decoded. Export it as PNG or JPG and try again."}
        }
        Add-Type -AssemblyName System.Drawing
        $source=[Drawing.Image]::FromFile($decodedPath)
        Assert-StudioImageDimensions $source.Width $source.Height
        if($orientation -ne 1) {
            $rotations=@{2='RotateNoneFlipX';3='Rotate180FlipNone';4='Rotate180FlipX';5='Rotate90FlipX';6='Rotate90FlipNone';7='Rotate270FlipX';8='Rotate270FlipNone'}
            $source.RotateFlip([Drawing.RotateFlipType][Enum]::Parse([Drawing.RotateFlipType],$rotations[$orientation]))
        }
        $bitmap=[Drawing.Bitmap]::new($source.Width,$source.Height,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([Drawing.Color]::Black)
        # WIC outputs may carry zero/unequal DPI. Explicit pixel rectangles keep
        # the imported image from being drawn at an unexpected physical size.
        $rect=[Drawing.Rectangle]::new(0,0,$source.Width,$source.Height)
        $graphics.DrawImage($source,$rect,$rect,[Drawing.GraphicsUnit]::Pixel)
        $graphics.Dispose();$graphics=$null
        $encoder=[Drawing.Imaging.ImageCodecInfo]::GetImageEncoders()|Where-Object MimeType -EQ 'image/jpeg'|Select-Object -First 1
        $parameters=[Drawing.Imaging.EncoderParameters]::new(1)
        $parameters.Param[0]=[Drawing.Imaging.EncoderParameter]::new([Drawing.Imaging.Encoder]::Quality,95L)
        $bitmap.Save($Destination,$encoder,$parameters)
    } finally {
        foreach($resource in @($graphics,$bitmap,$source,$stream,$parameters)){if($null -ne $resource){$resource.Dispose()}}
        if([IO.File]::Exists($decodedPath)){[IO.File]::Delete($decodedPath)}
    }
}

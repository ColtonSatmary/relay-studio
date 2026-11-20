$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'StudioProject.ps1')
. (Join-Path $PSScriptRoot 'StudioMedia.ps1')
Add-Type -AssemblyName System.Drawing
function Assert-Format([bool]$Condition,[string]$Message){if(-not $Condition){throw "Test failed: $Message"}}
function Import-Format([string]$Path,[string]$Name,[string]$SourceName=''){$stream=[IO.File]::OpenRead($Path);try{Import-StudioMedia $stream $Name $SourceName}finally{$stream.Dispose()}}
$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$leaf='RelayImageFormats-'+[guid]::NewGuid().ToString('N')
$fixture=[IO.Directory]::CreateDirectory((Join-Path $tempParent $leaf)).FullName
$mediaRoot=Join-Path $fixture 'Media'
try {
    $bitmap=[Drawing.Bitmap]::new(640,360,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g=[Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.Clear([Drawing.Color]::Transparent);$g.FillRectangle([Drawing.Brushes]::Red,320,0,320,360)
        foreach($entry in @(@('png',[Drawing.Imaging.ImageFormat]::Png),@('gif',[Drawing.Imaging.ImageFormat]::Gif),@('bmp',[Drawing.Imaging.ImageFormat]::Bmp),@('tiff',[Drawing.Imaging.ImageFormat]::Tiff))) {
            $path=Join-Path $fixture ('source.'+$entry[0]);$bitmap.Save($path,$entry[1])
            $originalPixels=[Drawing.Bitmap]::new($path);try{Assert-Format ($originalPixels.GetPixel(500,100).R -gt 200) 'Test image missing source red pixel'}finally{$originalPixels.Dispose()}
            $solution=Import-Format $path ('Still-'+$entry[0]+'.'+$entry[0])
            Assert-Format ($solution.name -ceq ('Still-'+$entry[0]) -and $solution.source.fileName -ceq ('Still-'+$entry[0]+'.'+$entry[0]) -and $solution.width -eq 640 -and $solution.height -eq 360 -and $solution.source.extension -ceq '.jpg') "$($entry[0]) dimensions/name/storage format failed"
            $stored=Get-StudioMediaAsset $solution.source.assetId
            $pixels=[Drawing.Bitmap]::new($stored.path);$thumb=[Drawing.Bitmap]::new($stored.thumbnailPath)
            try {
                Assert-Format ($pixels.RawFormat.Guid -eq [Drawing.Imaging.ImageFormat]::Jpeg.Guid -and $pixels.GetPixel(500,100).R -gt 200 -and $thumb.Width -eq 320 -and $thumb.Height -eq 180) "$($entry[0]) pixels/thumbnail incorrect: format=$($pixels.RawFormat.Guid), pixel=$($pixels.GetPixel(500,100)), thumb=$($thumb.Width)x$($thumb.Height)"
                if($entry[0] -in 'png','tiff'){Assert-Format ($pixels.GetPixel(100,100).R -lt 10) 'Transparency did not flatten to black'}
            }finally{$pixels.Dispose();$thumb.Dispose()}
            $repeat=Import-Format $path ('Still-'+$entry[0]+'.'+$entry[0]);Assert-Format ($repeat.id -ceq $solution.id) 'Normalized import not deterministic'
        }
    }finally{$g.Dispose();$bitmap.Dispose()}
    $ffmpeg=Get-StudioFfmpegPath
    $png=Join-Path $fixture 'source.png'
    foreach($entry in @(@('webp','libwebp'),@('tga','targa'),@('jp2','jpeg2000'),@('ppm','ppm'),@('pgm','pgm'),@('pbm','pbm'))) {
        $path=Join-Path $fixture ('source.'+$entry[0])
        $made=Invoke-StudioVideoTool $ffmpeg @('-hide_banner','-nostdin','-i',$png,'-frames:v','1','-c:v',$entry[1],'-f','image2',$path) 30000
        Assert-Format ($made.code -eq 0) "Could not create $($entry[0]) fixture: $($made.log)"
        $solution=Import-Format $path ('Raster.'+$entry[0])
        Assert-Format ($solution.width -eq 640 -and $solution.height -eq 360 -and $solution.source.kind -ceq 'localImage' -and $solution.source.extension -ceq '.jpg') "$($entry[0]) normalization failed"
    }
    foreach($i in 0,1) {
        $frame=[Drawing.Bitmap]::new(64,32);$draw=[Drawing.Graphics]::FromImage($frame)
        try{$draw.Clear($(if($i -eq 0){[Drawing.Color]::Red}else{[Drawing.Color]::Blue}));$frame.Save((Join-Path $fixture "frame$i.png"),[Drawing.Imaging.ImageFormat]::Png)}finally{$draw.Dispose();$frame.Dispose()}
    }
    foreach($extension in 'gif','apng') {
        $animated=Join-Path $fixture "animated.$extension"
        $made=Invoke-StudioVideoTool $ffmpeg @('-hide_banner','-nostdin','-framerate','1','-i',(Join-Path $fixture 'frame%d.png'),'-frames:v','2','-f',$extension,$animated) 30000
        Assert-Format ($made.code -eq 0) "Could not create animated $extension fixture"
        $solution=Import-Format $animated "Animated.$extension"
        $asset=Get-StudioMediaAsset $solution.source.assetId;$pixels=[Drawing.Bitmap]::new($asset.path)
        try{Assert-Format ($pixels.GetPixel(20,20).R -gt 200 -and $pixels.GetPixel(20,20).B -lt 20) "$extension did not import its first frame"}finally{$pixels.Dispose()}
    }
    $icon=Join-Path $fixture 'source.ico'
    $made=Invoke-StudioVideoTool $ffmpeg @('-hide_banner','-nostdin','-i',(Join-Path $fixture 'frame0.png'),'-frames:v','1','-c:v','bmp','-f','ico',$icon) 30000
    Assert-Format ($made.code -eq 0) 'Could not create ICO fixture'
    $solution=Import-Format $icon 'Icon.ico'
    Assert-Format ($solution.width -eq 64 -and $solution.height -eq 32) 'ICO dimensions incorrect'
    $svg=Import-Format $png 'Vector.png' 'Original.Vector.svg'
    $avif=Import-Format $png 'Photo.png' 'Original.Photo.avif'
    Assert-Format ($svg.name -ceq 'Original.Vector' -and $svg.source.fileName -ceq 'Original.Vector.svg' -and $avif.source.fileName -ceq 'Original.Photo.avif') 'Browser converted image original filename not retained'
    foreach($name in @('../escape.svg',('x'*256)+'.svg','not-avif.txt')) {
        $failure='';try{$null=Import-Format $png 'Pixels.png' $name}catch{$failure=$_.Exception.Message}
        Assert-Format ([bool]$failure) 'Invalid browser source label accepted'
    }
    $bad=Join-Path $fixture 'broken.webp';[IO.File]::WriteAllBytes($bad,[byte[]]@(1,2,3,4))
    $failure='';try{$null=Import-Format $bad 'Broken.webp'}catch{$failure=$_.Exception.Message}
    Assert-Format ($failure -like '*could not be decoded*') 'Corrupt image unexpectedly accepted'
    Assert-Format (@(Get-ChildItem -LiteralPath $mediaRoot -Directory -Filter '.upload-*').Count -eq 0) 'Import left staging files'
    'Image format checks passed: PNG/GIF/APNG/BMP/TIFF/WebP/TGA/JPEG2000/ICO/PPM/PGM/PBM decode; first animation frame; JPEG normalization; black transparency; thumbnails; deterministic imports; SVG/AVIF source labels; invalid names and corruption.'
}finally {
    $resolved=[IO.Path]::GetFullPath($fixture).TrimEnd('\')
    if([IO.Path]::GetDirectoryName($resolved) -ceq $tempParent -and [IO.Path]::GetFileName($resolved) -ceq $leaf -and $leaf -cmatch '^RelayImageFormats-[a-f0-9]{32}$'){
        $linked=@(Get-ChildItem -LiteralPath $resolved -Force -Recurse|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint})
        if(-not $linked.Count){[IO.Directory]::Delete($resolved,$true)}
    }
}

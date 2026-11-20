# Player screenshots are captured on demand. Only the fixed native screenshot
# endpoint and its restricted screenshot-cache file are read by the transport.
function Convert-StudioPlayerPreview([byte[]]$Bytes,[string]$WorkDirectory) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { return Convert-StudioMacPlayerPreview $Bytes $WorkDirectory }
    if ($null -eq $Bytes -or $Bytes.Length -lt 16 -or $Bytes.Length -gt 8MB) {throw 'The player returned an empty or oversized preview image.'}
    $inputPath=Join-Path $WorkDirectory 'screen-preview-source.jpg'
    $input=$null;$picture=$null;$small=$null;$graphics=$null;$output=$null;$parameters=$null
    try {
        if ($Bytes[0] -eq 255 -and $Bytes[1] -eq 216) {
            [IO.File]::WriteAllBytes($inputPath,$Bytes)
            $dimensions=Read-StudioJpegDimensions $inputPath
        } elseif ([BitConverter]::ToString($Bytes,0,8) -eq '89-50-4E-47-0D-0A-1A-0A' -and $Bytes.Length -ge 33 -and [Text.Encoding]::ASCII.GetString($Bytes,12,4) -ceq 'IHDR') {
            $width=([long]$Bytes[16]*16777216)+([long]$Bytes[17]*65536)+([long]$Bytes[18]*256)+[long]$Bytes[19]
            $height=([long]$Bytes[20]*16777216)+([long]$Bytes[21]*65536)+([long]$Bytes[22]*256)+[long]$Bytes[23]
            $dimensions=@{width=$width;height=$height}
        } else {throw 'The player returned an unsupported preview image. A JPEG or PNG screenshot is required.'}
        if($dimensions.width -lt 1 -or $dimensions.height -lt 1 -or $dimensions.width -gt 8192 -or $dimensions.height -gt 8192 -or [long]$dimensions.width*$dimensions.height -gt 16MB) {throw 'The player returned preview dimensions that are too large.'}
        Add-Type -AssemblyName System.Drawing
        $input=[IO.MemoryStream]::new($Bytes,$false)
        try {$picture=[Drawing.Image]::FromStream($input,$false,$true)} catch {throw 'The player preview image could not be decoded.'}
        if($picture.Width -ne $dimensions.width -or $picture.Height -ne $dimensions.height -or $picture.RawFormat.Guid -notin @([Drawing.Imaging.ImageFormat]::Jpeg.Guid,[Drawing.Imaging.ImageFormat]::Png.Guid)) {throw 'The player preview dimensions or format did not match its image header.'}
        $scale=[math]::Min(1.0,480.0/[math]::Max($picture.Width,$picture.Height))
        $width=[math]::Max(1,[int][math]::Round($picture.Width*$scale));$height=[math]::Max(1,[int][math]::Round($picture.Height*$scale))
        $small=[Drawing.Bitmap]::new($width,$height,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $graphics=[Drawing.Graphics]::FromImage($small)
        $graphics.Clear([Drawing.Color]::Black)
        $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawImage($picture,[Drawing.Rectangle]::new(0,0,$width,$height))
        $encoder=[Drawing.Imaging.ImageCodecInfo]::GetImageEncoders()|Where-Object MimeType -EQ 'image/jpeg'|Select-Object -First 1
        $parameters=[Drawing.Imaging.EncoderParameters]::new(1)
        $parameters.Param[0]=[Drawing.Imaging.EncoderParameter]::new([Drawing.Imaging.Encoder]::Quality,75L)
        $output=[IO.MemoryStream]::new();$small.Save($output,$encoder,$parameters)
        if($output.Length -gt 512KB){throw 'The resized player preview is unexpectedly large.'}
        return @{imageDataUrl='data:image/jpeg;base64,'+[Convert]::ToBase64String($output.ToArray());width=$width;height=$height}
    } finally {
        foreach($resource in @($graphics,$small,$picture,$input,$output,$parameters)){if($null -ne $resource){$resource.Dispose()}}
        if([IO.File]::Exists($inputPath)){[IO.File]::Delete($inputPath)}
    }
}

function Invoke-StudioPlayerPreview($Options,[string]$WorkDirectory) {
    $session=$null;$mutex=$null;$locked=$false
    try {
        $sha=[Security.Cryptography.SHA256]::Create()
        try {$key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Options.device.sn))).Replace('-','')} finally {$sha.Dispose()}
        $mutex=[Threading.Mutex]::new($false,'Local\RelayNetworkPlayer-'+$key)
        try {$locked=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$locked=$true}
        if(-not $locked){throw 'This board is busy with another operation. Refresh its preview after that finishes.'}
        Write-StudioNetworkProgress $WorkDirectory 10 'Connecting to capture the current display...'
        $session=New-StudioVerifiedNetworkSession $Options
        $width=[double]$Options.device.width;$height=[double]$Options.device.height
        if($width -le 0 -or $height -le 0){$width=640;$height=360}
        $scale=[math]::Min(1.0,480.0/[math]::Max($width,$height))
        $captureWidth=[math]::Max(1,[int][math]::Round($width*$scale));$captureHeight=[math]::Max(1,[int][math]::Round($height*$scale))
        Write-StudioNetworkProgress $WorkDirectory 35 'Capturing a small screenshot of the current display...'
        $capture=$session.RequestScreenCapture($captureWidth,$captureHeight) | ConvertFrom-Json -ErrorAction Stop
        if($capture.path -isnot [string] -or -not $capture.path){throw 'This player did not provide a screen preview. Its firmware may not support screenshots.'}
        Write-StudioNetworkProgress $WorkDirectory 65 'Reading the screenshot...'
        $bytes=$session.ReadScreenCaptureFile([string]$capture.path)
        $preview=Convert-StudioPlayerPreview $bytes $WorkDirectory
        $preview.capturedAt=[datetime]::UtcNow.ToString('o');$preview.kind='snapshot';$preview.available=$true
        $preview.message='Snapshot of the player output. Refresh to capture a newer frame.'
        return @{event='complete';progress=100;message='Current display preview captured.';device=(Get-StudioNetworkDeviceSummary $session.Device);preview=$preview}
    } finally {
        if($session){$session.Dispose()}
        if($locked){$mutex.ReleaseMutex()}
        if($mutex){$mutex.Dispose()}
    }
}

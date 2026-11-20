# macOS adapters for the shared local server and network workers.
function Invoke-StudioMacTool([string]$Executable,[string[]]$Arguments,[int]$TimeoutMs=60000,[string]$InputText=$null) {
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$Executable;$info.UseShellExecute=$false
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($argument in $Arguments){$info.ArgumentList.Add($argument)}
    if($null -ne $InputText){$info.RedirectStandardInput=$true}
    $process=[Diagnostics.Process]::Start($info)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if($info.RedirectStandardInput){$process.StandardInput.Write($InputText);$process.StandardInput.Close()}
        if(-not $process.WaitForExit($TimeoutMs)){$process.Kill($true);$process.WaitForExit();throw 'The macOS operation timed out.'}
        return @{code=$process.ExitCode;output=$stdout.GetAwaiter().GetResult();log=$stderr.GetAwaiter().GetResult()}
    } finally {$process.Dispose()}
}

function Get-StudioMacFfmpegPath {
    foreach($candidate in @((Get-Command ffmpeg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),'/opt/homebrew/bin/ffmpeg','/usr/local/bin/ffmpeg')) {
        if($candidate -and [IO.File]::Exists($candidate)){return $candidate}
    }
    throw 'Install FFmpeg for macOS and reopen Relay Studio. See macos/README.md.'
}

function Get-StudioMacImageInput([string]$Path,[string]$Extension) {
    if(([IO.FileInfo]::new($Path)).Length -gt 256MB){throw 'This image is too large. Export a copy smaller than 256 MB.'}
    if($Extension -in '.svg','.avif'){throw 'Import SVG or AVIF through the browser so it can convert it to PNG.'}
    $demuxer=if($Extension -in '.jpg','.jpeg','.jpe','.jfif'){'jpeg_pipe'}elseif($Extension -in '.heic','.heif'){'mov'}else{$studioImageDemuxers[$Extension]}
    if(-not $demuxer){throw "The installed macOS image decoder does not support $Extension. Export a PNG, JPG or TIFF copy and import it."}
    $arguments=@('-hide_banner','-nostdin','-protocol_whitelist','file','-max_alloc','268435456','-threads','1','-f',$demuxer)
    if($demuxer -eq 'image2'){$arguments+=@('-pattern_type','none')}
    $arguments+=@('-i',$Path,'-map','0:v:0','-an','-sn','-dn')
    $probe=Invoke-StudioMacTool (Get-StudioMacFfmpegPath) ($arguments+@('-frames:v','0','-f','null','/dev/null')) 20000
    $size=[regex]::Match($probe.log,'(?m)^\s*Stream #0:\d+[^\r\n]*?Video:[^\r\n]*?\b(\d{1,8})x(\d{1,8})\b')
    if(-not $size.Success){throw "The installed FFmpeg decoder could not read this $Extension image. Export it as PNG or JPG."}
    Assert-StudioImageDimensions ([long]$size.Groups[1].Value) ([long]$size.Groups[2].Value)
    return ,$arguments
}

function Convert-StudioMacRasterImage([string]$Path,[string]$Extension,[string]$Destination) {
    $arguments=Get-StudioMacImageInput $Path $Extension
    # FFmpeg autorotates EXIF; black compositing gives transparent pixels the
    # same background used by Windows and by the LED playback canvas.
    $filter='[0:v:0]split[a][b];[b]format=rgb24,lutrgb=r=0:g=0:b=0[bg];[bg][a]overlay=format=auto,format=yuvj444p[out]'
    $arguments=@($arguments | ForEach-Object {if($_ -ceq '0:v:0'){'[out]'}else{$_}})
    $result=Invoke-StudioMacTool (Get-StudioMacFfmpegPath) ($arguments+@('-filter_complex',$filter,'-frames:v','1','-threads','1','-c:v','mjpeg','-q:v','2','-f','image2',$Destination))
    if($result.code -ne 0 -or -not [IO.File]::Exists($Destination)){throw 'The image could not be converted. Export it as PNG or JPG and try again.'}
}

function Read-StudioMacImage([string]$Path,[string]$Preview) {
    $null=Read-StudioJpegDimensions $Path
    $normal=$Path+'.upright.tmp'
    try {
        Convert-StudioMacRasterImage $Path '.jpg' $normal
        $size=Read-StudioJpegDimensions $normal
        $arguments=Get-StudioMacImageInput $normal '.jpg'
        $result=Invoke-StudioMacTool (Get-StudioMacFfmpegPath) ($arguments+@('-vf','scale=w=min(320\,iw):h=min(320\,ih):force_original_aspect_ratio=decrease','-frames:v','1','-threads','1','-c:v','png','-f','image2',$Preview))
        if($result.code -ne 0 -or -not [IO.File]::Exists($Preview)){throw 'The image thumbnail could not be created.'}
        [IO.File]::Move($normal,$Path,$true)
        return @{mediaType='image';width=$size.width;height=$size.height;durationMs=10000;codec='jpeg';normalizedOrientation=$true}
    } finally {if([IO.File]::Exists($normal)){[IO.File]::Delete($normal)}}
}

function Convert-StudioMacPlayerPreview([byte[]]$Bytes,[string]$WorkDirectory) {
    if($null -eq $Bytes -or $Bytes.Length -lt 16 -or $Bytes.Length -gt 8MB){throw 'The player returned an empty or oversized preview image.'}
    $path=Join-Path $WorkDirectory 'screen-preview-source.jpg';$output=Join-Path $WorkDirectory 'screen-preview-small.jpg'
    try {
        if($Bytes[0] -eq 255 -and $Bytes[1] -eq 216){$extension='.jpg';[IO.File]::WriteAllBytes($path,$Bytes);$size=Read-StudioJpegDimensions $path}
        elseif([BitConverter]::ToString($Bytes,0,8) -eq '89-50-4E-47-0D-0A-1A-0A' -and $Bytes.Length -ge 33 -and [Text.Encoding]::ASCII.GetString($Bytes,12,4) -ceq 'IHDR'){
            $extension='.png';$size=@{width=0L;height=0L}
            for($index=0;$index -lt 4;$index++){$size.width=$size.width*256+$Bytes[16+$index];$size.height=$size.height*256+$Bytes[20+$index]}
            [IO.File]::WriteAllBytes($path,$Bytes)
        }else{throw 'The player returned an unsupported screenshot. A PNG or JPEG is required.'}
        if($size.width -lt 1 -or $size.height -lt 1 -or $size.width -gt 8192 -or $size.height -gt 8192 -or $size.width*$size.height -gt 16MB){throw 'The player returned preview dimensions that are too large.'}
        $arguments=Get-StudioMacImageInput $path $extension
        $result=Invoke-StudioMacTool (Get-StudioMacFfmpegPath) ($arguments+@('-vf','scale=w=min(480\,iw):h=min(480\,ih):force_original_aspect_ratio=decrease','-frames:v','1','-threads','1','-c:v','mjpeg','-q:v','5','-f','image2',$output))
        if($result.code -ne 0 -or -not [IO.File]::Exists($output)){throw 'The player preview image could not be decoded.'}
        $bytesOut=[IO.File]::ReadAllBytes($output);$dimensions=Read-StudioJpegDimensions $output
        if($bytesOut.Length -gt 512KB){throw 'The resized player preview is unexpectedly large.'}
        return @{imageDataUrl='data:image/jpeg;base64,'+[Convert]::ToBase64String($bytesOut);width=$dimensions.width;height=$dimensions.height}
    } finally {foreach($file in @($path,$output)){if([IO.File]::Exists($file)){[IO.File]::Delete($file)}}}
}

function Get-StudioMacPasswordAccount {
    if(-not ('RelayMacKeychain' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'StudioMacKeychain.cs')}
    $hash=[Security.Cryptography.SHA256]::Create()
    try{return [Convert]::ToHexString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($WorkspaceDirectory)))).ToLowerInvariant()}
    finally{$hash.Dispose()}
}

function Get-StudioMacBoardTimeZone([string]$Zone,[long]$UtcTimeMillis) {
    # macOS supplies the IANA database. BaseUtcOffsetDelta accounts for historic
    # changes to a zone's standard offset without accidentally adding DST.
    if($Zone -cnotmatch '^(?:UTC|[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)+)$'){throw 'Unknown IANA time zone. Use a zone such as America/Los_Angeles.'}
    try{$resolved=[TimeZoneInfo]::FindSystemTimeZoneById($Zone)}catch{throw 'Unknown IANA time zone. Use a zone such as America/Los_Angeles.'}
    $instant=[DateTimeOffset]::FromUnixTimeMilliseconds($UtcTimeMillis)
    $date=[TimeZoneInfo]::ConvertTime($instant,$resolved).Date
    $offset=$resolved.BaseUtcOffset
    foreach($rule in $resolved.GetAdjustmentRules()){if($date -ge $rule.DateStart -and $date -le $rule.DateEnd){$offset+=$rule.BaseUtcOffsetDelta;break}}
    $minutes=[int][math]::Abs($offset.TotalMinutes);$sign=if($offset.Ticks -lt 0){'-'}else{'+'}
    return @{timeZone=$Zone;gmt=('GTM{0}{1:00}:{2:00}' -f $sign,[int][math]::Floor($minutes/60),($minutes%60))}
}

. (Join-Path $PSScriptRoot 'StudioMacUsb.ps1')

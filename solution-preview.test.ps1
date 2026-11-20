# Exercise the normal HTTP routes against a disposable library, including an
# unread response large enough to stall a synchronous single-threaded listener.
$ErrorActionPreference = 'Stop'
function Assert-Preview($condition, $message) { if (-not $condition) { throw $message } }
function Send-PreviewRequest($Url, [string]$Range, [string]$Method = 'GET') {
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.Method = $Method
    $request.Proxy = $null
    $request.Timeout = 8000
    $request.ServicePoint.ConnectionLimit = 8
    if ($Range) {
        if ($Range -match '^-(\d+)$') { $request.AddRange(-[long]$Matches[1]) }
        elseif ($Range -match '^(\d+)-(\d+)$') { $request.AddRange([long]$Matches[1],[long]$Matches[2]) }
        else { $request.AddRange([long]$Range.TrimEnd('-')) }
    }
    try { return $request.GetResponse() }
    catch [Net.WebException] { if ($_.Exception.Response) { return $_.Exception.Response }; throw }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('relay-preview-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $testRoot 'ViPlexExpress\Config'
$snapshot = Join-Path $fixture 'Publish\1'
$nativeMedia = Join-Path $fixture 'Media'
$workspace = Join-Path $testRoot 'workspace'
$alias = '1234567890abcdef'
$uuid = [guid]::NewGuid().ToString('D')
$listenerTest = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listenerTest.Start()
$port = $listenerTest.LocalEndpoint.Port
$listenerTest.Stop()
$server = $null
$pending = $null
try {
    foreach ($dir in $snapshot,$nativeMedia,$workspace) { [void][IO.Directory]::CreateDirectory($dir) }
    # Opaque synthetic content is sufficient to test transport and seeking.
    $original = Join-Path $testRoot 'Fixture.mp4'
    $stream = [IO.File]::Create($original)
    try {
        $stream.SetLength(32MB)
        $stream.Position = $stream.Length - 3
        $stream.Write([byte[]](12,34,56),0,3)
    } finally { $stream.Dispose() }
    $id = (Get-FileHash $original -Algorithm SHA256).Hash.ToLowerInvariant()
    $digest = (Get-FileHash $original -Algorithm MD5).Hash.ToLowerInvariant()
    $assetDir = Join-Path (Join-Path $workspace 'Media') $id
    [void][IO.Directory]::CreateDirectory($assetDir)
    [IO.File]::Copy($original,(Join-Path $assetDir 'content.mp4'))
    [IO.File]::WriteAllText((Join-Path $assetDir 'asset.json'),(@{assetId=$id;md5=$digest;bytes=32MB;width=720;height=1280
        durationMs=4321;codec='h264';extension='.mp4'} | ConvertTo-Json))
    [IO.File]::WriteAllText((Join-Path $assetDir "name-$alias.json"),'{"fileName":"Imported.mp4"}')
    [IO.File]::WriteAllBytes((Join-Path $assetDir 'preview.png'),[byte[]](1))
    $video = @{type='VIDEO';name='Fixture.mp4';duration=4321;filesize=32MB;dataSource="$digest.mp4";originalDataSource=$original}
    $unavailable = @{type='PICTURE';name='Missing';dataSource='../outside.png'}
    $widgetGroup = @{contents=@{widgets=@($unavailable)}}
    $page = @{widgetContainers=@(@{contents=@{widgets=@($video);widgetGroups=@($widgetGroup)}})}
    $list = @{name='Display';uuid=$uuid;width=720;height=1280;sceneItems=@(@{name='Welcome';page=$page})}
    [IO.File]::WriteAllText((Join-Path $snapshot 'playlist0.json'),($list | ConvertTo-Json -Depth 18))

    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = 'powershell.exe'
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'Start-Studio.ps1') +
        '" -NoBrowser -WorkspaceDirectory "' + $workspace + '" -ExportRoot "' + (Join-Path $testRoot 'exports') + '" -Port ' + $port
    $info.EnvironmentVariables['ProgramData'] = $testRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $server = [Diagnostics.Process]::Start($info)
    $base = "http://127.0.0.1:$port"
    $ready = $false
    for ($i=0; $i -lt 100; $i++) {
        try { $ready = (Invoke-RestMethod "$base/api/session").solutionPreviewVersion -eq 1 } catch {}
        if ($ready) { break }
        if ($server.HasExited) { throw 'Fixture server exited during startup.' }
        Start-Sleep -Milliseconds 100
    }
    Assert-Preview $ready 'Preview service did not start.'
    # Exercise a real JPEG through the authenticated import route, not a
    # hand-written metadata fixture, then stream it through its solution URL.
    Add-Type -AssemblyName System.Drawing
    $jpegPath=Join-Path $testRoot 'Lobby.JPG'
    $bitmap=[Drawing.Bitmap]::new(80,40)
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.Color]::CornflowerBlue)
        $bitmap.Save($jpegPath,[Drawing.Imaging.ImageFormat]::Jpeg)
    } finally {$graphics.Dispose();$bitmap.Dispose()}
    $jpegBytes=[IO.File]::ReadAllBytes($jpegPath)
    $headers=@{Origin=$base;'X-Studio-Token'=(Invoke-RestMethod "$base/api/session").exportToken}
    $imageImport=Invoke-RestMethod "$base/api/media?name=Lobby.JPG" -Method Post -Headers $headers -ContentType 'image/jpeg' -InFile $jpegPath
    $imageSolution=$imageImport.solution
    Assert-Preview ($imageSolution.id -cmatch '^image-[a-f0-9]{64}-[a-f0-9]{16}$' -and $imageSolution.source.kind -ceq 'localImage' -and $imageSolution.name -ceq 'Lobby' -and $imageSolution.width -eq 80 -and $imageSolution.height -eq 40) 'JPEG import did not create a named image solution.'
    $imageDetail=Invoke-RestMethod "$base/api/solutions/$($imageSolution.id)"
    Assert-Preview ($imageDetail.sourceKind -ceq 'localImage' -and $imageDetail.items.Count -eq 1 -and $imageDetail.items[0].type -ceq 'image') 'Image preview details were treated as a video or reference.'
    Assert-Preview (-not (($imageDetail|ConvertTo-Json -Depth 8).Contains($testRoot))) 'Image preview exposed a filesystem path.'
    $imageUrl=$base+$imageDetail.items[0].url
    $response=Send-PreviewRequest $imageUrl '' 'HEAD'
    try {Assert-Preview ($response.StatusCode -eq 200 -and $response.ContentType -eq 'image/jpeg' -and $response.ContentLength -eq $jpegBytes.Length) 'Image HEAD has incorrect type or length.'} finally {$response.Dispose()}
    $response=Send-PreviewRequest $imageUrl
    try {
        $imageBuffer=[IO.MemoryStream]::new()
        $response.GetResponseStream().CopyTo($imageBuffer)
        Assert-Preview ([Convert]::ToBase64String($imageBuffer.ToArray()) -ceq [Convert]::ToBase64String($jpegBytes)) 'Image preview returned different content.'
    } finally {$response.Dispose();$imageBuffer.Dispose()}
    $duplicate=Invoke-RestMethod "$base/api/media?name=Lobby.JPG" -Method Post -Headers $headers -ContentType 'application/octet-stream' -InFile $jpegPath
    Assert-Preview ($duplicate.solution.id -ceq $imageSolution.id) 'Duplicate JPG import did not reuse its solution.'
    $unauthorized=$null
    try {Invoke-RestMethod "$base/api/media?name=Denied.jpg" -Method Post -ContentType 'image/jpeg' -InFile $jpegPath|Out-Null} catch {$unauthorized=$_.Exception.Response.StatusCode}
    Assert-Preview ([int]$unauthorized -eq 403) 'Image import bypassed request authentication.'
    $corruptStatus=$null
    try {Invoke-RestMethod "$base/api/media?name=Broken.jpg" -Method Post -Headers $headers -ContentType 'image/jpeg' -Body 'not a JPEG'|Out-Null} catch {$corruptStatus=$_.Exception.Response.StatusCode}
    Assert-Preview ([int]$corruptStatus -eq 422) 'Invalid JPEG bytes were accepted.'
    Assert-Preview (@((Invoke-RestMethod "$base/api/catalog").solutions|Where-Object {$_.source.kind -ceq 'localImage'}).Count -eq 1) 'Invalid/duplicate import left extra image solutions.'
    $native = Invoke-RestMethod "$base/api/solutions/viplex-$uuid"
    $import = Invoke-RestMethod "$base/api/solutions/video-$id-$alias"
    Assert-Preview ($native.items.Count -eq 2 -and $native.items[1].type -ceq 'image' -and -not $native.items[1].url) ("Nested or unavailable widget mismatch. Details: " + ($native | ConvertTo-Json -Depth 6 -Compress))
    Assert-Preview ($native.items[0].scene -ceq 'Welcome' -and $native.items[0].durationMs -eq 4321 -and -not $native.durationMs) 'Native details mismatch.'
    Assert-Preview ($import.sourceKind -ceq 'localVideo' -and $import.items[0].codec -ceq 'h264' -and $import.durationMs -eq 4321) 'Local solution details mismatch.'
    Assert-Preview (-not (($native | ConvertTo-Json -Depth 6).Contains($testRoot))) 'Preview detail exposed a filesystem path.'
    $url = $base + $native.items[0].url
    $response = Send-PreviewRequest $url '' 'HEAD'
    try { Assert-Preview ($response.StatusCode -eq 200 -and $response.ContentLength -eq 32MB -and $response.Headers['Accept-Ranges'] -eq 'bytes') 'HEAD failed.' }
    finally { $response.Dispose() }
    $pending = Send-PreviewRequest $url
    Assert-Preview ((Invoke-RestMethod -TimeoutSec 5 "$base/api/solutions/video-$id-$alias").name -ceq 'Imported') 'A paused transfer blocked another request.'
    foreach ($path in $url,($base+$import.items[0].url)) {
        $response = Send-PreviewRequest $path '-3'
        try {
            $buffer = [IO.MemoryStream]::new()
            $response.GetResponseStream().CopyTo($buffer)
            Assert-Preview ($response.StatusCode -eq 206 -and $response.ContentType -eq 'video/mp4' -and
                $response.Headers['Content-Range'] -ceq 'bytes 33554429-33554431/33554432' -and
                [BitConverter]::ToString($buffer.ToArray()) -ceq '0C-22-38') 'Suffix seek returned the wrong bytes.'
        } finally { $response.Dispose(); $buffer.Dispose() }
    }
    $pending.Dispose()
    $pending = $null
    foreach ($range in '0-0','1-','33554432-') {
        $response = Send-PreviewRequest $url $range 'HEAD'
        try {
            $expected = if ($range -eq '33554432-') { 416 } else { 206 }
            Assert-Preview ([int]$response.StatusCode -eq $expected) 'Invalid range status.'
        } finally { $response.Dispose() }
    }
    foreach ($path in ($url -replace '/0$','/1'), ($url -replace '/0$','/100000000000000000000')) {
        $response = Send-PreviewRequest $path
        try { Assert-Preview ($response.StatusCode -eq 404) 'Unknown item URL was accepted.' } finally { $response.Dispose() }
    }
    'JPEG HTTP import/authentication, image/video preview details, byte range, HEAD, abort, and concurrency checks passed.'
} finally {
    if ($pending) { $pending.Dispose() }
    if ($server) {
        if (-not $server.HasExited) { $server.Kill(); $server.WaitForExit() }
        $server.Dispose()
    }
    $tempDir = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $actual = [IO.Path]::GetFullPath($testRoot)
    if ([IO.Path]::GetDirectoryName($actual) -eq $tempDir -and [IO.Path]::GetFileName($actual) -cmatch '^relay-preview-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $actual -Recurse -Force
    }
}

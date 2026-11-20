[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ZipPath)

$ErrorActionPreference='Stop'
$fixtureParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureLeaf='RelayReleaseTest-'+[guid]::NewGuid().ToString('N')
$fixtureRoot=[IO.Directory]::CreateDirectory((Join-Path $fixtureParent $fixtureLeaf)).FullName
$server=$null
function Assert-Release($Condition,[string]$Message){if(-not $Condition){throw $Message}}
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Path]::GetFullPath($ZipPath)
    $expectedHash=([IO.File]::ReadAllText($zip+'.sha256').Trim() -split '\s+')[0]
    Assert-Release ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expectedHash) 'The ZIP checksum did not match.'
    $extracted=[IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'extracted')).FullName
    [IO.Compression.ZipFile]::ExtractToDirectory($zip,$extracted)
    $roots=@(Get-ChildItem -LiteralPath $extracted -Directory)
    Assert-Release ($roots.Count -eq 1) 'The ZIP must contain one application folder.'
    $app=$roots[0].FullName
    $manifestPath=Join-Path $app 'release-manifest.json'
    $manifestText=[IO.File]::ReadAllText($manifestPath)
    $manifest=$manifestText | ConvertFrom-Json
    $expected=@('release-manifest.json')+@($manifest.files | ForEach-Object path)
    $actual=@(Get-ChildItem -LiteralPath $app -File -Recurse | ForEach-Object {$_.FullName.Substring($app.Length+1).Replace('\','/')})
    Assert-Release ($actual.Count -eq $expected.Count -and -not @(Compare-Object $actual $expected).Count) 'The ZIP contains unexpected files.'
    foreach($entry in $manifest.files){
        Assert-Release ((Get-FileHash -LiteralPath (Join-Path $app $entry.path) -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $entry.sha256) ('File checksum failed: '+$entry.path)
        Assert-Release ($entry.path -notmatch '(?i)(workspace|player-settings|players)\.json|DB\.SQLite|\.test\.|\.(exe|dll|mp4|mov|mkv|zip)$') 'The release includes user data, development tests, or bundled executable dependencies.'
        Assert-Release ($entry.path -notmatch '(?i)\.(png|gif|webp|bmp|tiff?|mp3|wav|m4v|jpe?g)$' -or $entry.path -ceq 'ScheduleThumb.png') 'The release includes an unreviewed media asset.'
    }
    # Install into an isolated directory without shortcuts or starting another app.
    $installRoot=Join-Path $fixtureRoot 'programs'
    $null=& (Join-Path $app 'Install-Studio.ps1') -InstallRoot $installRoot -NoShortcuts -NoLaunch
    $installed=Join-Path $installRoot $manifest.version
    Assert-Release ([IO.File]::Exists((Join-Path $installed 'Launch Studio.cmd'))) 'The per-user installer missed its launcher.'
    $null=& (Join-Path $app 'Install-Studio.ps1') -InstallRoot $installRoot -NoShortcuts -NoLaunch
    # Corrupt and traversing packages must fail before copying anything.
    $appScript=Join-Path $app 'app.js';$original=[IO.File]::ReadAllText($appScript)
    [IO.File]::AppendAllText($appScript,"`n// altered fixture")
    $refused=$false
    try {$null=& (Join-Path $app 'Install-Studio.ps1') -InstallRoot (Join-Path $fixtureRoot 'corrupt') -NoShortcuts -NoLaunch}catch{$refused=$true}
    Assert-Release $refused 'The installer accepted a changed package.'
    Assert-Release (-not [IO.Directory]::Exists((Join-Path $fixtureRoot 'corrupt'))) 'The installer wrote files before validation.'
    [IO.File]::WriteAllText($appScript,$original,[Text.UTF8Encoding]::new($false))
    $manifest.files[0].path='../escape.txt'
    [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $refused=$false
    try {$null=& (Join-Path $app 'Install-Studio.ps1') -InstallRoot (Join-Path $fixtureRoot 'traversal') -NoShortcuts -NoLaunch}catch{$refused=$true}
    Assert-Release $refused 'The installer accepted a traversing file path.'
    [IO.File]::WriteAllText($manifestPath,$manifestText,[Text.UTF8Encoding]::new($false))

    # Start the extracted production service against empty data and an empty
    # ViPlex configuration. Existing user libraries and players are not read.
    $portProbe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $portProbe.Start();$port=$portProbe.LocalEndpoint.Port;$portProbe.Stop()
    $origin="http://127.0.0.1:$port"
    $workspace=Join-Path $fixtureRoot 'workspace'
    [void][IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'ViPlexExpress/Config'))
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName='powershell.exe';$info.WorkingDirectory=$installed
    $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $installed 'Start-Studio.ps1')+'" -NoBrowser -Port '+$port+' -WorkspaceDirectory "'+$workspace+'" -ExportRoot "'+(Join-Path $fixtureRoot 'exports')+'"'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.EnvironmentVariables['ProgramData']=$fixtureRoot
    $server=[Diagnostics.Process]::Start($info)
    $session=$null
    for($attempt=0;$attempt -lt 100;$attempt++){
        try{$session=Invoke-RestMethod ($origin+'/api/session');break}catch{if($server.HasExited){throw 'The packaged service stopped during startup.'};Start-Sleep -Milliseconds 100}
    }
    Assert-Release ([bool]$session.exportToken) 'The packaged service did not start.'
    Assert-Release ([bool]$session.runtimeBuild) 'The packaged service omitted its runtime build.'
    $index=(Invoke-WebRequest ($origin+'/') -UseBasicParsing).Content
    foreach($asset in @([regex]::Matches($index,'(?:src|href)="([^"#]+\.(?:js|css|svg))"') | ForEach-Object {$_.Groups[1].Value} | Select-Object -Unique)){
        Assert-Release ((Invoke-WebRequest ($origin+'/'+$asset) -UseBasicParsing).StatusCode -eq 200) ('Missing packaged UI asset: '+$asset)
    }
    $catalog=Invoke-RestMethod ($origin+'/api/catalog')
    Assert-Release (@($catalog.solutions).Count -eq 0 -and @($catalog.schedules).Count -eq 0) 'A fresh package unexpectedly loaded personal library data.'
    $players=Invoke-RestMethod ($origin+'/api/network/players')
    Assert-Release (@($players.players).Count -eq 0) 'A fresh package unexpectedly loaded personal players.'
    $settings=Invoke-RestMethod ($origin+'/api/settings')
    Assert-Release (-not $settings.hasDefaultPlayerPassword) 'A fresh package unexpectedly loaded a saved password.'
    $headers=@{Origin=$origin;'X-Studio-Token'=$session.exportToken}
    $project=@{version=1;title='Package smoke test';screens=@(@{id='demo';name='Demo';width=320;height=1080});solutions=@();cues=@()}
    $saved=Invoke-RestMethod ($origin+'/api/project') -Method Post -Headers $headers -ContentType 'application/json' -Body (@{baseRevision=$null;project=$project}|ConvertTo-Json -Depth 8)
    Assert-Release ([bool]$saved.revision) 'The packaged service could not save a new workspace.'
    $loaded=Invoke-RestMethod ($origin+'/api/project')
    Assert-Release ($loaded.project.title -eq 'Package smoke test') 'The packaged service could not reopen its saved workspace.'
    Add-Type -AssemblyName System.Drawing
    $imageFile=Join-Path $fixtureRoot 'Welcome.jpg'
    $picture=[Drawing.Bitmap]::new(32,108)
    try{$picture.Save($imageFile,[Drawing.Imaging.ImageFormat]::Jpeg)}finally{$picture.Dispose()}
    $imported=Invoke-RestMethod ($origin+'/api/media?name=Welcome.jpg') -Method Post -Headers $headers -ContentType 'application/octet-stream' -InFile $imageFile
    Assert-Release ($imported.solution.name -eq 'Welcome' -and $imported.solution.source.kind -eq 'localImage') 'Packaged JPEG import failed.'
    Assert-Release ((Invoke-WebRequest ($origin+$imported.solution.thumbnail) -UseBasicParsing).StatusCode -eq 200) 'Packaged image preview failed.'
    $sourceExposed=$false
    try{$sourceExposed=(Invoke-WebRequest ($origin+'/StudioSettings.ps1') -UseBasicParsing).StatusCode -eq 200}catch{}
    Assert-Release (-not $sourceExposed) 'Server source files must not be public HTTP routes.'
    'Windows ZIP checks, isolated per-user install, corruption/path refusal, clean-data launch, all UI assets, project save and JPEG import/preview passed.'
} finally {
    if($server -and -not $server.HasExited){$server.Kill();$server.WaitForExit()}
    if($server){$server.Dispose()}
    $expectedRoot=[IO.Path]::GetFullPath((Join-Path $fixtureParent $fixtureLeaf))
    if($fixtureRoot -ceq $expectedRoot -and [IO.Path]::GetDirectoryName($fixtureRoot) -ceq $fixtureParent){
        $linked=@(Get-Item -LiteralPath $fixtureRoot;Get-ChildItem -LiteralPath $fixtureRoot -Recurse -Force)|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}
        if(-not $linked){[IO.Directory]::Delete($fixtureRoot,$true)}
    }
}

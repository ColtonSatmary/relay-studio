[CmdletBinding()]
param([string]$Version,[string]$OutputDirectory,[switch]$Force)

$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$release=[IO.File]::ReadAllText((Join-Path $root 'packaging/release.json')) | ConvertFrom-Json
if(-not $Version){$Version=$release.version}
if($Version -cnotmatch '^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$'){throw 'Use a semantic release version such as 0.1.0-preview.1.'}
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root 'dist'}
$outputRoot=[IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory)).FullName.TrimEnd('\')
if((Get-Item -LiteralPath $outputRoot).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The release output folder cannot be a linked directory.'}
$packageName="Relay-Studio-$Version-windows-x64"
$zipPath=Join-Path $outputRoot ($packageName+'.zip')
$checksumPath=$zipPath+'.sha256'
if(([IO.File]::Exists($zipPath) -or [IO.File]::Exists($checksumPath)) -and -not $Force){throw 'This release already exists. Choose a new version, or use -Force to rebuild this generated release.'}
$allow=[IO.File]::ReadAllText((Join-Path $root 'packaging/windows-files.json')) | ConvertFrom-Json
# License/notice files are optional until a distribution policy is selected.
foreach($optional in 'LICENSE','LICENSE.md','NOTICE','NOTICE.md'){
    if([IO.File]::Exists((Join-Path $root $optional))){$allow+=$optional}
}
$inputs=@(foreach($relative in $allow){[pscustomobject]@{source=[string]$relative;target=[string]$relative}})
$inputs+=[pscustomobject]@{source='packaging/START-HERE.txt';target='START HERE.txt'}
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($releaseInput in $inputs){
    foreach($name in @($releaseInput.source,$releaseInput.target)){
        if(-not $name -or [IO.Path]::IsPathRooted($name) -or $name -match '[:\\]' -or @($name.Split('/')|Where-Object {$_ -in '','.','..'}).Count){throw 'The release allowlist contains an unsafe path.'}
    }
    if(-not $seen.Add($releaseInput.target)){throw 'The release allowlist repeats a destination.'}
    $source=Get-Item -LiteralPath (Join-Path $root $releaseInput.source) -ErrorAction Stop
    if($source.PSIsContainer -or ($source.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Release inputs must be ordinary files.'}
    if($source.Name -match '^(?:workspace|players|player-settings)\.json(?:\.bak)?$|^DB\.SQLite|\.test\.' -or
       $source.Extension -in '.exe','.dll','.mp4','.mov','.mkv','.jpg','.jpeg','.sqlite','.zip' -or
       ($source.Extension -in '.png','.gif','.webp','.bmp','.tif','.tiff','.mp3','.wav','.m4v' -and $releaseInput.source -cne 'ScheduleThumb.png')){
        throw "A runtime-data or binary file was included in the release allowlist: $($releaseInput.source)"
    }
}
$staging=Join-Path $outputRoot ('.release-'+[guid]::NewGuid().ToString('N'))
$packageRoot=[IO.Directory]::CreateDirectory((Join-Path $staging $packageName)).FullName
$tempZip=Join-Path $outputRoot ('.release-'+[guid]::NewGuid().ToString('N')+'.zip')
try {
    $manifestFiles=@(foreach($releaseInput in $inputs){
        $source=Join-Path $root $releaseInput.source
        $target=Join-Path $packageRoot $releaseInput.target
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy($source,$target,$false)
        [pscustomobject]@{path=$releaseInput.target;bytes=([IO.FileInfo]::new($target)).Length;sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    foreach($releaseInput in $inputs){
        $snapshot=$manifestFiles | Where-Object path -CEQ $releaseInput.target | Select-Object -First 1
        if((Get-FileHash -LiteralPath (Join-Path $root $releaseInput.source) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $snapshot.sha256){throw "Source changed while packaging: $($releaseInput.source). Rebuild once edits finish."}
    }
    $manifest=[ordered]@{schemaVersion=1;product='Relay Studio';version=$Version;platform='windows-x64';channel=$release.channel;createdUtc=[datetime]::UtcNow.ToString('o');files=$manifestFiles}
    [IO.File]::WriteAllText((Join-Path $packageRoot 'release-manifest.json'),($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($staging,$tempZip,[IO.Compression.CompressionLevel]::Optimal,$false)
    $hash=(Get-FileHash -LiteralPath $tempZip -Algorithm SHA256).Hash.ToLowerInvariant()
    Move-Item -LiteralPath $tempZip -Destination $zipPath -Force:$Force
    [IO.File]::WriteAllText($checksumPath,($hash+'  '+[IO.Path]::GetFileName($zipPath)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{version=$Version;package=$zipPath;sha256=$hash;checksumFile=$checksumPath;files=$manifestFiles.Count;bytes=([IO.FileInfo]::new($zipPath)).Length}
} finally {
    if([IO.File]::Exists($tempZip) -and [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($tempZip)) -ceq $outputRoot){[IO.File]::Delete($tempZip)}
    if([IO.Directory]::Exists($staging) -and [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($staging)) -ceq $outputRoot -and
        [IO.Path]::GetFileName($staging) -cmatch '^\.release-[a-f0-9]{32}$'){
        $linked=@(Get-Item -LiteralPath $staging;Get-ChildItem -LiteralPath $staging -Recurse -Force)|Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
        if(-not $linked){[IO.Directory]::Delete($staging,$true)}
    }
}

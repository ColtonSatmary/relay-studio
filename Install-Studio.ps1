[CmdletBinding()]
param([string]$InstallRoot, [switch]$NoShortcuts, [switch]$NoLaunch)

$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT'){throw 'This installer is for Windows. Use the macOS package on a Mac.'}
if(-not $InstallRoot){$InstallRoot=Join-Path $env:LOCALAPPDATA 'Programs\Relay Studio'}
$installParent=[IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$sourceRoot=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$manifestPath=Join-Path $sourceRoot 'release-manifest.json'
if(-not [IO.File]::Exists($manifestPath)){throw 'Extract the complete Relay release ZIP before running its installer.'}
$manifest=[IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
if($manifest.product -cne 'Relay Studio' -or $manifest.platform -cne 'windows-x64' -or
    $manifest.version -cnotmatch '^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$' -or
    $manifest.files -isnot [array] -or $manifest.files.Count -lt 1){throw 'The release manifest is invalid.'}
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$files=@(foreach($entry in $manifest.files){
    $name=[string]$entry.path
    if(-not $name -or [IO.Path]::IsPathRooted($name) -or $name -match '[:\\]' -or
       @($name.Split('/') | Where-Object {$_ -in '','.','..'}).Count -or
       $entry.sha256 -cnotmatch '^[a-f0-9]{64}$' -or -not $seen.Add($name)) {throw 'The package contains an invalid or repeated file path.'}
    $path=[IO.Path]::GetFullPath((Join-Path $sourceRoot $name))
    if(-not $path.StartsWith($sourceRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'A package path is outside its folder.'}
    $file=Get-Item -LiteralPath $path -ErrorAction Stop
    if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
       (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256){throw "The package file '$name' is missing or changed. Extract a fresh release ZIP."}
    [pscustomobject]@{name=$name;path=$path;sha256=$entry.sha256}
})
foreach($required in 'Start-Studio.ps1','Launch Studio.cmd','index.html'){
    if(-not $seen.Contains($required)){throw "The release is missing $required."}
}
[void][IO.Directory]::CreateDirectory($installParent)
if((Get-Item -LiteralPath $installParent).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Choose an installation folder that is not a linked directory.'}
$destination=[IO.Path]::GetFullPath((Join-Path $installParent $manifest.version))
if([IO.Path]::GetDirectoryName($destination) -cne $installParent){throw 'The installation path is invalid.'}
if([IO.Directory]::Exists($destination)){
    if((Get-Item -LiteralPath $destination).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The existing installation is a linked directory.'}
    foreach($file in $files){
        $installed=Join-Path $destination $file.name
        if(-not [IO.File]::Exists($installed) -or (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256){
            throw "Version $($manifest.version) is already installed with different files. Use a new release version or keep a backup before removing that application folder."
        }
    }
} else {
    $staging=Join-Path $installParent ('.install-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($staging)
    try {
        foreach($file in $files){
            $target=Join-Path $staging $file.name
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            [IO.File]::Copy($file.path,$target,$false)
        }
        [IO.File]::Copy($manifestPath,(Join-Path $staging 'release-manifest.json'),$false)
        # Both resolved paths are direct children of this explicit install root.
        if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($staging)) -cne $installParent -or
            [IO.Path]::GetDirectoryName($destination) -cne $installParent){throw 'The installation destination changed.'}
        [IO.Directory]::Move($staging,$destination)
    } finally {
        if([IO.Directory]::Exists($staging) -and [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($staging)) -ceq $installParent -and
           [IO.Path]::GetFileName($staging) -cmatch '^\.install-[a-f0-9]{32}$'){
            $linked=@(Get-Item -LiteralPath $staging; Get-ChildItem -LiteralPath $staging -Recurse -Force) | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
            if(-not $linked){[IO.Directory]::Delete($staging,$true)}
        }
    }
}

if(-not $NoShortcuts){
    $shell=New-Object -ComObject WScript.Shell
    try {
        foreach($folder in @([Environment]::GetFolderPath('DesktopDirectory'),[Environment]::GetFolderPath('Programs'))){
            $shortcut=$shell.CreateShortcut((Join-Path $folder 'Relay Studio.lnk'))
            $shortcut.TargetPath=Join-Path $destination 'Launch Studio.cmd'
            $shortcut.WorkingDirectory=$destination
            $shortcut.Description='Relay Studio schedules and LED player controls'
            $shortcut.IconLocation=(Join-Path $env:SystemRoot 'System32\shell32.dll')+',15'
            $shortcut.WindowStyle=7
            $shortcut.Save()
        }
    } finally { if($shell){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)} }
}
Write-Output "Relay Studio $($manifest.version) is installed in $destination"
Write-Output 'Your workspace and media stay in the separate Relay Studio data folder.'
if(-not $NoLaunch){Start-Process -FilePath (Join-Path $destination 'Launch Studio.cmd') -WorkingDirectory $destination -WindowStyle Hidden}

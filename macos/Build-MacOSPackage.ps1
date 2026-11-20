[CmdletBinding()]
param([ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$')][string]$Version='0.1.0-preview.1',[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root 'dist'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$name='Relay-Studio-'+$Version+'-macos'
$archive=Join-Path $OutputDirectory ($name+'.zip')
if([IO.File]::Exists($archive)){throw "The release already exists: $archive"}
# Explicit runtime allowlist; no media, player directory, saved credentials,
# export packages, workspaces, developer tools, or installed ViPlex files.
$windows=[IO.File]::ReadAllText((Join-Path $root 'packaging/windows-files.json')) | ConvertFrom-Json
$files=@($windows | Where-Object {$_ -cnotin @('Install Studio.cmd','Install-Studio.ps1','Launch Studio.cmd','WINDOWS-INSTALL.md')})
$files+=@('LICENSE','ScheduleThumb.png','macos/Launch Relay Studio.command','macos/README.md','macos/StudioJsonCompat.cs','macos/StudioMacKeychain.cs','macos/StudioMacPlatform.ps1','macos/StudioMacUsb.ps1','macos/StudioMacUsbFiles.cs')
$files=@($files | Sort-Object -Unique)
$manifest=[ordered]@{name='Relay Studio';version=$Version;platform='macOS';packageType='PowerShell source preview';createdUtc=[DateTime]::UtcNow.ToString('o');files=@()}
Add-Type -AssemblyName System.IO.Compression
$stream=[IO.File]::Open($archive,[IO.FileMode]::CreateNew)
try{
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try{
        foreach($relative in $files){
            if($relative -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($relative)){throw 'The release allowlist contains an unsafe path.'}
            $path=Join-Path $root $relative
            if(-not [IO.File]::Exists($path)){throw "Required release source missing: $relative"}
            $before=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            $entry=$zip.CreateEntry($name+'/'+$relative.Replace('\','/'),[IO.Compression.CompressionLevel]::Optimal)
            # Unix executable bit survives Archive Utility extraction. Text
            # files use normal 0644; the launcher uses 0755.
            $mode=if($relative.EndsWith('.command')){33261}else{33188}
            $entry.ExternalAttributes=[int]([long]$mode*65536-4294967296)
            $sourceStream=[IO.File]::OpenRead($path);$entryStream=$entry.Open()
            try{$sourceStream.CopyTo($entryStream)}finally{$sourceStream.Dispose();$entryStream.Dispose()}
            $after=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            if($before -cne $after){throw "A release source changed while packaging: $relative"}
            $manifest.files+=@{path=$relative.Replace('\','/');sha256=$after}
        }
        $metadata=$zip.CreateEntry($name+'/release-manifest.json',[IO.Compression.CompressionLevel]::Optimal)
        $metadata.ExternalAttributes=-2119958528
        $metadataStream=$metadata.Open();$metadataWriter=[IO.StreamWriter]::new($metadataStream,[Text.UTF8Encoding]::new($false))
        try{$metadataWriter.Write(($manifest|ConvertTo-Json -Depth 8))}finally{$metadataWriter.Dispose()}
    }finally{$zip.Dispose()}
}finally{$stream.Dispose()}
$sha=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($archive+'.sha256',$sha+'  '+[IO.Path]::GetFileName($archive)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
[pscustomobject]@{path=$archive;sha256=$sha;files=$files.Count;platform='macOS source preview; Apple Silicon and Intel; requires PowerShell 7.5+ (.NET 9+) and FFmpeg'}

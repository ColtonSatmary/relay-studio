# Staging-only integration checks. Never contacts a player or writes ViPlex data.
param([string]$ConfigRoot = (Join-Path $env:ProgramData 'ViPlexExpress\Config'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StudioCatalog.ps1')
. (Join-Path $PSScriptRoot 'Viplex.ps1')
. (Join-Path $PSScriptRoot 'ViplexUsb.ps1')
. (Join-Path $PSScriptRoot 'StudioNetworkCatalog.ps1')
function Assert-NetworkStage([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }

# The fixture deliberately includes extra secret properties to verify whitelisting.
& {
    function Read-StudioRows($Database, $Query) {
        Assert-NetworkStage ($Query -notmatch '(?i)passwd|password|token|\bkey\b|SELECT\s+\*') 'Inventory queried credentials.'
        @(
            [pscustomobject]@{Sn='fixture-1';Alias='Test one';Ip='192.168.41.1';Width=320;Height=1080;ProductName='T50';Passwd='never-return-fixture';Key='never-return-fixture'},
            [pscustomobject]@{Sn='fixture-2';Alias='Test two';Ip='192.168.41.1';Width=320;Height=1080;ProductName='T50'},
            [pscustomobject]@{Sn='fixture-1';Alias='Old duplicate';Ip='192.168.1.5';Width=320;Height=1080;ProductName='T50'},
            [pscustomobject]@{Sn=$null;Alias='Invalid';Ip='192.168.41.1';Width=0;Height=0;ProductName='T50'}
        )
    }
    $known = @(Get-StudioNetworkKnownPlayers $ConfigRoot)
    Assert-NetworkStage ($known.Count -eq 2 -and $known[0].name -ceq 'Test one') 'Serial deduplication failed.'
    Assert-NetworkStage ($known[0].ip -eq $known[1].ip -and $known[0].sn -ne $known[1].sn) 'Repeated AP addresses lost player identity.'
    Assert-NetworkStage (($known | ConvertTo-Json -Depth 4) -notmatch 'never-return|Passwd|"Key"') 'Inventory leaked a credential property.'
}

$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$leaf = 'RelayNetworkStageTest-' + [guid]::NewGuid().ToString('N')
$stageRoot = [IO.Directory]::CreateDirectory((Join-Path $tempParent $leaf)).FullName
try {
    $catalog = (Get-StudioCatalog $ConfigRoot).data
    $solution = $catalog.solutions | Where-Object { $_.source.playlistUuid } | Select-Object -First 1
    Assert-NetworkStage ($null -ne $solution) 'This staging check requires one readable ViPlex library solution.'
    $screen = [pscustomobject]@{id='network-fixture-screen';name='Relay Network Fixture';width=$solution.width;height=$solution.height}
    $project = [pscustomobject]@{solutions=@($solution);screens=@($screen);cues=@([pscustomobject]@{
        screenId=$screen.id;solutionId=$solution.id;startDate='2026-11-17';endDate='2026-11-17';start='09:00';end='09:15';days=@(2)
    })}
    foreach ($type in @('solution','schedule')) {
        $folder = [IO.Directory]::CreateDirectory((Join-Path $stageRoot $type)).FullName
        $id = if ($type -eq 'solution') { $solution.id } else { $screen.id }
        $package = Export-StudioNetworkProgram -ConfigRoot $ConfigRoot -Project $project -ProgramType $type -ProgramId $id -OutputDirectory $folder
        Assert-NetworkStage (-not [IO.File]::Exists((Join-Path $folder 'nova\command.json'))) 'Network staging wrote a USB command.'
        Assert-NetworkStage ($package.width -eq $solution.width -and $package.height -eq $solution.height) 'Canvas dimensions changed.'
        Assert-NetworkStage ($package.mediaCount -ge 1 -and $package.totalMediaSize -gt 0 -and $package.totalSize -gt 0) 'Missing network size metadata.'
        Assert-NetworkStage ($package.programFiles.Count -eq @($package.programFiles.fileName | Select-Object -Unique).Count) 'Network destination filenames are not unique.'
        $plan = Get-Content -LiteralPath (Join-Path $package.programDirectory 'planlist.json') -Raw | ConvertFrom-Json
        foreach ($resource in $plan.resources) {
            $match = @($package.mediaFiles | Where-Object fileName -CEQ $resource.fileName)
            Assert-NetworkStage ($match.Count -eq 1 -and $match[0].md5 -eq $resource.md5 -and $match[0].size -eq $resource.size) 'Media metadata disagrees with native manifest.'
        }
        foreach ($listFile in $plan.playlists) {
            $list = Get-Content -LiteralPath (Join-Path $package.programDirectory $listFile.fileName) -Raw | ConvertFrom-Json
            foreach ($scene in $list.sceneItems) {
                if ($scene.thumbnail) { Assert-NetworkStage (@($package.programFiles | Where-Object fileName -CEQ $scene.thumbnail).Count -eq 1) 'A playlist page thumbnail will not be uploaded.' }
            }
        }
        $failed = $false
        try { $null = Export-StudioNetworkProgram -ConfigRoot $ConfigRoot -Project $project -ProgramType $type -ProgramId $id -OutputDirectory $folder } catch { $failed = $true }
        Assert-NetworkStage $failed 'Reusing a nonempty staging folder should be refused.'
    }
    'Network inventory and solution/schedule staging checks passed. No player was contacted.'
} finally {
    $expected = [IO.Path]::GetFullPath((Join-Path $tempParent $leaf))
    if ($stageRoot -ceq $expected -and [IO.Path]::GetDirectoryName($stageRoot) -eq $tempParent.TrimEnd('\') -and
        $leaf -match '^RelayNetworkStageTest-[a-f0-9]{32}$' -and
        -not @(Get-ChildItem -LiteralPath $stageRoot -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
        [IO.Directory]::Delete($stageRoot, $true)
    }
}

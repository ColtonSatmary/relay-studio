# Isolated JPG integration checks. Stages packages only; never contacts players.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StudioProject.ps1')
. (Join-Path $PSScriptRoot 'StudioCatalog.ps1')
. (Join-Path $PSScriptRoot 'StudioMedia.ps1')
. (Join-Path $PSScriptRoot 'Viplex.ps1')
. (Join-Path $PSScriptRoot 'ViplexUsb.ps1')
. (Join-Path $PSScriptRoot 'StudioNetworkCatalog.ps1')
function Assert-ImageExport([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }

$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$leaf = 'RelayImageExportTest-' + [guid]::NewGuid().ToString('N')
$stageRoot = [IO.Directory]::CreateDirectory((Join-Path $tempParent $leaf)).FullName
$mediaRoot = Join-Path $stageRoot 'library'
$configRoot = [IO.Directory]::CreateDirectory((Join-Path $stageRoot 'config')).FullName
try {
    Add-Type -AssemblyName System.Drawing
    $inputPath = Join-Path $stageRoot 'Lobby.JPG'
    $bitmap = [Drawing.Bitmap]::new(320,180)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.Color]::Navy)
        $graphics.FillRectangle([Drawing.Brushes]::Orange,20,20,100,80)
        $bitmap.Save($inputPath,[Drawing.Imaging.ImageFormat]::Jpeg)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    $inputHash = (Get-FileHash -LiteralPath $inputPath -Algorithm MD5).Hash.ToLowerInvariant()
    $stream = [IO.File]::OpenRead($inputPath)
    try { $solution = Import-StudioMedia $stream 'Lobby.JPG' } finally { $stream.Dispose() }
    Assert-ImageExport ($solution.source.kind -ceq 'localImage' -and $solution.width -eq 320 -and $solution.height -eq 180) 'Image import metadata is unavailable.'
    $asset = Get-StudioMediaAsset $solution.source.assetId
    Assert-ImageExport ($solution.source.md5 -ceq $inputHash) 'Ordinary JPEG bytes were changed during import.'
    $screen = [pscustomobject]@{id='image-fixture-screen';name='Image Schedule';width=1920;height=1080}
    $project = [pscustomobject]@{solutions=@($solution);screens=@($screen);cues=@([pscustomobject]@{
        screenId=$screen.id;solutionId=$solution.id;startDate='2026-11-17';endDate='2026-11-17';start='09:00';end='09:15';days=@(2)
    })}

    # Project snapshots are untrusted: only the stored asset supplies media,
    # duration and checksums. The selected screen supplies the target canvas.
    $tampered = $solution | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $tampered.source.md5 = '0' * 32
    $tampered.source.durationMs = 123456
    $bundle = Get-ViplexProgramBundle $configRoot $tampered $screen
    Assert-ImageExport ($bundle.resources[0].md5 -ceq $inputHash -and $bundle.playlist.sceneItems[0].page.widgetContainers[0].contents.widgets[0].duration -eq 10000) 'Project metadata overrode the trusted media store.'

    foreach ($mode in @('usb-solution','usb-schedule','network-solution','network-schedule','viplex-schedule')) {
        $folder = [IO.Directory]::CreateDirectory((Join-Path $stageRoot $mode)).FullName
        $type = if ($mode.EndsWith('solution')) { 'solution' } else { 'schedule' }
        $id = if ($type -eq 'solution') { $solution.id } else { $screen.id }
        if ($mode.StartsWith('usb-')) {
            $receipt = Export-ViplexUsbPlayback -ConfigRoot $configRoot -Project $project -ProgramType $type -ProgramId $id -PlayerPassword 'local-fixture-password' -OutputDirectory $folder
            Assert-ImageExport ($receipt.mediaCount -eq 1) "$mode did not stage the image."
            Assert-ImageExport ([IO.File]::Exists((Join-Path $folder 'nova\command.json'))) "$mode is missing its USB command."
        } elseif ($mode.StartsWith('network-')) {
            $receipt = Export-StudioNetworkProgram -ConfigRoot $configRoot -Project $project -ProgramType $type -ProgramId $id -OutputDirectory $folder
            Assert-ImageExport ($receipt.mediaCount -eq 1 -and $receipt.mediaFiles[0].md5 -ceq $inputHash) "$mode did not include the image in its upload manifest."
            Assert-ImageExport (-not [IO.File]::Exists((Join-Path $folder 'nova\command.json'))) 'Network staging wrote a USB command.'
        } else {
            $receipt = Export-ViplexSchedule -ConfigRoot $configRoot -Project $project -ScreenId $id -OutputDirectory $folder
        }
        $planFile = @(Get-ChildItem -LiteralPath (Join-Path $folder 'nova\program') -Recurse -Filter 'planlist.json')
        Assert-ImageExport ($planFile.Count -eq 1) "$mode has no unique native plan."
        $plan = Get-Content -LiteralPath $planFile[0].FullName -Raw | ConvertFrom-Json
        $program = $planFile[0].DirectoryName
        Assert-ImageExport ($plan.resources.Count -eq 1 -and $plan.resources[0].type -ceq 'PICTURE') "$mode is not a native PICTURE resource."
        $resource = $plan.resources[0]
        $imageCopy = Join-Path (Join-Path $folder 'nova\media') $resource.fileName
        Assert-ImageExport ($resource.fileName -ceq ($inputHash + '.jpg') -and $resource.md5 -ceq $inputHash) "$mode has an invalid image reference."
        Assert-ImageExport ((Get-FileHash -LiteralPath $imageCopy -Algorithm MD5).Hash -eq $inputHash -and [IO.FileInfo]::new($imageCopy).Length -eq $resource.size) "$mode changed the JPEG media bytes."
        $list = Get-Content -LiteralPath (Join-Path $program $plan.playlists[0].fileName) -Raw | ConvertFrom-Json
        $expectedWidth = if ($type -eq 'solution') { 320 } else { 1920 }
        $expectedHeight = if ($type -eq 'solution') { 180 } else { 1080 }
        Assert-ImageExport ($list.width -eq $expectedWidth -and $list.height -eq $expectedHeight) "$mode lost the image or schedule canvas dimensions."
        $scene = $list.sceneItems[0]
        $container = $scene.page.widgetContainers[0]
        $widget = $container.contents.widgets[0]
        Assert-ImageExport ($container.WCtype -ceq 'PICTURE' -and $widget.type -ceq 'PICTURE' -and $null -eq $widget.metadata) "$mode contains video metadata for its image."
        Assert-ImageExport ($widget.dataSource -ceq $resource.fileName -and $widget.filesize -eq $resource.size -and $widget.displayRatio -ceq 'FULL') "$mode does not reference the full-screen image correctly."
        Assert-ImageExport ($widget.duration -eq 10000 -and $widget.repeatCount -eq 1 -and $scene.rules -ceq 'TIMES') "$mode has an invalid still-image page duration."
        $constraints = Get-Content -LiteralPath (Join-Path $program $plan.scheduleConstraints[0].fileName) -Raw | ConvertFrom-Json
        if ($type -eq 'schedule') {
            $active = @($constraints.constraints | Where-Object startTime -Like '2026-11-17*')
            Assert-ImageExport ($active.Count -eq 1 -and $active[0].startTime -match 'T09:00:00Z' -and $active[0].endTime -match 'T09:14:59Z') "$mode does not retain the entire fifteen-minute image block."
        } else {
            Assert-ImageExport ($constraints.constraints.Count -eq 1 -and -not $constraints.constraints[0].isNotForever) "$mode does not keep the standalone image playing."
        }
    }

    # Corrupting a local fixture must be caught by the existing package checksum
    # verification before the package could be sent to a player.
    $bytes = [IO.File]::ReadAllBytes($asset.path)
    $bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 1
    [IO.File]::WriteAllBytes($asset.path,$bytes)
    $badFolder = [IO.Directory]::CreateDirectory((Join-Path $stageRoot 'corrupt')).FullName
    $failed = $false
    try { $null = Export-ViplexUsbSolution $configRoot $solution $badFolder } catch { $failed = $_.Exception.Message -match 'checksum' }
    Assert-ImageExport $failed 'A corrupted image bypassed native media checksum validation.'
    'Image USB, network and ViPlex schedule export checks passed. No player was contacted.'
} finally {
    $expected = [IO.Path]::GetFullPath((Join-Path $tempParent $leaf))
    if ($stageRoot -ceq $expected -and [IO.Path]::GetDirectoryName($stageRoot) -eq $tempParent.TrimEnd('\') -and
        $leaf -match '^RelayImageExportTest-[a-f0-9]{32}$' -and
        -not @(Get-ChildItem -LiteralPath $stageRoot -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
        [IO.Directory]::Delete($stageRoot,$true)
    }
}

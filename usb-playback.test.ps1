# Staging-only integration test. Uses native authoring data read-only and never opens a USB volume.
param([string]$ConfigRoot = (Join-Path $env:ProgramData 'ViPlexExpress\Config'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StudioCatalog.ps1')
. (Join-Path $PSScriptRoot 'Viplex.ps1')
. (Join-Path $PSScriptRoot 'ViplexUsb.ps1')

function Assert-Playback([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Test-PlaybackFiles($Directory, $Name, $Password, [bool]$Copy, [bool]$Replace) {
    $nova = Join-Path $Directory 'nova'
    $bytes = [Convert]::FromBase64String([IO.File]::ReadAllText((Join-Path $nova 'command.json')))
    $command = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    Assert-Playback ($command.authenticUserInfos.Count -eq 1) 'Expected exactly one player login.'
    $login = $command.authenticUserInfos[0]
    Assert-Playback ($login.username -ceq 'admin' -and $login.password -ceq $Password) 'Player login mismatch.'
    Assert-Playback ($command.programInfos.Count -eq 1) 'Expected exactly one playback target.'
    $info = $command.programInfos[0]
    Assert-Playback ($info.name -ceq $Name -and $info.url -ceq $Name -and $info.isPlay) 'Wrong autoplay target.'
    Assert-Playback ($info.isImport -eq $Copy -and $info.isOverride -eq $Replace) 'Play mode or duplicate policy mismatch.'
    $program = Join-Path (Join-Path $nova 'program') $info.url
    Assert-Playback ([IO.File]::Exists((Join-Path $program $info.thumbnailName))) 'Missing program cover.'
    $planPath = Join-Path $program 'planlist.json'
    Assert-Playback ((Get-FileHash -LiteralPath $planPath -Algorithm MD5).Hash -eq $info.identifier) 'Program identifier mismatch.'
    $plan = [IO.File]::ReadAllText($planPath) | ConvertFrom-Json
    foreach ($entry in (@($plan.playRelations) + @($plan.playSolutions) + @($plan.playlists) + @($plan.scheduleConstraints) + @($plan.thumbnails))) {
        Assert-Playback ((Get-FileHash -LiteralPath (Join-Path $program $entry.fileName) -Algorithm MD5).Hash -eq $entry.md5) 'Program manifest checksum mismatch.'
    }
    foreach ($entry in $plan.resources) {
        $media = Join-Path (Join-Path $nova 'media') $entry.fileName
        Assert-Playback ((Get-FileHash -LiteralPath $media -Algorithm MD5).Hash -eq $entry.md5) 'Media checksum mismatch.'
        Assert-Playback ([IO.FileInfo]::new($media).Length -eq $entry.size) 'Media size mismatch.'
    }
    return $plan
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$folderName = 'relay-usb-writer-' + [guid]::NewGuid().ToString('N')
$stage = [IO.Directory]::CreateDirectory((Join-Path $tempRoot $folderName)).FullName
try {
    $catalog = (Get-StudioCatalog $ConfigRoot).data
    $solution = $catalog.solutions | Where-Object { $_.source.snapshot } | Select-Object -First 1
    Assert-Playback ($null -ne $solution) 'This integration test requires an installed ViPlex library with a playable solution.'
    $screen = [pscustomobject]@{id='test-lane'; name='Relay USB playback test'; width=$solution.width; height=$solution.height}
    $project = [pscustomobject]@{
        solutions=$catalog.solutions; screens=@($screen); cues=@([pscustomobject]@{
            screenId=$screen.id; solutionId=$solution.id; startDate='2026-11-16'; endDate='2026-11-16'
            start='09:00'; end='11:00'; days=@(1)
        })
    }
    $password = [guid]::NewGuid().ToString('N') + ' +$'
    $folder = [IO.Directory]::CreateDirectory((Join-Path $stage 'standalone')).FullName
    $result = Export-ViplexUsbPlayback -ConfigRoot $ConfigRoot -Project $project -ProgramType solution -ProgramId $solution.id -PlayerPassword $password -OutputDirectory $folder
    $plan = Test-PlaybackFiles $folder $solution.name $password $true $true
    Assert-Playback ($plan.scheduleConstraints[0].fileName -ceq 'schedule_constraint.json') 'A standalone solution needs the unnumbered native playback rule.'
    Assert-Playback ($result.solutionCount -eq 1 -and $plan.playlists.Count -eq 1) 'Wrong standalone playlist count.'
    $form = [IO.File]::ReadAllText((Join-Path (Join-Path (Join-Path $folder 'nova\program') $solution.name) 'schedule_constraint.json')) | ConvertFrom-Json
    Assert-Playback ($form.constraints.Count -eq 1 -and $form.constraints[0].cron[0] -ceq '0 0 0 ? * 1,2,3,4,5,6,7') 'The standalone solution is not scheduled on every day.'
    Assert-Playback ((ConvertTo-Json $result) -notlike ('*' + $password + '*')) 'A receipt contained the password.'

    $folder = [IO.Directory]::CreateDirectory((Join-Path $stage 'keep-both')).FullName
    $result = Export-ViplexUsbPlayback -ConfigRoot $ConfigRoot -Project $project -ProgramType solution -ProgramId $solution.id -PlayerPassword $password -OutputDirectory $folder -DuplicatePolicy keep
    $null = Test-PlaybackFiles $folder $solution.name $password $true $false

    $folder = [IO.Directory]::CreateDirectory((Join-Path $stage 'schedule')).FullName
    $result = Export-ViplexUsbPlayback -ConfigRoot $ConfigRoot -Project $project -ProgramType schedule -ProgramId $screen.id -PlayerPassword $password -OutputDirectory $folder -PlayMode plug -DuplicatePolicy replace
    $plan = Test-PlaybackFiles $folder $screen.name $password $false $true
    Assert-Playback ($plan.scheduleConstraints[0].fileName -ceq 'schedule_constraint0.json') 'A screen schedule needs native scheduling rules.'
    $form = [IO.File]::ReadAllText((Join-Path (Join-Path (Join-Path $folder 'nova\program') $screen.name) 'schedule_constraint0.json')) | ConvertFrom-Json
    $rule = @($form.constraints | Where-Object { $_.startTime -like '2026-11-16T09:00:00*' })
    Assert-Playback ($rule.Count -eq 1 -and $rule[0].endTime -like '2026-11-16T10:59:59*') 'The screen cue was not retained.'

    $folder = [IO.Directory]::CreateDirectory((Join-Path $stage 'desktop')).FullName
    $result = Export-ViplexSchedule -ConfigRoot $ConfigRoot -Project $project -ScreenId $screen.id -OutputDirectory $folder
    $bytes = [Convert]::FromBase64String([IO.File]::ReadAllText((Join-Path $folder 'nova\command.json')))
    $command = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    Assert-Playback ($command.authenticUserInfos.Count -eq 0 -and -not $command.programInfos[0].isPlay) 'Desktop import behavior changed.'
    'USB playback staging passed for a standalone solution and a timed schedule. Desktop import is intact.'
} finally {
    $expected = [IO.Path]::GetFullPath((Join-Path $tempRoot $folderName))
    if ([IO.Path]::GetFullPath($stage) -ceq $expected -and [IO.Path]::GetFileName($stage) -match '^relay-usb-writer-[0-9a-f]{32}$') {
        [IO.Directory]::Delete($stage, $true)
    }
}

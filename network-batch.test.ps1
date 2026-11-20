# Queue/API tests use synthetic workers. No player or real workspace is touched.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'StudioNetwork.ps1')
function Assert-Batch([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Fail-Batch([scriptblock]$Action,[string]$Pattern){$message='';try{& $Action}catch{$message=$_.Exception.Message};Assert-Batch ($message -like "*$Pattern*") "Expected $Pattern, got $message"}
function Test-StudioProject($Project){$Project.version -eq 1 -and $Project.screens -is [array] -and $Project.solutions -is [array] -and $Project.cues -is [array]}
function Get-StudioCachedCatalog {@{data=@{solutions=@([pscustomobject]@{id='fixture-solution';name='Canonical solution';width=1920;height=1080;source=@{kind='localVideo'}})}}}
function Get-StudioManagedPlayers {foreach($c in $script:networkConnections.Values){[pscustomobject]@{sn=$c.device.sn;name='Alias '+$c.device.sn}}}
function Start-StudioNetworkJob($Kind,$Options){
    $id=[guid]::NewGuid().ToString('N')
    $copy=$Options|ConvertTo-Json -Depth 32 -Compress|ConvertFrom-Json
    $script:started.Add([pscustomobject]@{id=$id;kind=$Kind;options=$copy})
    $script:networkJobs[$id]=@{id=$id;kind=$Kind;status='running';progress=0;message='Uploading';sn=$copy.device.sn;ip=$copy.device.ip}
    return $id
}
function Reset-BatchFixture {
    $script:networkJobs=@{};$script:networkConnections=@{};$script:networkBatches=@{}
    $script:started=[Collections.Generic.List[object]]::new()
    1..7 | ForEach-Object {
        $id=([string]$_).PadLeft(32,'0')
        $script:networkConnections[$id]=@{device=@{sn="BOARD-$_";ip="192.168.8.$(100+$_)";name="Board $_";model='T50';width=320;height=1080};certificateSha256=('A'*64);created=[datetime]::UtcNow}
    }
}
function New-BatchOptions([int]$Count=7) {
    [pscustomobject]@{requestId=[guid]::NewGuid().ToString('N');programType='solution';programId='fixture-solution';playerPassword='fixture-private-password'
        targets=@(1..$Count|ForEach-Object{[pscustomobject]@{connectionId=([string]$_).PadLeft(32,'0')}})
        project=[pscustomobject]@{version=1;solutions=@([pscustomobject]@{id='fixture-solution';width=1;height=1});screens=@([pscustomobject]@{id='fixture-screen';name='Fixture schedule';width=1920;height=1080});cues=@([pscustomobject]@{screenId='fixture-screen';solutionId='fixture-solution';start='09:00';end='09:15'})}}
}

Reset-BatchFixture
$options=New-BatchOptions
$id=Start-StudioNetworkBatch $options
$batch=$script:networkBatches[$id]
Assert-Batch ($script:started.Count -eq 3 -and @($batch.targets|Where-Object status -EQ 'queued').Count -eq 4) 'Seven boards did not start exactly three concurrent transfers.'
Assert-Batch ($script:started[0].options.project.solutions[0].width -eq 1920 -and $script:started[0].options.device.width -eq 320) 'Canonical content or mosaic tile dimensions were replaced.'
Assert-Batch ($script:started[0].options.certificateSha256 -ceq ('A'*64) -and $script:started[0].options.playerPassword -ceq 'fixture-private-password') 'Verified identity or worker credentials were lost.'
Assert-Batch (Test-StudioNetworkPlayerReserved 'BOARD-7' '192.168.8.107') 'Queued boards were not reserved.'
$same=Start-StudioNetworkBatch $options
Assert-Batch ($same -eq $id -and $script:started.Count -eq 3) 'An idempotent retry dispatched duplicate uploads.'
$changed=$options|ConvertTo-Json -Depth 20|ConvertFrom-Json;$changed.programId='other'
Fail-Batch {Start-StudioNetworkBatch $changed} 'different upload'
Fail-Batch {Start-StudioNetworkBatch (New-BatchOptions 1)} 'operation in progress'
foreach($worker in @($script:networkJobs.Values)){$worker.status='complete';$worker.progress=100;$worker.message='Accepted';$worker.receipt=@{bytesUploaded=42}}
Update-StudioNetworkBatches
Assert-Batch ($script:started.Count -eq 6 -and @($script:networkJobs.Values|Where-Object status -EQ 'running').Count -eq 3) 'Queue did not advance after the first three completed.'
$running=@($script:networkJobs.Values|Where-Object status -EQ 'running')
$running[0].status='failed';$running[0].error='Synthetic board failure';$running[0].message='Synthetic board failure'
foreach($worker in @($running|Select-Object -Skip 1)){$worker.status='complete';$worker.progress=100}
Update-StudioNetworkBatches
Assert-Batch ($script:started.Count -eq 7 -and $null -eq $batch.playerPassword -and $null -eq $batch.project) 'Last board was not started or dispatch retained secret/project state.'
foreach($worker in @($script:networkJobs.Values|Where-Object status -EQ 'running')){$worker.status='complete';$worker.progress=100}
Update-StudioNetworkBatches
Assert-Batch ($batch.status -eq 'partial' -and @($batch.targets|Where-Object status -EQ 'complete').Count -eq 6 -and $batch.progress -eq 100) 'A failed board cancelled others or partial result was lost.'
Assert-Batch (-not (Test-StudioNetworkPlayerReserved 'BOARD-7' '192.168.8.107')) 'Finished batch kept the board reserved.'
$summary=Get-StudioNetworkBatchSummary $batch
Assert-Batch (($summary|ConvertTo-Json -Depth 12) -notmatch 'fixture-private-password|certificateSha256|fingerprint|playerPassword') 'Batch summary exposed internal identity/credentials.'
Assert-Batch ($summary.requestId -eq $options.requestId -and $summary.targets[0].name -like 'Alias BOARD-*') 'Batch lost command recovery ID or alias.'
$script:networkConnections=@{}
Assert-Batch ((Start-StudioNetworkBatch $options) -eq $id -and $script:started.Count -eq 7) 'Accepted command could not be recovered after connections expired.'

Reset-BatchFixture
$options=New-BatchOptions;$options.targets[-1].connectionId='f'*32
Fail-Batch {Start-StudioNetworkBatch $options} 'expired'
Assert-Batch ($script:started.Count -eq 0 -and $script:networkBatches.Count -eq 0) 'An invalid last target allowed a partial dispatch.'
$options=New-BatchOptions 2;$options.targets[1].connectionId=$options.targets[0].connectionId
Fail-Batch {Start-StudioNetworkBatch $options} 'only be selected once'
$options=New-BatchOptions 1;$options.playerPassword=''
Fail-Batch {Start-StudioNetworkBatch $options} 'password'
$options=New-BatchOptions 1;$options.programId='unknown'
Fail-Batch {Start-StudioNetworkBatch $options} 'unavailable'
$options=New-BatchOptions 1;$options.project.version=0
Fail-Batch {Start-StudioNetworkBatch $options} 'Choose a solution'
$options=New-BatchOptions 1;$options.requestId='../path'
Fail-Batch {Start-StudioNetworkBatch $options} 'unique request ID'
Assert-Batch ($script:started.Count -eq 0) 'Invalid command reached a worker.'

Reset-BatchFixture
1..4|ForEach-Object{$script:networkJobs["other$_"]=@{kind='check';status='running';sn="OTHER-$_";ip="192.168.9.$_"}}
$options=New-BatchOptions 1;$options.programType='schedule';$options.programId='fixture-screen'
$id=Start-StudioNetworkBatch $options
Assert-Batch ($script:started.Count -eq 0 -and $script:networkBatches[$id].status -eq 'running') 'A full worker pool rejected the queue or exceeded four workers.'
$script:networkJobs.other1.status='complete'
Update-StudioNetworkBatches
Assert-Batch ($script:started.Count -eq 1 -and $script:started[0].options.programType -eq 'schedule') 'Schedule did not dispatch when a worker slot opened.'

# Actual dispatcher checks with protected request and workers mocked.
& {
    function Read-StudioJsonRequest($Request,$Response){if($script:deny){Write-StudioJson $Response @{error='Denied'} 403;return};$script:payload}
    function Write-StudioJson($Response,$Body,[int]$Status=200){$script:reply=@{status=$Status;body=$Body}}
    function Update-StudioNetworkJobs {Update-StudioNetworkBatches}
    Reset-BatchFixture
    $script:payload=New-BatchOptions 1;$script:deny=$true
    Invoke-StudioNetworkRequest ([pscustomobject]@{HttpMethod='POST'}) $null '/api/network/batches'
    Assert-Batch ($script:reply.status -eq 403 -and $script:started.Count -eq 0) 'Batch bypassed protected request validation.'
    $script:deny=$false
    Invoke-StudioNetworkRequest ([pscustomobject]@{HttpMethod='POST'}) $null '/api/network/batches'
    $accepted=$script:reply.body.batchId
    Assert-Batch ($script:reply.status -eq 202 -and $null -eq $script:payload.playerPassword) 'Batch response was invalid or input retained its password.'
    Invoke-StudioNetworkRequest ([pscustomobject]@{HttpMethod='GET'}) $null "/api/network/batches/$accepted"
    Assert-Batch ($script:reply.status -eq 200 -and $script:reply.body.targets.Count -eq 1) 'Batch detail route lost target progress.'
    Invoke-StudioNetworkRequest ([pscustomobject]@{HttpMethod='GET'}) $null '/api/network/batches'
    Assert-Batch ($script:reply.body.batches.Count -eq 1) 'Accepted batch could not be recovered by request ID.'
    $script:payload=[pscustomobject]@{ip='192.168.8.101';expectedSn='BOARD-1';playerPassword='fixture-private-password'}
    Invoke-StudioNetworkRequest ([pscustomobject]@{HttpMethod='POST'}) $null '/api/network/check'
    Assert-Batch ($script:reply.status -eq 422 -and $script:started.Count -eq 1) 'Connection check bypassed a queued upload reservation.'
}
'Batch queue, partial failure, canonical media, private credentials, idempotency, reservations and API checks passed. No player contacted.'

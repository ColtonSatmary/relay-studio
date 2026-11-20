# One operator command, independently verified uploads to each selected player.
# Queues and credentials stay in this service's memory, never in job files.
$script:networkBatches=@{}

function Test-StudioNetworkPlayerReserved([string]$Serial,[string]$Address) {
    foreach($batch in @($script:networkBatches.Values)) {
        if($batch.status -ne 'running'){continue}
        foreach($target in $batch.targets) {
            if($target.status -in 'queued','running' -and (($Serial -and $target.sn -eq $Serial) -or ($Address -and $target.ip -eq $Address))){return $true}
        }
    }
    return $false
}

function Get-StudioNetworkBatchSummary($Batch) {
    [ordered]@{id=$Batch.id;requestId=$Batch.requestId;status=$Batch.status;name=$Batch.name
        programType=$Batch.programType;programId=$Batch.programId;created=$Batch.created.ToString('o')
        progress=[int]$Batch.progress;message=$Batch.message
        targets=@($Batch.targets | ForEach-Object {
            [ordered]@{sn=$_.sn;ip=$_.ip;name=$_.name;status=$_.status;progress=[int]$_.progress
                message=$_.message;error=$_.error;jobId=$_.jobId;receipt=$_.receipt}
        })}
}

function Start-StudioNetworkBatch($Options) {
    if($Options.requestId -isnot [string] -or $Options.requestId -cnotmatch '^(?:[a-f0-9]{32}|[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})$'){throw 'The upload command needs a unique request ID.'}
    if($Options.programType -cnotin 'solution','schedule' -or $Options.programId -isnot [string] -or -not (Test-StudioProject $Options.project)){throw 'Choose a solution or schedule to upload.'}
    if($Options.targets -isnot [array] -or $Options.targets.Count -lt 1 -or $Options.targets.Count -gt 64){throw 'Select between 1 and 64 connected boards.'}
    $connectionIds=@(foreach($target in $Options.targets) {
        if($target.connectionId -isnot [string] -or $target.connectionId -cnotmatch '^[a-f0-9]{32}$'){throw 'Connect every selected board before uploading.'}
        [string]$target.connectionId
    })
    if(@($connectionIds | Select-Object -Unique).Count -ne $connectionIds.Count){throw 'Each board can only be selected once.'}
    # The same accepted command can be recovered after an interrupted HTTP
    # response, even if its connection checks have subsequently expired.
    $command=[ordered]@{programType=$Options.programType;programId=$Options.programId;connections=@($connectionIds | Sort-Object);project=$Options.project}
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$fingerprint=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($command | ConvertTo-Json -Depth 32 -Compress)))).Replace('-','')}
    finally {$sha.Dispose()}
    $existing=@($script:networkBatches.Values | Where-Object requestId -CEQ $Options.requestId) | Select-Object -First 1
    if($existing) {
        if($existing.fingerprint -cne $fingerprint){throw 'This request ID already belongs to a different upload. Check its progress before starting a new command.'}
        return $existing.id
    }
    if($Options.playerPassword -isnot [string] -or $Options.playerPassword.Length -lt 1 -or $Options.playerPassword.Length -gt 256){throw 'Enter the shared player password.'}
    if(@($script:networkBatches.Values | Where-Object status -EQ 'running').Count -ge 4){throw 'Four upload groups are already queued. Wait for one to finish.'}
    $serials=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $addresses=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $directory=@(Get-StudioManagedPlayers)
    $targets=@(foreach($connectionId in $connectionIds) {
        $checked=$script:networkConnections[$connectionId]
        if(-not $checked -or ([datetime]::UtcNow-$checked.created).TotalMinutes -gt 30){throw 'A selected connection expired. Reconnect the selected boards before uploading.'}
        $device=$checked.device
        if(-not $serials.Add($device.sn) -or -not $addresses.Add($device.ip)){throw 'Two selected connections point to the same board or address. Refresh the player list.'}
        if((Test-StudioNetworkPlayerReserved $device.sn $device.ip) -or
            @($script:networkJobs.Values | Where-Object {$_.status -eq 'running' -and ($_.sn -eq $device.sn -or $_.ip -eq $device.ip)}).Count){throw "The board at $($device.ip) already has an operation in progress. Wait for it to finish."}
        $known=$directory | Where-Object sn -EQ $device.sn | Select-Object -First 1
        @{sn=$device.sn;ip=$device.ip;name=$(if($known.name){$known.name}else{$device.name});status='queued';progress=0
            message='Queued';error='';jobId='';receipt=$null
            device=$device;certificateSha256=$checked.certificateSha256}
    })
    # Retain a private project snapshot; only the server's media catalog supplies
    # solutions, filenames, dimensions and hashes for every target.
    $canonical=$Options.project | ConvertTo-Json -Depth 32 -Compress | ConvertFrom-Json
    $canonical.solutions=(Get-StudioCachedCatalog).data.solutions
    $items=if($Options.programType -eq 'solution'){$canonical.solutions}else{$canonical.screens}
    $program=@($items | Where-Object id -CEQ $Options.programId)
    if($program.Count -ne 1 -or $program[0].missing){throw 'The selected program is unavailable. Refresh the library and choose again.'}
    if($Options.programType -eq 'schedule' -and -not @($canonical.cues | Where-Object screenId -CEQ $Options.programId).Count){throw 'Add a block to this schedule before uploading.'}
    $id=[guid]::NewGuid().ToString('N')
    $script:networkBatches[$id]=@{id=$id;requestId=$Options.requestId;fingerprint=$fingerprint;status='running';created=[datetime]::UtcNow
        name=$program[0].name;programType=$Options.programType;programId=$Options.programId;project=$canonical;targets=$targets
        playerPassword=$Options.playerPassword;progress=0;message='Queued for upload.'}
    Update-StudioNetworkBatches
    return $id
}

function Update-StudioNetworkBatches {
    foreach($batch in @($script:networkBatches.Values | Sort-Object created)) {
        if($batch.status -ne 'running'){continue}
        foreach($target in $batch.targets) {
            if($target.status -ne 'running'){continue}
            $job=$script:networkJobs[$target.jobId]
            if(-not $job){$target.status='failed';$target.error='The upload worker is unavailable. Check the board before retrying.';$target.message=$target.error;continue}
            $target.progress=$job.progress;$target.message=$job.message
            if($job.status -in 'complete','failed') {$target.status=$job.status;$target.error=$job.error;$target.receipt=$job.receipt}
        }
        foreach($target in $batch.targets) {
            if($target.status -ne 'queued'){continue}
            $active=@($script:networkJobs.Values | Where-Object status -EQ 'running')
            if($active.Count -ge 4 -or @($active | Where-Object kind -EQ 'publish').Count -ge 3){break}
            if(@($active | Where-Object {$_.sn -eq $target.sn -or $_.ip -eq $target.ip}).Count){continue}
            try {
                $options=[pscustomobject]@{project=$batch.project;programType=$batch.programType;programId=$batch.programId
                    device=$target.device;certificateSha256=$target.certificateSha256;playerPassword=$batch.playerPassword}
                $target.jobId=Start-StudioNetworkJob 'publish' $options
                $target.status='running';$target.message='Starting upload...'
            } catch {
                $target.status='failed';$target.error='The upload could not be started. '+$_.Exception.Message
                if($batch.playerPassword){$target.error=$target.error.Replace($batch.playerPassword,'[redacted]')}
                $target.message=$target.error
            } finally {if($options){$options.playerPassword=$null}}
        }
        $remaining=@($batch.targets | Where-Object {$_.status -in 'queued','running'}).Count
        $complete=@($batch.targets | Where-Object status -EQ 'complete').Count
        $failed=@($batch.targets | Where-Object status -EQ 'failed').Count
        $batch.progress=[int](($batch.targets | ForEach-Object {if($_.status -in 'complete','failed'){100}else{[int]$_.progress}} | Measure-Object -Average).Average)
        $batch.message="$complete of $($batch.targets.Count) boards complete"+$(if($failed){"; $failed failed."}else{'.'})
        if(-not @($batch.targets | Where-Object status -EQ 'queued').Count){$batch.playerPassword=$null;$batch.project=$null}
        if(-not $remaining) {
            $batch.status=if(-not $failed){'complete'}elseif($complete){'partial'}else{'failed'}
            $batch.finished=[datetime]::UtcNow;$batch.playerPassword=$null;$batch.project=$null
        }
    }
    foreach($id in @($script:networkBatches.Keys)) {
        if($script:networkBatches[$id].finished -and ([datetime]::UtcNow-$script:networkBatches[$id].finished).TotalHours -gt 24){$script:networkBatches.Remove($id)}
    }
}

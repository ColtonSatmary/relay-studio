# Network operations run in separate PowerShell jobs so media transfers do not
# block the local editor. Credentials stay in memory and never enter job files.
$script:networkJobs = @{}
$script:networkConnections = @{}
. (Join-Path $PSScriptRoot 'StudioPlayers.ps1')
. (Join-Path $PSScriptRoot 'StudioNetworkBatch.ps1')

function Test-StudioNetworkAddress([string]$Address) {
    if ($Address -cnotmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$') { return $false }
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address,[ref]$parsed)) { return $false }
    $b = $parsed.GetAddressBytes()
    return ($b.Length -eq 4 -and $b[3] -ne 0 -and $b[3] -ne 255 -and ($b[0] -eq 10 -or
        ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
        ($b[0] -eq 192 -and $b[1] -eq 168) -or
        ($b[0] -eq 169 -and $b[1] -eq 254) -or
        ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127)))
}

function Get-StudioNetworkDeviceSummary($Device) {
    [ordered]@{sn=[string]$Device.Sn; ip=[string]$Device.Ip; name=[string]$Device.Name
        model=[string]$Device.Model; width=[int]$Device.Width; height=[int]$Device.Height}
}

function Initialize-StudioNetworkTransport {
    if (-not ('RelayNetworkTransport' -as [type])) {
        $sources=@((Join-Path $PSScriptRoot 'StudioNetworkTransport.cs'),(Join-Path $PSScriptRoot 'StudioPlayerDiscovery.cs'))
        if ($PSVersionTable.PSEdition -eq 'Core') {
            Add-Type -Path ($sources+(Join-Path $PSScriptRoot 'macos/StudioJsonCompat.cs')) -IgnoreWarnings -WarningAction SilentlyContinue
        } else { Add-Type -Path $sources -ReferencedAssemblies 'System.Web.Extensions.dll' }
    }
}

function New-StudioVerifiedNetworkSession($Options) {
    # Options.device and certificateSha256 come from the server's checked
    # connection, never from client-supplied player identity fields.
    $device=[RelayNetworkDevice]::new()
    $device.Ip=[string]$Options.device.ip;$device.Sn=[string]$Options.device.sn
    $device.Name=[string]$Options.device.name;$device.Model=[string]$Options.device.model
    $device.Width=[int]$Options.device.width;$device.Height=[int]$Options.device.height
    $device.HttpsPort=16674;$device.CertificateSha256=[string]$Options.certificateSha256
    return [RelayNetworkSession]::new($device,[string]$Options.playerPassword)
}

function Write-StudioNetworkProgress([string]$WorkDirectory, [int]$Progress, [string]$Message) {
    $value = @{progress=[math]::Max(0,[math]::Min(100,$Progress));message=$Message}
    $path = Join-Path $WorkDirectory 'progress.json'
    $temp = Join-Path $WorkDirectory 'progress.tmp'
    [IO.File]::WriteAllText($temp,($value | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp,$path,[Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($temp,$path) }
}

function Remove-StudioNetworkWorkDirectory([string]$Directory, [string]$Parent) {
    $full = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $expectedParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($full) -cne $expectedParent -or
        [IO.Path]::GetFileName($full) -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid network work directory.' }
    if ([IO.Directory]::Exists($full)) { [IO.Directory]::Delete($full,$true) }
}

function Invoke-StudioNetworkTransfer($Options, [string]$WorkDirectory, [string]$ConfigRoot) {
    Write-StudioNetworkProgress $WorkDirectory 1 'Building and verifying the playback package...'
    $stage = [IO.Directory]::CreateDirectory((Join-Path $WorkDirectory 'package')).FullName
    $package = Export-StudioNetworkProgram -ConfigRoot $ConfigRoot -Project $Options.project `
        -ProgramType $Options.programType -ProgramId $Options.programId -OutputDirectory $stage
    $session = $null
    $mutex = $null
    $locked = $false
    try {
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $key = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Options.device.sn))).Replace('-','') }
        finally { $hash.Dispose() }
        $mutex = [Threading.Mutex]::new($false,'Local\RelayNetworkPlayer-'+$key)
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
        if (-not $locked) { throw 'Another Relay upload is already using this player. Wait for it to finish.' }
        Write-StudioNetworkProgress $WorkDirectory 5 'Checking the player identity and signing in...'
        $session = New-StudioVerifiedNetworkSession $Options
        # A player may output one tile of a larger content canvas. Keep both sizes
        # unchanged; the transport still verifies the selected serial and certificate.
        $start = [ordered]@{
            deviceIdentifier=('RelayStudio-'+[Environment]::MachineName); totalSize=[long]$package.totalSize
            type='DEFAULT'; local=$false; source=0
            solutions=[ordered]@{name=$package.name;identifier=$package.programInfo.identifier}
            totalMediaSize=[long]$package.totalMediaSize; judgeForDevice=$true
            checkFiles=@($package.mediaFiles | ForEach-Object fileName)
        }
        Write-StudioNetworkProgress $WorkDirectory 8 'Checking available space and media already on the player...'
        $transfer = $session.StartTransfer(($start | ConvertTo-Json -Depth 12 -Compress)) | ConvertFrom-Json
        if ($transfer.canTranster -ne $true -or $null -eq $transfer.errorCode -or [int]$transfer.errorCode -ne 0 -or
            $null -eq $transfer.appliedInfos.statusCode -or [int]$transfer.appliedInfos.statusCode -ne 0) {
            throw 'The player did not accept this transfer. Check its free storage and try again in ViPlex if needed.'
        }
        $programDirectory = [string]$transfer.appliedInfos.uploadUrl
        $mediaDirectory = [string]$transfer.uploadMediaUrl
        if (-not $mediaDirectory) { $mediaDirectory = [string]$transfer.mediaInfo.uploadMediaUrl }
        if ($transfer.appliedInfos.name -cne $package.name -or
            $transfer.appliedInfos.identifier -cne $package.programInfo.identifier) {
            throw 'The player returned a different program identity. Upload stopped.'
        }
        if ($null -eq $transfer.checkFiles -or $transfer.checkFiles -is [string]) {
            throw 'The player did not return a valid media checklist. Upload stopped.'
        }
        $mediaIndex = @{}
        foreach ($file in $package.mediaFiles) { $mediaIndex[$file.fileName] = $file }
        $requested = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $uploads = @(foreach ($name in @($transfer.checkFiles)) {
            if ($name -isnot [string] -or -not $mediaIndex.ContainsKey($name)) { throw 'The player requested an unknown media file. Upload stopped.' }
            if ($requested.Add($name)) { [pscustomobject]@{file=$mediaIndex[$name];directory=$mediaDirectory} }
        })
        $uploads += @(foreach ($file in $package.programFiles) { [pscustomobject]@{file=$file;directory=$programDirectory} })
        $total = [long](($uploads | ForEach-Object { $_.file.size } | Measure-Object -Sum).Sum)
        $sent = 0L
        $progressState = @{lastPercent=-1}
        foreach ($upload in $uploads) {
            $file = $upload.file
            $progressCallback = [Action[long,long]]{
                param($fileSent,$fileTotal)
                $percent = 10 + [int](80.0 * ($sent + $fileSent) / [math]::Max(1,$total))
                if ($percent -ne $progressState.lastPercent) {
                    Write-StudioNetworkProgress $WorkDirectory $percent ('Uploading '+$file.fileName+'...')
                    $progressState.lastPercent = $percent
                }
            }
            $null = $session.UploadFile($file.path,$upload.directory,$file.fileName,$progressCallback)
            $sent += [long]$file.size
        }
        Write-StudioNetworkProgress $WorkDirectory 94 'Verifying the files and starting playback...'
        $finish = [ordered]@{
            confirmedInfos=[ordered]@{
                identifier=$package.programInfo.identifier; name=$package.name
                planListUrl=$programDirectory.TrimEnd('/')+'/planlist.json'
                thumbnailUrl=$programDirectory.TrimEnd('/')+'/'+$package.programInfo.thumbnailName; type='DEFAULT'
            }
            source=[ordered]@{type=1;platform=2}; delayTime=0; playTime=0
            playImmediately=$true; isSupportMd5Checkout=$true
        }
        try { $receipt = $session.EndTransfer(($finish | ConvertTo-Json -Depth 12 -Compress)) | ConvertFrom-Json }
        catch {
            $failure=$_.Exception
            while($failure.InnerException){$failure=$failure.InnerException}
            throw ('The files were uploaded, but playback could not be confirmed. '+$failure.Message+' Check the player before retrying.')
        }
        # Native ViPlex also accepts an explicit null data payload after code:0.
        # A non-null receipt still requires its own successful status.
        if ($null -ne $receipt -and ($null -eq $receipt.errorType -or [int]$receipt.errorType -ne 0)) {
            $code=if($null -ne $receipt.errorType){[string][int]$receipt.errorType}else{'missing status'}
            throw ('The player did not confirm playback (code '+$code+'). Check its screen before retrying.')
        }
        return @{event='complete';name=$package.name;device=(Get-StudioNetworkDeviceSummary $session.Device)
            message='Upload complete. The player accepted the playback command.';progress=100
            receipt=@{mediaUploaded=$requested.Count;mediaReused=@($package.mediaFiles).Count-$requested.Count;bytesUploaded=$sent}}
    } finally {
        if ($null -ne $session) { $session.Dispose() }
        if ($locked) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function Start-StudioNetworkJob([string]$Kind, $Options) {
    $id = [guid]::NewGuid().ToString('N')
    $parent = Join-Path ([IO.Path]::GetFullPath($WorkspaceDirectory)) 'NetworkJobs'
    $work = [IO.Directory]::CreateDirectory((Join-Path $parent $id)).FullName
    $root = $PSScriptRoot
    # Start-Job serializes arguments after it returns. Callers clear their
    # credentials immediately, so snapshot the complete request synchronously
    # into an immutable in-memory string before handing it to the worker.
    $workerJson = $Options | ConvertTo-Json -Depth 32 -Compress
    try { $job = Start-Job -ScriptBlock {
        param($Root,$Kind,$OptionsJson,$Work,$ConfigRoot,$MediaRoot)
        $ErrorActionPreference='Stop'
        $mediaRoot=$MediaRoot
        try {
            $Options=$OptionsJson | ConvertFrom-Json
            $OptionsJson=$null
            . (Join-Path $Root 'StudioCatalog.ps1')
            . (Join-Path $Root 'StudioMedia.ps1')
            . (Join-Path $Root 'Viplex.ps1')
            . (Join-Path $Root 'ViplexUsb.ps1')
            . (Join-Path $Root 'StudioNetworkCatalog.ps1')
            . (Join-Path $Root 'StudioNetwork.ps1')
            Initialize-StudioNetworkTransport
            if ($Kind -eq 'discover') {
                Write-StudioNetworkProgress $Work 10 'Discovering players on the connected local network...'
                $found=[RelayPlayerDiscovery]::Scan()
                @{event='complete';players=@($found.Devices | ForEach-Object {Get-StudioNetworkDeviceSummary $_});networks=@($found.Networks)
                    warnings=@($found.Warnings);probedAddresses=$found.ProbedAddresses;message=$found.Message;progress=100}
            } elseif ($Kind -eq 'check') {
                Write-StudioNetworkProgress $Work 10 'Looking for the player and checking the connection...'
                $device = [RelayNetworkTransport]::Check($Options.ip,$Options.playerPassword,$Options.expectedSn)
                @{event='complete';device=(Get-StudioNetworkDeviceSummary $device);certificateSha256=$device.CertificateSha256
                    progress=100;message='Connected. Ready to upload.'}
            } elseif ($Kind -eq 'preview') {
                . (Join-Path $Root 'StudioPlayerPreview.ps1')
                Invoke-StudioPlayerPreview $Options $Work
            } elseif ($Kind -in 'controls-read','controls-apply') {
                . (Join-Path $Root 'StudioBoardControls.ps1')
                Invoke-StudioNetworkControl $Kind $Options $Work
            } else {
                Invoke-StudioNetworkTransfer $Options $Work $ConfigRoot
            }
        } catch {
            $failure=$_.Exception
            while ($failure.InnerException) { $failure=$failure.InnerException }
            $message=[string]$failure.Message
            if ($Options.playerPassword) { $message=$message.Replace([string]$Options.playerPassword,'[redacted]') }
            @{event='failed';error=$message;message=$message}
        } finally {
            if ($Options.PSObject.Properties['playerPassword']) {$Options.playerPassword=$null}
        }
    } -ArgumentList $root,$Kind,$workerJson,$work,$configRoot,$mediaRoot -ErrorAction Stop }
    catch {
        Remove-StudioNetworkWorkDirectory $work $parent
        throw
    }
    finally { $workerJson=$null }
    $script:networkJobs[$id]=@{
        id=$id;kind=$Kind;status='running';stage=$Kind;message='Starting...';progress=0;created=[datetime]::UtcNow
        native=$job;work=$work;parent=$parent;ip=$(if($Kind -eq 'check'){$Options.ip}else{$Options.device.ip})
        sn=$(if($Kind -eq 'check'){$Options.expectedSn}else{$Options.device.sn})
    }
    return $id
}

function Update-StudioNetworkJobs {
    foreach ($entry in @($script:networkJobs.Values)) {
        if (-not $entry.native) { continue }
        try {
            $progressPath=Join-Path $entry.work 'progress.json'
            if ([IO.File]::Exists($progressPath)) {
                $stream=[IO.File]::Open($progressPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8)
                try { $update=$reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
                $entry.progress=[int]$update.progress; $entry.message=[string]$update.message
            }
        } catch { }
        $output=@(Receive-Job -Job $entry.native -ErrorAction SilentlyContinue)
        foreach ($jobEvent in $output) {
            if ($jobEvent.event -eq 'failed') {
                $entry.status='failed';$entry.error=[string]$jobEvent.error;$entry.message=$entry.error
            } elseif ($jobEvent.event -eq 'complete') {
                $entry.status='complete';$entry.progress=100;$entry.message=[string]$jobEvent.message
                $entry.device=$jobEvent.device;$entry.name=$jobEvent.name;$entry.receipt=$jobEvent.receipt
                $entry.controls=$jobEvent.controls;$entry.appliedSection=$jobEvent.appliedSection
                $entry.verified=$jobEvent.verified;$entry.reconnectRequired=$jobEvent.reconnectRequired
                $entry.preview=$jobEvent.preview
                if ($entry.kind -eq 'discover') {
                    $entry.players=@($jobEvent.players);$entry.networks=@($jobEvent.networks)
                    $entry.warnings=@($jobEvent.warnings);$entry.probedAddresses=$jobEvent.probedAddresses
                    try {Save-StudioDiscoveredPlayers $entry.players}
                    catch {$entry.message+=' Players were found, but their addresses could not be saved: '+$_.Exception.Message}
                } elseif ($entry.kind -eq 'check') {
                    Remove-StudioPlayerConnections ([string]$jobEvent.device.sn)
                    $connectionId=[guid]::NewGuid().ToString('N')
                    $script:networkConnections[$connectionId]=@{device=$jobEvent.device;certificateSha256=$jobEvent.certificateSha256;created=[datetime]::UtcNow}
                    $entry.connectionId=$connectionId
                    try {Save-StudioDiscoveredPlayers @($jobEvent.device) 'Relay'}
                    catch {$entry.message+=' The connection is ready, but its address could not be saved: '+$_.Exception.Message}
                }
            }
        }
        if ($entry.native.State -in 'Completed','Failed','Stopped' -and $entry.status -eq 'running') {
            $entry.status='failed';$entry.error='The network worker stopped before completing. Check the player and try again.';$entry.message=$entry.error
        }
        if ($entry.status -ne 'running' -and -not $entry.finished) { $entry.finished=[datetime]::UtcNow }
        if ($entry.status -ne 'running' -and $entry.native.State -in 'Completed','Failed','Stopped') {
            Remove-Job -Job $entry.native -Force -ErrorAction SilentlyContinue
            $entry.native=$null
            try { Remove-StudioNetworkWorkDirectory $entry.work $entry.parent } catch { }
        }
    }
    foreach ($id in @($script:networkConnections.Keys)) {
        if (([datetime]::UtcNow-$script:networkConnections[$id].created).TotalMinutes -gt 30) { $script:networkConnections.Remove($id) }
    }
    foreach ($id in @($script:networkJobs.Keys)) {
        if ($script:networkJobs[$id].finished -and ([datetime]::UtcNow-$script:networkJobs[$id].finished).TotalHours -gt 1) { $script:networkJobs.Remove($id) }
    }
    Update-StudioNetworkBatches
}

function Get-StudioNetworkJobSummary($Job) {
    [ordered]@{id=$Job.id;kind=$Job.kind;status=$Job.status;stage=$Job.stage;message=$Job.message
        progress=$Job.progress;device=$Job.device;connectionId=$Job.connectionId;name=$Job.name;receipt=$Job.receipt;error=$Job.error
        controls=$Job.controls;appliedSection=$Job.appliedSection;verified=$Job.verified;reconnectRequired=$Job.reconnectRequired
        players=$Job.players;networks=$Job.networks;warnings=$Job.warnings;probedAddresses=$Job.probedAddresses;preview=$Job.preview}
}

function Invoke-StudioNetworkControl([string]$Kind,$Options,[string]$WorkDirectory) {
    $session=$null;$mutex=$null;$locked=$false
    try {
        $hash=[Security.Cryptography.SHA256]::Create()
        try {$key=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Options.device.sn))).Replace('-','')}
        finally {$hash.Dispose()}
        $mutex=[Threading.Mutex]::new($false,'Local\RelayNetworkPlayer-'+$key)
        try {$locked=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$locked=$true}
        if(-not $locked){throw 'Another Relay operation is already using this player. Wait for it to finish.'}
        Write-StudioNetworkProgress $WorkDirectory 10 'Connecting to the verified player...'
        $session=New-StudioVerifiedNetworkSession $Options
        if($Kind -eq 'controls-read') {
            Write-StudioNetworkProgress $WorkDirectory 30 'Reading current player settings...'
            $result=@{controls=(Invoke-StudioBoardRead $session);message='Current player settings loaded.'}
        } else {
            Write-StudioNetworkProgress $WorkDirectory 30 'Applying the selected player setting...'
            $result=Invoke-StudioBoardApply $session $Options.section $Options.values
        }
        $result.event='complete';$result.progress=100;$result.device=Get-StudioNetworkDeviceSummary $session.Device
        return $result
    } finally {
        if($null -ne $session){$session.Dispose()}
        if($locked){$mutex.ReleaseMutex()}
        if($null -ne $mutex){$mutex.Dispose()}
    }
}

function Invoke-StudioNetworkRequest($Request,$Response,[string]$Path) {
    Update-StudioNetworkJobs
    if ($Path -eq '/api/network/batches' -and $Request.HttpMethod -eq 'GET') {
        Write-StudioJson $Response @{batches=@($script:networkBatches.Values | Sort-Object @{Expression={if($_.status -eq 'running'){0}else{1}}},@{Expression={$_.created};Descending=$true} | Select-Object -First 20 | ForEach-Object {Get-StudioNetworkBatchSummary $_})}
        return
    }
    if ($Path -match '^/api/network/batches/([a-f0-9]{32})$' -and $Request.HttpMethod -eq 'GET') {
        $batch=$script:networkBatches[$Matches[1]]
        if(-not $batch){Write-StudioJson $Response @{error='This upload group is no longer available. Check the players before uploading again.'} 404;return}
        Write-StudioJson $Response (Get-StudioNetworkBatchSummary $batch)
        return
    }
    if ($Path -eq '/api/network/players' -and $Request.HttpMethod -eq 'GET') {
        try {
            $players=@(Get-StudioManagedPlayers)
            $discovery=@($script:networkJobs.Values | Where-Object kind -EQ 'discover' | Sort-Object created -Descending) | Select-Object -First 1
            Write-StudioJson $Response @{players=$players;supported=$true;available=$true;message=$script:playerDirectoryWarning;discovery=$(if($discovery){Get-StudioNetworkJobSummary $discovery}else{$null})}
        } catch {Write-StudioJson $Response @{error=$_.Exception.Message;players=@();supported=$true;available=$true} 422}
        return
    }
    if ($Path -match '^/api/network/jobs/([a-f0-9]{32})$' -and $Request.HttpMethod -eq 'GET') {
        $job=$script:networkJobs[$Matches[1]]
        if (-not $job) { Write-StudioJson $Response @{error='This upload session is no longer available. Check the connection again.'} 404;return }
        Write-StudioJson $Response (Get-StudioNetworkJobSummary $job)
        return
    }
    if ($Request.HttpMethod -ne 'POST' -or $Path -notin '/api/network/check','/api/network/publish','/api/network/controls/read','/api/network/controls/apply','/api/network/discover','/api/network/player','/api/network/batches','/api/network/preview') {
        Write-StudioJson $Response @{error='Network endpoint not found.'} 404;return
    }
    $options=Read-StudioJsonRequest $Request $Response
    if ($null -eq $options) { return }
    try {
        if ($Path -eq '/api/network/batches') {
            $id=Start-StudioNetworkBatch $options
            Write-StudioJson $Response @{batchId=$id} 202
            return
        }
        if ($Path -eq '/api/network/player') {
            Set-StudioPlayerDirectory $options
            Write-StudioJson $Response @{players=@(Get-StudioManagedPlayers);supported=$true;available=$true}
            return
        }
        if ($Path -eq '/api/network/discover') {
            $running=@($script:networkJobs.Values | Where-Object {$_.kind -eq 'discover' -and $_.status -eq 'running'}) | Select-Object -First 1
            if ($running) {Write-StudioJson $Response @{jobId=$running.id} 202;return}
        }
        if (@($script:networkJobs.Values | Where-Object status -EQ 'running').Count -ge 4) { throw 'Four network operations are already running. Wait for one to finish.' }
        if ($Path -eq '/api/network/discover') {
            $id=Start-StudioNetworkJob 'discover' ([pscustomobject]@{})
            Write-StudioJson $Response @{jobId=$id} 202
            return
        }
        if ($options.playerPassword -isnot [string] -or $options.playerPassword.Length -lt 1 -or $options.playerPassword.Length -gt 256) { throw 'Enter the player password.' }
        if ($Path -eq '/api/network/check') {
            if ($options.ip -isnot [string] -or -not (Test-StudioNetworkAddress $options.ip)) { throw 'Enter a local-network IPv4 address, such as 192.168.1.107.' }
            if ($options.expectedSn -and ($options.expectedSn -isnot [string] -or $options.expectedSn -cnotmatch '^[A-Za-z0-9_-]{1,128}$')) { throw 'Choose a valid player or enter its IP address.' }
            if(Test-StudioNetworkPlayerReserved ([string]$options.expectedSn) ([string]$options.ip)){throw 'This board has a queued upload. Wait for that upload to finish.'}
            if (@($script:networkJobs.Values | Where-Object { $_.status -eq 'running' -and ($_.ip -eq $options.ip -or ($options.expectedSn -and $_.sn -eq $options.expectedSn)) }).Count) { throw 'A network operation is already using this player.' }
            $jobOptions=[pscustomobject]@{ip=$options.ip;playerPassword=$options.playerPassword;expectedSn=[string]$options.expectedSn}
            $id=Start-StudioNetworkJob 'check' $jobOptions
        } else {
            $connection=if($options.connectionId -is [string]){$script:networkConnections[$options.connectionId]}
            if (-not $connection) { throw 'Check the player connection before uploading.' }
            if(Test-StudioNetworkPlayerReserved ([string]$connection.device.sn) ([string]$connection.device.ip)){throw 'This board has a queued upload. Wait for that upload to finish.'}
            if (@($script:networkJobs.Values | Where-Object { $_.status -eq 'running' -and ($_.ip -eq $connection.device.ip -or $_.sn -eq $connection.device.sn) }).Count) { throw 'A network operation is already using this player.' }
            if($Path -eq '/api/network/preview') {
                $jobOptions=[pscustomobject]@{device=$connection.device;certificateSha256=$connection.certificateSha256;playerPassword=$options.playerPassword}
                $id=Start-StudioNetworkJob 'preview' $jobOptions
                Write-StudioJson $Response @{jobId=$id} 202
                return
            }
            if ($Path -in '/api/network/controls/read','/api/network/controls/apply') {
                $kind=if($Path.EndsWith('/apply')){'controls-apply'}else{'controls-read'}
                if($kind -eq 'controls-apply' -and ($options.section -cnotin 'brightness','colorTemperature','mosaic','time','ethernet' -or $options.values -isnot [pscustomobject])) {throw 'Choose a supported player setting and its new values.'}
                $jobOptions=[pscustomobject]@{device=$connection.device;certificateSha256=$connection.certificateSha256;playerPassword=$options.playerPassword;section=$options.section;values=$options.values}
                $id=Start-StudioNetworkJob $kind $jobOptions
                Write-StudioJson $Response @{jobId=$id} 202
                return
            }
            if ($options.programType -cnotin 'solution','schedule' -or $options.programId -isnot [string] -or -not (Test-StudioProject $options.project)) { throw 'Choose a solution or schedule to upload.' }
            $project=$options.project
            $project.solutions=(Get-StudioCachedCatalog).data.solutions
            $items=if($options.programType -eq 'solution'){$project.solutions}else{$project.screens}
            $selected=@($items | Where-Object id -CEQ $options.programId)
            if ($selected.Count -ne 1) { throw 'The selected program is unavailable. Refresh the library and choose again.' }
            $jobOptions=[pscustomobject]@{project=$project;programType=$options.programType;programId=$options.programId;device=$connection.device;certificateSha256=$connection.certificateSha256;playerPassword=$options.playerPassword}
            $id=Start-StudioNetworkJob 'publish' $jobOptions
        }
        Write-StudioJson $Response @{jobId=$id} 202
    } catch {
        Write-StudioJson $Response @{error=$_.Exception.Message} 422
    } finally {
        if ($options.PSObject.Properties['playerPassword']) { $options.playerPassword=$null }
    }
}

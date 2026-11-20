# Relay's player directory is separate from the ViPlex database and credentials.
# Serial numbers identify boards; an IP address is only their last-known location.
function Get-StudioPlayerStorePath {
    Join-Path ([IO.Path]::GetFullPath($WorkspaceDirectory)) 'players.json'
}

function Read-StudioPlayerStore {
    $path=Get-StudioPlayerStorePath
    if (-not [IO.File]::Exists($path)) { return [pscustomobject]@{version=1;players=@()} }
    $file=[IO.FileInfo]::new($path)
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -gt 4MB) { throw 'The saved player directory cannot be read safely.' }
    try {
        $store=[IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        if ($store.version -ne 1 -or $store.players -isnot [array]) { throw 'Invalid player directory.' }
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($row in $store.players) {
            if ($row.sn -isnot [string] -or $row.sn -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or -not $seen.Add($row.sn) -or
                $row.alias -isnot [string] -or $row.alias.Length -gt 100 -or
                ($row.ip -and -not (Test-StudioNetworkAddress ([string]$row.ip)))) { throw 'Invalid saved player.' }
        }
        return $store
    } catch { throw 'The saved player directory is damaged. Restore players.json from its backup before editing players.' }
}

function Update-StudioPlayerStore([scriptblock]$Mutation) {
    $path=Get-StudioPlayerStorePath
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($path.ToUpperInvariant()))).Replace('-','') }
    finally { $sha.Dispose() }
    $mutex=[Threading.Mutex]::new($false,'Local\RelayStudioPlayers-'+$key)
    $locked=$false;$temp=$null
    try {
        try {$locked=$mutex.WaitOne(5000)} catch [Threading.AbandonedMutexException] {$locked=$true}
        if (-not $locked) { throw 'The player directory is busy. Try again.' }
        $store=Read-StudioPlayerStore
        $null=& $Mutation $store
        $parent=[IO.Path]::GetDirectoryName($path)
        [void][IO.Directory]::CreateDirectory($parent)
        $temp=Join-Path $parent ('players-'+[guid]::NewGuid().ToString('N')+'.tmp')
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($store | ConvertTo-Json -Depth 8 -Compress))
        $output=[IO.FileStream]::new($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {$output.Write($bytes,0,$bytes.Length);$output.Flush($true)} finally {$output.Dispose()}
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp,$path,$path+'.bak') }
        else { [IO.File]::Move($temp,$path) }
    } finally {
        if ($temp -and [IO.File]::Exists($temp)) {[IO.File]::Delete($temp)}
        if ($locked) {$mutex.ReleaseMutex()};$mutex.Dispose()
    }
}

function Get-StudioManagedPlayers {
    $store=Read-StudioPlayerStore
    $rows=@{}
    foreach($saved in $store.players) {$rows[$saved.sn]=$saved}
    $script:playerDirectoryWarning=''
    try {$nativePlayers=@(Get-StudioNetworkKnownPlayers $configRoot)}
    catch {$nativePlayers=@();$script:playerDirectoryWarning='ViPlex remembered players could not be read. Saved Relay players are still available.'}
    foreach($native in $nativePlayers) {
        if (-not $rows.ContainsKey($native.sn)) {
            $rows[$native.sn]=[pscustomobject]@{sn=$native.sn;alias='';deviceName=$native.name;ip=$(if(Test-StudioNetworkAddress $native.ip){$native.ip}else{''})
                model=$native.model;width=$native.width;height=$native.height;source='ViPlex';lastSeen='';forgotten=$false}
        }
    }
    foreach($row in @($rows.Values | Sort-Object @{Expression={if($_.alias){$_.alias}else{$_.deviceName}}},sn)) {
        if ($row.forgotten) {continue}
        $connectionId='';$until='';$device=$null
        foreach($key in @($script:networkConnections.Keys)) {
            $connection=$script:networkConnections[$key]
            if ($connection.device.sn -eq $row.sn -and $connection.device.ip -eq $row.ip -and
                ([datetime]::UtcNow-$connection.created).TotalMinutes -le 30) {
                $connectionId=$key;$until=$connection.created.AddMinutes(30).ToString('o');$device=$connection.device
            }
        }
        [pscustomobject]@{id=$row.sn;sn=$row.sn;name=$(if($row.alias){$row.alias}elseif($row.deviceName){$row.deviceName}else{$row.sn})
            alias=[string]$row.alias;deviceName=[string]$row.deviceName;ip=[string]$row.ip;model=[string]$row.model
            width=[int]$row.width;height=[int]$row.height;source=[string]$row.source;lastSeen=[string]$row.lastSeen
            remembered=$true;httpsPort=16674;connected=[bool]$connectionId;connectionId=$connectionId;connectedUntil=$until;device=$device}
    }
}

function Remove-StudioPlayerConnections([string]$Serial) {
    foreach($id in @($script:networkConnections.Keys)) {
        if ($script:networkConnections[$id].device.sn -eq $Serial) {$script:networkConnections.Remove($id)}
    }
}

function Save-StudioDiscoveredPlayers($Devices,[string]$Source='Discovery') {
    $valid=@(foreach($device in @($Devices)) {
        if ($device.sn -cmatch '^[A-Za-z0-9_-]{1,128}$' -and (Test-StudioNetworkAddress ([string]$device.ip))) {$device}
    })
    if (-not $valid.Count) {return}
    Update-StudioPlayerStore {
        param($store)
        foreach($device in $valid) {
            $existing=@($store.players | Where-Object sn -EQ $device.sn) | Select-Object -First 1
            $record=[pscustomobject]@{sn=[string]$device.sn;alias=$(if($existing){[string]$existing.alias}else{''})
                deviceName=([string]$device.name).Substring(0,[math]::Min(160,([string]$device.name).Length));ip=[string]$device.ip
                model=([string]$device.model).Substring(0,[math]::Min(80,([string]$device.model).Length));width=[int]$device.width;height=[int]$device.height
                source=$Source;lastSeen=[datetime]::UtcNow.ToString('o');forgotten=$false}
            $store.players=@($store.players | Where-Object sn -NE $device.sn)+@($record)
        }
    }
    foreach($device in $valid) {
        foreach($id in @($script:networkConnections.Keys)) {
            $old=$script:networkConnections[$id].device
            if (($old.sn -eq $device.sn -and $old.ip -ne $device.ip) -or ($old.ip -eq $device.ip -and $old.sn -ne $device.sn)) {
                $script:networkConnections.Remove($id)
            }
        }
    }
}

function Set-StudioPlayerDirectory($Options) {
    $action=[string]$Options.action
    if ($action -cnotin 'alias','forget','forget-all','clear-ip','clear-ips') {throw 'Choose a supported player action.'}
    $players=@(Get-StudioManagedPlayers)
    $targets=@(if($action -in 'clear-ips','forget-all'){$players}else{$players | Where-Object sn -CEQ $Options.sn})
    if ($action -notin 'clear-ips','forget-all' -and $targets.Count -ne 1) {throw 'This board is not in the player directory. Refresh the list.'}
    if ($action -eq 'alias' -and ($Options.alias -isnot [string] -or $Options.alias.Trim().Length -gt 100 -or $Options.alias -match '[\x00-\x1f\x7f]')) {throw 'Use an alias of 100 characters or fewer, without control characters.'}
    if ($action -ne 'alias') {
        foreach($target in $targets) {
            if(Test-StudioNetworkPlayerReserved $target.sn $target.ip){throw 'Wait for queued board uploads to finish before forgetting players.'}
            if (@($script:networkJobs.Values | Where-Object {$_.status -eq 'running' -and ($_.sn -eq $target.sn -or ($target.ip -and $_.ip -eq $target.ip))}).Count) {
                throw 'Wait for the current board operation to finish before clearing or forgetting it.'
            }
        }
        if (@($script:networkJobs.Values | Where-Object {$_.status -eq 'running' -and $_.kind -eq 'discover'}).Count) {throw 'Wait for discovery to finish before clearing or forgetting players.'}
    }
    Update-StudioPlayerStore {
        param($store)
        foreach($target in $targets) {
            $record=[pscustomobject]@{sn=$target.sn;alias=$target.alias;deviceName=$target.deviceName;ip=$target.ip;model=$target.model
                width=$target.width;height=$target.height;source=$target.source;lastSeen=$target.lastSeen;forgotten=$false}
            switch($action) {
                'alias' {$record.alias=$Options.alias.Trim()}
                'forget' {$record.forgotten=$true;$record.ip=''}
                'forget-all' {$record.forgotten=$true;$record.ip=''}
                default {$record.ip=''}
            }
            $store.players=@($store.players | Where-Object sn -NE $target.sn)+@($record)
        }
    }
    if ($action -ne 'alias') {foreach($target in $targets){Remove-StudioPlayerConnections $target.sn}}
}

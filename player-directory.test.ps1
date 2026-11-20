# Isolated local state only. No player discovery, credentials, or live ViPlex data.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'StudioNetwork.ps1')
. (Join-Path $PSScriptRoot 'StudioPlayers.ps1')
function Assert-Directory([bool]$Condition,[string]$Message) {if(-not $Condition){throw "Test failed: $Message"}}
function Assert-DirectoryReject([scriptblock]$Action,[string]$Expected) {
    $message='';try {& $Action | Out-Null} catch {$message=$_.Exception.Message}
    Assert-Directory ($message -like "*$Expected*") "Expected '$Expected'; received '$message'."
}
function Get-StudioNetworkKnownPlayers([string]$ConfigRoot) {
    Assert-Directory ($ConfigRoot -ceq $script:fixtureConfig) 'The test tried to use a non-fixture ViPlex directory.'
    $script:nativeFixtures
}
function New-DirectoryDevice([string]$Serial,[string]$Address,[string]$Name=$Serial) {
    [pscustomobject]@{id=$Serial;sn=$Serial;name=$Name;ip=$Address;model='T50';width=320;height=1080;source='ViPlex';remembered=$true}
}
function Reset-DirectoryFixture([string]$Name) {
    $script:WorkspaceDirectory=[IO.Directory]::CreateDirectory((Join-Path $script:fixtureRoot $Name)).FullName
    $script:configRoot=$script:fixtureConfig
    $script:networkConnections=@{};$script:networkJobs=@{}
    $script:nativeFixtures=@((New-DirectoryDevice 'BOARD-A' '192.168.1.24' 'Native A'),(New-DirectoryDevice 'BOARD-B' '192.168.1.25' 'Native B'))
}
function Get-DirectoryPlayer([string]$Serial) {@(Get-StudioManagedPlayers | Where-Object sn -CEQ $Serial) | Select-Object -First 1}
function Add-DirectoryConnection([string]$Id,[string]$Serial,[string]$Address,[double]$Age=0) {
    $script:networkConnections[$Id]=@{device=(New-DirectoryDevice $Serial $Address);created=[datetime]::UtcNow.AddMinutes(-$Age);certificateSha256='fixture-pin'}
}

$fixtureParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureLeaf='RelayPlayerDirectoryTest-'+[guid]::NewGuid().ToString('N')
$script:fixtureRoot=[IO.Directory]::CreateDirectory((Join-Path $fixtureParent $fixtureLeaf)).FullName
$script:fixtureConfig=[IO.Directory]::CreateDirectory((Join-Path $script:fixtureRoot 'native-fixture')).FullName
try {
    Reset-DirectoryFixture 'aliases'
    Assert-Directory (@(Get-StudioManagedPlayers).Count -eq 2) 'Remembered players were not merged.'
    Set-StudioPlayerDirectory ([pscustomobject]@{action='alias';sn='BOARD-A';alias='  Lobby left  '})
    $a=Get-DirectoryPlayer 'BOARD-A'
    Assert-Directory ($a.alias -ceq 'Lobby left' -and $a.name -ceq 'Lobby left' -and $a.deviceName -ceq 'Native A') 'Alias was not trimmed or changed device identity.'
    Add-DirectoryConnection 'old-a' 'BOARD-A' '192.168.1.24'
    Add-DirectoryConnection 'b' 'BOARD-B' '192.168.1.25'
    Save-StudioDiscoveredPlayers @((New-DirectoryDevice 'BOARD-A' '192.168.1.124' 'Updated device name'))
    $a=Get-DirectoryPlayer 'BOARD-A'
    Assert-Directory ($a.alias -ceq 'Lobby left' -and $a.ip -ceq '192.168.1.124' -and $a.deviceName -ceq 'Updated device name') 'Discovery lost an alias after an IP change.'
    Assert-Directory (-not $script:networkConnections.ContainsKey('old-a') -and $script:networkConnections.ContainsKey('b')) 'IP change invalidated the wrong board connection.'
    $saved=Read-StudioPlayerStore
    Assert-Directory (@($saved.players | Where-Object sn -CEQ 'BOARD-A').Count -eq 1) 'IP changes duplicated the serial in storage.'
    Assert-Directory ([IO.File]::Exists((Get-StudioPlayerStorePath)+'.bak')) 'Directory edits did not keep a previous backup.'
    Assert-Directory ([IO.File]::ReadAllText((Get-StudioPlayerStorePath)) -notmatch 'fixture-pin|connectionId|password') 'Persistent player directory leaked connection secrets.'
    # A fresh in-memory connection table models a launcher restart.
    $script:networkConnections=@{}
    Assert-Directory ((Get-DirectoryPlayer 'BOARD-A').alias -ceq 'Lobby left') 'Alias did not survive a new read without sessions.'

    Reset-DirectoryFixture 'clear-one'
    Add-DirectoryConnection 'a' 'BOARD-A' '192.168.1.24'
    Add-DirectoryConnection 'b' 'BOARD-B' '192.168.1.25'
    Set-StudioPlayerDirectory ([pscustomobject]@{action='clear-ip';sn='BOARD-A'})
    Assert-Directory ((Get-DirectoryPlayer 'BOARD-A').ip -ceq '' -and (Get-DirectoryPlayer 'BOARD-B').ip -ceq '192.168.1.25') 'Cleared IP was repopulated from stale ViPlex data or changed another board.'
    Assert-Directory (-not $script:networkConnections.ContainsKey('a') -and $script:networkConnections.ContainsKey('b')) 'Clearing one IP invalidated other sessions.'
    Save-StudioDiscoveredPlayers @((New-DirectoryDevice 'BOARD-A' '192.168.1.44'))
    Assert-Directory ((Get-DirectoryPlayer 'BOARD-A').ip -ceq '192.168.1.44') 'Rediscovery failed to populate a cleared IP.'
    Set-StudioPlayerDirectory ([pscustomobject]@{action='alias';sn='BOARD-A';alias='Tile A'})
    Add-DirectoryConnection 'a-new' 'BOARD-A' '192.168.1.44'
    Set-StudioPlayerDirectory ([pscustomobject]@{action='clear-ips'})
    $players=@(Get-StudioManagedPlayers)
    Assert-Directory ($players.Count -eq 2 -and @($players | Where-Object ip).Count -eq 0 -and $script:networkConnections.Count -eq 0) 'Clear saved IPs did not clear all visible boards and sessions.'
    Assert-Directory ((Get-DirectoryPlayer 'BOARD-A').alias -ceq 'Tile A') 'Clearing IPs lost aliases.'

    Reset-DirectoryFixture 'forget'
    Set-StudioPlayerDirectory ([pscustomobject]@{action='alias';sn='BOARD-A';alias='Stage left'})
    Add-DirectoryConnection 'a' 'BOARD-A' '192.168.1.24'
    Add-DirectoryConnection 'b' 'BOARD-B' '192.168.1.25'
    Set-StudioPlayerDirectory ([pscustomobject]@{action='forget';sn='BOARD-A'})
    Assert-Directory ($null -eq (Get-DirectoryPlayer 'BOARD-A') -and @(Get-StudioManagedPlayers).Count -eq 1) 'Forgotten board reappeared from ViPlex.'
    Assert-Directory (-not $script:networkConnections.ContainsKey('a') -and $script:networkConnections.ContainsKey('b')) 'Forgetting a board affected another connection.'
    Save-StudioDiscoveredPlayers @((New-DirectoryDevice 'BOARD-A' '192.168.1.60' 'Rediscovered'))
    $a=Get-DirectoryPlayer 'BOARD-A'
    Assert-Directory ($a.alias -ceq 'Stage left' -and $a.ip -ceq '192.168.1.60' -and @(Get-StudioManagedPlayers).Count -eq 2) 'Rediscovery did not restore the forgotten board and its alias.'

    Reset-DirectoryFixture 'sessions'
    Add-DirectoryConnection 'a-live' 'BOARD-A' '192.168.1.24' 29
    Add-DirectoryConnection 'b-live' 'BOARD-B' '192.168.1.25' 4
    Assert-Directory ((Get-DirectoryPlayer 'BOARD-A').connected -and (Get-DirectoryPlayer 'BOARD-B').connected) 'Two board sessions were not independently available.'
    $script:networkConnections['a-live'].created=[datetime]::UtcNow.AddMinutes(-31)
    Assert-Directory (-not (Get-DirectoryPlayer 'BOARD-A').connected -and (Get-DirectoryPlayer 'BOARD-B').connectionId -ceq 'b-live') 'Expiring one session disconnected another board.'
    Update-StudioNetworkJobs
    Assert-Directory (-not $script:networkConnections.ContainsKey('a-live') -and $script:networkConnections.ContainsKey('b-live')) 'Expired-session cleanup removed a current session.'
    # A DHCP address can move to another serial: its previous pinned session must stop being offered.
    Save-StudioDiscoveredPlayers @((New-DirectoryDevice 'BOARD-C' '192.168.1.25'))
    Assert-Directory (-not $script:networkConnections.ContainsKey('b-live')) 'A session survived its IP being observed on another serial.'

    Reset-DirectoryFixture 'validation'
    foreach($badAlias in @((('a')*101),"bad`nname",[int]42,$null)) {
        Assert-DirectoryReject {Set-StudioPlayerDirectory ([pscustomobject]@{action='alias';sn='BOARD-A';alias=$badAlias})} 'alias'
    }
    Assert-DirectoryReject {Set-StudioPlayerDirectory ([pscustomobject]@{action='alias';sn='UNKNOWN';alias='Name'})} 'not in the player directory'
    Assert-DirectoryReject {Set-StudioPlayerDirectory ([pscustomobject]@{action='arbitrary';sn='BOARD-A'})} 'supported player action'
    Save-StudioDiscoveredPlayers @((New-DirectoryDevice 'BAD SERIAL!' '192.168.1.30'),(New-DirectoryDevice 'PUBLIC' '8.8.8.8'))
    Assert-Directory (@(Get-StudioManagedPlayers).Count -eq 2) 'Invalid discovered identity/address entered the directory.'
    Set-StudioPlayerDirectory ([pscustomobject]@{action='alias';sn='BOARD-A';alias='Temporary'})
    Set-StudioPlayerDirectory ([pscustomobject]@{action='alias';sn='BOARD-A';alias=' '})
    Assert-Directory ((Get-DirectoryPlayer 'BOARD-A').name -ceq 'Native A') 'Clearing an alias did not restore the device name.'

    Reset-DirectoryFixture 'active-jobs'
    $script:networkJobs['upload']=@{kind='publish';status='running';sn='BOARD-A';ip='192.168.1.24'}
    foreach($directoryAction in @('clear-ip','forget','clear-ips')) {
        Assert-DirectoryReject {Set-StudioPlayerDirectory ([pscustomobject]@{action=$directoryAction;sn='BOARD-A'})} 'current*operation'
    }
    Set-StudioPlayerDirectory ([pscustomobject]@{action='alias';sn='BOARD-A';alias='During upload'})
    Assert-Directory ((Get-DirectoryPlayer 'BOARD-A').alias -ceq 'During upload') 'Renaming a board unnecessarily blocks its active upload.'
    Set-StudioPlayerDirectory ([pscustomobject]@{action='clear-ip';sn='BOARD-B'})
    Assert-Directory ((Get-DirectoryPlayer 'BOARD-B').ip -ceq '') 'An unrelated active board blocked clearing another IP.'
    $script:networkJobs=@{discovery=@{kind='discover';status='running'}}
    Assert-DirectoryReject {Set-StudioPlayerDirectory ([pscustomobject]@{action='forget';sn='BOARD-B'})} 'discovery'
    $script:networkJobs=@{}
    Set-StudioPlayerDirectory ([pscustomobject]@{action='forget';sn='BOARD-B'})
    Assert-Directory ($null -eq (Get-DirectoryPlayer 'BOARD-B')) 'Forgetting remained blocked after jobs finished.'

    Reset-DirectoryFixture 'forget-all'
    Set-StudioPlayerDirectory ([pscustomobject]@{action='alias';sn='BOARD-A';alias='Stage left'})
    $script:networkBatches=@{fixture=@{status='running';targets=@(@{sn='BOARD-A';ip='192.168.1.24';status='queued'})}}
    Assert-DirectoryReject {Set-StudioPlayerDirectory ([pscustomobject]@{action='forget-all'})} 'queued'
    Assert-Directory (@(Get-StudioManagedPlayers).Count -eq 2) 'Blocked Forget all partially removed players.'
    $script:networkBatches=@{}
    Set-StudioPlayerDirectory ([pscustomobject]@{action='forget-all'})
    Assert-Directory (@(Get-StudioManagedPlayers).Count -eq 0 -and $script:networkConnections.Count -eq 0) 'Forget all retained visible ViPlex players or active connections.'
    Assert-Directory (@(Get-StudioManagedPlayers).Count -eq 0) 'Forgotten native players reappeared on reload.'
    Save-StudioDiscoveredPlayers @((New-DirectoryDevice 'BOARD-A' '192.168.1.44'))
    Assert-Directory (@(Get-StudioManagedPlayers).Count -eq 1 -and (Get-DirectoryPlayer 'BOARD-A').alias -ceq 'Stage left') 'Rediscovery after Forget all did not restore the chosen board and alias.'

    # Exercise the actual route dispatcher with its request-authentication helper
    # stubbed. Worker launch is replaced, so discovery cannot send network traffic.
    & {
        function Update-StudioNetworkJobs {}
        function Read-StudioJsonRequest($Request,$Response) {
            $script:bodyReads++
            if($script:apiReject){Write-StudioJson $Response @{error='Rejected fixture request'} $script:apiReject;return}
            $script:apiPayload
        }
        function Write-StudioJson($Response,$Body,[int]$Status=200) {$script:apiResponse=@{status=$Status;body=$Body}}
        function Start-StudioNetworkJob($Kind,$Options) {$script:apiStarts++;$script:apiKind=$Kind;$script:apiOptions=$Options;'11111111111111111111111111111111'}
        function Reset-PlayerApi {
            $script:networkJobs=@{};$script:networkConnections=@{};$script:apiReject=0;$script:bodyReads=0
            $script:apiStarts=0;$script:apiKind='';$script:apiOptions=$null;$script:apiResponse=$null;$script:apiPayload=[pscustomobject]@{}
        }
        function Invoke-PlayerApi([string]$Path,[string]$Method='POST') {Invoke-StudioNetworkRequest ([pscustomobject]@{HttpMethod=$Method}) $null $Path}
        Reset-DirectoryFixture 'api'
        foreach($route in @('/api/network/player','/api/network/discover')) {
            Reset-PlayerApi
            $script:apiReject=403
            $script:apiPayload=[pscustomobject]@{action='alias';sn='BOARD-A';alias='Unauthorized alias'}
            Invoke-PlayerApi $route
            Assert-Directory ($script:apiResponse.status -eq 403 -and $script:apiStarts -eq 0 -and (Get-DirectoryPlayer 'BOARD-A').alias -ceq '') 'Rejected request reached discovery or directory mutation.'
            Reset-PlayerApi
            $script:apiPayload=[pscustomobject]@{action='clear-ip';sn='BOARD-A'}
            Invoke-PlayerApi $route 'GET'
            Assert-Directory ($script:apiResponse.status -eq 404 -and $script:apiStarts -eq 0 -and $script:bodyReads -eq 0 -and (Get-DirectoryPlayer 'BOARD-A').ip -ceq '192.168.1.24') 'GET request performed a mutation or launched discovery.'
        }
        Reset-PlayerApi
        Invoke-PlayerApi '/api/network/discover'
        Assert-Directory ($script:apiResponse.status -eq 202 -and $script:apiStarts -eq 1 -and $script:apiKind -ceq 'discover') 'Discovery unexpectedly required a player password.'
        Assert-Directory (-not $script:apiOptions.PSObject.Properties['playerPassword']) 'Discovery was supplied a player password.'
        Reset-PlayerApi
        $runningId='22222222222222222222222222222222'
        $script:networkJobs[$runningId]=@{id=$runningId;kind='discover';status='running'}
        1..3 | ForEach-Object {$script:networkJobs["other$_"]=@{kind='check';status='running';sn="OTHER$_";ip="192.168.3.$_"}}
        Invoke-PlayerApi '/api/network/discover'
        Assert-Directory ($script:apiResponse.status -eq 202 -and $script:apiResponse.body.jobId -ceq $runningId -and $script:apiStarts -eq 0) 'Repeated discovery started another scan or failed when reusing its running job.'
        Reset-PlayerApi
        1..4 | ForEach-Object {$script:networkJobs["other$_"]=@{kind='check';status='running';sn="OTHER$_";ip="192.168.3.$_"}}
        Invoke-PlayerApi '/api/network/discover'
        Assert-Directory ($script:apiResponse.status -eq 422 -and $script:apiStarts -eq 0) 'Discovery bypassed the four-worker limit.'
        Reset-PlayerApi
        $script:apiPayload=[pscustomobject]@{action='alias';sn='BOARD-A';alias='API alias'}
        Invoke-PlayerApi '/api/network/player'
        Assert-Directory ($script:apiResponse.status -eq 200 -and (Get-DirectoryPlayer 'BOARD-A').alias -ceq 'API alias') 'Authenticated directory alias route did not persist.'
        $script:apiPayload=[pscustomobject]@{action='clear-ip';sn='BOARD-A'}
        Invoke-PlayerApi '/api/network/player'
        Assert-Directory ($script:apiResponse.status -eq 200 -and (Get-DirectoryPlayer 'BOARD-A').ip -ceq '' -and $script:apiStarts -eq 0) 'Directory IP clearing failed or started hardware work.'
        Invoke-PlayerApi '/api/network/players' 'GET'
        Assert-Directory ($script:apiResponse.status -eq 200 -and $script:apiResponse.body.available -and @($script:apiResponse.body.players).Count -eq 2) 'Players GET did not expose the managed directory.'
    }

    'Player directory persistence, aliases, IP clearing, forgetting/rediscovery, independent sessions, expiry, active-operation guards and API checks passed.'
} catch {
    Write-Output $_.ScriptStackTrace
    throw
} finally {
    $expected=[IO.Path]::GetFullPath((Join-Path $fixtureParent $fixtureLeaf))
    if($script:fixtureRoot -ceq $expected -and [IO.Path]::GetDirectoryName($script:fixtureRoot) -ceq $fixtureParent) {
        $links=@(Get-Item -LiteralPath $script:fixtureRoot;Get-ChildItem -LiteralPath $script:fixtureRoot -Force -Recurse)|Where-Object {($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0}
        if(-not $links){[IO.Directory]::Delete($script:fixtureRoot,$true)}
    }
}

# Isolated API/worker tests: all network sessions, jobs, and staging dependencies
# are synthetic. Run in a fresh powershell.exe process; no device is contacted.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StudioNetwork.ps1')
function Assert-NetworkApi([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "Test failed: $Message" } }
function Assert-NetworkFailure([scriptblock]$Action,[string]$Expected) {
    $message=''
    try { & $Action } catch { $message=$_.Exception.Message }
    Assert-NetworkApi ($message -like "*$Expected*") "Expected '$Expected'; got '$message'."
}

foreach($ip in @('10.0.0.8','172.16.0.8','172.31.0.8','192.168.41.1','169.254.10.8','100.64.10.8','100.127.10.8')) {
    Assert-NetworkApi (Test-StudioNetworkAddress $ip) "Local IPv4 address rejected: $ip"
}
foreach($ip in @('8.8.8.8','127.0.0.1','0.0.0.0','192.168.1.0','192.168.1.255','192.168.001.8','172.32.1.8','100.128.1.8','localhost','https://192.168.1.8','::1','192.168.1.256')) {
    Assert-NetworkApi (-not (Test-StudioNetworkAddress $ip)) "Invalid/public IPv4 address accepted: $ip"
}

& {
    function Update-StudioNetworkJobs { }
    function Read-StudioJsonRequest($Request,$Response) {
        if ($script:rejectRequest) { Write-StudioJson $Response @{error='Synthetic request rejection'} $script:rejectRequest; return }
        $script:payload
    }
    function Write-StudioJson($Response,$Body,[int]$Status=200) { $script:response=@{status=$Status;body=$Body} }
    function Test-StudioProject($Project) { $Project.version -eq 1 -and $Project.screens -is [array] -and $Project.solutions -is [array] -and $Project.cues -is [array] }
    function Get-StudioCachedCatalog { @{data=@{solutions=@([pscustomobject]@{id='solution-1';name='Fixture';width=$script:catalogWidth;height=1080;source=@{kind='localVideo'}})}} }
    function Start-StudioNetworkJob($Kind,$Options) { $script:started++;$script:jobOptions=$Options;$script:jobKind=$Kind;'11111111111111111111111111111111' }
    function New-ApiFixture {
        $script:networkJobs=@{};$script:networkConnections=@{};$script:started=0;$script:response=$null;$script:rejectRequest=0;$script:jobOptions=$null;$script:catalogWidth=320
        $script:payload=[pscustomobject]@{ip='192.168.1.8';expectedSn='fixture-sn';playerPassword='fixture-private-password'}
    }
    function Invoke-ApiFixture([string]$Path='/api/network/check') { Invoke-StudioNetworkRequest ([pscustomobject]@{HttpMethod='POST'}) $null $Path }
    function New-PublishFixture {
        New-ApiFixture
        $script:networkConnections['connection-fixture']=@{device=@{sn='fixture-sn';ip='192.168.1.8';name='Test player';width=320;height=1080;model='T50'};certificateSha256=('A'*64);created=[datetime]::UtcNow}
        $script:payload=[pscustomobject]@{
            connectionId='connection-fixture';programType='solution';programId='solution-1';playerPassword='fixture-private-password'
            device=@{sn='client-forged-sn';ip='8.8.8.8'};certificateSha256='client-forged-pin'
            project=[pscustomobject]@{version=1;solutions=@([pscustomobject]@{id='solution-1';width=999;height=999});screens=@([pscustomobject]@{id='screen-1';width=320;height=1080});cues=@()}
        }
    }
    function New-ControlFixture {
        New-PublishFixture
        $script:payload | Add-Member -NotePropertyName section -NotePropertyValue 'brightness'
        $script:payload | Add-Member -NotePropertyName values -NotePropertyValue ([pscustomobject]@{ratio=42})
        $script:payload | Add-Member -NotePropertyName ip -NotePropertyValue '8.8.8.8'
    }
    foreach($status in @(400,403)) {
        New-ApiFixture;$script:rejectRequest=$status;Invoke-ApiFixture
        Assert-NetworkApi ($script:response.status -eq $status -and $script:started -eq 0) 'Rejected authentication/body reached worker launch.'
    }
    New-ApiFixture;$script:payload.ip='8.8.8.8';Invoke-ApiFixture
    Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) 'Public address was queued.'
    New-ApiFixture;$script:payload.expectedSn='../other';Invoke-ApiFixture
    Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) 'Malformed serial was queued.'
    New-ApiFixture;$script:payload.playerPassword='';Invoke-ApiFixture
    Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) 'Missing password was queued.'
    New-ApiFixture;Invoke-ApiFixture
    Assert-NetworkApi ($script:response.status -eq 202 -and $script:started -eq 1 -and $script:jobKind -eq 'check') 'Valid connection check was not queued.'
    Assert-NetworkApi (($script:response.body | ConvertTo-Json) -notmatch 'fixture-private|certificate|password|token' -and $null -eq $script:payload.playerPassword) 'Connection response leaked credentials or input retained password.'
    foreach($same in @('ip','sn')) {
        New-ApiFixture
        $script:networkJobs.busy=@{status='running';ip=$(if($same -eq 'ip'){'192.168.1.8'}else{'192.168.1.9'});sn='fixture-sn'}
        Invoke-ApiFixture
        Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) "Concurrent check for same $same was queued."
    }
    New-PublishFixture;$script:payload.connectionId='unknown';Invoke-ApiFixture '/api/network/publish'
    Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) 'Unknown connection identity was accepted.'
    New-PublishFixture;Invoke-ApiFixture '/api/network/publish'
    Assert-NetworkApi ($script:response.status -eq 202 -and $script:started -eq 1) 'Valid publish was not queued.'
    Assert-NetworkApi ($script:jobOptions.device.sn -ceq 'fixture-sn' -and $script:jobOptions.device.ip -ceq '192.168.1.8' -and $script:jobOptions.certificateSha256 -ceq ('A'*64)) 'Client overrode verified player identity or certificate.'
    Assert-NetworkApi ($script:jobOptions.project.solutions[0].width -eq 320) 'Client overrode canonical library data.'
    Assert-NetworkApi (($script:response.body | ConvertTo-Json) -notmatch 'fixture-private|certificate|password|token') 'Publish response leaked credentials.'
    New-PublishFixture;$script:catalogWidth=1920;Invoke-ApiFixture '/api/network/publish'
    Assert-NetworkApi ($script:response.status -eq 202 -and $script:started -eq 1 -and $script:jobOptions.project.solutions[0].width -eq 1920 -and $script:jobOptions.device.width -eq 320) 'A larger solution canvas was blocked or resized to the player output.'
    Assert-NetworkApi ($script:jobOptions.device.sn -ceq 'fixture-sn' -and $script:jobOptions.certificateSha256 -ceq ('A'*64)) 'A canvas mismatch bypassed verified player identity.'
    New-PublishFixture;$script:payload.programType='schedule';$script:payload.programId='screen-1';$script:payload.project.screens[0].width=1920;Invoke-ApiFixture '/api/network/publish'
    Assert-NetworkApi ($script:response.status -eq 202 -and $script:started -eq 1 -and $script:jobOptions.project.screens[0].width -eq 1920 -and $script:jobOptions.device.width -eq 320) 'A larger schedule canvas was blocked or resized to the player output.'
    New-PublishFixture;$script:payload.project.version=0;Invoke-ApiFixture '/api/network/publish'
    Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) 'Malformed project was queued.'
    New-PublishFixture;$script:payload.programType='unknown';Invoke-ApiFixture '/api/network/publish'
    Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) 'Unsupported program type was queued.'
    foreach($same in @('ip','sn')) {
        New-PublishFixture
        $script:networkJobs.busy=@{status='running';ip=$(if($same -eq 'ip'){'192.168.1.8'}else{'192.168.1.9'});sn='fixture-sn'}
        Invoke-ApiFixture '/api/network/publish'
        Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) "Concurrent publish for same $same was queued."
    }
    foreach($route in @('/api/network/controls/read','/api/network/controls/apply')) {
        foreach($status in @(400,403)) {
            New-ControlFixture;$script:rejectRequest=$status;Invoke-ApiFixture $route
            Assert-NetworkApi ($script:response.status -eq $status -and $script:started -eq 0) "Control route $route bypassed request authentication/body validation."
        }
        New-ControlFixture;$script:payload.connectionId='unknown';Invoke-ApiFixture $route
        Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) 'Control route accepted an unchecked connection.'
        New-ControlFixture;$script:payload.playerPassword='';Invoke-ApiFixture $route
        Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) 'Control route accepted an empty password.'
        New-ControlFixture;Invoke-ApiFixture $route
        $expectedKind=if($route.EndsWith('/apply')){'controls-apply'}else{'controls-read'}
        Assert-NetworkApi ($script:response.status -eq 202 -and $script:started -eq 1 -and $script:jobKind -ceq $expectedKind) 'Valid control operation was not queued.'
        Assert-NetworkApi ($script:jobOptions.device.ip -ceq '192.168.1.8' -and $script:jobOptions.device.sn -ceq 'fixture-sn' -and $script:jobOptions.certificateSha256 -ceq ('A'*64)) 'Control client overrode checked IP, serial, or certificate.'
        Assert-NetworkApi ($script:jobOptions.playerPassword -ceq 'fixture-private-password' -and $null -eq $script:payload.playerPassword) 'Control credentials were lost before dispatch or retained in API input.'
        Assert-NetworkApi (($script:response.body | ConvertTo-Json) -notmatch 'fixture-private|certificate|password|token') 'Control dispatch response leaked credentials.'
        foreach($same in @('ip','sn')) {
            New-ControlFixture
            $script:networkJobs.busy=@{kind='publish';status='running';ip=$(if($same -eq 'ip'){'192.168.1.8'}else{'192.168.1.9'});sn='fixture-sn'}
            Invoke-ApiFixture $route
            Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) "Control operation bypassed the shared $same busy guard."
        }
        New-ControlFixture
        1..4 | ForEach-Object {$script:networkJobs["busy$_"]=@{status='running';ip="192.168.2.$_";sn="other$_"}}
        Invoke-ApiFixture $route
        Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) 'Control operation bypassed the worker limit.'
        New-ControlFixture
        Invoke-StudioNetworkRequest ([pscustomobject]@{HttpMethod='GET'}) $null $route
        Assert-NetworkApi ($script:response.status -eq 404 -and $script:started -eq 0) 'Control operation accepted a GET mutation/read request.'
    }
    New-PublishFixture
    Invoke-ApiFixture '/api/network/preview'
    Assert-NetworkApi ($script:response.status -eq 202 -and $script:jobKind -ceq 'preview' -and $script:jobOptions.device.sn -ceq 'fixture-sn' -and $script:jobOptions.certificateSha256 -ceq ('A'*64)) 'Preview did not use the checked player identity and pin.'
    Assert-NetworkApi ($null -eq $script:payload.playerPassword -and ($script:response.body | ConvertTo-Json) -notmatch 'fixture-private|certificate|password') 'Preview route retained or exposed credentials.'
    New-PublishFixture;$script:rejectRequest=403;Invoke-ApiFixture '/api/network/preview'
    Assert-NetworkApi ($script:response.status -eq 403 -and $script:started -eq 0) 'Preview bypassed protected request validation.'
    New-PublishFixture;$script:payload.connectionId='unknown';Invoke-ApiFixture '/api/network/preview'
    Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) 'Preview accepted an unchecked player.'
    New-PublishFixture
    $script:networkBatches=@{fixture=@{status='running';targets=@(@{sn='fixture-sn';ip='192.168.1.8';status='queued'})}}
    Invoke-ApiFixture '/api/network/preview'
    Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) 'Preview interrupted a reserved upload.'
    $script:networkBatches=@{}

    foreach($section in @('brightness','colorTemperature','mosaic','time','ethernet')) {
        New-ControlFixture;$script:payload.section=$section;Invoke-ApiFixture '/api/network/controls/apply'
        Assert-NetworkApi ($script:response.status -eq 202 -and $script:jobOptions.section -ceq $section -and $script:jobOptions.values.ratio -eq 42) "Supported $section section was rejected or values changed before worker validation."
    }
    foreach($section in @('wifi','Brightness','../login','')) {
        New-ControlFixture;$script:payload.section=$section;Invoke-ApiFixture '/api/network/controls/apply'
        Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) 'Unsupported control section was queued.'
    }
    foreach($values in @($null,'{}',42,@(1,2))) {
        New-ControlFixture;$script:payload.values=$values;Invoke-ApiFixture '/api/network/controls/apply'
        Assert-NetworkApi ($script:response.status -eq 422 -and $script:started -eq 0) 'Non-object control values were queued.'
    }
}

# Exercise long-running job completion without starting an operating-system job.
& {
    function Receive-Job($Job) { if(-not $Job.drained){$Job.drained=$true;$script:queuedEvent} }
    function Remove-Job($Job,[switch]$Force) { $script:removedJobs++ }
    function Remove-StudioNetworkWorkDirectory($Directory,$Parent) { $script:removedDirectories++ }
    $script:networkJobs=@{};$script:networkConnections=@{};$script:removedJobs=0;$script:removedDirectories=0
    $jobId='22222222222222222222222222222222'
    $script:networkJobs[$jobId]=@{id=$jobId;kind='publish';status='running';created=[datetime]::UtcNow.AddHours(-2);work=[IO.Path]::GetTempPath();parent=[IO.Path]::GetTempPath();native=[pscustomobject]@{State='Running';drained=$false}}
    $script:queuedEvent=@{event='complete';device=@{sn='fixture-sn'};name='Fixture';message='Complete';receipt=@{mediaUploaded=1}}
    Update-StudioNetworkJobs
    Assert-NetworkApi ($script:networkJobs.ContainsKey($jobId) -and $script:networkJobs[$jobId].status -eq 'complete') 'Long upload lost completion before user could read it.'
    Assert-NetworkApi ($script:removedJobs -eq 0) 'Worker was killed before its finally block finished.'
    $script:networkJobs[$jobId].native.State='Completed'
    Update-StudioNetworkJobs
    Assert-NetworkApi ($script:removedJobs -eq 1 -and $script:removedDirectories -eq 1) 'Finished worker did not clean up exactly once.'
    Update-StudioNetworkJobs
    Assert-NetworkApi ($script:removedJobs -eq 1) 'Terminal worker cleanup repeated.'
    $script:networkJobs[$jobId].finished=[datetime]::UtcNow.AddHours(-2)
    Update-StudioNetworkJobs
    Assert-NetworkApi (-not $script:networkJobs.ContainsKey($jobId)) 'Old completion was not expired.'
}

# Fresh-process fake class: the real HTTP/UDP transport is never loaded.
if ('RelayNetworkSession' -as [type]) { throw 'Run network-api.test.ps1 in a fresh PowerShell process.' }
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class RelayNetworkTransport { }
public sealed class RelayNetworkDevice {
    public string Sn="fixture-sn", Ip="192.168.1.8", Name="Test player", Model="T50";
    public string CertificateSha256;
    public int Width=320, Height=1080, HttpsPort;
}
public sealed class RelayNetworkSession : IDisposable {
    public RelayNetworkDevice Device = new RelayNetworkDevice();
    public static int Width=320, Instances, Starts, Ends, Uploads, Disposals, FailUploadAt, LastHttpsPort, VerifiedInstances;
    public static string StartResponse, EndResponse, StartRequest, EndRequest, LastIp, LastSn, LastPin, IdentityFailure;
    public static List<string> Uploaded = new List<string>();
    public RelayNetworkSession(string ip,string password,string sn,string pin) {
        if(String.IsNullOrEmpty(password)) throw new ArgumentException("Enter the player password.");
        Instances++; LastIp=ip; LastSn=sn; LastPin=pin;
        if(IdentityFailure!=null) throw new InvalidOperationException(IdentityFailure);
        Device.Width=Width;
    }
    public RelayNetworkSession(RelayNetworkDevice checkedDevice,string password)
        : this(checkedDevice.Ip,password,checkedDevice.Sn,checkedDevice.CertificateSha256) {
        LastHttpsPort=checkedDevice.HttpsPort;VerifiedInstances++;
    }
    public string StartTransfer(string request) { Starts++; StartRequest=request; return StartResponse; }
    public string UploadFile(string path,string directory,string name,Action<long,long> progress) {
        Uploads++; if(FailUploadAt==Uploads) throw new InvalidOperationException("Synthetic upload failure");
        Uploaded.Add(name); if(progress!=null) progress(64,64); return "{}";
    }
    public string EndTransfer(string request) { Ends++;EndRequest=request;return EndResponse; }
    public void Dispose() { Disposals++; }
    public static void Reset() { Width=320;Instances=Starts=Ends=Uploads=Disposals=FailUploadAt=LastHttpsPort=VerifiedInstances=0;Uploaded.Clear();StartRequest=EndRequest=LastIp=LastSn=LastPin=IdentityFailure=null; }
}
public sealed class FixtureNetworkMutex : IDisposable {
    readonly System.Threading.ManualResetEvent acquired=new System.Threading.ManualResetEvent(false), release=new System.Threading.ManualResetEvent(false);
    readonly System.Threading.Thread thread;
    public FixtureNetworkMutex(string name) {
        thread=new System.Threading.Thread(delegate() {using(var mutex=new System.Threading.Mutex(false,name)){mutex.WaitOne();acquired.Set();release.WaitOne();mutex.ReleaseMutex();}});
        thread.IsBackground=true;thread.Start();if(!acquired.WaitOne(5000))throw new Exception("Fixture mutex was not acquired.");
    }
    public void Dispose(){release.Set();if(!thread.Join(5000))throw new Exception("Fixture mutex did not stop.");acquired.Dispose();release.Dispose();}
}
'@
$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempLeaf='RelayNetworkApiTest-'+[guid]::NewGuid().ToString('N')
$tempRoot=[IO.Directory]::CreateDirectory((Join-Path $tempParent $tempLeaf)).FullName
try {
    & {
        function Export-StudioNetworkProgram($ConfigRoot,$Project,$ProgramType,$ProgramId,$OutputDirectory) {
            [pscustomobject]@{name='Fixture';width=$script:packageWidth;height=1080;totalSize=128;totalMediaSize=128
                programInfo=@{identifier=('a'*32);thumbnailName='cover.png'}
                mediaFiles=@([pscustomobject]@{fileName=('b'*32)+'.mp4';path='synthetic-media-1';size=64},[pscustomobject]@{fileName=('c'*32)+'.mp4';path='synthetic-media-2';size=64})
                programFiles=@([pscustomobject]@{fileName='planlist.json';path='synthetic-plan';size=64},[pscustomobject]@{fileName='cover.png';path='synthetic-cover';size=64})}
        }
        function Reset-TransferFixture {
            [RelayNetworkSession]::Reset()
            $script:packageWidth=320
            $script:startData=@{canTranster=$true;errorCode=0;appliedInfos=@{statusCode=0;name='Fixture';identifier=('a'*32);uploadUrl='sdcard/nova/viplex_terminal/program/program_fixture/temp_Fixture'};uploadMediaUrl='sdcard/nova/viplex_terminal/media';checkFiles=@(('b'*32)+'.mp4')}
            [RelayNetworkSession]::EndResponse='{"errorType":0,"errorStr":"SUCCESS"}'
        }
        function Invoke-TransferFixture {
            [RelayNetworkSession]::StartResponse=$script:startData | ConvertTo-Json -Depth 6 -Compress
            $work=[IO.Directory]::CreateDirectory((Join-Path $tempRoot ([guid]::NewGuid().ToString('N')))).FullName
            $options=[pscustomobject]@{project=@{};programType='solution';programId='fixture';device=@{sn='fixture-sn';ip='192.168.1.8'};playerPassword='fixture-private-password';certificateSha256=('A'*64)}
            Invoke-StudioNetworkTransfer $options $work 'synthetic-config'
        }
        Reset-TransferFixture
        $result=Invoke-TransferFixture
        Assert-NetworkApi ($result.event -eq 'complete' -and [RelayNetworkSession]::Ends -eq 1 -and [RelayNetworkSession]::Disposals -eq 1) 'Successful transfer did not finalize/dispose exactly once.'
        Assert-NetworkApi ([RelayNetworkSession]::VerifiedInstances -eq 1 -and [RelayNetworkSession]::LastHttpsPort -eq 16674) 'Transfer did not reconnect through the verified HTTPS device snapshot.'
        Assert-NetworkApi ($result.receipt.mediaUploaded -eq 1 -and $result.receipt.mediaReused -eq 1 -and [RelayNetworkSession]::Uploads -eq 3) 'Media reuse checklist was not honored.'
        $start=[RelayNetworkSession]::StartRequest | ConvertFrom-Json;$finish=[RelayNetworkSession]::EndRequest | ConvertFrom-Json
        Assert-NetworkApi ($start.solutions -is [pscustomobject] -and $start.checkFiles.Count -eq 2 -and $finish.confirmedInfos -is [pscustomobject] -and $finish.playImmediately) 'Native start/end object shape changed.'
        Assert-NetworkApi (($result | ConvertTo-Json -Depth 6) -notmatch 'fixture-private|certificate|password|token') 'Transfer receipt leaked credentials.'
        Reset-TransferFixture;$script:startData.checkFiles=@();$result=Invoke-TransferFixture
        Assert-NetworkApi ($result.receipt.mediaUploaded -eq 0 -and $result.receipt.mediaReused -eq 2 -and [RelayNetworkSession]::Uploads -eq 2) 'Empty checklist should reuse all existing media.'
        Reset-TransferFixture;[RelayNetworkSession]::FailUploadAt=2
        Assert-NetworkFailure {Invoke-TransferFixture} 'Synthetic upload failure'
        Assert-NetworkApi ([RelayNetworkSession]::Ends -eq 0 -and [RelayNetworkSession]::Disposals -eq 1) 'Upload failure activated playback or leaked session.'
        Reset-TransferFixture;$script:startData.checkFiles=@('unknown.mp4')
        Assert-NetworkFailure {Invoke-TransferFixture} 'unknown media file'
        Assert-NetworkApi ([RelayNetworkSession]::Uploads -eq 0 -and [RelayNetworkSession]::Ends -eq 0) 'Unknown checklist file was uploaded/finalized.'
        Reset-TransferFixture;$script:startData.checkFiles=('b'*32)+'.mp4'
        Assert-NetworkFailure {Invoke-TransferFixture} 'valid media checklist'
        Assert-NetworkApi ([RelayNetworkSession]::Ends -eq 0) 'Malformed checklist activated playback.'
        Reset-TransferFixture;$script:startData.appliedInfos.identifier=('d'*32)
        Assert-NetworkFailure {Invoke-TransferFixture} 'different program identity'
        Assert-NetworkApi ([RelayNetworkSession]::Uploads -eq 0 -and [RelayNetworkSession]::Ends -eq 0) 'Mismatched manifest was uploaded/finalized.'
        Reset-TransferFixture;$script:startData.canTranster=$false
        Assert-NetworkFailure {Invoke-TransferFixture} 'did not accept this transfer'
        Assert-NetworkApi ([RelayNetworkSession]::Ends -eq 0) 'Rejected transfer activated playback.'
        Reset-TransferFixture;$script:packageWidth=1920
        $result=Invoke-TransferFixture
        Assert-NetworkApi ($result.event -eq 'complete' -and [RelayNetworkSession]::Starts -eq 1 -and [RelayNetworkSession]::Ends -eq 1 -and $result.device.width -eq 320) 'A larger content canvas was blocked by the transfer worker.'
        Assert-NetworkApi ([RelayNetworkSession]::LastSn -ceq 'fixture-sn' -and [RelayNetworkSession]::LastPin -ceq ('A'*64)) 'The mismatched-size transfer omitted the checked serial or certificate.'
        Reset-TransferFixture;$script:packageWidth=1920;[RelayNetworkSession]::Width=640
        $result=Invoke-TransferFixture
        Assert-NetworkApi ($result.event -eq 'complete' -and $result.device.width -eq 640) 'A newly reported output size was treated as player identity.'
        Reset-TransferFixture;$script:packageWidth=1920;[RelayNetworkSession]::IdentityFailure='Synthetic player identity changed'
        Assert-NetworkFailure {Invoke-TransferFixture} 'Synthetic player identity changed'
        Assert-NetworkApi ([RelayNetworkSession]::Starts -eq 0 -and [RelayNetworkSession]::Uploads -eq 0 -and [RelayNetworkSession]::Ends -eq 0) 'Failed player identity verification reached transfer or playback.'
        Reset-TransferFixture;[RelayNetworkSession]::EndResponse='{"errorType":7,"errorStr":"FAILED"}'
        Assert-NetworkFailure {Invoke-TransferFixture} 'did not confirm playback'
        Assert-NetworkApi ([RelayNetworkSession]::Ends -eq 1 -and [RelayNetworkSession]::Disposals -eq 1) 'Rejected completion leaked session.'
        Reset-TransferFixture;[RelayNetworkSession]::EndResponse='null'
        $result=Invoke-TransferFixture
        Assert-NetworkApi ($result.event -eq 'complete' -and [RelayNetworkSession]::Ends -eq 1) 'Native null completion payload was incorrectly rejected.'
        Reset-TransferFixture;[RelayNetworkSession]::EndResponse='{}'
        Assert-NetworkFailure {Invoke-TransferFixture} 'missing status'
    }
    & {
        function Invoke-StudioBoardRead($Session) {$script:controlReads++;if($script:controlFailure){throw $script:controlFailure};@{brightness=@{available=$true;value=@{ratio=42}}}}
        function Invoke-StudioBoardApply($Session,$Section,$Values) {
            $script:controlApplies++;$script:lastSection=$Section;$script:lastValues=$Values
            if($script:controlFailure){throw $script:controlFailure}
            @{controls=@{brightness=@{available=$true;value=@{ratio=42}}};appliedSection=$Section;verified=$false;reconnectRequired=($Section -eq 'ethernet');message='Synthetic accepted settings'}
        }
        function Reset-ControlWorkerFixture {
            [RelayNetworkSession]::Reset();$script:controlReads=0;$script:controlApplies=0;$script:controlFailure=$null
            $script:controlOptions=[pscustomobject]@{device=@{ip='192.168.1.8';sn='fixture-sn'};certificateSha256=('A'*64);playerPassword='fixture-private-password';section='brightness';values=[pscustomobject]@{ratio=42}}
        }
        function Invoke-ControlWorkerFixture([string]$Kind) {
            $work=[IO.Directory]::CreateDirectory((Join-Path $tempRoot ([guid]::NewGuid().ToString('N')))).FullName
            Invoke-StudioNetworkControl $Kind $script:controlOptions $work
        }
        foreach($kind in @('controls-read','controls-apply')) {
            Reset-ControlWorkerFixture
            $result=Invoke-ControlWorkerFixture $kind
            Assert-NetworkApi ($result.event -ceq 'complete' -and $result.progress -eq 100 -and [RelayNetworkSession]::Disposals -eq 1) 'Control worker did not finish and dispose exactly once.'
            Assert-NetworkApi ([RelayNetworkSession]::VerifiedInstances -eq 1 -and [RelayNetworkSession]::LastHttpsPort -eq 16674) 'Control worker did not reconnect through the verified HTTPS device snapshot.'
            Assert-NetworkApi ([RelayNetworkSession]::LastIp -ceq '192.168.1.8' -and [RelayNetworkSession]::LastSn -ceq 'fixture-sn' -and [RelayNetworkSession]::LastPin -ceq ('A'*64)) 'Control worker omitted checked address, serial, or pin.'
            Assert-NetworkApi ([RelayNetworkSession]::Starts -eq 0 -and [RelayNetworkSession]::Uploads -eq 0 -and [RelayNetworkSession]::Ends -eq 0) 'Control operation reached playback transfer methods.'
            if($kind -eq 'controls-read') {Assert-NetworkApi ($script:controlReads -eq 1 -and $script:controlApplies -eq 0) 'Read control operation applied a setting.'}
            else {Assert-NetworkApi ($script:controlApplies -eq 1 -and $script:controlReads -eq 0 -and $script:lastSection -ceq 'brightness' -and $script:lastValues.ratio -eq 42 -and -not $result.verified) 'Apply control operation lost values or claimed unverified success.'}
            Assert-NetworkApi (($result | ConvertTo-Json -Depth 8) -notmatch 'fixture-private|certificate|password|token') 'Control worker receipt leaked credentials.'
            Reset-ControlWorkerFixture;[RelayNetworkSession]::IdentityFailure='Synthetic certificate or serial changed'
            Assert-NetworkFailure {Invoke-ControlWorkerFixture $kind} 'Synthetic certificate or serial changed'
            Assert-NetworkApi ($script:controlReads -eq 0 -and $script:controlApplies -eq 0) 'Control worker bypassed changed identity/pin failure.'
            Reset-ControlWorkerFixture;$script:controlFailure='Synthetic control failure'
            Assert-NetworkFailure {Invoke-ControlWorkerFixture $kind} 'Synthetic control failure'
            Assert-NetworkApi ([RelayNetworkSession]::Disposals -eq 1) 'Failed control operation leaked its session.'
        }
        Reset-ControlWorkerFixture;$script:controlOptions.section='ethernet'
        $result=Invoke-ControlWorkerFixture 'controls-apply'
        Assert-NetworkApi ($result.reconnectRequired -and -not $result.verified -and $result.appliedSection -ceq 'ethernet') 'Network reconnect/verification state was lost.'
        $hash=[Security.Cryptography.SHA256]::Create()
        try {$key=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes('fixture-sn'))).Replace('-','')}finally{$hash.Dispose()}
        foreach($kind in @('controls-read','controls-apply')) {
            Reset-ControlWorkerFixture
            $held=[FixtureNetworkMutex]::new('Local\RelayNetworkPlayer-'+$key)
            try {Assert-NetworkFailure {Invoke-ControlWorkerFixture $kind} 'Another Relay operation is already using this player'}finally{$held.Dispose()}
            Assert-NetworkApi ([RelayNetworkSession]::Instances -eq 0 -and $script:controlReads -eq 0 -and $script:controlApplies -eq 0) 'Busy player was connected to by a control worker.'
            $null=Invoke-ControlWorkerFixture $kind
            Assert-NetworkApi ([RelayNetworkSession]::Instances -eq 1 -and [RelayNetworkSession]::Disposals -eq 1) 'Control mutex was not reusable after busy failure.'
        }
        $public=Get-StudioNetworkJobSummary @{id='fixture';kind='controls-apply';status='complete';controls=@{brightness=@{available=$true;value=@{ratio=42}}};appliedSection='brightness';verified=$false;reconnectRequired=$true;certificateSha256=('A'*64);playerPassword='fixture-private-password';token='fixture-private-token';native='private-worker';work='private-path'}
        Assert-NetworkApi ($public.controls.brightness.value.ratio -eq 42 -and -not $public.verified -and $public.reconnectRequired) 'Public control summary lost useful result fields.'
        Assert-NetworkApi (($public | ConvertTo-Json -Depth 8) -notmatch 'fixture-private|certificate|password|token|private-worker|private-path') 'Public control summary exposed private worker fields.'
    }
    # Execute the real worker wrapper synchronously with a fake transport. This
    # checks failure redaction and finally cleanup without starting an OS job.
    & {
        function Start-Job([scriptblock]$ScriptBlock,$ArgumentList) {
            Assert-NetworkApi ($ArgumentList[2] -is [string]) 'Worker request was not snapshotted before asynchronous handoff.'
            # Match real asynchronous launch: the request owner releases its
            # credential before the worker consumes its private snapshot.
            $script:callerOptions.playerPassword=$null
            $script:workerEvents=@(& $ScriptBlock @ArgumentList)
            [pscustomobject]@{State='Completed';drained=$false}
        }
        function Receive-Job($Job) {if(-not $Job.drained){$Job.drained=$true;$script:workerEvents}}
        function Remove-Job($Job,[switch]$Force) { }
        $WorkspaceDirectory=$tempRoot;$configRoot='synthetic-config';$mediaRoot='synthetic-media'
        foreach($kind in @('controls-read','controls-apply')) {
            [RelayNetworkSession]::Reset();[RelayNetworkSession]::IdentityFailure='Synthetic connection error containing fixture-private-password'
            $options=[pscustomobject]@{device=@{ip='192.168.1.8';sn='fixture-sn'};certificateSha256=('A'*64);playerPassword='fixture-private-password';section='brightness';values=[pscustomobject]@{ratio=42}}
            $script:callerOptions=$options
            $id=Start-StudioNetworkJob $kind $options
            Update-StudioNetworkJobs
            $public=Get-StudioNetworkJobSummary $script:networkJobs[$id]
            Assert-NetworkApi ($public.status -ceq 'failed' -and $public.error -like '*[[]redacted[]]*' -and $null -eq $options.playerPassword) 'Real control worker wrapper did not redact/clear its password on failure.'
            Assert-NetworkApi (($public | ConvertTo-Json -Depth 8) -notmatch 'fixture-private|certificate|password|token') 'Control failure summary exposed credentials.'
        }
    }
    'Network API, transfer, and control worker checks passed. All device operations were mocked.'
} finally {
    $expected=[IO.Path]::GetFullPath((Join-Path $tempParent $tempLeaf))
    if($tempRoot -ceq $expected -and [IO.Path]::GetDirectoryName($tempRoot) -eq $tempParent.TrimEnd('\') -and
       $tempLeaf -match '^RelayNetworkApiTest-[a-f0-9]{32}$' -and
       -not @(Get-ChildItem -LiteralPath $tempRoot -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
        [IO.Directory]::Delete($tempRoot,$true)
    }
}

# Runs the real HTTP service and background job scheduler in an isolated copy.
# Packages and transfer orchestration are real. Only the transport is replaced:
# no sockets or player traffic are possible, and every session requires the password.
$ErrorActionPreference='Stop'
$fixtureParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureLeaf='RelayBatchServer-'+[guid]::NewGuid().ToString('N')
$fixtureRoot=[IO.Directory]::CreateDirectory((Join-Path $fixtureParent $fixtureLeaf)).FullName
$server=$null
try {
    $source=[IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'source')).FullName
    foreach($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object {$_.Extension -in '.ps1','.cs' -and $_.Name -notlike '*.test.ps1'})) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $source $file.Name)
    }
    $networkPath=Join-Path $source 'StudioNetwork.ps1'
    $fake=@'

# TEST ONLY: Replace network I/O, retaining real staging and transfer functions.
function Initialize-StudioNetworkTransport {
    if('RelayNetworkTransport' -as [type]){return}
    Add-Type -ReferencedAssemblies 'System.Web.Extensions.dll' -TypeDefinition @"
using System;
using System.IO;
using System.Collections.Generic;
using System.Web.Script.Serialization;
public static class RelayNetworkTransport { }
public sealed class RelayNetworkDevice {
    public string Sn, Ip, Name, Model, CertificateSha256;
    public int Width, Height, HttpsPort;
}
public sealed class RelayNetworkSession : IDisposable {
    public RelayNetworkDevice Device;
    readonly JavaScriptSerializer json = new JavaScriptSerializer();
    public RelayNetworkSession(RelayNetworkDevice device, string password) {
        if(password != "fixture-private-password") throw new ArgumentException("The transport did not receive its player password.");
        if(!device.Sn.StartsWith("FIXTURE-") || device.CertificateSha256 != new string('A',64) || device.HttpsPort != 16674) throw new ArgumentException("The transport lost its checked identity.");
        Device = device;
    }
    public string StartTransfer(string request) {
        var body=json.Deserialize<Dictionary<string,object>>(request);
        var solution=(Dictionary<string,object>)body["solutions"];
        return json.Serialize(new Dictionary<string,object> {
            {"canTranster",true},{"errorCode",0},{"checkFiles",body["checkFiles"]},
            {"appliedInfos",new Dictionary<string,object> {
                {"statusCode",0},{"name",solution["name"]},{"identifier",solution["identifier"]},{"uploadUrl","fixture/program"}}},
            {"uploadMediaUrl","fixture/media"}
        });
    }
    public string UploadFile(string path,string directory,string name,Action<long,long> progress) {
        var file=new FileInfo(path);
        if(!file.Exists || file.Length==0) throw new IOException("The real package file was unavailable.");
        if(progress!=null) progress(file.Length,file.Length);
        return "{}";
    }
    public string EndTransfer(string request) { return "{\"errorType\":0}"; }
    public void Dispose() { }
}
"@
}
1..7 | ForEach-Object {
    $key=([string]$_).PadLeft(32,'0')
    $script:networkConnections[$key]=@{created=[datetime]::UtcNow;certificateSha256=('A'*64);device=@{sn="FIXTURE-$_";ip="192.168.99.$(100+$_)";name="Fixture $_";width=320;height=1080;model='Fake'}}
}
'@
    [IO.File]::AppendAllText($networkPath,$fake)
    $workspace=Join-Path $fixtureRoot 'workspace'
    $mediaRoot=Join-Path $workspace 'Media'
    . (Join-Path $PSScriptRoot 'StudioProject.ps1')
    . (Join-Path $PSScriptRoot 'StudioMedia.ps1')
    Add-Type -AssemblyName System.Drawing
    $image=[Drawing.Bitmap]::new(32,108)
    $pixels=[IO.MemoryStream]::new()
    try {
        $graphics=[Drawing.Graphics]::FromImage($image)
        try {$graphics.Clear([Drawing.Color]::DarkGreen)}finally{$graphics.Dispose()}
        $image.Save($pixels,[Drawing.Imaging.ImageFormat]::Jpeg);$pixels.Position=0
        $fixtureSolution=Import-StudioMedia $pixels 'Fixture.jpg'
    } finally {$pixels.Dispose();$image.Dispose()}
    $solutionJson=$fixtureSolution | ConvertTo-Json -Depth 16 -Compress
    $startPath=Join-Path $source 'Start-Studio.ps1'
    $startup=[IO.File]::ReadAllText($startPath)
    $old='$script:catalog = Get-StudioCatalog $configRoot'
    if(-not $startup.Contains($old)){throw 'Catalog fixture hook changed.'}
    $startup=$startup.Replace($old,('$script:catalog = @{data=@{solutions=@(('''+$solutionJson.Replace("'","''")+''' | ConvertFrom-Json));schedules=@()}}'))
    [IO.File]::WriteAllText($startPath,$startup,[Text.UTF8Encoding]::new($false))
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
    $origin="http://127.0.0.1:$port"
    [void][IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'ViPlexExpress\Config'))
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName='powershell.exe';$info.WorkingDirectory=$source
    $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$startPath+'" -NoBrowser -Port '+$port+' -WorkspaceDirectory "'+$workspace+'" -ExportRoot "'+(Join-Path $fixtureRoot 'exports')+'"'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.EnvironmentVariables['ProgramData']=$fixtureRoot
    $server=[Diagnostics.Process]::Start($info)
    $session=$null
    for($attempt=0;$attempt -lt 80;$attempt++) {
        try {$session=Invoke-RestMethod ($origin+'/api/session');break}catch{if($server.HasExited){throw 'Fixture server stopped.'};Start-Sleep -Milliseconds 100}
    }
    if(-not $session){throw 'Fixture server did not start.'}
    $body=[ordered]@{requestId=[guid]::NewGuid().ToString('N');programType='solution';programId=$fixtureSolution.id;playerPassword='fixture-private-password'
        targets=@(1..7|ForEach-Object{@{connectionId=([string]$_).PadLeft(32,'0')}})
        project=@{version=1;title='Fixture';screens=@();solutions=@($fixtureSolution);cues=@()}}
    $headers=@{Origin=$origin;'X-Studio-Token'=$session.exportToken}
    $accepted=Invoke-RestMethod ($origin+'/api/network/batches') -Method Post -Headers $headers -ContentType 'application/json' -Body ($body|ConvertTo-Json -Depth 12 -Compress)
    if($accepted.batchId -notmatch '^[a-f0-9]{32}$'){throw 'No accepted batch.'}
    # No HTTP requests during this interval: later waves must start through the
    # server's idle loop, not through frontend progress polling.
    Start-Sleep -Seconds 15
    $result=Invoke-RestMethod ($origin+'/api/network/batches/'+$accepted.batchId)
    if($result.status -ne 'complete' -or @($result.targets|Where-Object status -EQ 'complete').Count -ne 7){throw ('Idle queue did not finish: '+($result|ConvertTo-Json -Depth 8 -Compress))}
    if(($result|ConvertTo-Json -Depth 10) -match 'fixture-private-password|certificateSha256'){throw 'Batch response leaked internal values.'}
    $again=Invoke-RestMethod ($origin+'/api/network/batches') -Method Post -Headers $headers -ContentType 'application/json' -Body ($body|ConvertTo-Json -Depth 12 -Compress)
    if($again.batchId -ne $accepted.batchId){throw 'HTTP retry duplicated the upload group.'}
    if(@($result.targets | Where-Object {$_.receipt.mediaUploaded -ne 1 -or $_.receipt.bytesUploaded -le 0}).Count){throw 'Real package files did not reach each simulated transport.'}
    'Real HTTP batch staged and transferred packages for seven targets without browser polling, required every session password, and recovered the same command after retry. Only network I/O was mocked.'
} finally {
    if($server -and -not $server.HasExited){$server.Kill();$server.WaitForExit()}
    if($server){$server.Dispose()}
    $expected=[IO.Path]::GetFullPath((Join-Path $fixtureParent $fixtureLeaf))
    if($fixtureRoot -ceq $expected -and [IO.Path]::GetDirectoryName($fixtureRoot) -ceq $fixtureParent) {
        $links=@(Get-Item -LiteralPath $fixtureRoot;Get-ChildItem -LiteralPath $fixtureRoot -Recurse -Force)|Where-Object {($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0}
        if(-not $links){[IO.Directory]::Delete($fixtureRoot,$true)}
    }
}

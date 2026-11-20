# Loopback transport and isolated image fixtures only. Never contacts a player.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'StudioMedia.ps1')
. (Join-Path $PSScriptRoot 'StudioPlayerPreview.ps1')
function Assert-PlayerPreview([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Expect-PreviewFailure([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action}catch{$failed=$true};Assert-PlayerPreview $failed $Message}
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'StudioNetworkTransport.cs'))
$tests=@'
public static class RelayPlayerPreviewTests {
    static void Assert(bool value,string message){if(!value)throw new System.Exception(message);}
    static void Fail(System.Action action,string text){try{action();}catch(System.Exception e){Assert(e.Message.Contains(text),e.Message);return;}throw new System.Exception("Expected "+text);}
    sealed class Server:System.IDisposable {
        readonly System.Net.HttpListener listener=new System.Net.HttpListener();
        readonly System.Threading.Tasks.Task worker;
        public readonly System.Uri Endpoint;
        public readonly System.Collections.Generic.List<string> Requests=new System.Collections.Generic.List<string>();
        public int Mode;
        public Server(){
            var probe=new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback,0);probe.Start();int port=((System.Net.IPEndPoint)probe.LocalEndpoint).Port;probe.Stop();
            Endpoint=new System.Uri("http://127.0.0.1:"+port+"/");listener.Prefixes.Add(Endpoint.AbsoluteUri);listener.Start();
            worker=System.Threading.Tasks.Task.Run(delegate{
                while(listener.IsListening){
                    System.Net.HttpListenerContext context;try{context=listener.GetContext();}catch{break;}
                    try{
                        var req=context.Request;var res=context.Response;Requests.Add(req.HttpMethod+" "+req.Url.AbsolutePath);
                        string body;using(var reader=new System.IO.StreamReader(req.InputStream))body=reader.ReadToEnd();
                        string output=null;
                        if(req.Url.AbsolutePath=="/terminal/core/v1/login") output="{\"code\":0,\"data\":{\"sn\":\"PREVIEW-QA\",\"logined\":true,\"validation\":true,\"token\":\"preview-fixture-token\"}}";
                        else{
                            Assert(req.Headers["Authorization"]=="preview-fixture-token","Snapshot request lost authentication.");
                            if(req.Url.AbsolutePath=="/terminal/core/v1/screen/shot/get"){
                                Assert(req.HttpMethod=="PUT","Capture was not PUT.");var options=RelayNetworkTransport.Object(body);
                                Assert(RelayNetworkTransport.Number(options,"width",0)==142&&RelayNetworkTransport.Number(options,"height",0)==480&&RelayNetworkTransport.Number(options,"type",-1)==1,"Wrong capture geometry/format.");
                                output=Mode==4?"{\"code\":-1,\"data\":null,\"message\":\"private-device-detail\"}":"{\"code\":0,\"data\":{\"path\":\"/sdcard/nova/viplex_terminal/cache/screenShots/screenshot_3.1.0\"}}";
                            }else{
                                Assert(req.Url.AbsolutePath=="/terminal/tools/v1/file/download"&&req.HttpMethod=="GET"&&body.Length==0,"Unexpected preview route or method.");
                                Assert(req.QueryString["filePath"]=="/sdcard/nova/viplex_terminal/cache/screenShots/screenshot_3.1.0","Wrong screenshot file query.");
                                if(Mode==1){res.StatusCode=307;res.RedirectLocation="http://192.168.1.200/forbidden";}
                                else if(Mode==2){res.ContentLength64=8*1024*1024+1;res.OutputStream.WriteByte(0);res.OutputStream.Flush();}
                                else if(Mode==3)res.ContentLength64=0;
                                else if(Mode==5){res.ContentLength64=4;res.OutputStream.WriteByte(255);res.OutputStream.Flush();System.Threading.Thread.Sleep(1000);res.OutputStream.Write(new byte[]{216,255,217},0,3);}
                                else{byte[] bytes=new byte[]{255,216,255,217};res.ContentLength64=bytes.Length;res.OutputStream.Write(bytes,0,bytes.Length);}
                            }
                        }
                        if(output!=null){byte[] bytes=System.Text.Encoding.UTF8.GetBytes(output);res.ContentLength64=bytes.Length;res.ContentType="application/json";res.OutputStream.Write(bytes,0,bytes.Length);}
                    }catch(System.Net.HttpListenerException){}finally{try{context.Response.Close();}catch(System.InvalidOperationException){context.Response.Abort();}}
                }
            });
        }
        public void Dispose(){listener.Close();Assert(worker.Wait(5000),"Preview fixture failed to stop.");}
    }
    public static string Run(){
        const string valid="/sdcard/nova/viplex_terminal/cache/screenShots/screenshot_3.1.0";
        foreach(string bad in new[]{"http://192.168.1.8/a","/sdcard/nova/viplex_terminal/media/secret","/sdcard/nova/viplex_terminal/cache/screenShots/../secret","/sdcard/nova/viplex_terminal/cache/screenShots/%2e%2e","/sdcard/nova/viplex_terminal/cache/screenShots/a?token=secret"})Fail(delegate{RelayNetworkSession.ScreenCaptureDownloadPath(bad);},"preview location");
        using(var server=new Server())using(var session=new RelayNetworkSession(server.Endpoint,new RelayNetworkDevice{Ip="127.0.0.1",Sn="PREVIEW-QA",HttpsPort=16674},"preview-password")){
            Fail(delegate{session.RequestScreenCapture(0,480);},"preview size");Fail(delegate{session.RequestScreenCapture(641,480);},"preview size");
            Assert(server.Requests.Count==1,"Bad dimensions reached a player.");
            string result=session.RequestScreenCapture(142,480);Assert(result.Contains("screenshot_3.1.0"),"Capture path lost.");
            byte[] image=session.ReadScreenCaptureFile(valid);Assert(image.Length==4&&image[0]==255,"Screenshot binary changed.");
            server.Mode=1;Fail(delegate{session.ReadScreenCaptureFile(valid);},"unavailable");
            server.Mode=2;Fail(delegate{session.ReadScreenCaptureFile(valid);},"oversized");
            server.Mode=3;Fail(delegate{session.ReadScreenCaptureFile(valid);},"empty");
            server.Mode=4;int before=server.Requests.Count;Fail(delegate{session.RequestScreenCapture(142,480);},"code -1");Assert(server.Requests.Count==before+1,"Failed capture was replayed.");
            server.Mode=5;var watch=System.Diagnostics.Stopwatch.StartNew();bool timedOut=false;
            try{session.ReadScreenCaptureFile(valid,150);}catch(System.Exception){timedOut=true;}
            Assert(timedOut&&watch.ElapsedMilliseconds<900,"A trickled response bypassed the whole-download deadline.");
            foreach(string route in server.Requests)Assert(!route.Contains("forbidden")&&!route.Contains("play/"),"Preview changed playback or followed a redirect.");
        }
        return "Snapshot capture/download transport checks passed (loopback only).";
    }
}
'@
Add-Type -TypeDefinition ($source+[Environment]::NewLine+$tests) -ReferencedAssemblies System.Web.Extensions
[RelayPlayerPreviewTests]::Run()
$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$work=[IO.Directory]::CreateDirectory((Join-Path $parent ('RelayPreviewTest-'+[guid]::NewGuid().ToString('N')))).FullName
try{
    Add-Type -AssemblyName System.Drawing
    $bitmap=[Drawing.Bitmap]::new(1920,1080);$graphics=[Drawing.Graphics]::FromImage($bitmap);$stream=[IO.MemoryStream]::new()
    try{$graphics.Clear([Drawing.Color]::Navy);$graphics.FillRectangle([Drawing.Brushes]::Orange,0,0,960,1080);$bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Jpeg);$fixture=$stream.ToArray()}finally{$graphics.Dispose();$bitmap.Dispose();$stream.Dispose()}
    $preview=Convert-StudioPlayerPreview $fixture $work
    Assert-PlayerPreview ($preview.width -eq 480 -and $preview.height -eq 270 -and $preview.imageDataUrl.StartsWith('data:image/jpeg;base64,')) 'Preview was not downscaled proportionally.'
    $read=[IO.MemoryStream]::new([Convert]::FromBase64String($preview.imageDataUrl.Substring(23)));$decoded=[Drawing.Bitmap]::new($read)
    try{Assert-PlayerPreview ($decoded.GetPixel(40,40).R -gt 180 -and $decoded.GetPixel(440,40).B -gt 70) 'Preview pixel content was lost.'}finally{$decoded.Dispose();$read.Dispose()}
    $png=[Drawing.Bitmap]::new(320,1080);$stream=[IO.MemoryStream]::new()
    try{$png.Save($stream,[Drawing.Imaging.ImageFormat]::Png);$pngBytes=$stream.ToArray()}finally{$png.Dispose();$stream.Dispose()}
    $preview=Convert-StudioPlayerPreview $pngBytes $work
    Assert-PlayerPreview ($preview.width -eq 142 -and $preview.height -eq 480) 'PNG portrait preview dimensions changed.'
    $bad=$pngBytes.Clone();$bad[16]=127
    Expect-PreviewFailure {Convert-StudioPlayerPreview $bad $work} 'Oversized PNG dimensions accepted.'
    Expect-PreviewFailure {Convert-StudioPlayerPreview ([byte[]](1,2,3)) $work} 'Truncated image accepted.'
    Expect-PreviewFailure {Convert-StudioPlayerPreview ([Text.Encoding]::UTF8.GetBytes('This is not an image file.')) $work} 'Unrecognized bytes accepted.'
    Expect-PreviewFailure {Convert-StudioPlayerPreview ([byte[]]::new(8MB+1)) $work} 'Oversized image payload accepted.'
    function New-StudioVerifiedNetworkSession($Options){
        $fake=[pscustomobject]@{Device=[pscustomobject]@{Sn='FIXTURE-BOARD';Ip='192.168.1.2';Name='Fixture';Model='T50';Width=320;Height=1080}}
        $fake|Add-Member ScriptMethod RequestScreenCapture {param($width,$height) Assert-PlayerPreview ($width -eq 142 -and $height -eq 480) 'Worker requested invalid downscale.';' {"path":"/sdcard/nova/viplex_terminal/cache/screenShots/screenshot_3.1.0"}'}
        $fake|Add-Member ScriptMethod ReadScreenCaptureFile {param($path) return ,$pngBytes}
        $fake|Add-Member ScriptMethod Dispose {}
        return $fake
    }
    function Get-StudioNetworkDeviceSummary($Device){@{sn=$Device.Sn;ip=$Device.Ip}}
    function Write-StudioNetworkProgress($WorkDirectory,$Progress,$Message){}
    $result=Invoke-StudioPlayerPreview ([pscustomobject]@{device=@{sn='FIXTURE-BOARD';width=320;height=1080};playerPassword='fixture-secret'}) $work
    Assert-PlayerPreview ($result.event -eq 'complete' -and $result.preview.kind -eq 'snapshot' -and $result.preview.width -eq 142 -and $result.preview.capturedAt.EndsWith('Z')) 'Worker preview result invalid.'
    Assert-PlayerPreview (($result|ConvertTo-Json -Depth 5 -Compress) -notmatch 'fixture-secret|screenShots|certificate|token') 'Worker preview leaked internal details.'
    'JPEG/PNG resize, dimension bounds, validation, actual pixels and worker snapshot checks passed.'
}finally{
    if([IO.Path]::GetDirectoryName($work) -ceq $parent -and [IO.Path]::GetFileName($work) -cmatch '^RelayPreviewTest-[a-f0-9]{32}$'){
        $left=Join-Path $work 'screen-preview-source.jpg';if([IO.File]::Exists($left)){[IO.File]::Delete($left)}
        [IO.Directory]::Delete($work,$false)
    }
}

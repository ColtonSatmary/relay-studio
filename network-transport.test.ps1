# Uses loopback UDP/HTTP only. Never contacts a real player.
$ErrorActionPreference = 'Stop'
$transportSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'StudioNetworkTransport.cs'))
if ($PSVersionTable.PSEdition -eq 'Core') {
    # Synthetic fixture diagnostics only. Never print exception messages,
    # request bodies, headers, or credentials from a transport failure.
    $retryProbe=@'
bool CanRetryConnection(WebException error) {
    for(System.Exception diagnostic=error;diagnostic!=null;diagnostic=diagnostic.InnerException) {
        var diagnosticType=diagnostic.GetType();
        var category=diagnosticType.GetProperty("HttpRequestError");
        var socket=diagnostic as System.Net.Sockets.SocketException;
        System.Console.WriteLine("Fixture reset type="+diagnosticType.FullName+"; hresult="+diagnostic.HResult+
            "; http="+(category==null?"none":System.Convert.ToString(category.GetValue(diagnostic,null)))+
            "; socket="+(socket==null?"none":socket.SocketErrorCode.ToString()));
    }
'@
    $transportSource=$transportSource.Replace('bool CanRetryConnection(WebException error) {',$retryProbe)
}
$testSource = @'
public static class RelayNetworkTransportTests {
    static void Assert(bool condition, string message) { if (!condition) throw new System.Exception(message); }
    static System.Exception Throws(System.Action action, string contains) {
        try { action(); } catch (System.Exception ex) { Assert(ex.Message.Contains(contains), "Unexpected error: " + ex.Message); return ex; }
        throw new System.Exception("Expected failure: " + contains);
    }
    sealed class Server : System.IDisposable {
        readonly System.Net.HttpListener listener = new System.Net.HttpListener();
        readonly System.Threading.Tasks.Task worker;
        volatile bool running=true;
        public readonly System.Collections.Generic.List<string> Requests = new System.Collections.Generic.List<string>();
        public System.Uri Endpoint;
        public Server(System.Func<System.Net.HttpListenerRequest,string> response) {
            var portProbe = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback,0);
            portProbe.Start(); int port = ((System.Net.IPEndPoint)portProbe.LocalEndpoint).Port; portProbe.Stop();
            Endpoint = new System.Uri("http://127.0.0.1:"+port+"/");
            listener.Prefixes.Add(Endpoint.AbsoluteUri); listener.Start();
            worker = System.Threading.Tasks.Task.Run(delegate {
                while (running) {
                    System.Net.HttpListenerContext context;
                    try {
                        var pending=listener.GetContextAsync();
                        while(running && !pending.Wait(100)) {}
                        if(!running)break;
                        context=pending.GetAwaiter().GetResult();
                    } catch { break; }
                    try {
                        Requests.Add(context.Request.HttpMethod+" "+context.Request.Url.AbsolutePath);
                        string body = response(context.Request);
                        if (body == "REDIRECT") {
                            context.Response.StatusCode=307;
                            context.Response.RedirectLocation="http://192.168.1.200:16674/should-not-follow";
                        } else {
                            if (body == "HTTP503") {
                                context.Response.StatusCode=503;
                                context.Response.StatusDescription="qa-only-password";
                                context.Response.Headers["X-Private-Test"]="qa-only-token";
                                body="{\"message\":\"qa-only-password qa-only-token\"}";
                            }
                            byte[] bytes=System.Text.Encoding.UTF8.GetBytes(body);
                            context.Response.ContentType="application/json";
                            context.Response.ContentLength64=bytes.Length;
                            context.Response.OutputStream.Write(bytes,0,bytes.Length);
                        }
                    } finally { context.Response.Close(); }
                }
            });
        }
        public void Dispose() { running=false; listener.Stop(); try { Assert(worker.Wait(5000),"HTTP fixture did not stop."); } finally { listener.Close(); } }
    }
    static RelayNetworkDevice Device() { return new RelayNetworkDevice {Ip="127.0.0.1",Sn="QA-SERIAL",Name="Fixture",HttpsPort=16674}; }
    static RelayNetworkDevice CheckedDevice() {
        return new RelayNetworkDevice {Ip="192.168.1.2",Sn="QA-SERIAL",Name="Checked fixture",Model="T50",Width=320,Height=1080,HttpsPort=16674,CertificateSha256=new string('a',64)};
    }
    static string LoginResult(string sn) {
        return "{\"code\":0,\"data\":{\"sn\":\""+sn+"\",\"validation\":true,\"logined\":true,\"token\":\"qa-only-token\"}}";
    }
    static string VersionResult(string sn) {
        return RelayNetworkTransport.Json().Serialize(new System.Collections.Generic.Dictionary<string,object> {
            {"code",0},{"data",new System.Collections.Generic.Dictionary<string,object>{{"sn",sn},{"aliasName","HTTPS fixture"},{"productName","T50"},{"password","private-response-field"},{"width",1920},{"height",1080}}}
        });
    }
    static RelayNetworkDevice NoDiscovery(string ip,int timeout) {throw new RelayNetworkDiscoveryUnavailableException("Synthetic discovery timeout");}
    static string ReadBody(System.Net.HttpListenerRequest request) {
        return System.Text.Encoding.UTF8.GetString(ReadBytes(request,2*1024*1024));
    }
    static byte[] ReadBytes(System.Net.HttpListenerRequest request,int maximum) {
        using(var result=new System.IO.MemoryStream()) {
            var buffer=new byte[16384];
            while(true) {
                var pending=request.InputStream.ReadAsync(buffer,0,buffer.Length);
                if(!pending.Wait(5000))throw new System.TimeoutException("Fixture request body did not finish.");
                int count=pending.GetAwaiter().GetResult();if(count==0)break;
                if(result.Length+count>maximum)throw new System.IO.IOException("Fixture request body too large.");
                result.Write(buffer,0,count);
            }
            return result.ToArray();
        }
    }
    sealed class DiscoveryServer : System.IDisposable {
        readonly System.Net.Sockets.UdpClient first,second;
        readonly System.Threading.Tasks.Task[] workers;
        public readonly int[] Counts=new int[2];
        volatile bool running=true;
        public DiscoveryServer(byte[] reply) {
            first=new System.Net.Sockets.UdpClient(new System.Net.IPEndPoint(System.Net.IPAddress.Loopback,16601));
            try {second=new System.Net.Sockets.UdpClient(new System.Net.IPEndPoint(System.Net.IPAddress.Loopback,16611));}
            catch {first.Close();throw;}
            first.Client.ReceiveTimeout=250;second.Client.ReceiveTimeout=250;
            workers=new[]{Worker(first,0,reply),Worker(second,1,null)};
        }
        System.Threading.Tasks.Task Worker(System.Net.Sockets.UdpClient socket,int index,byte[] reply) {
            return System.Threading.Tasks.Task.Run(delegate {
                while(running) {
                    var remote=new System.Net.IPEndPoint(System.Net.IPAddress.Any,0);
                    byte[] query;
                    try {query=socket.Receive(ref remote);} catch(System.Net.Sockets.SocketException error) {if(!running)break;if(error.SocketErrorCode==System.Net.Sockets.SocketError.TimedOut || error.SocketErrorCode==System.Net.Sockets.SocketError.WouldBlock)continue;throw;} catch(System.ObjectDisposedException){break;}
                    Assert(System.BitConverter.ToString(query)==System.BitConverter.ToString(RelayNetworkTransport.DiscoveryPacket()),"Discovery retry changed wire bytes.");
                    int count=System.Threading.Interlocked.Increment(ref Counts[index]);
                    // Deliberately discard the first query to model packet loss.
                    if(reply!=null && count==2)socket.Send(reply,reply.Length,remote);
                }
            });
        }
        public void Dispose() {running=false;first.Close();second.Close();Assert(System.Threading.Tasks.Task.WaitAll(workers,5000),"Discovery fixture did not stop.");}
    }
    sealed class ResetServer : System.IDisposable {
        readonly System.Net.Sockets.TcpListener listener;
        readonly System.Threading.Tasks.Task worker;
        volatile bool running=true;
        public readonly System.Collections.Generic.List<string> Requests=new System.Collections.Generic.List<string>();
        public readonly System.Collections.Generic.List<string> Bodies=new System.Collections.Generic.List<string>();
        public readonly System.Uri Endpoint;
        public ResetServer(System.Func<string,string,string> response) {
            listener=new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback,0);listener.Start();
            Endpoint=new System.Uri("http://127.0.0.1:"+((System.Net.IPEndPoint)listener.LocalEndpoint).Port+"/");
            worker=System.Threading.Tasks.Task.Run(delegate {
                while(running) {
                    System.Net.Sockets.TcpClient client;
                    try {
                        var pending=listener.AcceptTcpClientAsync();
                        while(running && !pending.Wait(100)) {}
                        if(!running)break;
                        client=pending.GetAwaiter().GetResult();
                    }catch(System.Exception){if(!running)break;throw;}
                    using(client)using(var stream=client.GetStream()) {
                        stream.ReadTimeout=5000;
                        var header=new System.Text.StringBuilder();
                        while(header.Length<16384 && !header.ToString().EndsWith("\r\n\r\n")) {int next=stream.ReadByte();if(next<0)break;header.Append((char)next);}
                        string[] lines=header.ToString().Split(new[]{"\r\n"},System.StringSplitOptions.None);
                        int length=0;foreach(string line in lines)if(line.StartsWith("Content-Length:",System.StringComparison.OrdinalIgnoreCase))length=int.Parse(line.Substring(15).Trim());
                        Assert(length>=0 && length<=1048576,"Unexpected fixture body length.");
                        byte[] bytes=new byte[length];int offset=0;
                        while(offset<length){int read=stream.Read(bytes,offset,length-offset);if(read==0)break;offset+=read;}
                        Assert(offset==length,"Fixture received truncated request.");
                        string body=System.Text.Encoding.UTF8.GetString(bytes);
                        string path=lines[0].Split(' ')[1];Requests.Add(lines[0]);Bodies.Add(body);
                        string result=response(path,body);
                        if(result=="RESET") {client.Client.LingerState=new System.Net.Sockets.LingerOption(true,0);continue;}
                        byte[] content=System.Text.Encoding.UTF8.GetBytes(result);
                        byte[] prefix=System.Text.Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "+content.Length+"\r\nConnection: close\r\n\r\n");
                        stream.Write(prefix,0,prefix.Length);stream.Write(content,0,content.Length);stream.Flush();
                    }
                }
            });
        }
        public void Dispose(){running=false;listener.Stop();Assert(worker.Wait(5000),"Reset fixture did not stop.");}
    }
    static RelayNetworkDevice DiscoverLoopback(int timeout) {
        var method=typeof(RelayNetworkTransport).GetMethod("Discover",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Static,null,new[]{typeof(System.Net.IPAddress),typeof(int)},null);
        try {return (RelayNetworkDevice)method.Invoke(null,new object[]{System.Net.IPAddress.Loopback,timeout});}
        catch(System.Reflection.TargetInvocationException ex){throw ex.InnerException;}
    }
    public static string Run(string directory) {
        System.Console.WriteLine("Transport fixture: address validation and checked reconnect");
        foreach(string ip in new[]{"10.1.2.3","172.16.1.2","192.168.1.2","169.254.1.2","100.64.1.2"})
            Assert(RelayNetworkTransport.ValidateAddress(ip)==ip,"Valid private address rejected.");
        foreach(string ip in new[]{"8.8.8.8","127.0.0.1","0.0.0.0","239.1.2.3","192.168.1.255","100.128.1.2","192.168.1.2/path","localhost","10.1.2.+3"})
            Throws(delegate {RelayNetworkTransport.ValidateAddress(ip);},"address");
        Throws(delegate {new RelayNetworkSession("192.168.1.2","fixture","QA-SERIAL",null);},"Check the player's connection");
        using(var server=new Server(delegate(System.Net.HttpListenerRequest request){ReadBody(request);return LoginResult("QA-SERIAL");})) {
            Throws(delegate {new RelayNetworkSession((RelayNetworkDevice)null,"fixture",server.Endpoint);},"Check the player's connection");
            foreach(var invalidate in new System.Action<RelayNetworkDevice>[] {
                delegate(RelayNetworkDevice d){d.Sn=null;},delegate(RelayNetworkDevice d){d.Sn=" ";},delegate(RelayNetworkDevice d){d.Sn="bad\r\nserial";},
                delegate(RelayNetworkDevice d){d.Sn=new string('x',129);},delegate(RelayNetworkDevice d){d.CertificateSha256=null;},
                delegate(RelayNetworkDevice d){d.CertificateSha256="invalid";},delegate(RelayNetworkDevice d){d.CertificateSha256=new string('z',64);},
                delegate(RelayNetworkDevice d){d.HttpsPort=443;},delegate(RelayNetworkDevice d){d.Ip="8.8.8.8";},
                delegate(RelayNetworkDevice d){d.Ip="localhost";},delegate(RelayNetworkDevice d){d.Width=-1;},delegate(RelayNetworkDevice d){d.Height=100001;}
            }) {
                var checkedDevice=CheckedDevice();invalidate(checkedDevice);
                var error=Throws(delegate{new RelayNetworkSession(checkedDevice,"fixture",server.Endpoint);},"");
                Assert(error is System.ArgumentException,"Invalid checked device did not fail validation.");
            }
            Assert(server.Requests.Count==0,"Invalid checked device reached HTTP login.");
            var original=CheckedDevice();
            using(var session=new RelayNetworkSession(original,"qa-only-password",server.Endpoint)) {
                original.Ip="192.168.1.99";original.Sn="CHANGED";original.Name="Changed";original.CertificateSha256=new string('b',64);
                Assert(session.Device.Ip=="192.168.1.2" && session.Device.Sn=="QA-SERIAL" && session.Device.Name=="Checked fixture" && session.Device.CertificateSha256==new string('A',64),"Checked device snapshot changed with caller mutation.");
                var pin=(string)typeof(RelayNetworkSession).GetField("certificate",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance).GetValue(session);
                Assert(pin==new string('A',64),"Verified reconnect lost its certificate pin.");
            }
            Assert(server.Requests.Count==1,"Verified reconnect performed unexpected HTTP operations.");
        }
        using(var server=new Server(delegate(System.Net.HttpListenerRequest request){ReadBody(request);return LoginResult("CHANGED");}))
            Throws(delegate{using(var session=new RelayNetworkSession(CheckedDevice(),"qa-only-password",server.Endpoint)){}},"identity changed");
        System.Console.WriteLine("Transport fixture: identity-before-login and receiver geometry");
        var cardRegions=new System.Collections.Generic.List<object>();
        for(int i=0;i<6;i++)cardRegions.Add(new System.Collections.Generic.Dictionary<string,object>{{"X",0},{"Y",i*180},{"width",320},{"height",180}});
        string cardResponse=RelayNetworkTransport.Json().Serialize(new System.Collections.Generic.Dictionary<string,object>{{"code",0},{"data",new System.Collections.Generic.Dictionary<string,object>{{"receiveCardRegionInfo",cardRegions}}}});
        using(var server=new Server(delegate(System.Net.HttpListenerRequest request) {
            string body=ReadBody(request);
            if(request.Url.AbsolutePath.EndsWith("/version")) {
                Assert(request.HttpMethod=="GET" && body=="" && request.Headers["Authorization"]==null,"Identity probe sent credentials before verification.");
                return VersionResult("QA-SERIAL");
            }
            if(request.Url.AbsolutePath.EndsWith("/login")) {
                var login=RelayNetworkTransport.Object(body);
                Assert((string)login["sn"]=="QA-SERIAL" && (string)login["password"]=="qa-only-password","Fallback login did not use verified identity.");
                return LoginResult("QA-SERIAL");
            }
            Assert(request.Url.AbsolutePath=="/terminal/core/v1/monitor/receivercard/info" && request.Headers["Authorization"]=="qa-only-token","Output dimensions were not read after authenticated login.");
            return cardResponse;
        })) {
            using(var session=new RelayNetworkSession(server.Endpoint,"qa-only-password","QA-SERIAL",NoDiscovery)) {
                Assert(session.Device.Sn=="QA-SERIAL" && session.Device.Name=="HTTPS fixture" && session.Device.Model=="T50" && session.Device.Width==320 && session.Device.Height==1080,"Fallback identity or physical output geometry was incorrect.");
                Assert(!RelayNetworkTransport.Json().Serialize(session.Device).Contains("private-response-field"),"Identity response leaked unknown credential fields.");
            }
            Assert(server.Requests.Count==3 && server.Requests[0].EndsWith("/version") && server.Requests[1].EndsWith("/login"),"Fallback did not verify identity before login.");
        }
        foreach(string sn in new string[]{null,""," ","bad\r\nserial",new string('x',129),"OTHER-SERIAL"}) {
            using(var server=new Server(delegate(System.Net.HttpListenerRequest request){ReadBody(request);return VersionResult(sn);})) {
                Throws(delegate{using(var session=new RelayNetworkSession(server.Endpoint,"qa-only-password","QA-SERIAL",NoDiscovery)){}},sn=="OTHER-SERIAL" ? "different player" : "valid identity");
                Assert(server.Requests.Count==1 && server.Requests[0].StartsWith("GET "),"Invalid or mismatched identity received a login/password.");
            }
        }
        using(var server=new Server(delegate(System.Net.HttpListenerRequest request){ReadBody(request);return request.Url.AbsolutePath.EndsWith("/version") ? VersionResult("QA-SERIAL") : LoginResult("CHANGED");})) {
            Throws(delegate{using(var session=new RelayNetworkSession(server.Endpoint,"qa-only-password",null,NoDiscovery)){}},"identity changed");
            Assert(server.Requests.Count==2,"Fallback accepted changed login serial or continued to geometry lookup.");
        }
        foreach(string geometry in new[]{"{\"receiveCardRegionInfo\":[]}","{\"receiveCardRegionInfo\":[{\"X\":0,\"Y\":0,\"width\":1920.5,\"height\":1080}]}","{\"receiveCardRegionInfo\":[{\"X\":-1,\"Y\":0,\"width\":320,\"height\":180}]}","{\"receiveCardRegionInfo\":[{\"X\":100000,\"Y\":0,\"width\":320,\"height\":180}]}"}) {
            using(var server=new Server(delegate(System.Net.HttpListenerRequest request){ReadBody(request);return request.Url.AbsolutePath.EndsWith("/version") ? VersionResult("QA-SERIAL") : request.Url.AbsolutePath.EndsWith("/login") ? LoginResult("QA-SERIAL") : "{\"code\":0,\"data\":"+geometry+"}";})) {
                using(var session=new RelayNetworkSession(server.Endpoint,"qa-only-password",null,NoDiscovery))
                    Assert(session.Device.Width==0 && session.Device.Height==0,"Invalid receiver geometry or source canvas was used as player output size.");
            }
        }
        using(var server=new Server(delegate(System.Net.HttpListenerRequest request){throw new System.Exception("Unexpected HTTP during discovery error");})) {
            Throws(delegate{new RelayNetworkSession(server.Endpoint,"qa-only-password",null,delegate(string ip,int timeout){throw new System.InvalidOperationException("Synthetic socket failure");});},"Synthetic socket failure");
            Assert(server.Requests.Count==0,"Non-timeout discovery failure triggered HTTPS fallback.");
        }
        System.Console.WriteLine("Transport fixture: UDP discovery retry");
        byte[] packet=RelayNetworkTransport.DiscoveryPacket();
        Assert(System.BitConverter.ToString(packet)=="41-56-4F-4E-FF-FF-FF-FF-55-88-81-00-01-00-00-00-00-00-00-00-00-00-8F-00","Discovery wire bytes differ from vendor protocol.");
        byte[] json=System.Text.Encoding.UTF8.GetBytes("{\"sn\":\"QA-SERIAL\",\"aliasName\":\"Test screen\",\"productName\":\"T50\",\"width\":320,\"height\":1080,\"terminalEntrancePortHttps\":16674}");
        byte[] response=new byte[24+json.Length];System.Buffer.BlockCopy(packet,0,response,0,24);System.Buffer.BlockCopy(json,0,response,24,json.Length);
        System.Buffer.BlockCopy(System.BitConverter.GetBytes((short)1),0,response,10,2);
        System.Buffer.BlockCopy(System.BitConverter.GetBytes(json.Length),0,response,16,4);
        System.Buffer.BlockCopy(System.BitConverter.GetBytes(RelayNetworkTransport.Checksum(response,24,json.Length)),0,response,20,2);
        System.Buffer.BlockCopy(System.BitConverter.GetBytes(RelayNetworkTransport.Checksum(response,0,22)),0,response,22,2);
        var found=RelayNetworkTransport.ParseDiscovery(response,"192.168.1.2");
        Assert(found!=null && found.Sn=="QA-SERIAL" && found.Width==320 && found.HttpsPort==16674,"Discovery data mismatch.");
        using(var server=new DiscoveryServer(response)) {
            var timer=System.Diagnostics.Stopwatch.StartNew();
            found=DiscoverLoopback(2500);
            Assert(found.Sn=="QA-SERIAL" && server.Counts[0]==2 && server.Counts[1]>=1,"Discovery did not recover after dropped first packet.");
            Assert(timer.ElapsedMilliseconds>=650 && timer.ElapsedMilliseconds<2000,"Discovery retry cadence was not bounded.");
            System.Console.WriteLine("Transport fixture: UDP success received; disposing first listener");
        }
        System.Console.WriteLine("Transport fixture: UDP discovery timeout");
        using(var server=new DiscoveryServer(null)) {
            var timer=System.Diagnostics.Stopwatch.StartNew();
            Throws(delegate {DiscoverLoopback(1800);},"No NovaStar player answered");
            Assert(timer.ElapsedMilliseconds>=1700 && timer.ElapsedMilliseconds<2500,"Discovery exceeded its timeout budget.");
            Assert(server.Counts[0]>=2 && server.Counts[0]<=3 && server.Counts[1]>=2 && server.Counts[1]<=3,"Discovery retry count was not bounded.");
            System.Console.WriteLine("Transport fixture: UDP timeout received; disposing second listener");
        }
        response[24]^=1;Assert(RelayNetworkTransport.ParseDiscovery(response,"192.168.1.2")==null,"Corrupt payload accepted.");
        Assert(RelayNetworkTransport.ParseDiscovery(new byte[3],"192.168.1.2")==null,"Short packet accepted.");

        System.Console.WriteLine("Transport fixture: authenticated streaming upload and cancellation");
        string fixture=System.IO.Path.Combine(directory,"upload.bin");
        byte[] media=new byte[300000];for(int i=0;i<media.Length;i++)media[i]=(byte)(i%251);
        System.IO.File.WriteAllBytes(fixture,media);
        long finalProgress=0;int uploadCount=0;
        using(var server=new Server(delegate(System.Net.HttpListenerRequest request) {
            if(request.Url.AbsolutePath.EndsWith("/login")) {
                var login=RelayNetworkTransport.Object(ReadBody(request));
                Assert(request.HttpMethod=="POST" && (string)login["password"]=="qa-only-password" && (int)login["loginType"]==9,"Login request mismatch.");
                return LoginResult("QA-SERIAL");
            }
            Assert(request.Headers["Authorization"]=="qa-only-token","Authorization token mismatch.");
            Assert(request.HttpMethod=="PUT","Publish operation did not use PUT.");
            if(request.Url.AbsolutePath.EndsWith("uploadUseBinary")) {
                Assert(request.ContentType=="application/octet-stream","Upload type mismatch.");
                Assert(request.QueryString["fileName"]=="file & name.bin","Upload filename encoding failed.");
                Assert(request.QueryString["targetDir"]=="sdcard/nova/viplex_terminal/media","Upload directory mismatch.");
                byte[] received=ReadBytes(request,media.Length);
                Assert(received.Length==media.Length,"Upload length mismatch.");
                for(int i=0;i<media.Length;i++)Assert(received[i]==media[i],"Upload bytes changed.");
                uploadCount++;return "{\"code\":0,\"data\":true}";
            }
            ReadBody(request);
            return "{\"code\":0,\"data\":{\"errorType\":0,\"canTranster\":true}}";
        })) {
            using(var session=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password")) {
                Assert(RelayNetworkTransport.Object(session.StartTransfer("{\"solutions\":{\"name\":\"Fixture\"}}"))["canTranster"].Equals(true),"Start response not unwrapped.");
                session.UploadFile(fixture,"sdcard/nova/viplex_terminal/media","file & name.bin",delegate(long sent,long total) {
                    Assert(total==media.Length && sent>=finalProgress,"Progress invalid.");finalProgress=sent;
                    var active=(System.Net.HttpWebRequest)typeof(RelayNetworkSession).GetField("active",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance).GetValue(session);
                    Assert(active.Timeout==120000 && active.ReadWriteTimeout==120000,"Media upload timeout too short.");
                });
                session.EndTransfer("{\"playImmediately\":true}");
                var errorMethod=typeof(RelayNetworkSession).GetMethod("RequestError",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance);
                foreach(var status in new[]{System.Net.WebExceptionStatus.Timeout,System.Net.WebExceptionStatus.ConnectFailure,System.Net.WebExceptionStatus.SecureChannelFailure}) {
                    var sanitized=(System.Exception)errorMethod.Invoke(session,new object[]{new System.Net.WebException("qa-only-password qa-only-token",status),"login"});
                    Assert(sanitized.Message.Contains(status.ToString()) && !sanitized.Message.Contains("qa-only") && sanitized.InnerException==null,"Transport status leaked a secret or lost its diagnostic.");
                }
                var newRequest=typeof(RelayNetworkSession).GetMethod("NewRequest",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance);
                var controlRequest=(System.Net.HttpWebRequest)newRequest.Invoke(session,new object[]{"PUT","/test","application/json",0L});
                Assert(controlRequest.Timeout==30000 && controlRequest.ReadWriteTimeout==30000,"Control request timeout changed unexpectedly.");
                Assert(controlRequest.KeepAlive==(typeof(object).Assembly.GetName().Name=="mscorlib") && !string.IsNullOrEmpty(controlRequest.ConnectionGroupName),"Session connection isolation settings changed.");
                Throws(delegate {session.UploadFile(fixture,"sdcard/nova/viplex_terminal/../escape","bad.bin",null);},"invalid upload directory");
                session.Cancel();Throws(delegate {session.StartTransfer("{}");},"canceled");
            }
            Assert(server.Requests.Count==4 && uploadCount==1 && finalProgress==media.Length,"Unexpected requests or progress.");
        }
        System.Console.WriteLine("Transport fixture: rejected login, redirect and HTTP errors");
        using(var server=new Server(delegate(System.Net.HttpListenerRequest request){ReadBody(request);return LoginResult("OTHER-SERIAL");}))
            Throws(delegate {using(var session=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password")){}},"identity changed");
        using(var server=new Server(delegate(System.Net.HttpListenerRequest request){ReadBody(request);return "{\"code\":39,\"data\":null,\"message\":\"do not echo qa-only-password\"}";}))
            Throws(delegate {using(var session=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password")){}},"code 39");
        using(var server=new Server(delegate(System.Net.HttpListenerRequest request){ReadBody(request);return "REDIRECT";}))
            Throws(delegate {using(var session=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password")){}},"did not accept");
        using(var server=new Server(delegate(System.Net.HttpListenerRequest request){ReadBody(request);return "HTTP503";})) {
            var error=Throws(delegate {using(var session=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password")){}},"HTTP 503; ProtocolError");
            Assert(!error.Message.Contains("qa-only") && error.InnerException==null,"HTTP diagnostic leaked server secrets.");
            Assert(server.Requests.Count==1,"Failed login was retried unexpectedly.");
        }
        using(var server=new Server(delegate(System.Net.HttpListenerRequest request){ReadBody(request);return request.Url.AbsolutePath.EndsWith("/login") ? LoginResult("QA-SERIAL") : "HTTP503";})) {
            using(var session=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password")) {
                var error=Throws(delegate {session.EndTransfer("{\"playImmediately\":true}");},"HTTP 503; ProtocolError");
                Assert(error.Message.Contains("Check the screen before retrying") && !error.Message.Contains("qa-only"),"Activation uncertainty or secret filtering was lost.");
            }
            Assert(server.Requests.Count==2,"Playback activation was retried unexpectedly.");
        }
        System.Console.WriteLine("Transport fixture: bounded login and GET reset recovery");
        int loginAttempts=0,readAttempts=0;
        using(var server=new ResetServer(delegate(string path,string body) {
            if(path.EndsWith("/login"))return ++loginAttempts==1 ? "RESET" : LoginResult("QA-SERIAL");
            return ++readAttempts==1 ? "RESET" : "{\"code\":0,\"data\":{\"ratio\":42}}";
        })) {
            using(var session=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password")) {
                Assert(RelayNetworkTransport.Object(session.ReadControl("brightness"))["ratio"].Equals(42),"GET did not recover after connection reset.");
            }
            Assert(loginAttempts==2 && readAttempts==2 && server.Requests.Count==4,"Login/read retry count changed.");
            Assert(server.Bodies[0]==server.Bodies[1],"Login retry changed credentials or client identity.");
        }
        int failedReads=0;
        using(var server=new ResetServer(delegate(string path,string body) {if(path.EndsWith("/login"))return LoginResult("QA-SERIAL");failedReads++;return "RESET";})) {
            using(var session=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password"))
                Throws(delegate{session.ReadControl("brightness");},"read brightness request");
            // Framework internally replays a failed GET once; Core does not
            // replay this fixture. Both allow exactly one explicit recovery.
            int expectedReads=typeof(object).Assembly.GetName().Name=="mscorlib" ? 4 : 2;
            Assert(failedReads==expectedReads,"GET framework/application retry limit changed (observed "+failedReads+").");
        }
        using(var server=new ResetServer(delegate(string path,string body){return "RESET";})) {
            Throws(delegate{using(var session=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password")){}},"login request");
            Assert(server.Requests.Count==2 && server.Bodies[0]==server.Bodies[1],"Repeated login reset exceeded one retry or changed its body.");
        }
        System.Console.WriteLine("Transport fixture: session connection isolation");
        var clientPorts=new System.Collections.Generic.List<int>();
        using(var server=new Server(delegate(System.Net.HttpListenerRequest request){clientPorts.Add(request.RemoteEndPoint.Port);ReadBody(request);return request.Url.AbsolutePath.EndsWith("/login") ? LoginResult("QA-SERIAL") : "{\"code\":0,\"data\":{\"ratio\":42}}";})) {
            using(var first=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password")) {
                first.ReadControl("brightness");
                using(var second=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password")) {
                    first.ReadControl("brightness");second.ReadControl("brightness");
                }
            }
            if(typeof(object).Assembly.GetName().Name=="mscorlib")
                Assert(clientPorts.Count==5 && clientPorts[0]==clientPorts[1] && clientPorts[0]==clientPorts[3] && clientPorts[2]==clientPorts[4] && clientPorts[0]!=clientPorts[2],"Session TCP reuse/isolation did not match connection groups.");
            else
                Assert(clientPorts.Count==5 && new System.Collections.Generic.HashSet<int>(clientPorts).Count==5,"Core requests reused a connection across pin/session boundaries.");
        }
        foreach(string operation in new[]{"start","end","control","upload"}) {
            System.Console.WriteLine("Transport fixture: no replay after reset for "+operation);
            int writes=0;
            using(var server=new ResetServer(delegate(string path,string body) {if(path.EndsWith("/login"))return LoginResult("QA-SERIAL");writes++;return "RESET";})) {
                using(var session=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password")) {
                    Throws(delegate {
                        if(operation=="start")session.StartTransfer("{}");
                        else if(operation=="end")session.EndTransfer("{}");
                        else if(operation=="control")session.WriteControl("brightness","{\"ratio\":42}");
                        else session.UploadFile(fixture,"sdcard/nova/viplex_terminal/media","fixture.bin",null);
                    },operation=="end" ? "Check the screen before retrying" : "request");
                }
                Assert(writes==1,"A "+operation+" write was replayed after TCP reset.");
            }
        }
        System.Console.WriteLine("Transport fixture: control acknowledgement envelopes");
        using(var server=new Server(delegate(System.Net.HttpListenerRequest request) {
            ReadBody(request);
            if(request.Url.AbsolutePath.EndsWith("/login"))return LoginResult("QA-SERIAL");
            Assert(request.HttpMethod==(request.Url.AbsolutePath.EndsWith("/time") ? "PUT" : "POST"),"Control setter method changed.");
            return "{\"code\":0,\"message\":\"private-response-field\"}";
        })) {
            using(var session=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password"))
                foreach(string section in new[]{"brightness","brightnessMode","colorTemperature","mosaic","time","ethernet"})
                    Assert(session.WriteControl(section,"{}")=="null","Native control acknowledgement without data was rejected or exposed response text.");
            Assert(server.Requests.Count==7,"Control acknowledgement caused an unexpected retry.");
        }
        foreach(string acknowledgement in new[]{"{\"code\":17,\"message\":\"private-response-field\"}","{}","{\"code\":\"0\"}","{\"code\":false}","{\"code\":0.5}","[]"}) {
            using(var server=new Server(delegate(System.Net.HttpListenerRequest request){ReadBody(request);return request.Url.AbsolutePath.EndsWith("/login") ? LoginResult("QA-SERIAL") : acknowledgement;})) {
                using(var session=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password")) {
                    var error=Throws(delegate{session.WriteControl("brightness","{\"ratio\":42}");},"");
                    Assert(error is System.InvalidOperationException && !error.Message.Contains("private-response-field"),"Malformed/rejected setter acknowledgement was accepted or leaked response text.");
                }
                Assert(server.Requests.Count==2,"Rejected setter acknowledgement was replayed.");
            }
        }
        using(var server=new Server(delegate(System.Net.HttpListenerRequest request){ReadBody(request);return "{\"code\":0}";})) {
            Throws(delegate{using(var session=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password")){}},"incomplete login response");
            Assert(server.Requests.Count==1,"Login without data was retried or accepted.");
        }
        foreach(string operation in new[]{"read","start","upload"}) {
            using(var server=new Server(delegate(System.Net.HttpListenerRequest request){ReadBody(request);return request.Url.AbsolutePath.EndsWith("/login") ? LoginResult("QA-SERIAL") : "{\"code\":0}";})) {
                using(var session=new RelayNetworkSession(server.Endpoint,Device(),"qa-only-password"))
                    Throws(delegate {
                        if(operation=="read")session.ReadControl("brightness");
                        else if(operation=="start")session.StartTransfer("{}");
                        else session.UploadFile(fixture,"sdcard/nova/viplex_terminal/media","fixture.bin",null);
                    },"incomplete");
                Assert(server.Requests.Count==2,"Missing-data allowance escaped control setters or caused a retry.");
            }
        }
        return "Network transport tests passed: discovery loss, identity fallback before credentials, receiver bounds, bounded login/GET recovery, no write replay, pinned reconnect validation, streaming upload, cancellation, diagnostics, and no redirects. Loopback only.";
    }
}
'@
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('RelayNetworkTransportTests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
try {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $compiledFixture=Join-Path $fixtureRoot 'transport-fixture.cs'
        [IO.File]::WriteAllText($compiledFixture,($transportSource+[Environment]::NewLine+$testSource))
        try { Add-Type -Path @($compiledFixture,(Join-Path $PSScriptRoot 'macos/StudioJsonCompat.cs')) -IgnoreWarnings -WarningAction SilentlyContinue }
        finally { [IO.File]::Delete($compiledFixture) }
    } else { Add-Type -TypeDefinition ($transportSource + [Environment]::NewLine + $testSource) -ReferencedAssemblies System.Web.Extensions }
    [RelayNetworkTransportTests]::Run($fixtureRoot)
} finally {
    $fixturePath = [IO.Path]::GetFullPath((Join-Path $fixtureRoot 'upload.bin'))
    if ($fixturePath.StartsWith([IO.Path]::GetFullPath($fixtureRoot) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and [IO.File]::Exists($fixturePath)) { [IO.File]::Delete($fixturePath) }
    [IO.Directory]::Delete($fixtureRoot, $false)
}

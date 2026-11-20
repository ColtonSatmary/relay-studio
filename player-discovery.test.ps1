# Pure scope checks and loopback HTTP only; never scans a real network.
$ErrorActionPreference='Stop'
$testCode=@'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;

public static class RelayPlayerDiscoveryTests {
    static void Assert(bool value,string message) {if(!value)throw new Exception(message);}
    sealed class Server:IDisposable {
        readonly HttpListener listener=new HttpListener();
        readonly Task worker;
        public Uri Endpoint;
        public readonly List<string> Paths=new List<string>();
        public bool HadCredentials,HadBody;
        public Server(string body,bool redirect=false) {
            var probe=new TcpListener(IPAddress.Loopback,0);probe.Start();int port=((IPEndPoint)probe.LocalEndpoint).Port;probe.Stop();
            Endpoint=new Uri("http://127.0.0.1:"+port+"/");listener.Prefixes.Add(Endpoint.AbsoluteUri);listener.Start();
            worker=Task.Run(delegate {
                while(listener.IsListening) {
                    HttpListenerContext context;
                    try {context=listener.GetContext();} catch {break;}
                    try {
                        Paths.Add(context.Request.HttpMethod+" "+context.Request.Url.AbsolutePath);
                        HadCredentials|=!String.IsNullOrEmpty(context.Request.Headers["Authorization"]) || !String.IsNullOrEmpty(context.Request.Headers["Cookie"]);
                        HadBody|=context.Request.HasEntityBody;
                        if(redirect) {context.Response.StatusCode=307;context.Response.RedirectLocation=Endpoint+"never-follow";}
                        else {byte[] bytes=Encoding.UTF8.GetBytes(body);context.Response.ContentType="application/json";context.Response.ContentLength64=bytes.Length;context.Response.OutputStream.Write(bytes,0,bytes.Length);}
                    } catch(HttpListenerException) {} finally {context.Response.Close();}
                }
            });
        }
        public void Dispose() {listener.Close();Assert(worker.Wait(5000),"Loopback fixture did not stop.");}
    }
    sealed class ResetServer:IDisposable {
        readonly TcpListener listener=new TcpListener(IPAddress.Loopback,0);
        readonly Task worker;
        volatile bool running=true;
        public Uri Endpoint;
        public readonly List<string> Requests=new List<string>();
        public ResetServer(string body,int resetCount) {
            listener.Start();Endpoint=new Uri("http://127.0.0.1:"+((IPEndPoint)listener.LocalEndpoint).Port+"/");
            worker=Task.Run(delegate {
                while(running) {
                    TcpClient client;
                    try {client=listener.AcceptTcpClient();} catch(SocketException) {if(!running)break;throw;}
                    using(client) {
                        var stream=client.GetStream();stream.ReadTimeout=2000;
                        var header=new StringBuilder();int value;
                        while(header.Length<8192 && (value=stream.ReadByte())>=0) {
                            header.Append((char)value);
                            if(header.ToString().EndsWith("\r\n\r\n",StringComparison.Ordinal))break;
                        }
                        Requests.Add(header.ToString());
                        if(Requests.Count<=resetCount) {client.Client.LingerState=new LingerOption(true,0);continue;}
                        byte[] bytes=Encoding.UTF8.GetBytes(body);
                        byte[] head=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "+bytes.Length+"\r\nConnection: close\r\n\r\n");
                        stream.Write(head,0,head.Length);stream.Write(bytes,0,bytes.Length);
                    }
                }
            });
        }
        public void Dispose() {running=false;listener.Stop();Assert(worker.Wait(5000),"Reset fixture did not stop.");}
    }
    public static string Run() {
        var lan=RelayPlayerDiscovery.Network("Wi-Fi","192.168.8.195","255.255.255.0");
        Assert(lan!=null && lan.ScanCidr=="192.168.8.0/24" && lan.Broadcast=="192.168.8.255" && lan.HostCount==253,"Wrong /24 scope.");
        Assert(RelayPlayerDiscovery.Contains(lan,"192.168.8.24"),"A LAN host was rejected.");
        foreach(string ip in new[]{"192.168.8.195","192.168.8.0","192.168.8.255","192.168.9.24","8.8.8.8","127.0.0.1","::1"})
            Assert(!RelayPlayerDiscovery.Contains(lan,ip),"Out-of-scope host accepted: "+ip);
        var broad=RelayPlayerDiscovery.Network("Ethernet","10.25.6.42","255.0.0.0");
        Assert(broad.ScanCidr=="10.25.6.0/24" && broad.HostCount==253 && broad.PrefixLength==8,"Broad local subnet was not capped.");
        var narrow=RelayPlayerDiscovery.Network("Ethernet","172.16.1.5","255.255.255.252");
        Assert(narrow.ScanCidr=="172.16.1.4/30" && narrow.HostCount==1 && RelayPlayerDiscovery.Contains(narrow,"172.16.1.6") && !RelayPlayerDiscovery.Contains(narrow,"172.16.1.7"),"Narrow scope expanded outside its subnet.");
        foreach(string ip in new[]{"8.8.8.8","127.0.0.1","100.100.1.1","0.0.0.0","224.0.0.1"})
            Assert(RelayPlayerDiscovery.Network("Invalid",ip,"255.255.255.0")==null,"Public/VPN scope was accepted.");
        Assert(RelayPlayerDiscovery.Network("Invalid","192.168.1.5","255.0.255.0")==null,"Invalid subnet mask accepted.");
        Assert(RelayPlayerDiscovery.Network("Single","192.168.1.5","255.255.255.255")==null,"Single-host scope accepted.");
        string valid="{\"code\":0,\"data\":{\"sn\":\"QA-SERIAL_7\",\"aliasName\":\"Lobby\",\"productName\":\"T50\",\"width\":1920,\"height\":1080,\"password\":\"must-not-escape\"}}";
        var identity=RelayPlayerDiscovery.ParseIdentity(valid,"192.168.8.24","fixture-cert");
        Assert(identity.Sn=="QA-SERIAL_7" && identity.Name=="Lobby" && identity.Model=="T50" && identity.Width==0 && identity.Height==0,"Identity shape invalid or version canvas mistaken for output geometry.");
        foreach(string body in new[]{"{\"code\":1,\"data\":{\"sn\":\"QA\"}}","{\"code\":0,\"data\":null}","{\"code\":0,\"data\":{\"sn\":\"bad serial\"}}","{\"data\":{\"sn\":\"QA\"}}"})
            Assert(RelayPlayerDiscovery.ParseIdentity(body,"192.168.8.24",null)==null,"Invalid identity accepted.");
        var merged=new Dictionary<string,RelayNetworkDevice>(StringComparer.Ordinal);
        RelayPlayerDiscovery.Merge(merged,new RelayNetworkDevice{Ip="192.168.8.24",Sn=identity.Sn,Name="UDP name",Width=320,Height=1080,HttpsPort=16674});
        RelayPlayerDiscovery.Merge(merged,identity);
        Assert(merged.Count==1 && merged[identity.Sn].Width==320 && merged[identity.Sn].Height==1080 && merged[identity.Sn].Name=="Lobby","Serial dedupe lost native dimensions or HTTPS identity.");
        var late=RelayPlayerDiscovery.ParseIdentity(valid,"192.168.8.25","second-cert");
        merged.Clear();RelayPlayerDiscovery.Merge(merged,late);
        RelayPlayerDiscovery.Merge(merged,new RelayNetworkDevice{Ip=late.Ip,Sn=late.Sn,Name="UDP name",Width=320,Height=1080});
        Assert(merged[late.Sn].Width==320 && merged[late.Sn].Height==1080 && merged[late.Sn].CertificateSha256=="second-cert","Late UDP round lost HTTPS identity or output dimensions.");
        Assert(RelayPlayerDiscovery.CanRetryProbe(new WebException("reset",null,WebExceptionStatus.ReceiveFailure,null)),"Receive reset was not retryable.");
        Assert(RelayPlayerDiscovery.CanRetryProbe(new WebException("reset",new SocketException((int)SocketError.ConnectionReset),WebExceptionStatus.ConnectFailure,null)),"Nested socket reset was not retryable.");
        foreach(var status in new[]{WebExceptionStatus.Timeout,WebExceptionStatus.RequestCanceled,WebExceptionStatus.ProtocolError,WebExceptionStatus.TrustFailure})
            Assert(!RelayPlayerDiscovery.CanRetryProbe(new WebException("no retry",null,status,null)),"Non-transient failure was retryable.");
        Assert(!RelayPlayerDiscovery.CanRetryProbe(new WebException("refused",new SocketException((int)SocketError.ConnectionRefused),WebExceptionStatus.ConnectFailure,null)),"Closed ports received retries.");
        using(var server=new Server(valid)) {
            var result=RelayPlayerDiscovery.Probe("192.168.8.24",server.Endpoint);
            Assert(result!=null && result.Sn==identity.Sn && result.Ip=="192.168.8.24","Read-only HTTPS probe shape failed.");
            Assert(server.Paths.Count==1 && server.Paths[0]=="GET /terminal/core/v1/version" && !server.HadCredentials && !server.HadBody,"Discovery sent credentials/body or used a mutating path.");
        }
        using(var server=new Server(valid,true)) {
            Assert(RelayPlayerDiscovery.Probe("192.168.8.24",server.Endpoint)==null && server.Paths.Count==1,"Discovery followed a redirect.");
        }
        using(var server=new Server(new string('x',65537))) Assert(RelayPlayerDiscovery.Probe("192.168.8.24",server.Endpoint)==null,"Discovery accepted an oversized body.");
        using(var server=new Server("not JSON")) Assert(RelayPlayerDiscovery.Probe("192.168.8.24",server.Endpoint)==null,"Discovery accepted invalid JSON.");
        // .NET may replay a GET internally. Drop the first two TCP responses so
        // at least one application retry is needed if it already replayed once.
        using(var server=new ResetServer(valid,2)) {
            var result=RelayPlayerDiscovery.Probe("192.168.8.24",server.Endpoint);
            Assert(result!=null && result.Sn==identity.Sn && server.Requests.Count>=3 && server.Requests.Count<=4,"Identity GET did not recover from connection resets within its retry bound.");
            foreach(string request in server.Requests) Assert(request.StartsWith("GET /terminal/core/v1/version HTTP/") && !request.Contains("Authorization:") && !request.Contains("Cookie:"),"Reset recovery changed the read-only request.");
        }
        return "Discovery scope, serial dedupe, read-only identity, bounded reset recovery, redirects and response bounds passed. No real network was scanned.";
    }
}
'@
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('RelayDiscoveryTests-'+[guid]::NewGuid().ToString('N')+'.cs')
try {
    [IO.File]::WriteAllText($fixture,$testCode,[Text.UTF8Encoding]::new($false))
    Add-Type -Path @((Join-Path $PSScriptRoot 'StudioNetworkTransport.cs'),(Join-Path $PSScriptRoot 'StudioPlayerDiscovery.cs'),$fixture) -ReferencedAssemblies 'System.Web.Extensions.dll'
    [RelayPlayerDiscoveryTests]::Run()
} finally {
    if([IO.File]::Exists($fixture)){[IO.File]::Delete($fixture)}
}

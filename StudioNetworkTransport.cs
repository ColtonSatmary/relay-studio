using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

// Protocol shapes verified against this machine's ViPlex Express 3.0.5 managed
// discovery and GatewayHttpRequest implementations. No vendor assembly is executed.
public sealed class RelayNetworkDevice {
    public string Ip { get; set; }
    public string Sn { get; set; }
    public string Name { get; set; }
    public string Model { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
    public int HttpsPort { get; set; }
    public string CertificateSha256 { get; set; }
}

internal sealed class RelayNetworkDiscoveryUnavailableException : InvalidOperationException {
    internal RelayNetworkDiscoveryUnavailableException(string message) : base(message) { }
}

public static class RelayNetworkTransport {
    internal const int MaximumJsonBytes = 2 * 1024 * 1024;
    internal static JavaScriptSerializer Json() {
        return new JavaScriptSerializer { MaxJsonLength = MaximumJsonBytes, RecursionLimit = 32 };
    }
    internal static Dictionary<string, object> Object(string json) {
        if (json == null || json.Length > MaximumJsonBytes) throw new InvalidOperationException("The player returned an oversized response.");
        try {
            var value = Json().DeserializeObject(json) as Dictionary<string, object>;
            if (value == null) throw new FormatException();
            return value;
        } catch { throw new InvalidOperationException("The player returned an invalid response."); }
    }
    internal static string Text(Dictionary<string, object> value, string key) {
        object result; return value.TryGetValue(key, out result) ? result as string : null;
    }
    internal static int Number(Dictionary<string, object> value, string key, int fallback) {
        object result;
        if (!value.TryGetValue(key, out result) || !(result is int)) return fallback;
        return (int)result;
    }
    internal static bool Flag(Dictionary<string, object> value, string key) {
        object result; return value.TryGetValue(key, out result) && result is bool && (bool)result;
    }
    internal static bool ValidSerial(string value) {
        return !String.IsNullOrWhiteSpace(value) && value.Length <= 128 && value.IndexOfAny(new[] {'\r','\n','\0'}) < 0;
    }
    public static string ValidateAddress(string address) {
        if (String.IsNullOrWhiteSpace(address)) throw new ArgumentException("Enter the player's local IPv4 address.");
        string[] parts = address.Split('.');
        if (parts.Length != 4) throw new ArgumentException("Enter the player's local IPv4 address.");
        var bytes = new byte[4];
        for (int i = 0; i < 4; i++) {
            int part;
            if (parts[i].Length == 0 || parts[i].Length > 3 || !Int32.TryParse(parts[i], out part) || part < 0 || part > 255)
                throw new ArgumentException("Enter the player's local IPv4 address.");
            for (int j = 0; j < parts[i].Length; j++) if (parts[i][j] < '0' || parts[i][j] > '9')
                throw new ArgumentException("Enter the player's local IPv4 address.");
            bytes[i] = (byte)part;
        }
        bool local = bytes[0] == 10 || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
            (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254) ||
            (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127);
        if (!local || bytes[3] == 0 || bytes[3] == 255)
            throw new ArgumentException("Choose one player on a private, link-local, or Tailscale IPv4 address.");
        return new IPAddress(bytes).ToString();
    }
    internal static short Checksum(byte[] data, int offset, int count) {
        short sum = 0;
        for (int i = offset; i < offset + count; i++) sum = unchecked((short)(sum + (sbyte)data[i]));
        return sum;
    }
    internal static byte[] DiscoveryPacket() {
        var data = new byte[24];
        Buffer.BlockCopy(BitConverter.GetBytes(1313822273), 0, data, 0, 4);
        Buffer.BlockCopy(BitConverter.GetBytes(-1), 0, data, 4, 4);
        Buffer.BlockCopy(BitConverter.GetBytes((ushort)34901), 0, data, 8, 2);
        Buffer.BlockCopy(BitConverter.GetBytes((ushort)129), 0, data, 10, 2);
        Buffer.BlockCopy(BitConverter.GetBytes(1), 0, data, 12, 4);
        Buffer.BlockCopy(BitConverter.GetBytes(Checksum(data, 0, 22)), 0, data, 22, 2);
        return data;
    }
    internal static RelayNetworkDevice ParseDiscovery(byte[] data, string ip) {
        if (data == null || data.Length < 24 || data.Length > 65507 || BitConverter.ToInt32(data, 0) != 1313822273 ||
            BitConverter.ToUInt16(data, 8) != 34901 || BitConverter.ToUInt16(data, 10) != 1 ||
            BitConverter.ToInt16(data, 22) != Checksum(data, 0, 22)) return null;
        int length = BitConverter.ToInt32(data, 16);
        if (length <= 0 || length != data.Length - 24 || BitConverter.ToInt16(data, 20) != Checksum(data, 24, length)) return null;
        Dictionary<string, object> json;
        try { json = Object(new UTF8Encoding(false, true).GetString(data, 24, length)); } catch { return null; }
        string sn = Text(json, "sn"), name = Text(json, "aliasName"), model = Text(json, "productName");
        if (!ValidSerial(sn)) return null;
        int width = Number(json, "width", 0), height = Number(json, "height", 0);
        if (width < 0 || height < 0 || width > 100000 || height > 100000) return null;
        return new RelayNetworkDevice {
            Ip = ip, Sn = sn, Name = !String.IsNullOrWhiteSpace(name) && name.Length <= 256 ? name : sn,
            Model = model != null && model.Length <= 128 ? model : "NovaStar player",
            Width = width, Height = height, HttpsPort = Number(json, "terminalEntrancePortHttps", 0)
        };
    }
    public static RelayNetworkDevice Discover(string ip, int timeoutMs) {
        ip = ValidateAddress(ip);
        if (timeoutMs < 250 || timeoutMs > 10000) throw new ArgumentOutOfRangeException("timeoutMs");
        return Discover(IPAddress.Parse(ip),timeoutMs);
    }
    static RelayNetworkDevice Discover(IPAddress target, int timeoutMs) {
        string ip = target.ToString();
        byte[] packet = DiscoveryPacket();
        using (var socket = new UdpClient(new IPEndPoint(IPAddress.Any, 0))) {
            var timer = Stopwatch.StartNew();
            long nextProbe = 0;
            RelayNetworkDevice legacy = null;
            while (timer.ElapsedMilliseconds < timeoutMs) {
                if (timer.ElapsedMilliseconds >= nextProbe) {
                    // Discovery is a read-only UDP query; a lost request or reply
                    // should not exhaust the whole connection check.
                    socket.Send(packet, packet.Length, new IPEndPoint(target, 16601));
                    socket.Send(packet, packet.Length, new IPEndPoint(target, 16611));
                    nextProbe = timer.ElapsedMilliseconds + 750;
                }
                long remaining = timeoutMs - timer.ElapsedMilliseconds;
                if (remaining <= 0) break;
                socket.Client.ReceiveTimeout = (int)Math.Max(1,Math.Min(300,Math.Min(remaining,nextProbe-timer.ElapsedMilliseconds)));
                var remote = new IPEndPoint(IPAddress.Any, 0);
                byte[] data;
                try { data = socket.Receive(ref remote); }
                catch (SocketException ex) {
                    if (ex.SocketErrorCode == SocketError.TimedOut || ex.SocketErrorCode == SocketError.ConnectionReset) continue;
                    throw new InvalidOperationException("Could not read the player discovery response.");
                }
                if (!remote.Address.Equals(target) || (remote.Port != 16601 && remote.Port != 16611)) continue;
                var device = ParseDiscovery(data, ip);
                if (device == null) continue;
                if (device.HttpsPort == 16674) return device;
                legacy = device;
            }
            if (legacy != null) return legacy;
        }
        throw new RelayNetworkDiscoveryUnavailableException("No NovaStar player answered at " + ip + ". Check the player network and allow its discovery traffic, then try again.");
    }
    public static RelayNetworkDevice Check(string ip, string password, string expectedSn) {
        using (var session = RelayNetworkSession.ConnectForCheck(ip, password, expectedSn)) return session.Device;
    }
}

public sealed class RelayNetworkSession : IDisposable {
    readonly Uri endpoint;
    readonly object gate = new object();
    readonly CancellationTokenSource cancellation = new CancellationTokenSource();
    readonly string connectionGroup = "RelayStudio-" + Guid.NewGuid().ToString("N");
    HttpWebRequest active;
    string token;
    string certificate;
    bool disposed;
    public RelayNetworkDevice Device { get; private set; }

    public RelayNetworkSession(string ip, string password, string expectedSn, string certificateSha256)
        : this(ip,password,expectedSn,certificateSha256,false) { }
    // Reconnect only from a previously checked server-owned device. UDP discovery
    // can be lost on Wi-Fi; the pinned HTTPS login revalidates the same serial.
    public RelayNetworkSession(RelayNetworkDevice checkedDevice, string password)
        : this(checkedDevice,password,null) { }
    internal RelayNetworkSession(RelayNetworkDevice checkedDevice, string password, Uri testEndpoint) {
        if (checkedDevice == null) throw new ArgumentException("Check the player's connection before continuing.");
        certificate = NormalizeFingerprint(checkedDevice.CertificateSha256);
        if (certificate == null || !RelayNetworkTransport.ValidSerial(checkedDevice.Sn) || checkedDevice.HttpsPort != 16674)
            throw new ArgumentException("Check the player's connection before continuing.");
        string ip = RelayNetworkTransport.ValidateAddress(checkedDevice.Ip);
        if (checkedDevice.Width < 0 || checkedDevice.Height < 0 || checkedDevice.Width > 100000 || checkedDevice.Height > 100000)
            throw new ArgumentException("Check the player's connection before continuing.");
        // Take an independent snapshot so callers cannot mutate the expected
        // identity or certificate while the session is connecting.
        Device = new RelayNetworkDevice {
            Ip=ip, Sn=checkedDevice.Sn, CertificateSha256=certificate, HttpsPort=16674,
            Name=!String.IsNullOrWhiteSpace(checkedDevice.Name) && checkedDevice.Name.Length <= 256 ? checkedDevice.Name : checkedDevice.Sn,
            Model=!String.IsNullOrWhiteSpace(checkedDevice.Model) && checkedDevice.Model.Length <= 128 ? checkedDevice.Model : "NovaStar player",
            Width=checkedDevice.Width, Height=checkedDevice.Height
        };
        endpoint = new Uri("https://" + ip + ":16674/");
        if (testEndpoint != null) {
            if (!testEndpoint.IsLoopback || testEndpoint.Scheme != "http" || testEndpoint.AbsolutePath != "/")
                throw new ArgumentException("The test endpoint must be loopback HTTP.");
            endpoint = testEndpoint;
        }
        try { Login(password); } catch { Dispose(); throw; }
    }
    internal static RelayNetworkSession ConnectForCheck(string ip, string password, string expectedSn) {
        return new RelayNetworkSession(ip,password,expectedSn,null,true);
    }
    RelayNetworkSession(string ip, string password, string expectedSn, string certificateSha256, bool initialCheck)
        : this(ip,password,expectedSn,certificateSha256,initialCheck,null,RelayNetworkTransport.Discover) { }
    // Loopback-only discovery injection exercises the initial-check fallback
    // without sending UDP or credentials to any real player.
    internal RelayNetworkSession(Uri testEndpoint, string password, string expectedSn, Func<string,int,RelayNetworkDevice> discovery)
        : this("192.168.1.2",password,expectedSn,null,true,testEndpoint,discovery) { }
    RelayNetworkSession(string ip, string password, string expectedSn, string certificateSha256, bool initialCheck,
        Uri testEndpoint, Func<string,int,RelayNetworkDevice> discovery) {
        if (testEndpoint != null && (!testEndpoint.IsLoopback || testEndpoint.Scheme != "http" || testEndpoint.AbsolutePath != "/"))
            throw new ArgumentException("The test endpoint must be loopback HTTP.");
        if (discovery == null) throw new ArgumentNullException("discovery");
        ip = RelayNetworkTransport.ValidateAddress(ip);
        certificate = NormalizeFingerprint(certificateSha256);
        if (!initialCheck && (certificate == null || String.IsNullOrWhiteSpace(expectedSn)))
            throw new ArgumentException("Check the player's connection before publishing.");
        bool probeIdentity = false;
        try { Device = discovery(ip,3000); }
        catch (RelayNetworkDiscoveryUnavailableException) {
            if (!initialCheck) throw;
            probeIdentity = true;
            Device = new RelayNetworkDevice {Ip=ip,HttpsPort=16674,Width=0,Height=0};
        }
        if (!probeIdentity && !String.IsNullOrWhiteSpace(expectedSn) && !String.Equals(Device.Sn, expectedSn, StringComparison.Ordinal))
            throw new InvalidOperationException("A different player is now using this address. Check the connection again.");
        if (Device.HttpsPort != 16674)
            throw new InvalidOperationException("This player did not advertise the supported network playback service. Use USB playback or ViPlex Express for this player.");
        endpoint = testEndpoint ?? new Uri("https://" + Device.Ip + ":16674/");
        try {
            if (probeIdentity) {
                ReadVersionIdentity();
                if (!String.IsNullOrWhiteSpace(expectedSn) && !String.Equals(Device.Sn,expectedSn,StringComparison.Ordinal))
                    throw new InvalidOperationException("A different player is now using this address. Check the connection again.");
            }
            Login(password);
            if (probeIdentity) TryReadOutputResolution();
        } catch { Dispose(); throw; }
    }
    // This constructor is used only by in-process transport tests. App routes
    // expose the IPv4 constructor above, never an endpoint URL or bypass switch.
    internal RelayNetworkSession(Uri testEndpoint, RelayNetworkDevice device, string password) {
        if (!testEndpoint.IsLoopback || testEndpoint.Scheme != "http" || testEndpoint.AbsolutePath != "/")
            throw new ArgumentException("The test endpoint must be loopback HTTP.");
        endpoint = testEndpoint; Device = device;
        try { Login(password); } catch { Dispose(); throw; }
    }
    static string NormalizeFingerprint(string value) {
        if (String.IsNullOrEmpty(value)) return null;
        if (value.Length != 64) throw new ArgumentException("Check the player's connection before publishing.");
        for (int i = 0; i < value.Length; i++) if (!Uri.IsHexDigit(value[i]))
            throw new ArgumentException("Check the player's connection before publishing.");
        return value.ToUpperInvariant();
    }
    bool ValidateCertificate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
        if (cert == null || cancellation.IsCancellationRequested) return false;
        string hash;
        using (var sha = SHA256.Create()) hash = BitConverter.ToString(sha.ComputeHash(cert.GetRawCertData())).Replace("-", "");
        lock (gate) {
            if (certificate != null && !String.Equals(certificate, hash, StringComparison.Ordinal)) return false;
            certificate = hash; Device.CertificateSha256 = hash;
        }
        return true;
    }
    void ReadVersionIdentity() {
        // Probe the fixed read-only identity endpoint before sending a password.
        // Its TLS certificate becomes the pin used by the following login.
        var data = RelayNetworkTransport.Object(RequestGet("/terminal/core/v1/version","read player identity"));
        string sn=RelayNetworkTransport.Text(data,"sn");
        if (!RelayNetworkTransport.ValidSerial(sn))
            throw new InvalidOperationException("The player did not return a valid identity. No password was sent.");
        if (endpoint.Scheme=="https" && certificate==null)
            throw new InvalidOperationException("The player's secure identity could not be verified. No password was sent.");
        string name=RelayNetworkTransport.Text(data,"aliasName");
        string model=RelayNetworkTransport.Text(data,"productName") ?? RelayNetworkTransport.Text(data,"model");
        Device.Sn=sn;
        Device.Name=!String.IsNullOrWhiteSpace(name) && name.Length<=256 ? name : sn;
        Device.Model=!String.IsNullOrWhiteSpace(model) && model.Length<=128 ? model : "NovaStar player";
    }
    void TryReadOutputResolution() {
        // Receiver-card bounds describe this player's output, not the larger
        // source canvas used by a mosaic. Missing/invalid geometry stays unknown.
        try {
            var data=RelayNetworkTransport.Object(RequestGet("/terminal/core/v1/monitor/receivercard/info","read output dimensions"));
            object value;
            if (!data.TryGetValue("receiveCardRegionInfo",out value)) return;
            var cards=value as object[];
            if (cards==null || cards.Length==0 || cards.Length>4096) return;
            int right=0,bottom=0;
            foreach (object item in cards) {
                var card=item as Dictionary<string,object>;
                if (card==null) return;
                int x=RelayNetworkTransport.Number(card,"X",-1),y=RelayNetworkTransport.Number(card,"Y",-1);
                int width=RelayNetworkTransport.Number(card,"width",0),height=RelayNetworkTransport.Number(card,"height",0);
                if (x<0 || y<0 || x>100000 || y>100000 || width<=0 || height<=0 || width>100000 || height>100000 ||
                    (long)x+width>100000 || (long)y+height>100000) return;
                right=Math.Max(right,x+width);bottom=Math.Max(bottom,y+height);
            }
            Device.Width=right;Device.Height=bottom;
        } catch { /* Output size is optional; verified identity/login remain valid. */ }
    }
    void Login(string password) {
        if (String.IsNullOrEmpty(password) || password.Length > 512) throw new ArgumentException("Enter the player password.");
        var payload = new Dictionary<string, object> {
            {"sn",Device.Sn},{"username","admin"},{"password",password},
            {"clientId",Guid.NewGuid().ToString("N")},{"clientName","Relay Studio"},{"loginType",9},
            {"source",new Dictionary<string,object>{{"type",0},{"platform",2},{"platformVersion","3.0.5"}}}
        };
        string serialized = RelayNetworkTransport.Json().Serialize(payload);
        try {
            var data = RelayNetworkTransport.Object(RequestJson("POST", "/terminal/core/v1/login", serialized, "login"));
            if (!RelayNetworkTransport.Flag(data,"logined") ||
                !(RelayNetworkTransport.Flag(data,"validation") || RelayNetworkTransport.Flag(data,"validition")))
                throw new InvalidOperationException("The player did not accept this login. Check its password.");
            if (!String.Equals(RelayNetworkTransport.Text(data,"sn"), Device.Sn, StringComparison.Ordinal))
                throw new InvalidOperationException("The player identity changed during login. Check the connection again.");
            string value = RelayNetworkTransport.Text(data,"token");
            if (String.IsNullOrWhiteSpace(value) || value.Length > 16384 || value.IndexOfAny(new[] {'\r','\n','\0'}) >= 0)
                throw new InvalidOperationException("The player did not return a valid login session.");
            token = value;
        } finally { payload["password"] = null; serialized = null; }
    }
    HttpWebRequest NewRequest(string method, string path, string contentType, long length) {
        if (disposed) throw new ObjectDisposedException("RelayNetworkSession");
        cancellation.Token.ThrowIfCancellationRequested();
        var request = (HttpWebRequest)WebRequest.Create(new Uri(endpoint, path));
        request.Method = method;
        request.Proxy = null;
        request.AllowAutoRedirect = false;
        // Core ignores ConnectionGroupName. Use fresh Core connections so a
        // second board/session cannot inherit a pooled TLS socket whose pin
        // was checked by another session. Framework keeps its isolated group.
        request.KeepAlive = typeof(object).Assembly.GetName().Name == "mscorlib";
        request.ConnectionGroupName = connectionGroup;
        request.AllowWriteStreamBuffering = false;
        request.Timeout = 30000;
        request.ReadWriteTimeout = 30000;
        request.Accept = "application/json";
        request.ContentType = contentType;
        request.ContentLength = length;
        request.ServicePoint.Expect100Continue = false;
        if (endpoint.Scheme == "https") {
            // The T50 closes the connection during SystemDefault negotiation on
            // this Windows host. Its native publisher uses TLS 1.2. Explicitly
            // select that protocol; certificate pinning still runs per request.
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            request.ServerCertificateValidationCallback = ValidateCertificate;
        }
        if (token != null) request.Headers[HttpRequestHeader.Authorization] = token;
        lock (gate) active = request;
        return request;
    }
    string ReadResult(HttpWebRequest request, string operation, bool allowMissingData=false) {
        using (var response = (HttpWebResponse)request.GetResponse()) {
            if ((int)response.StatusCode < 200 || (int)response.StatusCode >= 300)
                throw new InvalidOperationException("The player did not accept the " + operation + " request.");
            if (response.ContentLength > RelayNetworkTransport.MaximumJsonBytes)
                throw new InvalidOperationException("The player returned an oversized response.");
            using (var stream = response.GetResponseStream())
            using (var memory = new MemoryStream()) {
                var buffer = new byte[16384]; int count;
                while ((count = stream.Read(buffer,0,buffer.Length)) > 0) {
                    cancellation.Token.ThrowIfCancellationRequested();
                    if (memory.Length + count > RelayNetworkTransport.MaximumJsonBytes)
                        throw new InvalidOperationException("The player returned an oversized response.");
                    memory.Write(buffer,0,count);
                }
                var root = RelayNetworkTransport.Object(new UTF8Encoding(false,true).GetString(memory.ToArray()));
                int code = RelayNetworkTransport.Number(root,"code",Int32.MinValue);
                if (code != 0) throw new InvalidOperationException(code == Int32.MinValue
                    ? "The player returned an invalid " + operation + " response."
                    : "The player rejected the " + operation + " request (code " + code + ").");
                object data;
                if (!root.TryGetValue("data",out data) && !allowMissingData)
                    throw new InvalidOperationException("The player returned an incomplete " + operation + " response.");
                return RelayNetworkTransport.Json().Serialize(data);
            }
        }
    }
    Exception RequestError(WebException error, string operation) {
        // Only emit local enum names and numeric HTTP status. Remote messages,
        // headers and response bodies may contain credentials or other secrets.
        var response = error.Response as HttpWebResponse;
        string diagnostic = response == null ? error.Status.ToString()
            : "HTTP " + (int)response.StatusCode + "; " + error.Status;
        if (error.Response != null) error.Response.Dispose();
        if (cancellation.IsCancellationRequested) return new OperationCanceledException("Network transfer canceled.");
        if (error.Status == WebExceptionStatus.TrustFailure || error.Status == WebExceptionStatus.SecureChannelFailure)
            return new InvalidOperationException("The player's secure connection could not be verified (" + diagnostic + "). Check its connection again.");
        if (operation == "activate playback")
            return new InvalidOperationException("The player did not confirm playback activation (" + diagnostic + "). Check the screen before retrying.");
        return new InvalidOperationException("The player could not complete the " + operation + " request (" + diagnostic + "). Check its connection and try again.");
    }
    bool CanRetryConnection(WebException error) {
        if (cancellation.IsCancellationRequested) return false;
        if (error.Status == WebExceptionStatus.ReceiveFailure || error.Status == WebExceptionStatus.ConnectionClosed ||
            error.Status == WebExceptionStatus.ConnectFailure) return true;
        // .NET Core's HttpWebRequest wraps a premature response/reset as
        // UnknownError + HttpRequestException/HttpIOException. Recognize only
        // the typed transport categories, never remote text or all unknown
        // failures. Callers still limit recovery to one login/GET retry.
        if (error.Status == WebExceptionStatus.UnknownError) {
            for (Exception inner = error.InnerException; inner != null; inner = inner.InnerException) {
                var type = inner.GetType();
                if (type.FullName != "System.Net.Http.HttpRequestException" && type.FullName != "System.Net.Http.HttpIOException") continue;
                var property = type.GetProperty("HttpRequestError");
                string category = property == null ? null : Convert.ToString(property.GetValue(inner,null));
                if (category == "ConnectionError" || category == "ResponseEnded") return true;
            }
        }
        return false;
    }
    void CloseConnections() {
        if (endpoint != null) ServicePointManager.FindServicePoint(endpoint,null).CloseConnectionGroup(connectionGroup);
    }
    void ResetConnection(WebException error) {
        if (error.Response != null) error.Response.Dispose();
        CloseConnections();
    }
    string RequestJson(string method, string path, string json, string operation, bool allowMissingData=false) {
        RelayNetworkTransport.Object(json);
        byte[] body = Encoding.UTF8.GetBytes(json);
        try {
            for (int attempt=0;;attempt++) {
                var request = NewRequest(method,path,"application/json; charset=utf-8",body.Length);
                using (cancellation.Token.Register(request.Abort)) {
                    try {
                        using (var stream = request.GetRequestStream()) stream.Write(body,0,body.Length);
                        return ReadResult(request,operation,allowMissingData);
                    } catch (WebException ex) {
                        // Only login is safe to replay here. Reuse the exact
                        // body/clientId and never replay a playback/config write.
                        if (attempt==0 && operation=="login" && CanRetryConnection(ex)) { ResetConnection(ex); continue; }
                        throw RequestError(ex,operation);
                    } finally { lock (gate) if (active == request) active = null; }
                }
            }
        } finally { Array.Clear(body,0,body.Length); }
    }
    public string StartTransfer(string requestJson) {
        return RequestJson("PUT","/terminal/core/v1/play/transfer/start",requestJson,"prepare transfer");
    }
    static string ControlPath(string section) {
        switch (section) {
            case "brightness": return "/terminal/core/v1/brightness";
            case "brightnessMode": return "/terminal/core/v1/brightness/mode";
            case "colorTemperature": return "/terminal/core/v1/colorTemperature";
            case "mosaic": return "/terminal/core/v1/splice/hdmi";
            case "time": return "/terminal/core/v1/time";
            case "timeSync": return "/terminal/core/v1/time/net/config";
            case "ethernet": return "/terminal/core/v1/net/ethernet/info";
            case "wifiState": return "/terminal/core/v1/wifi/station/state";
            case "wifiNetworks": return "/terminal/core/v1/wifi/station/list";
            case "programs": return "/terminal/core/v1/play/program/list";
            default: throw new ArgumentException("Unknown player control.");
        }
    }
    public string ReadControl(string section) {
        return RequestGet(ControlPath(section),"read " + section);
    }
    public string RequestScreenCapture(int width, int height) {
        if (width < 1 || height < 1 || width > 640 || height > 640)
            throw new ArgumentException("Use a preview size of at most 640 pixels per side.");
        var options = new Dictionary<string,object> {{"width",width},{"height",height},{"type",1}};
        // Native ScreenShotManager requests a fresh JPEG frame with PUT. This
        // captures current output without selecting a program or editing settings.
        // Do not automatically replay a capture request after an unclear response.
        return RequestJson("PUT","/terminal/core/v1/screen/shot/get",RelayNetworkTransport.Json().Serialize(options),"capture screen preview");
    }
    internal static string ScreenCaptureDownloadPath(string filePath) {
        const string prefix = "/sdcard/nova/viplex_terminal/cache/screenShots/";
        if (String.IsNullOrEmpty(filePath) || !filePath.StartsWith(prefix,StringComparison.Ordinal))
            throw new InvalidOperationException("The player returned an unsupported screen preview location.");
        string leaf = filePath.Substring(prefix.Length);
        if (leaf.Length < 1 || leaf.Length > 160 || leaf == "." || leaf == "..")
            throw new InvalidOperationException("The player returned an invalid screen preview location.");
        foreach (char c in leaf) if (!(Char.IsLetterOrDigit(c) || c == '_' || c == '-' || c == '.'))
            throw new InvalidOperationException("The player returned an invalid screen preview location.");
        return "/terminal/tools/v1/file/download?filePath=" + Uri.EscapeDataString(filePath);
    }
    public byte[] ReadScreenCaptureFile(string filePath) {
        return ReadScreenCaptureFile(filePath,20000);
    }
    internal byte[] ReadScreenCaptureFile(string filePath,int totalTimeoutMs) {
        if(totalTimeoutMs < 100 || totalTimeoutMs > 20000) throw new ArgumentOutOfRangeException("totalTimeoutMs");
        string path = ScreenCaptureDownloadPath(filePath);
        const int maximumBytes = 8 * 1024 * 1024;
        var elapsed=Stopwatch.StartNew();
        for (int attempt=0;;attempt++) {
            int remaining=totalTimeoutMs-(int)elapsed.ElapsedMilliseconds;
            if(remaining<=0) throw new InvalidOperationException("The player screen preview download timed out.");
            var request = NewRequest("GET",path,"application/octet-stream",0);
            request.Accept = "image/jpeg,image/png,application/octet-stream";
            request.Timeout = Math.Min(15000,remaining); request.ReadWriteTimeout = Math.Min(15000,remaining);
            // Bound the whole download, including a slowly trickled response
            // and the one allowed read retry, rather than only each read call.
            using(var deadline=new Timer(delegate{request.Abort();},null,remaining,Timeout.Infinite))
            using (cancellation.Token.Register(request.Abort)) {
                try {
                    using (var response = (HttpWebResponse)request.GetResponse()) {
                        if ((int)response.StatusCode != 200 || response.ContentLength > maximumBytes)
                            throw new InvalidOperationException("The player returned an unavailable or oversized screen preview.");
                        using (var input = response.GetResponseStream())
                        using (var output = new MemoryStream()) {
                            var buffer = new byte[16384]; int count;
                            while ((count=input.Read(buffer,0,buffer.Length)) > 0) {
                                cancellation.Token.ThrowIfCancellationRequested();
                                if (output.Length + count > maximumBytes) throw new InvalidOperationException("The screen preview exceeds the download limit.");
                                output.Write(buffer,0,count);
                            }
                            if (output.Length == 0) throw new InvalidOperationException("The player returned an empty screen preview.");
                            return output.ToArray();
                        }
                    }
                } catch (WebException ex) {
                    if (attempt==0 && CanRetryConnection(ex)) {ResetConnection(ex);continue;}
                    throw RequestError(ex,"read screen preview");
                } finally {lock(gate) if(active==request) active=null;}
            }
        }
    }
    string RequestGet(string path, string operation) {
        for (int attempt=0;;attempt++) {
            var request = NewRequest("GET",path,"application/json",0);
            using (cancellation.Token.Register(request.Abort)) {
                try { return ReadResult(request,operation); }
                catch (WebException ex) {
                    if (attempt==0 && CanRetryConnection(ex)) { ResetConnection(ex); continue; }
                    throw RequestError(ex,operation);
                }
                finally { lock (gate) if (active == request) active = null; }
            }
        }
    }
    public string WriteControl(string section, string requestJson) {
        if (section != "brightness" && section != "brightnessMode" && section != "colorTemperature" &&
            section != "mosaic" && section != "time" && section != "ethernet")
            throw new ArgumentException("This player control is read only.");
        // Native control setters acknowledge successful writes with code:0 and
        // may omit data. Reads, login and playback transfers stay strict.
        return RequestJson(section == "time" ? "PUT" : "POST",ControlPath(section),requestJson,"apply " + section,true);
    }
    public string EndTransfer(string requestJson) {
        return RequestJson("PUT","/terminal/core/v1/play/transfer/end",requestJson,"activate playback");
    }
    public string UploadFile(string localPath, string targetDir, string fileName, Action<long,long> progress) {
        if (String.IsNullOrWhiteSpace(targetDir) || targetDir.Length > 2048 ||
            !targetDir.StartsWith("sdcard/nova/viplex_terminal/",StringComparison.Ordinal) ||
            targetDir.IndexOfAny(new[] {'\\','\r','\n','\0','?' ,'#'}) >= 0)
            throw new ArgumentException("The player returned an invalid upload directory.");
        foreach (string part in targetDir.Split('/')) if (part == "." || part == ".." || part.Length == 0)
            throw new ArgumentException("The player returned an invalid upload directory.");
        if (String.IsNullOrWhiteSpace(fileName) || fileName.Length > 255 || fileName == "." || fileName == ".." ||
            fileName.IndexOfAny(new[] {'/','\\','\r','\n','\0'}) >= 0)
            throw new ArgumentException("The package contains an invalid upload filename.");
        string path = "/terminal/tools/v1/file/uploadUseBinary?targetDir=" + Uri.EscapeDataString(targetDir) + "&fileName=" + Uri.EscapeDataString(fileName);
        using (var input = new FileStream(localPath,FileMode.Open,FileAccess.Read,FileShare.Read)) {
            var request = NewRequest("PUT",path,"application/octet-stream",input.Length);
            // Media writes and the player's completion response can be slower
            // over Wi-Fi. Keep the shorter timeout for login/control requests.
            request.Timeout = 120000;
            request.ReadWriteTimeout = 120000;
            using (cancellation.Token.Register(request.Abort)) {
                try {
                    using (var output = request.GetRequestStream()) {
                        var buffer = new byte[128*1024]; long sent = 0; int count;
                        if (progress != null) progress(0,input.Length);
                        while ((count = input.Read(buffer,0,buffer.Length)) > 0) {
                            cancellation.Token.ThrowIfCancellationRequested();
                            output.Write(buffer,0,count); sent += count;
                            if (progress != null) progress(sent,input.Length);
                        }
                    }
                    return ReadResult(request,"upload file");
                } catch (WebException ex) { throw RequestError(ex,"upload file"); }
                finally { lock (gate) if (active == request) active = null; }
            }
        }
    }
    public void Cancel() {
        if (disposed) return;
        cancellation.Cancel();
        lock (gate) if (active != null) active.Abort();
    }
    public void Dispose() {
        if (disposed) return;
        Cancel(); disposed = true; token = null;
        try { CloseConnections(); } finally { cancellation.Dispose(); }
    }
}

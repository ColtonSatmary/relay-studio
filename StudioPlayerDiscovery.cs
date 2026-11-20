using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

public sealed class RelayDiscoveryNetwork {
    public string Name { get; set; }
    public string Address { get; set; }
    public int PrefixLength { get; set; }
    public string ScanCidr { get; set; }
    public string Broadcast { get; set; }
    public int HostCount { get; set; }
    internal uint First, Last;
}

public sealed class RelayPlayerDiscoveryResult {
    public RelayNetworkDevice[] Devices { get; set; }
    public RelayDiscoveryNetwork[] Networks { get; set; }
    public int ProbedAddresses { get; set; }
    public string Message { get; set; }
    public string[] Warnings { get; set; }
}

// Read-only discovery. Never logs in, sends credentials or changes playback.
// These helpers share the native packet parser with the checked transport and
// must be compiled into the same assembly as StudioNetworkTransport.cs.
public static class RelayPlayerDiscovery {
    const int MaxNetworks = 4, ParallelProbes = 24, ProbeTimeout = 1800;
    static uint ToNumber(IPAddress address) {
        byte[] b = address.GetAddressBytes();
        if (b.Length != 4) throw new ArgumentException("Use an IPv4 address.");
        return ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3];
    }
    static string ToAddress(uint value) {
        return new IPAddress(new[] {(byte)(value >> 24), (byte)(value >> 16), (byte)(value >> 8), (byte)value}).ToString();
    }
    internal static RelayDiscoveryNetwork Network(string name, string address, string mask) {
        IPAddress ip, subnet;
        if (!IPAddress.TryParse(address, out ip) || !IPAddress.TryParse(mask, out subnet) ||
            ip.AddressFamily != AddressFamily.InterNetwork || subnet.AddressFamily != AddressFamily.InterNetwork) return null;
        byte[] bytes = ip.GetAddressBytes();
        // Discovery is restricted to physical LAN ranges; remote VPN ranges
        // remain available through the existing manual-IP connection flow.
        if (!(bytes[0] == 10 || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
              (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254))) return null;
        uint bits = ToNumber(subnet), inverse = ~bits;
        if ((inverse & (inverse + 1)) != 0) return null;
        int prefix = 0;
        for (uint bit = 0x80000000; bit != 0 && (bits & bit) != 0; bit >>= 1) prefix++;
        if (prefix > 30) return null;
        int scanPrefix = Math.Max(24, prefix);
        uint scanMask = UInt32.MaxValue << (32 - scanPrefix), self = ToNumber(ip);
        uint start = self & scanMask, end = start | ~scanMask;
        return new RelayDiscoveryNetwork {
            Name = name, Address = ip.ToString(), PrefixLength = prefix,
            ScanCidr = ToAddress(start) + "/" + scanPrefix, Broadcast = ToAddress(end),
            First = start + 1, Last = end - 1, HostCount = (int)(end - start - 2)
        };
    }
    public static RelayDiscoveryNetwork[] GetNetworks() {
        var found = new List<RelayDiscoveryNetwork>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces()) {
            if (nic.OperationalStatus != OperationalStatus.Up ||
                (nic.NetworkInterfaceType != NetworkInterfaceType.Wireless80211 &&
                 nic.NetworkInterfaceType != NetworkInterfaceType.Ethernet &&
                 nic.NetworkInterfaceType != NetworkInterfaceType.GigabitEthernet &&
                 nic.NetworkInterfaceType != NetworkInterfaceType.FastEthernetT)) continue;
            if (Regex.IsMatch(nic.Name + " " + nic.Description,
                "virtual|vpn|tailscale|hyper-v|loopback|tunnel|vmware|zerotier|wireguard|tap-windows|wintun|bluetooth", RegexOptions.IgnoreCase)) continue;
            IPInterfaceProperties properties;
            try { properties = nic.GetIPProperties(); } catch (NetworkInformationException) { continue; }
            foreach (var item in properties.UnicastAddresses) {
                if (item.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                // .NET exposes duplicate-address state only on Windows. On
                // macOS, use the IPv4 addresses of the active LAN interface.
                if (Environment.OSVersion.Platform == PlatformID.Win32NT &&
                    item.DuplicateAddressDetectionState != DuplicateAddressDetectionState.Preferred) continue;
                var network = Network(nic.Name, item.Address.ToString(), item.IPv4Mask.ToString());
                if (network != null && network.HostCount > 0 && seen.Add(network.ScanCidr)) found.Add(network);
            }
        }
        found.Sort(delegate(RelayDiscoveryNetwork a, RelayDiscoveryNetwork b) {
            int linkLocal = a.Address.StartsWith("169.254.").CompareTo(b.Address.StartsWith("169.254."));
            return linkLocal != 0 ? linkLocal : StringComparer.Ordinal.Compare(a.Address, b.Address);
        });
        return found.ToArray();
    }
    internal static bool Contains(RelayDiscoveryNetwork network, string address) {
        IPAddress ip;
        if (!IPAddress.TryParse(address, out ip) || ip.AddressFamily != AddressFamily.InterNetwork) return false;
        uint value = ToNumber(ip);
        return value >= network.First && value <= network.Last && address != network.Address;
    }
    internal static bool IsValidDevice(RelayNetworkDevice device) {
        return device != null && !String.IsNullOrEmpty(device.Sn) &&
            Regex.IsMatch(device.Sn, "^[A-Za-z0-9_-]{1,128}$");
    }
    internal static void Merge(Dictionary<string, RelayNetworkDevice> found, RelayNetworkDevice device) {
        if (!IsValidDevice(device)) return;
        lock (found) {
            RelayNetworkDevice old;
            if (!found.TryGetValue(device.Sn, out old)) { found[device.Sn] = device; return; }
            // Prefer the HTTPS identity when a board answers through two paths,
            // retaining dimensions that are only available in its UDP response.
            if (String.Equals(old.Ip, device.Ip, StringComparison.Ordinal)) {
                if (device.Width == 0 && old.Width > 0) device.Width = old.Width;
                if (device.Height == 0 && old.Height > 0) device.Height = old.Height;
                if (old.Width == 0 && device.Width > 0) old.Width = device.Width;
                if (old.Height == 0 && device.Height > 0) old.Height = device.Height;
                if (device.Name == device.Sn && old.Name != old.Sn) device.Name = old.Name;
                if (!String.IsNullOrEmpty(device.CertificateSha256)) found[device.Sn] = device;
            } else if (String.IsNullOrEmpty(old.CertificateSha256) && !String.IsNullOrEmpty(device.CertificateSha256)) found[device.Sn] = device;
        }
    }
    static void Broadcast(RelayDiscoveryNetwork network, Dictionary<string, RelayNetworkDevice> found, List<string> warnings) {
        try {
            using (var socket = new UdpClient(new IPEndPoint(IPAddress.Parse(network.Address), 0))) {
                socket.EnableBroadcast = true;
                byte[] packet = RelayNetworkTransport.DiscoveryPacket();
                var watch = Stopwatch.StartNew(); long next = 0;
                while (watch.ElapsedMilliseconds < 2400) {
                    if (watch.ElapsedMilliseconds >= next) {
                        foreach (int port in new[] {16601, 16611}) socket.Send(packet, packet.Length, new IPEndPoint(IPAddress.Parse(network.Broadcast), port));
                        next += 750;
                    }
                    socket.Client.ReceiveTimeout = 200;
                    var sender = new IPEndPoint(IPAddress.Any, 0);
                    byte[] data;
                    try { data = socket.Receive(ref sender); }
                    catch (SocketException ex) {
                        if (ex.SocketErrorCode == SocketError.TimedOut || ex.SocketErrorCode == SocketError.ConnectionReset) continue;
                        throw;
                    }
                    string address = sender.Address.ToString();
                    if ((sender.Port != 16601 && sender.Port != 16611) || !Contains(network, address)) continue;
                    Merge(found, RelayNetworkTransport.ParseDiscovery(data, address));
                }
            }
        } catch (SocketException) {
            lock (warnings) warnings.Add("UDP discovery was unavailable on " + network.ScanCidr + "; HTTPS discovery was still attempted.");
        }
    }
    internal static RelayNetworkDevice ParseIdentity(string json, string ip, string certificate) {
        var root = RelayNetworkTransport.Object(json);
        if (RelayNetworkTransport.Number(root, "code", -1) != 0) return null;
        object value;
        if (!root.TryGetValue("data", out value)) return null;
        var data = value as Dictionary<string, object>;
        if (data == null) return null;
        string sn = RelayNetworkTransport.Text(data, "sn");
        string name = RelayNetworkTransport.Text(data, "aliasName");
        string model = RelayNetworkTransport.Text(data, "productName") ?? RelayNetworkTransport.Text(data, "model");
        var device = new RelayNetworkDevice {
            Ip = ip, Sn = sn, Name = !String.IsNullOrWhiteSpace(name) && name.Length <= 256 ? name : sn,
            Model = !String.IsNullOrWhiteSpace(model) && model.Length <= 128 ? model : "NovaStar player",
            HttpsPort = 16674, CertificateSha256 = certificate
        };
        return IsValidDevice(device) ? device : null;
    }
    internal static bool CanRetryProbe(WebException error) {
        // Refused ports and timeouts are normal on other LAN devices. Only a
        // broken in-progress connection warrants another read-only identity GET.
        if (error.Status == WebExceptionStatus.ReceiveFailure || error.Status == WebExceptionStatus.ConnectionClosed ||
            error.Status == WebExceptionStatus.KeepAliveFailure) return true;
        Exception cause = error;
        while (cause != null) {
            var socket = cause as SocketException;
            if (socket != null && (socket.SocketErrorCode == SocketError.ConnectionReset ||
                socket.SocketErrorCode == SocketError.ConnectionAborted || socket.SocketErrorCode == SocketError.NetworkReset)) return true;
            cause = cause.InnerException;
        }
        return false;
    }
    internal static RelayNetworkDevice Probe(string ip, Uri testEndpoint) {
        Uri endpoint = new Uri("https://" + RelayNetworkTransport.ValidateAddress(ip) + ":16674/terminal/core/v1/version");
        if (testEndpoint != null) {
            if (!testEndpoint.IsLoopback || testEndpoint.Scheme != "http" || testEndpoint.AbsolutePath != "/") throw new ArgumentException("Only loopback HTTP test endpoints are supported.");
            endpoint = new Uri(testEndpoint, "terminal/core/v1/version");
        }
        var watch = Stopwatch.StartNew();
        for (int attempt = 0; attempt < 2; attempt++) {
            int remaining = ProbeTimeout - (int)watch.ElapsedMilliseconds;
            if (remaining < 250) return null;
            var request = (HttpWebRequest)WebRequest.Create(endpoint);
            request.Method = "GET"; request.Proxy = null; request.AllowAutoRedirect = false;
            request.KeepAlive = false; request.Timeout = remaining; request.ReadWriteTimeout = remaining;
            request.Accept = "application/json";
            string certificate = null;
            if (endpoint.Scheme == "https") {
                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
                // A discovery observation is not a checked session or trust grant.
                // No credentials are sent; the check/login flow re-verifies identity.
                request.ServerCertificateValidationCallback = delegate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
                    if (cert == null) return false;
                    using (var sha = SHA256.Create()) certificate = BitConverter.ToString(sha.ComputeHash(cert.GetRawCertData())).Replace("-", "");
                    return true;
                };
            }
            using (var deadline = new Timer(delegate { request.Abort(); }, null, remaining, Timeout.Infinite)) {
                try {
                    using (var response = (HttpWebResponse)request.GetResponse()) {
                        if ((int)response.StatusCode != 200 || response.ContentLength > 65536) return null;
                        using (var input = response.GetResponseStream())
                        using (var bytes = new MemoryStream()) {
                            byte[] buffer = new byte[4096]; int count;
                            while ((count = input.Read(buffer, 0, buffer.Length)) > 0) {
                                if (bytes.Length + count > 65536) return null;
                                bytes.Write(buffer, 0, count);
                            }
                            if (endpoint.Scheme == "https" && certificate == null) return null;
                            return ParseIdentity(new UTF8Encoding(false, true).GetString(bytes.ToArray()), ip, certificate);
                        }
                    }
                } catch (WebException ex) {
                    if (ex.Response != null) ex.Response.Dispose();
                    if (attempt == 0 && CanRetryProbe(ex)) continue;
                    return null;
                }
                catch (IOException) { return null; }
                catch (InvalidOperationException) { return null; }
                catch (DecoderFallbackException) { return null; }
                finally { request.Abort(); }
            }
        }
        return null;
    }
    public static RelayPlayerDiscoveryResult Scan() {
        var available = GetNetworks();
        var networks = new List<RelayDiscoveryNetwork>(available);
        var warnings = new List<string>();
        if (networks.Count > MaxNetworks) {
            networks.RemoveRange(MaxNetworks, networks.Count - MaxNetworks);
            warnings.Add("Discovery scanned the first four active LAN interfaces. Use a manual IP for other interfaces.");
        }
        if (networks.Count == 0) return new RelayPlayerDiscoveryResult {
            Devices = new RelayNetworkDevice[0], Networks = new RelayDiscoveryNetwork[0], Warnings = new string[0],
            Message = "No active Wi-Fi or Ethernet IPv4 network was found. Connect to the players' network and try again."
        };
        var found = new Dictionary<string, RelayNetworkDevice>(StringComparer.Ordinal);
        Parallel.ForEach(networks, new ParallelOptions {MaxDegreeOfParallelism = MaxNetworks}, delegate(RelayDiscoveryNetwork network) { Broadcast(network, found, warnings); });
        var addresses = new List<string>(); var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var network in networks) for (uint value = network.First; value <= network.Last; value++) {
            string ip = ToAddress(value);
            if (ip != network.Address && seen.Add(ip)) addresses.Add(ip);
        }
        int probed = 0; var watch = Stopwatch.StartNew();
        Parallel.ForEach(addresses, new ParallelOptions {MaxDegreeOfParallelism = ParallelProbes}, delegate(string address) {
            if (watch.ElapsedMilliseconds >= 85000) return;
            Interlocked.Increment(ref probed);
            Merge(found, Probe(address, null));
        });
        // A second short broadcast window catches boards whose first replies
        // were lost or delayed while keeping the scan's target range unchanged.
        Parallel.ForEach(networks, new ParallelOptions {MaxDegreeOfParallelism = MaxNetworks}, delegate(RelayDiscoveryNetwork network) { Broadcast(network, found, warnings); });
        if (probed < addresses.Count) warnings.Add("Discovery reached its time limit. Try again to check remaining addresses.");
        var devices = new List<RelayNetworkDevice>(found.Values);
        devices.Sort(delegate(RelayNetworkDevice a, RelayNetworkDevice b) { return ToNumber(IPAddress.Parse(a.Ip)).CompareTo(ToNumber(IPAddress.Parse(b.Ip))); });
        return new RelayPlayerDiscoveryResult {
            Devices = devices.ToArray(), Networks = networks.ToArray(), ProbedAddresses = probed, Warnings = warnings.ToArray(),
            Message = "Found " + devices.Count + " player" + (devices.Count == 1 ? "" : "s") + ". Scanned " + probed + " addresses on " + networks.Count + " local network" + (networks.Count == 1 ? "" : "s") + ". Discovery does not change playback."
        };
    }
}

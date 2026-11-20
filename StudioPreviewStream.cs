using System;
using System.Collections.Concurrent;
using System.Globalization;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Threading.Tasks;

// Response ownership moves here so a paused video cannot block the scheduler's
// single request loop. The selected file stays open for verification and serving.
public static class StudioPreviewStream {
    private static readonly ConcurrentDictionary<string, string> verified =
        new ConcurrentDictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    public static void Send(HttpListenerRequest request, HttpListenerResponse response,
                            string path, string mime, string md5, long expectedLength) {
        Task.Run(() => Serve(request, response, path, mime, md5, expectedLength));
    }

    private static bool ValidFile(FileStream stream, string path, string expected, long length) {
        if (stream.Length != length || length == 0) return false;
        if (String.IsNullOrEmpty(expected)) return true;
        string stamp = expected + "|" + stream.Length + "|" + File.GetLastWriteTimeUtc(path).Ticks;
        string previous;
        if (verified.TryGetValue(path, out previous) && previous == stamp) return true;
        using (var md5 = MD5.Create()) {
            string actual = BitConverter.ToString(md5.ComputeHash(stream)).Replace("-", "");
            if (!actual.Equals(expected, StringComparison.OrdinalIgnoreCase)) return false;
        }
        verified[path] = stamp;
        return true;
    }

    private static bool ReadRange(string header, long length, out long first, out long last) {
        first = 0;
        last = length - 1;
        if (header == null) return true;
        if (!header.StartsWith("bytes=", StringComparison.OrdinalIgnoreCase)) return false;
        var parts = header.Substring(6).Trim().Split('-');
        if (parts.Length != 2) return false;
        long value;
        if (parts[0] == "") {
            if (!ReadNumber(parts[1], out value) || value == 0) return false;
            first = length - Math.Min(value, length);
        } else {
            if (!ReadNumber(parts[0], out first) || first >= length) return false;
            if (parts[1] != "") {
                if (!ReadNumber(parts[1], out value) || value < first) return false;
                last = Math.Min(last, value);
            }
        }
        return true;
    }

    private static bool ReadNumber(string text, out long value) {
        return Int64.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out value);
    }

    private static async Task Serve(HttpListenerRequest request, HttpListenerResponse response,
                                    string path, string mime, string md5, long expectedLength) {
        try {
            using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
                                              65536, FileOptions.Asynchronous | FileOptions.SequentialScan)) {
                if (!ValidFile(file, path, md5, expectedLength)) {
                    response.StatusCode = 409;
                    response.ContentLength64 = 0;
                    return;
                }
                long first, last;
                var range = request.Headers["Range"];
                response.Headers["Accept-Ranges"] = "bytes";
                if (!ReadRange(range, file.Length, out first, out last)) {
                    response.StatusCode = 416;
                    response.Headers["Content-Range"] = "bytes */" + file.Length;
                    response.ContentLength64 = 0;
                    return;
                }
                if (range != null) {
                    response.StatusCode = 206;
                    response.Headers["Content-Range"] = String.Format(CultureInfo.InvariantCulture,
                        "bytes {0}-{1}/{2}", first, last, file.Length);
                }
                long remaining = last - first + 1;
                response.ContentType = mime;
                response.ContentLength64 = remaining;
                if (request.HttpMethod == "HEAD") return;
                file.Position = first;
                byte[] buffer = new byte[65536];
                while (remaining > 0) {
                    int count = await file.ReadAsync(buffer, 0, (int)Math.Min(buffer.Length, remaining)).ConfigureAwait(false);
                    if (count == 0) throw new EndOfStreamException();
                    await response.OutputStream.WriteAsync(buffer, 0, count).ConfigureAwait(false);
                    remaining -= count;
                }
            }
        } catch (FileNotFoundException) {
            response.StatusCode = 404;
            response.ContentLength64 = 0;
        } catch (Exception) {
            // Browsers routinely abandon a transfer when the user seeks or
            // selects a different solution. Release its file and connection.
            try { response.Abort(); } catch (ObjectDisposedException) {}
        } finally {
            try { response.Close(); } catch (HttpListenerException) {} catch (ObjectDisposedException) {}
        }
    }
}

// WinPrestige cloud helpers, compiled at runtime by lib\Cloud.ps1 (C# 5, .NET Framework 4.7.2+).
// HTTP with streamed uploads/downloads, file hashes the providers report back, AWS SigV4 signing,
// the loopback listener that receives an OAuth redirect, and DPAPI for stored tokens.
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;

namespace WinPrestige
{
    public class HttpResult
    {
        public int Status;
        public string Body = "";
        public string Error = "";
        public Dictionary<string, string> Headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public string Header(string name) { string v; return Headers.TryGetValue(name, out v) ? v : ""; }
        public bool Ok { get { return Status >= 200 && Status < 300; } }
    }

    // A window onto part of a file, so one chunk can be sent without loading it into memory.
    class FileSegmentStream : Stream
    {
        readonly FileStream inner; readonly long start, length; long pos;
        public FileSegmentStream(string path, long offset, long count)
        {
            inner = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 20);
            start = offset; length = count; inner.Position = offset;
        }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return true; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { return length; } }
        public override long Position { get { return pos; } set { pos = value; inner.Position = start + value; } }
        public override int Read(byte[] buffer, int offset, int count)
        {
            if (CloudHttp.Cancel) throw new OperationCanceledException("Cancelled");
            long left = length - pos;
            if (left <= 0) return 0;
            int n = inner.Read(buffer, offset, (int)Math.Min(count, left));
            pos += n;
            Interlocked.Add(ref CloudHttp.BytesSent, n);
            return n;
        }
        public override long Seek(long offset, SeekOrigin origin)
        {
            long p = origin == SeekOrigin.Begin ? offset : origin == SeekOrigin.Current ? pos + offset : length + offset;
            Position = p; return p;
        }
        public override void Flush() { }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
        protected override void Dispose(bool disposing) { if (disposing) inner.Dispose(); base.Dispose(disposing); }
    }

    public static class CloudHttp
    {
        public static volatile bool Cancel;
        public static long BytesSent;
        public static int TimeoutSeconds = 120;
        public static string UserAgent = "WinPrestige";
        // Self-hosted servers often use their own certificate. The user approves it once by thumbprint.
        public static HashSet<string> TrustedThumbprints = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        public static string LastCertThumbprint = "";
        public static string LastCertSubject = "";
        static readonly HttpClient follow, noFollow;

        static CloudHttp()
        {
            try { ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12 | (SecurityProtocolType)12288; }
            catch { ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; }
            ServicePointManager.Expect100Continue = false;
            ServicePointManager.DefaultConnectionLimit = 16;
            follow = Make(true); noFollow = Make(false);
        }

        static HttpClient Make(bool redirect)
        {
            var h = new HttpClientHandler();
            h.AllowAutoRedirect = redirect;
            h.UseCookies = false;
            h.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            h.ServerCertificateCustomValidationCallback = Validate;
            var c = new HttpClient(h);
            c.Timeout = Timeout.InfiniteTimeSpan;
            return c;
        }

        static bool Validate(HttpRequestMessage req, X509Certificate2 cert, X509Chain chain, SslPolicyErrors errors)
        {
            if (errors == SslPolicyErrors.None) return true;
            if (cert == null) return false;
            LastCertThumbprint = cert.Thumbprint;
            LastCertSubject = cert.Subject;
            return TrustedThumbprints.Contains(cert.Thumbprint);
        }

        // headers: flat name/value pairs, e.g. { "Authorization", "Bearer x", "Content-Type", "application/json" }
        static void Apply(HttpRequestMessage req, string[] headers)
        {
            req.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
            if (headers == null) return;
            for (int i = 0; i + 1 < headers.Length; i += 2)
            {
                string n = headers[i], v = headers[i + 1];
                if (string.IsNullOrEmpty(n) || v == null) continue;
                bool contentHeader = n.StartsWith("Content-", StringComparison.OrdinalIgnoreCase);
                if (contentHeader)
                {
                    if (req.Content == null) continue;
                    req.Content.Headers.Remove(n);
                    req.Content.Headers.TryAddWithoutValidation(n, v);
                }
                else
                {
                    req.Headers.Remove(n);
                    req.Headers.TryAddWithoutValidation(n, v);
                }
            }
        }

        public static HttpResult Send(string method, string url, string[] headers, byte[] body, bool followRedirects)
        {
            var req = new HttpRequestMessage(new HttpMethod(method), url);
            if (body != null) req.Content = new ByteArrayContent(body);
            Apply(req, headers);
            return Run(req, followRedirects, null, 0);
        }

        public static HttpResult SendText(string method, string url, string[] headers, string body)
        {
            return Send(method, url, headers, body == null ? null : new UTF8Encoding(false).GetBytes(body), true);
        }

        // Sends bytes [offset, offset+length) of a file as the request body.
        public static HttpResult SendFile(string method, string url, string[] headers, string path, long offset, long length)
        {
            return SendFile(method, url, headers, path, offset, length, true);
        }

        public static HttpResult SendFile(string method, string url, string[] headers, string path, long offset, long length, bool followRedirects)
        {
            var req = new HttpRequestMessage(new HttpMethod(method), url);
            var content = new StreamContent(new FileSegmentStream(path, offset, length), 1 << 20);
            content.Headers.ContentLength = length;
            req.Content = content;
            Apply(req, headers);
            // Allow roughly 128 KB/s before giving up on a slow link.
            return Run(req, followRedirects, null, length / (128 * 1024));
        }

        public static HttpResult Download(string url, string[] headers, string outPath)
        {
            var req = new HttpRequestMessage(HttpMethod.Get, url);
            Apply(req, headers);
            return Run(req, true, outPath, 3600);
        }

        static HttpResult Run(HttpRequestMessage req, bool redirect, string outPath, long extraSeconds)
        {
            var r = new HttpResult();
            try
            {
                using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(TimeoutSeconds + Math.Max(0, extraSeconds))))
                using (var resp = (redirect ? follow : noFollow).SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token).GetAwaiter().GetResult())
                {
                    r.Status = (int)resp.StatusCode;
                    foreach (var h in resp.Headers) r.Headers[h.Key] = string.Join(",", h.Value);
                    if (resp.Content != null) foreach (var h in resp.Content.Headers) r.Headers[h.Key] = string.Join(",", h.Value);
                    if (resp.Headers.Location != null)
                        r.Headers["Location"] = resp.Headers.Location.IsAbsoluteUri ? resp.Headers.Location.AbsoluteUri : new Uri(req.RequestUri, resp.Headers.Location).AbsoluteUri;
                    if (resp.Content == null) return r;
                    if (outPath != null && r.Ok)
                    {
                        using (var s = resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
                        using (var f = new FileStream(outPath, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
                        {
                            var buf = new byte[1 << 20]; int n;
                            while ((n = s.Read(buf, 0, buf.Length)) > 0)
                            {
                                if (Cancel) throw new OperationCanceledException("Cancelled");
                                f.Write(buf, 0, n);
                                Interlocked.Add(ref BytesSent, n);
                            }
                        }
                    }
                    else r.Body = resp.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                }
            }
            catch (Exception e)
            {
                r.Status = 0;
                var sb = new StringBuilder();
                for (var x = e; x != null; x = x.InnerException) { if (sb.Length > 0) sb.Append(" "); sb.Append(x.Message); }
                r.Error = sb.ToString();
                if (outPath != null) { try { File.Delete(outPath); } catch { } }
            }
            finally { req.Dispose(); }
            return r;
        }
    }

    // OneDrive's QuickXorHash (published by Microsoft as a reference implementation; same algorithm).
    public class QuickXorHash : HashAlgorithm
    {
        const int BitsInLastCell = 32;
        const byte Shift = 11;
        const int WidthInBits = 160;
        ulong[] data;
        long lengthSoFar;
        int shiftSoFar;

        public QuickXorHash() { Initialize(); }

        protected override void HashCore(byte[] array, int ibStart, int cbSize)
        {
            unchecked
            {
                int currentShift = shiftSoFar;
                int vectorArrayIndex = currentShift / 64;
                int vectorOffset = currentShift % 64;
                int iterations = Math.Min(cbSize, WidthInBits);
                for (int i = 0; i < iterations; i++)
                {
                    bool isLastCell = vectorArrayIndex == data.Length - 1;
                    int bitsInVectorCell = isLastCell ? BitsInLastCell : 64;
                    if (vectorOffset <= bitsInVectorCell - 8)
                    {
                        for (int j = ibStart + i; j < cbSize + ibStart; j += WidthInBits)
                            data[vectorArrayIndex] ^= (ulong)array[j] << vectorOffset;
                    }
                    else
                    {
                        int index1 = vectorArrayIndex;
                        int index2 = isLastCell ? 0 : (vectorArrayIndex + 1);
                        byte low = (byte)(bitsInVectorCell - vectorOffset);
                        byte xoredByte = 0;
                        for (int j = ibStart + i; j < cbSize + ibStart; j += WidthInBits)
                            xoredByte ^= array[j];
                        data[index1] ^= (ulong)xoredByte << vectorOffset;
                        data[index2] ^= (ulong)xoredByte >> low;
                    }
                    vectorOffset += Shift;
                    while (vectorOffset >= bitsInVectorCell)
                    {
                        vectorArrayIndex = isLastCell ? 0 : vectorArrayIndex + 1;
                        vectorOffset -= bitsInVectorCell;
                    }
                }
                shiftSoFar = (shiftSoFar + Shift * (cbSize % WidthInBits)) % WidthInBits;
            }
            lengthSoFar += cbSize;
        }

        protected override byte[] HashFinal()
        {
            byte[] rgb = new byte[(WidthInBits - 1) / 8 + 1];
            for (int i = 0; i < data.Length - 1; i++)
                Buffer.BlockCopy(BitConverter.GetBytes(data[i]), 0, rgb, i * 8, 8);
            Buffer.BlockCopy(BitConverter.GetBytes(data[data.Length - 1]), 0, rgb, (data.Length - 1) * 8, rgb.Length - (data.Length - 1) * 8);
            byte[] lengthBytes = BitConverter.GetBytes(lengthSoFar);
            for (int i = 0; i < lengthBytes.Length; i++)
                rgb[(WidthInBits / 8) - lengthBytes.Length + i] ^= lengthBytes[i];
            return rgb;
        }

        public override void Initialize()
        {
            data = new ulong[(WidthInBits - 1) / 64 + 1];
            shiftSoFar = 0;
            lengthSoFar = 0;
        }

        public override int HashSize { get { return WidthInBits; } }
    }

    public static class FileHash
    {
        static string Hex(byte[] b) { var sb = new StringBuilder(b.Length * 2); foreach (var x in b) sb.Append(x.ToString("x2")); return sb.ToString(); }

        static byte[] Run(HashAlgorithm h, string path)
        {
            using (h)
            using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 20))
            {
                var buf = new byte[1 << 20]; int n;
                while ((n = f.Read(buf, 0, buf.Length)) > 0)
                {
                    if (CloudHttp.Cancel) throw new OperationCanceledException("Cancelled");
                    h.TransformBlock(buf, 0, n, null, 0);
                }
                h.TransformFinalBlock(buf, 0, 0);
                return h.Hash;
            }
        }

        public static string QuickXor(string path) { return Convert.ToBase64String(Run(new QuickXorHash(), path)); }
        public static string Md5(string path) { return Hex(Run(MD5.Create(), path)); }
        public static string Sha1(string path) { return Hex(Run(SHA1.Create(), path)); }
        public static string Sha256(string path) { return Hex(Run(SHA256.Create(), path)); }
        public static string Sha256Text(string s) { using (var h = SHA256.Create()) return Hex(h.ComputeHash(new UTF8Encoding(false).GetBytes(s ?? ""))); }
        public static string Md5Base64Bytes(byte[] b) { using (var h = MD5.Create()) return Convert.ToBase64String(h.ComputeHash(b)); }

        // Dropbox content_hash: SHA-256 of the concatenated SHA-256 digests of each 4 MB block.
        public static string Dropbox(string path)
        {
            const int Block = 4 * 1024 * 1024;
            using (var outer = SHA256.Create())
            using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 20))
            {
                var buf = new byte[Block];
                while (true)
                {
                    int got = 0, n;
                    while (got < Block && (n = f.Read(buf, got, Block - got)) > 0) got += n;
                    if (got == 0) break;
                    if (CloudHttp.Cancel) throw new OperationCanceledException("Cancelled");
                    using (var inner = SHA256.Create())
                    {
                        var d = inner.ComputeHash(buf, 0, got);
                        outer.TransformBlock(d, 0, d.Length, null, 0);
                    }
                    if (got < Block) break;
                }
                outer.TransformFinalBlock(new byte[0], 0, 0);
                return Hex(outer.Hash);
            }
        }

        // The ETag S3 gives an object: MD5 for a single PUT, MD5-of-part-MD5s plus "-N" for multipart.
        public static string S3Etag(string path, long partSize)
        {
            long len = new FileInfo(path).Length;
            if (partSize <= 0 || len <= partSize) return Md5(path);
            using (var outer = MD5.Create())
            using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 20))
            {
                var buf = new byte[1 << 20]; int parts = 0;
                while (f.Position < len)
                {
                    using (var inner = MD5.Create())
                    {
                        long left = Math.Min(partSize, len - f.Position);
                        while (left > 0)
                        {
                            int n = f.Read(buf, 0, (int)Math.Min(buf.Length, left));
                            if (n <= 0) break;
                            inner.TransformBlock(buf, 0, n, null, 0);
                            left -= n;
                        }
                        inner.TransformFinalBlock(buf, 0, 0);
                        outer.TransformBlock(inner.Hash, 0, inner.Hash.Length, null, 0);
                        parts++;
                    }
                }
                outer.TransformFinalBlock(new byte[0], 0, 0);
                return Hex(outer.Hash) + "-" + parts;
            }
        }
    }

    // AWS Signature Version 4 for S3 and S3-compatible servers (MinIO, Garage, B2, Wasabi, R2...).
    public static class SigV4
    {
        static byte[] Hmac(byte[] key, string data) { using (var h = new HMACSHA256(key)) return h.ComputeHash(Encoding.UTF8.GetBytes(data)); }
        static string Hex(byte[] b) { var sb = new StringBuilder(b.Length * 2); foreach (var x in b) sb.Append(x.ToString("x2")); return sb.ToString(); }

        // Returns header name/value pairs to add: x-amz-date, x-amz-content-sha256, Authorization.
        // url must already be percent-encoded (RFC 3986). extraHeaders are also signed (lower-case names).
        // amzDate is "yyyyMMddTHHmmssZ"; empty means now.
        public static string[] Sign(string method, string url, string region, string service, string accessKey, string secretKey,
                                    string payloadHash, string[] extraHeaders, string amzDate)
        {
            var uri = new Uri(url);
            if (string.IsNullOrEmpty(amzDate)) amzDate = DateTime.UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'");
            string date = amzDate.Substring(0, 8);
            if (string.IsNullOrEmpty(payloadHash)) payloadHash = "UNSIGNED-PAYLOAD";

            var headers = new SortedDictionary<string, string>(StringComparer.Ordinal);
            headers["host"] = uri.IsDefaultPort ? uri.Host : uri.Authority;
            headers["x-amz-content-sha256"] = payloadHash;
            headers["x-amz-date"] = amzDate;
            if (extraHeaders != null)
                for (int i = 0; i + 1 < extraHeaders.Length; i += 2)
                    headers[extraHeaders[i].ToLowerInvariant()] = extraHeaders[i + 1].Trim();

            var query = new List<KeyValuePair<string, string>>();
            string q = uri.Query.TrimStart('?');
            if (q.Length > 0)
                foreach (var part in q.Split('&'))
                {
                    if (part.Length == 0) continue;
                    int eq = part.IndexOf('=');
                    query.Add(eq < 0 ? new KeyValuePair<string, string>(part, "") : new KeyValuePair<string, string>(part.Substring(0, eq), part.Substring(eq + 1)));
                }
            query.Sort(delegate (KeyValuePair<string, string> a, KeyValuePair<string, string> b)
            {
                int c = string.CompareOrdinal(a.Key, b.Key);
                return c != 0 ? c : string.CompareOrdinal(a.Value, b.Value);
            });
            var cq = new StringBuilder();
            foreach (var kv in query) { if (cq.Length > 0) cq.Append('&'); cq.Append(kv.Key).Append('=').Append(kv.Value); }

            var ch = new StringBuilder(); var sh = new StringBuilder();
            foreach (var kv in headers)
            {
                ch.Append(kv.Key).Append(':').Append(kv.Value).Append('\n');
                if (sh.Length > 0) sh.Append(';');
                sh.Append(kv.Key);
            }
            string path = uri.AbsolutePath;
            if (string.IsNullOrEmpty(path)) path = "/";
            string canonical = method + "\n" + path + "\n" + cq + "\n" + ch + "\n" + sh + "\n" + payloadHash;
            string scope = date + "/" + region + "/" + service + "/aws4_request";
            string toSign = "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + FileHash.Sha256Text(canonical);
            byte[] k = Hmac(Encoding.UTF8.GetBytes("AWS4" + secretKey), date);
            k = Hmac(k, region); k = Hmac(k, service); k = Hmac(k, "aws4_request");
            string sig = Hex(Hmac(k, toSign));
            string auth = "AWS4-HMAC-SHA256 Credential=" + accessKey + "/" + scope + ", SignedHeaders=" + sh + ", Signature=" + sig;
            return new[] { "x-amz-date", amzDate, "x-amz-content-sha256", payloadHash, "Authorization", auth };
        }
    }

    // Receives the browser's redirect after an OAuth sign-in (http://localhost:port/?code=...).
    public static class Loopback
    {
        public static int FreePort()
        {
            var l = new TcpListener(IPAddress.Loopback, 0); l.Start();
            int p = ((IPEndPoint)l.LocalEndpoint).Port; l.Stop(); return p;
        }

        // Returns the request target ("/?code=...&state=..."), or null on timeout/cancel.
        public static string WaitForRedirect(int port, int timeoutSeconds, string html)
        {
            var listeners = new List<TcpListener>();
            foreach (var ip in new[] { IPAddress.Loopback, IPAddress.IPv6Loopback })
            {
                try { var l = new TcpListener(ip, port); l.Start(); listeners.Add(l); } catch { }
            }
            if (listeners.Count == 0) throw new InvalidOperationException("Port " + port + " is in use.");
            try
            {
                var end = DateTime.UtcNow.AddSeconds(timeoutSeconds);
                while (DateTime.UtcNow < end && !CloudHttp.Cancel)
                {
                    TcpListener ready = null;
                    foreach (var l in listeners) if (l.Pending()) { ready = l; break; }
                    if (ready == null) { Thread.Sleep(150); continue; }
                    using (var client = ready.AcceptTcpClient())
                    {
                        client.ReceiveTimeout = 5000; client.SendTimeout = 5000;
                        var s = client.GetStream();
                        var buf = new byte[16384]; int got = 0;
                        try
                        {
                            while (got < buf.Length)
                            {
                                int n = s.Read(buf, got, buf.Length - got);
                                if (n <= 0) break;
                                got += n;
                                if (Encoding.ASCII.GetString(buf, 0, got).Contains("\r\n\r\n")) break;
                            }
                        }
                        catch (IOException) { continue; }
                        string head = Encoding.ASCII.GetString(buf, 0, got);
                        string first = head.Split(new[] { "\r\n" }, StringSplitOptions.None)[0];
                        string[] bits = first.Split(' ');
                        string target = bits.Length >= 2 ? bits[1] : "/";
                        bool real = bits.Length >= 2 && bits[0] == "GET" && target.IndexOf('?') >= 0;
                        string body = real ? html : "Not found";
                        byte[] payload = Encoding.UTF8.GetBytes(body);
                        string resp = (real ? "HTTP/1.1 200 OK" : "HTTP/1.1 404 Not Found") + "\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " + payload.Length + "\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n";
                        byte[] hb = Encoding.ASCII.GetBytes(resp);
                        try { s.Write(hb, 0, hb.Length); s.Write(payload, 0, payload.Length); s.Flush(); } catch { }
                        if (real) return target;
                    }
                }
                return null;
            }
            finally { foreach (var l in listeners) { try { l.Stop(); } catch { } } }
        }
    }

    // Tokens and passwords are stored encrypted for the current Windows user (DPAPI).
    public static class Secret
    {
        static readonly byte[] Entropy = Encoding.UTF8.GetBytes("WinPrestige cloud accounts v1");
        public static string Protect(string plain)
        {
            return Convert.ToBase64String(ProtectedData.Protect(new UTF8Encoding(false).GetBytes(plain ?? ""), Entropy, DataProtectionScope.CurrentUser));
        }
        public static string Unprotect(string blob)
        {
            if (string.IsNullOrEmpty(blob)) return "";
            return new UTF8Encoding(false).GetString(ProtectedData.Unprotect(Convert.FromBase64String(blob), Entropy, DataProtectionScope.CurrentUser));
        }
        public static string RandomUrlSafe(int bytes)
        {
            var b = new byte[bytes];
            using (var r = RandomNumberGenerator.Create()) r.GetBytes(b);
            return Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        }
        public static string PkceChallenge(string verifier)
        {
            using (var h = SHA256.Create())
                return Convert.ToBase64String(h.ComputeHash(Encoding.ASCII.GetBytes(verifier))).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        }
    }
}

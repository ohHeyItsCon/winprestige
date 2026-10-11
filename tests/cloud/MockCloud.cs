// Test-only mock of the cloud APIs WinPrestige talks to. In-memory, one listener, prefixes per service.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public class MockCloud
{
    HttpListener l; Thread t; public string Base; public List<string> Log = new List<string>();
    public string S3Access = "AKTEST", S3Secret = "s3secret", S3Region = "us-east-1";
    public bool FailNextS3Put;   // one transient 503, to exercise retries
    public int Requests;

    // shared stores
    Dictionary<string, byte[]> files = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
    HashSet<string> folders = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    Dictionary<string, string> sums = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    object gate = new object();

    public MockCloud(int port)
    {
        Base = "http://localhost:" + port;
        l = new HttpListener(); l.Prefixes.Add(Base + "/"); l.Start();
        t = new Thread(Loop); t.IsBackground = true; t.Start();
    }
    public void Stop() { try { l.Stop(); } catch { } }

    void Loop()
    {
        while (l.IsListening)
        {
            HttpListenerContext c;
            try { c = l.GetContext(); } catch { return; }
            ThreadPool.QueueUserWorkItem(delegate { Handle(c); });
        }
    }

    static string RawPath(HttpListenerContext c) { return c.Request.RawUrl.Split('?')[0]; }
    static byte[] Read(HttpListenerRequest r) { using (var ms = new MemoryStream()) { r.InputStream.CopyTo(ms); return ms.ToArray(); } }
    static string Hex(byte[] b) { return string.Concat(b.Select(x => x.ToString("x2"))); }
    static string Md5(byte[] b) { using (var h = MD5.Create()) return Hex(h.ComputeHash(b)); }
    static string Sha1(byte[] b) { using (var h = SHA1.Create()) return Hex(h.ComputeHash(b)); }
    static string Esc(string s) { return System.Security.SecurityElement.Escape(s); }

    void Send(HttpListenerContext c, int status, string body, string type, Dictionary<string, string> headers)
    {
        try
        {
            c.Response.StatusCode = status;
            if (headers != null) foreach (var kv in headers) c.Response.Headers[kv.Key] = kv.Value;
            var b = Encoding.UTF8.GetBytes(body ?? "");
            if (type != null) c.Response.ContentType = type;
            c.Response.ContentLength64 = b.Length;
            c.Response.OutputStream.Write(b, 0, b.Length);
            c.Response.Close();
        }
        catch { }
    }
    void SendBytes(HttpListenerContext c, byte[] b)
    {
        try { c.Response.StatusCode = 200; c.Response.ContentType = "application/octet-stream"; c.Response.ContentLength64 = b.Length; c.Response.OutputStream.Write(b, 0, b.Length); c.Response.Close(); } catch { }
    }
    void Json(HttpListenerContext c, int status, string json) { Send(c, status, json, "application/json", null); }

    void Handle(HttpListenerContext c)
    {
        Interlocked.Increment(ref Requests);
        string path = RawPath(c);
        lock (Log) Log.Add(c.Request.HttpMethod + " " + c.Request.RawUrl);
        try
        {
            if (path.StartsWith("/oauth/")) OAuth(c);
            else if (path.StartsWith("/dav/")) Dav(c, "/dav/", "dav", "user", "pw1");
            else if (path.StartsWith("/nc/")) Nextcloud(c);
            else if (path.StartsWith("/s3/")) S3(c);
            else if (path.StartsWith("/graph/")) Graph(c);
            else if (path.StartsWith("/gd/")) Drive(c);
            else if (path.StartsWith("/dbx")) Dropbox(c);
            else Send(c, 404, "no route", "text/plain", null);
        }
        catch (Exception e) { Send(c, 500, e.ToString(), "text/plain", null); }
    }

    // ---------------- OAuth ----------------
    void OAuth(HttpListenerContext c)
    {
        var q = c.Request.QueryString;
        if (RawPath(c) == "/oauth/authorize")
        {
            if (string.IsNullOrEmpty(q["code_challenge"]) || q["code_challenge_method"] != "S256") { Send(c, 400, "pkce missing", "text/plain", null); return; }
            pendingChallenge = q["code_challenge"];
            var to = q["redirect_uri"] + (q["redirect_uri"].Contains("?") ? "&" : "?") + "code=c-" + Guid.NewGuid().ToString("N") + "&state=" + Uri.EscapeDataString(q["state"]);
            Send(c, 302, "", null, new Dictionary<string, string> { { "Location", to } });
            return;
        }
        var form = ParseForm(Encoding.UTF8.GetString(Read(c.Request)));
        if (form.ContainsKey("grant_type") && form["grant_type"] == "authorization_code")
        {
            string ch;
            using (var h = SHA256.Create()) ch = Convert.ToBase64String(h.ComputeHash(Encoding.ASCII.GetBytes(form["code_verifier"]))).TrimEnd('=').Replace('+', '-').Replace('/', '_');
            if (ch != pendingChallenge) { Json(c, 400, "{\"error\":\"invalid_grant\",\"error_description\":\"PKCE mismatch\"}"); return; }
            Json(c, 200, "{\"access_token\":\"at-1\",\"refresh_token\":\"rt-1\",\"expires_in\":3600}");
        }
        else if (form.ContainsKey("grant_type") && form["grant_type"] == "refresh_token" && form["refresh_token"] == "rt-1")
            Json(c, 200, "{\"access_token\":\"at-2\",\"refresh_token\":\"rt-1\",\"expires_in\":3600}");
        else Json(c, 400, "{\"error\":\"invalid_grant\"}");
    }
    string pendingChallenge = "";
    static Dictionary<string, string> ParseForm(string s)
    {
        var d = new Dictionary<string, string>();
        foreach (var p in s.Split('&')) { if (p.Length == 0) continue; var kv = p.Split(new[] { '=' }, 2); d[Uri.UnescapeDataString(kv[0])] = kv.Length > 1 ? Uri.UnescapeDataString(kv[1].Replace('+', ' ')) : ""; }
        return d;
    }
    bool Bearer(HttpListenerContext c)
    {
        var a = c.Request.Headers["Authorization"] ?? "";
        if (a == "Bearer at-1" || a == "Bearer at-2") return true;
        Json(c, 401, "{\"error\":{\"message\":\"bad token\"}}"); return false;
    }

    // ---------------- WebDAV (+ Nextcloud) ----------------
    void Dav(HttpListenerContext c, string prefix, string ns, string user, string pass)
    {
        var want = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(user + ":" + pass));
        if (c.Request.Headers["Authorization"] != want) { Send(c, 401, "auth", "text/plain", new Dictionary<string, string> { { "WWW-Authenticate", "Basic realm=\"x\"" } }); return; }
        string raw = RawPath(c).Substring(prefix.Length);
        string rel = Uri.UnescapeDataString(raw).Trim('/');
        string key = ns + ":" + rel;
        string m = c.Request.HttpMethod;
        lock (gate)
        {
            if (m == "PROPFIND")
            {
                Read(c.Request);
                bool isDir = rel == "" || folders.Contains(key);
                if (!isDir && !files.ContainsKey(key)) { Send(c, 404, "", null, null); return; }
                var depth = c.Request.Headers["Depth"] ?? "1";
                var sb = new StringBuilder("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\" xmlns:oc=\"http://owncloud.org/ns\">");
                Action<string, bool> add = delegate (string r, bool dir)
                {
                    string href = prefix + string.Join("/", r.Split('/').Where(x => x.Length > 0).Select(Uri.EscapeDataString)) + (dir ? "/" : "");
                    sb.Append("<d:response><d:href>" + Esc(href.Replace("//", "/")) + "</d:href><d:propstat><d:prop>");
                    if (dir) sb.Append("<d:resourcetype><d:collection/></d:resourcetype><d:quota-available-bytes>123456789</d:quota-available-bytes>");
                    else
                    {
                        sb.Append("<d:resourcetype/><d:getcontentlength>" + files[ns + ":" + r].Length + "</d:getcontentlength>");
                        string s; if (sums.TryGetValue(ns + ":" + r, out s)) sb.Append("<oc:checksums><oc:checksum>SHA1:" + s + " MD5:x</oc:checksum></oc:checksums>");
                    }
                    sb.Append("</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>");
                    if (dir) sb.Append("<d:propstat><d:prop><oc:checksums/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>");
                    sb.Append("</d:response>");
                };
                add(rel, isDir);
                if (isDir && depth != "0")
                {
                    string pre = rel == "" ? ns + ":" : key + "/";
                    foreach (var f in folders.Where(x => x.StartsWith(pre, StringComparison.OrdinalIgnoreCase) && x.Substring(pre.Length).IndexOf('/') < 0).ToList()) add(f.Substring(ns.Length + 1), true);
                    foreach (var f in files.Keys.Where(x => x.StartsWith(pre, StringComparison.OrdinalIgnoreCase) && x.Substring(pre.Length).IndexOf('/') < 0).ToList()) add(f.Substring(ns.Length + 1), false);
                }
                sb.Append("</d:multistatus>");
                Send(c, 207, sb.ToString(), "application/xml; charset=utf-8", null);
            }
            else if (m == "MKCOL")
            {
                if (folders.Contains(key)) { Send(c, 405, "exists", null, null); return; }
                string parent = rel.Contains("/") ? ns + ":" + rel.Substring(0, rel.LastIndexOf('/')) : null;
                if (parent != null && !folders.Contains(parent)) { Send(c, 409, "no parent", null, null); return; }
                folders.Add(key); Send(c, 201, "", null, null);
            }
            else if (m == "PUT")
            {
                string parent = rel.Contains("/") ? ns + ":" + rel.Substring(0, rel.LastIndexOf('/')) : null;
                if (parent != null && !folders.Contains(parent)) { Send(c, 409, "no parent", null, null); return; }
                var b = Read(c.Request);
                var oc = c.Request.Headers["OC-Checksum"];
                if (oc != null) { if (oc != "SHA1:" + Sha1(b)) { Send(c, 400, "checksum mismatch", null, null); return; } sums[key] = Sha1(b); }
                else sums.Remove(key);
                files[key] = b; Send(c, 201, "", null, null);
            }
            else if (m == "GET") { byte[] b; if (files.TryGetValue(key, out b)) SendBytes(c, b); else Send(c, 404, "", null, null); }
            else if (m == "DELETE")
            {
                bool any = files.Remove(key) | folders.Remove(key);
                foreach (var k in files.Keys.Where(x => x.StartsWith(key + "/", StringComparison.OrdinalIgnoreCase)).ToList()) files.Remove(k);
                Send(c, any ? 204 : 404, "", null, null);
            }
            else Send(c, 405, "", null, null);
        }
    }

    bool ncGranted;
    Dictionary<string, SortedDictionary<int, byte[]>> chunks = new Dictionary<string, SortedDictionary<int, byte[]>>();
    void Nextcloud(HttpListenerContext c)
    {
        string p = RawPath(c);
        if (p == "/nc/index.php/login/v2" && c.Request.HttpMethod == "POST") { Json(c, 200, "{\"poll\":{\"token\":\"tok1\",\"endpoint\":\"" + Base + "/nc/login/v2/poll\"},\"login\":\"" + Base + "/nc/login/v2/flow/tok1\"}"); return; }
        if (p == "/nc/login/v2/flow/tok1") { ncGranted = true; Send(c, 200, "granted", "text/plain", null); return; }
        if (p == "/nc/login/v2/poll")
        {
            var f = ParseForm(Encoding.UTF8.GetString(Read(c.Request)));
            if (ncGranted && f.ContainsKey("token") && f["token"] == "tok1") Json(c, 200, "{\"server\":\"" + Base + "/nc\",\"loginName\":\"user@example.com\",\"appPassword\":\"app-pw\"}");
            else Send(c, 404, "[]", "application/json", null);
            return;
        }
        var want = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes("user@example.com:app-pw"));
        var want2 = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes("user:app-pw"));
        var auth = c.Request.Headers["Authorization"];
        if (p == "/nc/ocs/v2.php/cloud/user")
        {
            if (auth != want && auth != want2) { Send(c, 401, "", null, null); return; }
            if (c.Request.Headers["OCS-APIRequest"] != "true") { Send(c, 400, "need OCS header", null, null); return; }
            Json(c, 200, "{\"ocs\":{\"data\":{\"id\":\"user\",\"email\":\"user@example.com\",\"displayname\":\"User Name\",\"quota\":{\"free\":500000000000,\"total\":1000000000000}}}}");
            return;
        }
        if (p.StartsWith("/nc/remote.php/dav/files/user/") || p == "/nc/remote.php/dav/files/user") { Dav(c, "/nc/remote.php/dav/files/user/", "nc", "user", "app-pw"); return; }
        if (p.StartsWith("/nc/remote.php/dav/uploads/user/"))
        {
            if (auth != want2) { Send(c, 401, "", null, null); return; }
            string rest = p.Substring("/nc/remote.php/dav/uploads/user/".Length);
            string id = rest.Split('/')[0];
            string m = c.Request.HttpMethod;
            lock (gate)
            {
                if (m == "MKCOL") { if (c.Request.Headers["Destination"] == null) { Send(c, 400, "v2 needs Destination", null, null); return; } chunks[id] = new SortedDictionary<int, byte[]>(); Send(c, 201, "", null, null); return; }
                if (!chunks.ContainsKey(id)) { Send(c, 404, "", null, null); return; }
                if (m == "PUT") { int n = int.Parse(rest.Split('/')[1]); if (n < 1 || n > 10000) { Send(c, 400, "bad chunk", null, null); return; } chunks[id][n] = Read(c.Request); Send(c, 201, "", null, null); return; }
                if (m == "MOVE")
                {
                    var dest = new Uri(c.Request.Headers["Destination"]).AbsolutePath;
                    string rel = Uri.UnescapeDataString(dest.Substring("/nc/remote.php/dav/files/user/".Length)).Trim('/');
                    var all = chunks[id].Values.SelectMany(x => x).ToArray();
                    if (c.Request.Headers["OC-Total-Length"] != all.Length.ToString()) { Send(c, 400, "length mismatch", null, null); return; }
                    files["nc:" + rel] = all;
                    var oc = c.Request.Headers["OC-Checksum"]; if (oc != null) sums["nc:" + rel] = Sha1(all);
                    chunks.Remove(id); Send(c, 201, "", null, null); return;
                }
                if (m == "DELETE") { chunks.Remove(id); Send(c, 204, "", null, null); return; }
            }
        }
        Send(c, 404, "", null, null);
    }

    // ---------------- S3 (path style, SigV4 checked) ----------------
    Dictionary<string, Dictionary<int, byte[]>> mpu = new Dictionary<string, Dictionary<int, byte[]>>();
    void S3(HttpListenerContext c)
    {
        var auth = c.Request.Headers["Authorization"] ?? "";
        var amz = c.Request.Headers["x-amz-date"] ?? "";
        var ph = c.Request.Headers["x-amz-content-sha256"] ?? "";
        string url = Base + c.Request.RawUrl;
        var expect = WinPrestige.SigV4.Sign(c.Request.HttpMethod, url, S3Region, "s3", S3Access, S3Secret, ph, null, amz);
        if (expect[5] != auth) { Send(c, 403, "<Error><Code>SignatureDoesNotMatch</Code><Message>sig mismatch for " + Esc(c.Request.RawUrl) + "</Message></Error>", "application/xml", null); return; }
        string rawPath = c.Request.RawUrl.Split('?')[0];
        var parts = rawPath.Substring(4).Split(new[] { '/' }, 2);   // after "/s3/"
        string bucket = Uri.UnescapeDataString(parts[0]);
        if (bucket != "backups") { Send(c, 404, "<Error><Code>NoSuchBucket</Code><Message>no bucket</Message></Error>", "application/xml", null); return; }
        string objKey = parts.Length > 1 ? Uri.UnescapeDataString(parts[1]) : "";
        var q = c.Request.QueryString;
        string m = c.Request.HttpMethod;
        string k = "s3:" + objKey;
        lock (gate)
        {
            if (objKey == "" && m == "GET")
            {
                string prefix = q["prefix"] ?? "", delim = q["delimiter"];
                int max = q["max-keys"] != null ? int.Parse(q["max-keys"]) : 3;   // tiny pages to exercise continuation
                var keys = files.Keys.Where(x => x.StartsWith("s3:" + prefix, StringComparison.Ordinal)).Select(x => x.Substring(3)).OrderBy(x => x, StringComparer.Ordinal).ToList();
                var cps = new SortedSet<string>(StringComparer.Ordinal); var objs = new List<string>();
                foreach (var key in keys)
                {
                    var restk = key.Substring(prefix.Length);
                    if (delim != null && restk.Contains(delim)) cps.Add(prefix + restk.Substring(0, restk.IndexOf(delim) + 1)); else objs.Add(key);
                }
                var all = objs.Select(x => "O" + x).Concat(cps.Select(x => "P" + x)).OrderBy(x => x.Substring(1), StringComparer.Ordinal).ToList();
                int start = q["continuation-token"] != null ? int.Parse(q["continuation-token"]) : 0;
                var page = all.Skip(start).Take(max).ToList();
                bool more = start + max < all.Count;
                var sb = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult><Name>backups</Name><Prefix>" + Esc(prefix) + "</Prefix><KeyCount>" + page.Count + "</KeyCount><IsTruncated>" + (more ? "true" : "false") + "</IsTruncated>");
                if (more) sb.Append("<NextContinuationToken>" + (start + max) + "</NextContinuationToken>");
                foreach (var e in page)
                {
                    if (e[0] == 'O') { var key = e.Substring(1); sb.Append("<Contents><Key>" + Esc(key) + "</Key><Size>" + files["s3:" + key].Length + "</Size><ETag>&quot;" + sums["s3:" + key] + "&quot;</ETag></Contents>"); }
                    else sb.Append("<CommonPrefixes><Prefix>" + Esc(e.Substring(1)) + "</Prefix></CommonPrefixes>");
                }
                sb.Append("</ListBucketResult>");
                Send(c, 200, sb.ToString(), "application/xml", null); return;
            }
            if (m == "POST" && q["uploads"] != null || (m == "POST" && c.Request.RawUrl.EndsWith("?uploads")))
            {
                var id = "u" + Guid.NewGuid().ToString("N"); mpu[id] = new Dictionary<int, byte[]>();
                Send(c, 200, "<InitiateMultipartUploadResult><UploadId>" + id + "</UploadId></InitiateMultipartUploadResult>", "application/xml", null); return;
            }
            if (m == "PUT" && q["uploadId"] != null)
            {
                var b = Read(c.Request); mpu[q["uploadId"]][int.Parse(q["partNumber"])] = b;
                Send(c, 200, "", null, new Dictionary<string, string> { { "ETag", "\"" + Md5(b) + "\"" } }); return;
            }
            if (m == "POST" && q["uploadId"] != null)
            {
                var body = Encoding.UTF8.GetString(Read(c.Request));
                var up = mpu[q["uploadId"]];
                var tags = Regex.Matches(body, "<PartNumber>(\\d+)</PartNumber><ETag>&quot;([0-9a-f]+)&quot;</ETag>");
                if (tags.Count != up.Count) { Send(c, 200, "<Error><Code>InvalidPart</Code><Message>parts " + tags.Count + " vs " + up.Count + "</Message></Error>", "application/xml", null); return; }
                using (var outer = MD5.Create())
                {
                    var cat = new List<byte>();
                    foreach (Match t in tags) { var b = up[int.Parse(t.Groups[1].Value)]; if (Md5(b) != t.Groups[2].Value) { Send(c, 400, "<Error><Code>InvalidPart</Code><Message>etag</Message></Error>", "application/xml", null); return; } using (var h = MD5.Create()) cat.AddRange(h.ComputeHash(b)); }
                    var all = up.OrderBy(x => x.Key).SelectMany(x => x.Value).ToArray();
                    files[k] = all; sums[k] = Hex(outer.ComputeHash(cat.ToArray())) + "-" + up.Count;
                }
                mpu.Remove(q["uploadId"]);
                Send(c, 200, "<CompleteMultipartUploadResult><ETag>&quot;" + sums[k] + "&quot;</ETag></CompleteMultipartUploadResult>", "application/xml", null); return;
            }
            if (m == "DELETE" && q["uploadId"] != null) { mpu.Remove(q["uploadId"]); Send(c, 204, "", null, null); return; }
            if (m == "PUT")
            {
                var b = Read(c.Request);
                if (FailNextS3Put) { FailNextS3Put = false; Send(c, 503, "<Error><Code>SlowDown</Code><Message>try again</Message></Error>", "application/xml", null); return; }
                var cm = c.Request.Headers["Content-MD5"];
                if (cm != null) { using (var h = MD5.Create()) if (Convert.ToBase64String(h.ComputeHash(b)) != cm) { Send(c, 400, "<Error><Code>BadDigest</Code><Message>md5</Message></Error>", "application/xml", null); return; } }
                files[k] = b; sums[k] = Md5(b);
                Send(c, 200, "", null, new Dictionary<string, string> { { "ETag", "\"" + sums[k] + "\"" } }); return;
            }
            if (m == "GET") { byte[] b; if (files.TryGetValue(k, out b)) SendBytes(c, b); else Send(c, 404, "<Error><Code>NoSuchKey</Code><Message>none</Message></Error>", "application/xml", null); return; }
            if (m == "DELETE") { files.Remove(k); sums.Remove(k); Send(c, 204, "", null, null); return; }
        }
        Send(c, 400, "unsupported", null, null);
    }

    // ---------------- Microsoft Graph (approot subset) ----------------
    Dictionary<string, Tuple<string, long, MemoryStream>> odSessions = new Dictionary<string, Tuple<string, long, MemoryStream>>();
    static string QX(byte[] b) { using (var h = new WinPrestige.QuickXorHash()) return Convert.ToBase64String(h.ComputeHash(b)); }
    void Graph(HttpListenerContext c)
    {
        string p = RawPath(c), m = c.Request.HttpMethod;
        if (p.StartsWith("/graph/upload/"))
        {
            var id = p.Substring(14); var s = odSessions[id];
            var cr = c.Request.Headers["Content-Range"]; var mm = Regex.Match(cr, @"bytes (\d+)-(\d+)/(\d+)");
            var b = Read(c.Request);
            if (long.Parse(mm.Groups[1].Value) != s.Item3.Length) { Json(c, 416, "{\"error\":{\"message\":\"wrong offset\"}}"); return; }
            long total = long.Parse(mm.Groups[3].Value);
            if (b.Length % 327680 != 0 && s.Item3.Length + b.Length != total) { Json(c, 400, "{\"error\":{\"message\":\"chunk not multiple of 320 KiB\"}}"); return; }
            if (c.Request.Headers["Authorization"] != null) { Json(c, 400, "{\"error\":{\"message\":\"no auth header on upload URLs\"}}"); return; }
            s.Item3.Write(b, 0, b.Length);
            if (s.Item3.Length == total) { lock (gate) { files["od:" + s.Item1] = s.Item3.ToArray(); MakeParents("od:", s.Item1); } odSessions.Remove(id); Json(c, 201, "{\"id\":\"x\"}"); }
            else Json(c, 202, "{\"nextExpectedRanges\":[\"" + s.Item3.Length + "-\"]}");
            return;
        }
        if (p.StartsWith("/graph/dl/")) { byte[] b; lock (gate) files.TryGetValue("od:" + Uri.UnescapeDataString(p.Substring(10)), out b); if (c.Request.Headers["Authorization"] != null) { Send(c, 400, "no auth on download urls", null, null); return; } if (b == null) Send(c, 404, "", null, null); else SendBytes(c, b); return; }
        if (!Bearer(c)) return;
        if (p == "/graph/v1.0/me") { Json(c, 200, "{\"displayName\":\"User Name\",\"userPrincipalName\":\"user@example.com\",\"mail\":null}"); return; }
        if (p == "/graph/v1.0/me/drive") { Json(c, 200, "{\"quota\":{\"remaining\":900000000000,\"total\":1099511627776}}"); return; }
        const string root = "/graph/v1.0/me/drive/special/approot";
        if (!p.StartsWith(root)) { Json(c, 404, "{}"); return; }
        string rest = p.Substring(root.Length), rel = "", op = "";
        if (rest.StartsWith(":/"))
        {
            int end = rest.IndexOf(':', 2);
            rel = Uri.UnescapeDataString(rest.Substring(2, end - 2)).Trim('/');
            op = rest.Substring(end + 1).Trim('/');
        }
        else op = rest.Trim('/');
        lock (gate)
        {
            if (op == "" && rel == "" && m == "GET") { Json(c, 200, "{\"id\":\"approot\",\"webUrl\":\"https://onedrive.live.com/?id=approot\"}"); return; }
            if (op == "children")
            {
                if (rel != "" && !folders.Contains("od:" + rel)) { Json(c, 404, "{\"error\":{\"code\":\"itemNotFound\",\"message\":\"nope\"}}"); return; }
                string pre = rel == "" ? "od:" : "od:" + rel + "/";
                var kids = new List<string>();
                foreach (var f in folders.Where(x => x.StartsWith(pre, StringComparison.OrdinalIgnoreCase) && x.Substring(pre.Length).IndexOf('/') < 0)) kids.Add("{\"id\":\"f\",\"name\":\"" + JsonEsc(f.Substring(pre.Length)) + "\",\"folder\":{\"childCount\":1}}");
                foreach (var f in files.Keys.Where(x => x.StartsWith(pre, StringComparison.OrdinalIgnoreCase) && x.Substring(pre.Length).IndexOf('/') < 0)) kids.Add("{\"id\":\"i\",\"name\":\"" + JsonEsc(f.Substring(pre.Length)) + "\",\"size\":" + files[f].Length + ",\"file\":{\"hashes\":{\"quickXorHash\":\"" + QX(files[f]) + "\"}}}");
                // two pages, to exercise @odata.nextLink
                int skip = c.Request.QueryString["skip"] != null ? int.Parse(c.Request.QueryString["skip"]) : 0;
                var page = kids.Skip(skip).Take(4).ToList();
                string next = skip + 4 < kids.Count ? ",\"@odata.nextLink\":\"" + Base + RawPath(c) + "?skip=" + (skip + 4) + "\"" : "";
                Json(c, 200, "{\"value\":[" + string.Join(",", page) + "]" + next + "}"); return;
            }
            if (op == "content" && m == "PUT") { var b = Read(c.Request); if (b.Length > 4 * 1024 * 1024) { Json(c, 413, "{\"error\":{\"message\":\"too big for simple upload\"}}"); return; } files["od:" + rel] = b; MakeParents("od:", rel); Json(c, 201, "{\"id\":\"n\"}"); return; }
            if (op == "createUploadSession") { Read(c.Request); var id = Guid.NewGuid().ToString("N"); odSessions[id] = Tuple.Create(rel, long.Parse(c.Request.Headers["X-Test-Size"] ?? "0"), new MemoryStream()); odPendingId = id; Json(c, 200, "{\"uploadUrl\":\"" + Base + "/graph/upload/" + id + "\"}"); return; }
            if (op == "" && m == "GET" && c.Request.RawUrl.Contains("downloadUrl")) { if (!files.ContainsKey("od:" + rel)) { Json(c, 404, "{}"); return; } Json(c, 200, "{\"id\":\"i\",\"@microsoft.graph.downloadUrl\":\"" + Base + "/graph/dl/" + Uri.EscapeDataString(rel) + "\"}"); return; }
            if (op == "" && m == "DELETE") { bool any = files.Remove("od:" + rel) | folders.Remove("od:" + rel); Send(c, any ? 204 : 404, "", null, null); return; }
        }
        Json(c, 400, "{\"error\":{\"message\":\"unsupported " + op + "\"}}");
    }
    string odPendingId;
    public void SetOdSessionSize(long size) { var s = odSessions[odPendingId]; odSessions[odPendingId] = Tuple.Create(s.Item1, size, s.Item3); }
    void MakeParents(string ns, string rel) { var segs = rel.Split('/'); for (int i = 1; i < segs.Length; i++) folders.Add(ns + string.Join("/", segs.Take(i))); }
    static string JsonEsc(string s) { return s.Replace("\\", "\\\\").Replace("\"", "\\\""); }

    // ---------------- Google Drive subset ----------------
    class GdItem { public string Id, Name, Parent; public bool Folder; public byte[] Data; }
    Dictionary<string, GdItem> gd = new Dictionary<string, GdItem>(); int gdNext;
    Dictionary<string, Tuple<string, long, MemoryStream>> gdSessions = new Dictionary<string, Tuple<string, long, MemoryStream>>();
    void Drive(HttpListenerContext c)
    {
        string p = RawPath(c), m = c.Request.HttpMethod;
        if (p.StartsWith("/gd/session/"))
        {
            var id = p.Substring(12); var s = gdSessions[id];
            var cr = c.Request.Headers["Content-Range"] ?? "";
            var b = Read(c.Request);
            if (cr == "bytes */0") { lock (gate) gd[s.Item1].Data = new byte[0]; Json(c, 200, "{}"); return; }
            var mm = Regex.Match(cr, @"bytes (\d+)-(\d+)/(\d+)");
            if (long.Parse(mm.Groups[1].Value) != s.Item3.Length) { Json(c, 400, "{\"error\":{\"message\":\"offset\"}}"); return; }
            if (s.Item3.Length + b.Length < s.Item2 && b.Length % 262144 != 0) { Json(c, 400, "{\"error\":{\"message\":\"chunk not multiple of 256 KiB\"}}"); return; }
            s.Item3.Write(b, 0, b.Length);
            if (s.Item3.Length == s.Item2) { lock (gate) gd[s.Item1].Data = s.Item3.ToArray(); gdSessions.Remove(id); Json(c, 200, "{}"); }
            else Send(c, 308, "", null, new Dictionary<string, string> { { "Range", "bytes=0-" + (s.Item3.Length - 1) } });
            return;
        }
        if (!Bearer(c)) return;
        var q = c.Request.QueryString;
        lock (gate)
        {
            if (p == "/gd/drive/v3/about") { Json(c, 200, "{\"user\":{\"emailAddress\":\"user@example.com\",\"displayName\":\"User Name\"},\"storageQuota\":{\"limit\":\"16106127360\",\"usage\":\"1000\"}}"); return; }
            if (p == "/gd/drive/v3/files" && m == "GET")
            {
                var qq = q["q"];
                var pm = Regex.Match(qq, "'([^']+)' in parents");
                var nm = Regex.Match(qq, "name = '((?:[^'\\\\]|\\\\.)*)'");
                var list = gd.Values.Where(x => x.Parent == pm.Groups[1].Value && (!nm.Success || x.Name == Regex.Unescape(nm.Groups[1].Value)) && (!qq.Contains("mimeType") || x.Folder)).ToList();
                var items = list.Select(x => "{\"id\":\"" + x.Id + "\",\"name\":\"" + JsonEsc(x.Name) + "\",\"mimeType\":\"" + (x.Folder ? "application/vnd.google-apps.folder" : "application/octet-stream") + "\"" + (x.Folder ? "" : ",\"size\":\"" + (x.Data ?? new byte[0]).Length + "\",\"md5Checksum\":\"" + Md5(x.Data ?? new byte[0]) + "\"") + "}");
                Json(c, 200, "{\"files\":[" + string.Join(",", items) + "]}"); return;
            }
            if (p == "/gd/drive/v3/files" && m == "POST")
            {
                var body = Encoding.UTF8.GetString(Read(c.Request));
                var it = new GdItem { Id = "g" + (++gdNext) + "x", Name = Regex.Unescape(Regex.Match(body, "\"name\":\"([^\"]*)\"").Groups[1].Value), Parent = Regex.Match(body, "\"parents\":\\[\"([^\"]+)\"\\]").Groups[1].Value, Folder = true };
                if (it.Parent == "") { Json(c, 400, "{\"error\":{\"message\":\"parents must be an array\"}}"); return; }
                gd[it.Id] = it; Json(c, 200, "{\"id\":\"" + it.Id + "\"}"); return;
            }
            if (p == "/gd/upload/drive/v3/files" && m == "POST" && q["uploadType"] == "resumable")
            {
                var body = Encoding.UTF8.GetString(Read(c.Request));
                var it = new GdItem { Id = "g" + (++gdNext) + "f", Name = Regex.Unescape(Regex.Match(body, "\"name\":\"([^\"]*)\"").Groups[1].Value), Parent = Regex.Match(body, "\"parents\":\\[\"([^\"]+)\"\\]").Groups[1].Value };
                if (it.Parent == "") { Json(c, 400, "{\"error\":{\"message\":\"parents must be an array\"}}"); return; }
                gd[it.Id] = it;
                var sid = Guid.NewGuid().ToString("N"); gdSessions[sid] = Tuple.Create(it.Id, long.Parse(c.Request.Headers["X-Upload-Content-Length"]), new MemoryStream());
                Send(c, 200, "", null, new Dictionary<string, string> { { "Location", Base + "/gd/session/" + sid } }); return;
            }
            if (p.StartsWith("/gd/upload/drive/v3/files/") && m == "PATCH")
            {
                Read(c.Request); var id = p.Substring(26);
                var sid = Guid.NewGuid().ToString("N"); gdSessions[sid] = Tuple.Create(id, long.Parse(c.Request.Headers["X-Upload-Content-Length"]), new MemoryStream());
                Send(c, 200, "", null, new Dictionary<string, string> { { "Location", Base + "/gd/session/" + sid } }); return;
            }
            if (p.StartsWith("/gd/drive/v3/files/"))
            {
                var id = p.Substring(19);
                if (m == "DELETE") { foreach (var k in gd.Values.Where(x => x.Parent == id).Select(x => x.Id).ToList()) gd.Remove(k); Send(c, gd.Remove(id) ? 204 : 404, "", null, null); return; }
                if (m == "GET" && q["alt"] == "media") { GdItem it; if (gd.TryGetValue(id, out it)) SendBytes(c, it.Data ?? new byte[0]); else Json(c, 404, "{}"); return; }
            }
        }
        Json(c, 400, "{\"error\":{\"message\":\"unsupported\"}}");
    }

    // ---------------- Dropbox subset ----------------
    Dictionary<string, MemoryStream> dbxSessions = new Dictionary<string, MemoryStream>();
    static string DbxHash(byte[] b)
    {
        using (var outer = SHA256.Create())
        {
            var cat = new List<byte>();
            for (int o = 0; o < b.Length; o += 4 * 1024 * 1024) using (var h = SHA256.Create()) cat.AddRange(h.ComputeHash(b, o, Math.Min(4 * 1024 * 1024, b.Length - o)));
            return Hex(outer.ComputeHash(cat.ToArray()));
        }
    }
    static string Arg(HttpListenerContext c, string name) { var a = c.Request.Headers["Dropbox-API-Arg"] ?? ""; var mm = Regex.Match(a, "\"" + name + "\":\"((?:[^\"\\\\]|\\\\.)*)\""); return mm.Success ? Regex.Unescape(mm.Groups[1].Value) : null; }
    void Dropbox(HttpListenerContext c)
    {
        if (!Bearer(c)) return;
        string p = RawPath(c);
        var arg = c.Request.Headers["Dropbox-API-Arg"];
        if (arg != null && Regex.IsMatch(arg, "[^\\x20-\\x7E]")) { Json(c, 400, "{\"error_summary\":\"non-ascii header\"}"); return; }
        lock (gate)
        {
            if (p == "/dbx/2/users/get_current_account") { if (c.Request.ContentType != null) { Json(c, 400, "{\"error_summary\":\"no body expected\"}"); return; } Json(c, 200, "{\"email\":\"user@example.com\",\"name\":{\"display_name\":\"User Name\"}}"); return; }
            if (p == "/dbx/2/users/get_space_usage") { Json(c, 200, "{\"used\":1000,\"allocation\":{\".tag\":\"individual\",\"allocated\":2147483648}}"); return; }
            if (p == "/dbx/2/files/list_folder" || p == "/dbx/2/files/list_folder/continue")
            {
                var body = Encoding.UTF8.GetString(Read(c.Request));
                string path;
                int start = 0;
                if (p.EndsWith("continue")) { var cur = Regex.Match(body, "\"cursor\":\"([^\"]+)\"").Groups[1].Value.Split('|'); path = cur[0]; start = int.Parse(cur[1]); }
                else path = Regex.Unescape(Regex.Match(body, "\"path\":\"((?:[^\"\\\\]|\\\\.)*)\"").Groups[1].Value);
                string rel = path.Trim('/');
                if (rel != "" && !folders.Contains("dbx:" + rel)) { Json(c, 409, "{\"error_summary\":\"path/not_found/.\"}"); return; }
                string pre = rel == "" ? "dbx:" : "dbx:" + rel + "/";
                var ents = new List<string>();
                foreach (var f in folders.Where(x => x.StartsWith(pre, StringComparison.OrdinalIgnoreCase) && x.Substring(pre.Length).IndexOf('/') < 0)) ents.Add("{\".tag\":\"folder\",\"name\":\"" + JsonEsc(f.Substring(pre.Length)) + "\",\"id\":\"id:f\"}");
                foreach (var f in files.Keys.Where(x => x.StartsWith(pre, StringComparison.OrdinalIgnoreCase) && x.Substring(pre.Length).IndexOf('/') < 0)) ents.Add("{\".tag\":\"file\",\"name\":\"" + JsonEsc(f.Substring(pre.Length)) + "\",\"id\":\"id:x\",\"size\":" + files[f].Length + ",\"content_hash\":\"" + DbxHash(files[f]) + "\"}");
                var page = ents.Skip(start).Take(3).ToList(); bool more = start + 3 < ents.Count;
                Json(c, 200, "{\"entries\":[" + string.Join(",", page) + "],\"cursor\":\"" + path + "|" + (start + 3) + "\",\"has_more\":" + (more ? "true" : "false") + "}"); return;
            }
            if (p == "/dbxc/2/files/upload") { var b = Read(c.Request); if (b.Length > 150 * 1024 * 1024) { Json(c, 400, "{}"); return; } var path = Arg(c, "path").Trim('/'); files["dbx:" + path] = b; MakeParents("dbx:", path); Json(c, 200, "{}"); return; }
            if (p == "/dbxc/2/files/upload_session/start") { var id = "s" + Guid.NewGuid().ToString("N"); var ms = new MemoryStream(); var b = Read(c.Request); ms.Write(b, 0, b.Length); dbxSessions[id] = ms; Json(c, 200, "{\"session_id\":\"" + id + "\"}"); return; }
            if (p == "/dbxc/2/files/upload_session/append_v2" || p == "/dbxc/2/files/upload_session/finish")
            {
                var id = Arg(c, "session_id"); var off = long.Parse(Regex.Match(arg, "\"offset\":(\\d+)").Groups[1].Value);
                var ms = dbxSessions[id]; if (off != ms.Length) { Json(c, 409, "{\"error_summary\":\"incorrect_offset/\"}"); return; }
                var b = Read(c.Request); ms.Write(b, 0, b.Length);
                if (p.EndsWith("finish")) { var path = Arg(c, "path").Trim('/'); files["dbx:" + path] = ms.ToArray(); MakeParents("dbx:", path); dbxSessions.Remove(id); }
                Json(c, 200, p.EndsWith("finish") ? "{\"name\":\"x\"}" : "null"); return;
            }
            if (p == "/dbx/2/files/delete_v2") { var body = Encoding.UTF8.GetString(Read(c.Request)); var path = Regex.Unescape(Regex.Match(body, "\"path\":\"((?:[^\"\\\\]|\\\\.)*)\"").Groups[1].Value).Trim('/'); if (files.Remove("dbx:" + path)) Json(c, 200, "{}"); else Json(c, 409, "{\"error_summary\":\"path_lookup/not_found/\"}"); return; }
            if (p == "/dbxc/2/files/download") { var path = Arg(c, "path").Trim('/'); byte[] b; if (files.TryGetValue("dbx:" + path, out b)) SendBytes(c, b); else Json(c, 409, "{\"error_summary\":\"path/not_found/\"}"); return; }
        }
        Json(c, 400, "{\"error_summary\":\"unsupported\"}");
    }

    public string[] Paths(string ns) { lock (gate) return files.Keys.Where(k => k.StartsWith(ns + ":")).Select(k => k.Substring(ns.Length + 1)).OrderBy(k => k).ToArray(); }
    public void Corrupt(string ns, string rel) { lock (gate) { var k = ns + ":" + rel; var b = files[k]; b = (byte[])b.Clone(); b[0] ^= 0xFF; files[k] = b; } }
}

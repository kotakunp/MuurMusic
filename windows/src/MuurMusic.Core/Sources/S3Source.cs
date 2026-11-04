using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Sources;

/// <summary>AWS Signature Version 4 signing (headers and presigned URLs) implemented from the AWS specification.</summary>
public static class AwsSigV4
{
    public const string Algorithm = "AWS4-HMAC-SHA256";
    public const string UnsignedPayload = "UNSIGNED-PAYLOAD";
    public const string EmptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    /// <summary>RFC 3986 percent-encoding as required by SigV4 (unreserved characters are kept).</summary>
    public static string Encode(string value, bool keepSlash = false)
    {
        var sb = new StringBuilder(value.Length * 2);
        foreach (var b in Encoding.UTF8.GetBytes(value))
        {
            var c = (char)b;
            if (c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_' or '.' or '~' || (keepSlash && c == '/'))
                sb.Append(c);
            else
                sb.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }

    public static string Hex(byte[] bytes) => Convert.ToHexStringLower(bytes);
    public static string Sha256Hex(string s) => Hex(SHA256.HashData(Encoding.UTF8.GetBytes(s)));
    public static string Sha256Hex(byte[] data) => Hex(SHA256.HashData(data));
    private static byte[] Hmac(byte[] key, string data) => HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(data));

    public static byte[] SigningKey(string secretKey, string date, string region, string service)
    {
        var kDate = Hmac(Encoding.UTF8.GetBytes("AWS4" + secretKey), date);
        var kRegion = Hmac(kDate, region);
        var kService = Hmac(kRegion, service);
        return Hmac(kService, "aws4_request");
    }

    /// <summary>Canonical query string from raw (unencoded) parameters.</summary>
    public static string CanonicalQuery(IEnumerable<KeyValuePair<string, string>> parameters) =>
        string.Join('&', parameters.Select(p => (K: Encode(p.Key), V: Encode(p.Value)))
            .OrderBy(p => p.K, StringComparer.Ordinal).ThenBy(p => p.V, StringComparer.Ordinal).Select(p => p.K + "=" + p.V));

    public static string CanonicalRequest(string method, string canonicalUri, string canonicalQuery, IReadOnlyDictionary<string, string> headers, string payloadHash, out string signedHeaders)
    {
        var sorted = headers.Select(h => (K: h.Key.ToLowerInvariant().Trim(), V: CollapseSpaces(h.Value.Trim())))
            .OrderBy(h => h.K, StringComparer.Ordinal).ToList();
        signedHeaders = string.Join(';', sorted.Select(h => h.K));
        var sb = new StringBuilder();
        sb.Append(method).Append('\n').Append(canonicalUri).Append('\n').Append(canonicalQuery).Append('\n');
        foreach (var (k, v) in sorted) sb.Append(k).Append(':').Append(v).Append('\n');
        sb.Append('\n').Append(signedHeaders).Append('\n').Append(payloadHash);
        return sb.ToString();
    }

    private static string CollapseSpaces(string s)
    {
        var sb = new StringBuilder(s.Length);
        var prevSpace = false;
        foreach (var c in s)
        {
            if (c == ' ') { if (!prevSpace) sb.Append(c); prevSpace = true; }
            else { sb.Append(c); prevSpace = false; }
        }
        return sb.ToString();
    }

    public static string StringToSign(string amzDate, string scope, string canonicalRequest) =>
        Algorithm + "\n" + amzDate + "\n" + scope + "\n" + Sha256Hex(canonicalRequest);

    public static string Scope(string date, string region, string service) => $"{date}/{region}/{service}/aws4_request";

    /// <summary>Computes the signature and Authorization header value for a request.</summary>
    /// <param name="headers">All headers to sign (must include host and x-amz-date).</param>
    public static (string Authorization, string Signature) Sign(string method, string canonicalUri, string canonicalQuery, IReadOnlyDictionary<string, string> headers,
        string payloadHash, string accessKey, string secretKey, string region, string service, DateTimeOffset timestamp)
    {
        var amzDate = timestamp.UtcDateTime.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        var date = amzDate[..8];
        var creq = CanonicalRequest(method, canonicalUri, canonicalQuery, headers, payloadHash, out var signed);
        var scope = Scope(date, region, service);
        var sts = StringToSign(amzDate, scope, creq);
        var sig = Hex(HMACSHA256.HashData(SigningKey(secretKey, date, region, service), Encoding.UTF8.GetBytes(sts)));
        return ($"{Algorithm} Credential={accessKey}/{scope}, SignedHeaders={signed}, Signature={sig}", sig);
    }

    /// <summary>Signs an HttpRequestMessage in place (adds x-amz-date, x-amz-content-sha256, optional session token, Authorization).</summary>
    public static void SignRequest(HttpRequestMessage request, string accessKey, string secretKey, string? sessionToken, string region, string service,
        DateTimeOffset timestamp, string payloadHash = UnsignedPayload)
    {
        var uri = request.RequestUri!;
        var amzDate = timestamp.UtcDateTime.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        var headers = new Dictionary<string, string>
        {
            ["host"] = uri.IsDefaultPort ? uri.Host : $"{uri.Host}:{uri.Port}",
            ["x-amz-date"] = amzDate,
            ["x-amz-content-sha256"] = payloadHash
        };
        if (!string.IsNullOrEmpty(sessionToken)) headers["x-amz-security-token"] = sessionToken;
        foreach (var h in request.Headers.Where(h => h.Key.StartsWith("x-amz-", StringComparison.OrdinalIgnoreCase)))
            headers[h.Key.ToLowerInvariant()] = string.Join(',', h.Value);
        if (request.Headers.Range is { } range) headers["range"] = range.ToString();
        var (auth, _) = Sign(request.Method.Method, CanonicalPath(uri.AbsolutePath), CanonicalQueryFromUri(uri), headers, payloadHash, accessKey, secretKey, region, service, timestamp);
        request.Headers.Remove("x-amz-date");
        request.Headers.Remove("x-amz-content-sha256");
        request.Headers.TryAddWithoutValidation("x-amz-date", amzDate);
        request.Headers.TryAddWithoutValidation("x-amz-content-sha256", payloadHash);
        if (!string.IsNullOrEmpty(sessionToken)) request.Headers.TryAddWithoutValidation("x-amz-security-token", sessionToken);
        request.Headers.TryAddWithoutValidation("Authorization", auth);
    }

    /// <summary>Creates a presigned URL (query-string auth) valid for <paramref name="expires"/> (max 7 days).</summary>
    public static string Presign(string method, Uri url, string accessKey, string secretKey, string? sessionToken, string region, string service, DateTimeOffset timestamp, TimeSpan expires)
    {
        var amzDate = timestamp.UtcDateTime.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        var date = amzDate[..8];
        var scope = Scope(date, region, service);
        var query = ParseQuery(url.Query);
        query.Add(new("X-Amz-Algorithm", Algorithm));
        query.Add(new("X-Amz-Credential", $"{accessKey}/{scope}"));
        query.Add(new("X-Amz-Date", amzDate));
        query.Add(new("X-Amz-Expires", ((long)Math.Min(expires.TotalSeconds, 604800)).ToString(CultureInfo.InvariantCulture)));
        if (!string.IsNullOrEmpty(sessionToken)) query.Add(new("X-Amz-Security-Token", sessionToken));
        query.Add(new("X-Amz-SignedHeaders", "host"));
        var cq = CanonicalQuery(query);
        var host = url.IsDefaultPort ? url.Host : $"{url.Host}:{url.Port}";
        var creq = CanonicalRequest(method, CanonicalPath(url.AbsolutePath), cq, new Dictionary<string, string> { ["host"] = host }, UnsignedPayload, out _);
        var sts = StringToSign(amzDate, scope, creq);
        var sig = Hex(HMACSHA256.HashData(SigningKey(secretKey, date, region, service), Encoding.UTF8.GetBytes(sts)));
        return $"{url.Scheme}://{host}{CanonicalPath(url.AbsolutePath)}?{cq}&X-Amz-Signature={sig}";
    }

    /// <summary>S3-style canonical path: each segment percent-encoded once.</summary>
    public static string CanonicalPath(string absolutePath)
    {
        var decoded = Uri.UnescapeDataString(absolutePath);
        if (decoded.Length == 0) return "/";
        return string.Join('/', decoded.Split('/').Select(s => Encode(s)));
    }

    private static string CanonicalQueryFromUri(Uri uri) => CanonicalQuery(ParseQuery(uri.Query));

    private static List<KeyValuePair<string, string>> ParseQuery(string query)
    {
        var list = new List<KeyValuePair<string, string>>();
        foreach (var part in query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = part.IndexOf('=');
            var k = Uri.UnescapeDataString((eq < 0 ? part : part[..eq]).Replace('+', ' '));
            var v = eq < 0 ? "" : Uri.UnescapeDataString(part[(eq + 1)..].Replace('+', ' '));
            list.Add(new(k, v));
        }
        return list;
    }
}

/// <summary>
/// Amazon S3 and S3-compatible storage (MinIO, Backblaze B2, Wasabi, Cloudflare R2, ...). Requests are signed with SigV4;
/// playback uses presigned URLs. URIs: <c>s3://&lt;sourceId&gt;/bucket/key</c>.
/// </summary>
public sealed class S3Source(SourceConfig config, SourceContext ctx) : MusicSourceBase(config)
{
    private string Region => Config.Get(SourceKeys.Region) ?? "us-east-1";
    private string? Bucket => Config.Get(SourceKeys.Bucket);
    private bool PathStyle => Config.GetBool(SourceKeys.PathStyle, Config.Get(SourceKeys.Endpoint) is not null);
    private Uri Endpoint => Uri.TryCreate(Config.Get(SourceKeys.Endpoint) ?? $"https://s3.{Region}.amazonaws.com", UriKind.Absolute, out var u)
        ? u : throw new SourceException("S3 endpoint URL is invalid.");

    public override SourceCapabilities Capabilities => SourceCapabilities.Browse | SourceCapabilities.Write;
    public override string RootUri => SourceUris.ForSourceScoped(SourceUris.S3, Config.Id, Bucket is null ? "" : Bucket + "/" + (Config.Get(SourceKeys.Path) ?? "").Trim('/') + "/");

    public override bool Owns(string uri) => SourceUris.TryParseSourceScoped(uri, out var s, out var id, out _) && s == SourceUris.S3 && id == Config.Id;

    private static (string Bucket, string Key) Split(string uri)
    {
        SourceUris.TryParseSourceScoped(uri, out _, out _, out var item);
        var slash = item.IndexOf('/');
        return slash < 0 ? (item, "") : (item[..slash], item[(slash + 1)..]);
    }

    private string UriOf(string bucket, string key) => SourceUris.ForSourceScoped(SourceUris.S3, Config.Id, bucket + "/" + key);

    internal Uri ObjectUrl(string? bucket, string key, string? query = null)
    {
        var ep = Endpoint;
        var port = ep.IsDefaultPort ? "" : ":" + ep.Port;
        var encodedKey = string.Join('/', key.Split('/').Select(s => AwsSigV4.Encode(s)));
        var basePath = ep.AbsolutePath.TrimEnd('/');
        string url;
        if (string.IsNullOrEmpty(bucket)) url = $"{ep.Scheme}://{ep.Host}{port}{basePath}/";
        else if (PathStyle) url = $"{ep.Scheme}://{ep.Host}{port}{basePath}/{bucket}/{encodedKey}";
        else url = $"{ep.Scheme}://{bucket}.{ep.Host}{port}{basePath}/{encodedKey}";
        if (query is not null) url += "?" + query;
        return new Uri(url);
    }

    private async Task<(string Access, string Secret, string? Token)> KeysAsync(CancellationToken ct)
    {
        var access = await ctx.SecretAsync(Config, SourceKeys.SecretAccessKey, ct).ConfigureAwait(false);
        var secret = await ctx.SecretAsync(Config, SourceKeys.SecretSecretKey, ct).ConfigureAwait(false);
        if (string.IsNullOrEmpty(access) || string.IsNullOrEmpty(secret)) throw new SourceAuthenticationException("S3 access key and secret key are required.");
        return (access, secret, await ctx.SecretAsync(Config, SourceKeys.SecretToken, ct).ConfigureAwait(false));
    }

    private async Task<HttpResponseMessage> SendAsync(HttpMethod method, Uri url, CancellationToken ct, HttpContent? content = null, string payloadHash = AwsSigV4.UnsignedPayload, Action<HttpRequestMessage>? configure = null)
    {
        var (access, secret, token) = await KeysAsync(ct).ConfigureAwait(false);
        var req = new HttpRequestMessage(method, url) { Content = content };
        configure?.Invoke(req);
        AwsSigV4.SignRequest(req, access, secret, token, Region, "s3", DateTimeOffset.UtcNow, payloadHash);
        HttpResponseMessage resp;
        try { resp = await ctx.Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false); }
        catch (HttpRequestException ex) { throw new SourceException($"Cannot reach {url.Host}: {ex.Message}", ex); }
        if (resp.IsSuccessStatusCode) return resp;
        var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        var code = (int)resp.StatusCode;
        resp.Dispose();
        var message = TryXml(body)?.Descendants().FirstOrDefault(e => e.Name.LocalName == "Message")?.Value ?? $"HTTP {code}";
        if (code is 401 or 403) throw new SourceAuthenticationException($"S3 denied the request: {message}");
        throw new SourceException($"S3 error: {message}");
    }

    private static XDocument? TryXml(string s)
    {
        try { return XDocument.Parse(s); } catch (System.Xml.XmlException) { return null; }
    }

    public override async Task TestConnectionAsync(CancellationToken ct = default) => await ListAsync(null, ct).ConfigureAwait(false);

    public override async Task<IReadOnlyList<SourceItem>> ListAsync(string? folderUri = null, CancellationToken ct = default)
    {
        var (bucket, prefix) = Split(folderUri ?? RootUri);
        if (bucket.Length == 0)
        {
            using var resp = await SendAsync(HttpMethod.Get, ObjectUrl(null, ""), ct).ConfigureAwait(false);
            var doc = XDocument.Parse(await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
            return doc.Descendants().Where(e => e.Name.LocalName == "Bucket")
                .Select(b => b.Elements().First(e => e.Name.LocalName == "Name").Value)
                .Select(name => FolderItem(UriOf(name, ""), name, subtitle: "Bucket")).ToList();
        }
        if (prefix.Length > 0 && !prefix.EndsWith('/')) prefix += "/";
        var items = new List<SourceItem>();
        string? continuation = null;
        do
        {
            var q = new List<string> { "list-type=2", "delimiter=%2F", "prefix=" + AwsSigV4.Encode(prefix) };
            if (continuation is not null) q.Add("continuation-token=" + AwsSigV4.Encode(continuation));
            using var resp = await SendAsync(HttpMethod.Get, ObjectUrl(bucket, "", string.Join('&', q)), ct).ConfigureAwait(false);
            var doc = XDocument.Parse(await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
            var root = doc.Root!;
            foreach (var cp in root.Elements().Where(e => e.Name.LocalName == "CommonPrefixes"))
            {
                var p = cp.Elements().First(e => e.Name.LocalName == "Prefix").Value;
                items.Add(FolderItem(UriOf(bucket, p), p[prefix.Length..].TrimEnd('/')));
            }
            foreach (var c in root.Elements().Where(e => e.Name.LocalName == "Contents"))
            {
                var key = c.Elements().First(e => e.Name.LocalName == "Key").Value;
                if (key == prefix || key.EndsWith('/')) continue;
                long.TryParse(c.Elements().FirstOrDefault(e => e.Name.LocalName == "Size")?.Value, out var size);
                DateTimeOffset? mod = DateTimeOffset.TryParse(c.Elements().FirstOrDefault(e => e.Name.LocalName == "LastModified")?.Value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var m) ? m : null;
                items.Add(FileItem(UriOf(bucket, key), key[prefix.Length..], size, mod));
            }
            var truncated = root.Elements().FirstOrDefault(e => e.Name.LocalName == "IsTruncated")?.Value == "true";
            continuation = truncated ? root.Elements().FirstOrDefault(e => e.Name.LocalName == "NextContinuationToken")?.Value : null;
        } while (continuation is not null);
        return Sort(items);
    }

    public override async Task<MediaLocation> ResolveAsync(string uri, CancellationToken ct = default)
    {
        var (bucket, key) = Split(uri);
        long length;
        using (var head = await SendAsync(HttpMethod.Head, ObjectUrl(bucket, key), ct).ConfigureAwait(false))
            length = head.Content.Headers.ContentLength ?? -1;
        var (access, secret, token) = await KeysAsync(ct).ConfigureAwait(false);
        var url = AwsSigV4.Presign("GET", ObjectUrl(bucket, key), access, secret, token, Region, "s3", DateTimeOffset.UtcNow, TimeSpan.FromHours(12));
        return MediaLocation.ForUrl(url, null, length, System.IO.Path.GetFileName(key));
    }

    public override async Task<Track?> GetTrackAsync(string uri, CancellationToken ct = default)
    {
        var (bucket, key) = Split(uri);
        try
        {
            using var head = await SendAsync(HttpMethod.Head, ObjectUrl(bucket, key), ct).ConfigureAwait(false);
            return CreateFileTrack(uri, System.IO.Path.GetFileName(key), head.Content.Headers.ContentLength ?? 0, head.Content.Headers.LastModified);
        }
        catch (SourceException) { return null; }
    }

    public override async Task<string> CreateFolderAsync(string parentUri, string name, CancellationToken ct = default)
    {
        var (bucket, prefix) = Split(parentUri);
        var key = (prefix.Length > 0 ? prefix.TrimEnd('/') + "/" : "") + FileSystemSourceBase.SanitizeName(name) + "/";
        using var _ = await SendAsync(HttpMethod.Put, ObjectUrl(bucket, key), ct, new ByteArrayContent(Array.Empty<byte>()), AwsSigV4.EmptyPayloadHash).ConfigureAwait(false);
        return UriOf(bucket, key);
    }

    public override async Task<string> RenameAsync(string uri, string newName, CancellationToken ct = default)
    {
        var (bucket, key) = Split(uri);
        if (key.EndsWith('/')) throw new NotSupportedException("Renaming S3 folders is not supported; rename the objects inside instead.");
        var newKey = key[..(key.LastIndexOf('/') + 1)] + FileSystemSourceBase.SanitizeName(newName);
        using (await SendAsync(HttpMethod.Put, ObjectUrl(bucket, newKey), ct, new ByteArrayContent(Array.Empty<byte>()), AwsSigV4.EmptyPayloadHash,
            r => r.Headers.TryAddWithoutValidation("x-amz-copy-source", "/" + bucket + "/" + string.Join('/', key.Split('/').Select(s => AwsSigV4.Encode(s))))).ConfigureAwait(false)) { }
        using (await SendAsync(HttpMethod.Delete, ObjectUrl(bucket, key), ct).ConfigureAwait(false)) { }
        return UriOf(bucket, newKey);
    }

    public override async Task DeleteAsync(string uri, CancellationToken ct = default)
    {
        var (bucket, key) = Split(uri);
        if (key.EndsWith('/') || key.Length == 0)
        {
            foreach (var child in await ListAsync(uri, ct).ConfigureAwait(false))
                await DeleteAsync(child.IsFolder && !child.Uri.EndsWith('/') ? child.Uri + "/" : child.Uri, ct).ConfigureAwait(false);
            if (key.Length == 0) return;
        }
        using var _ = await SendAsync(HttpMethod.Delete, ObjectUrl(bucket, key), ct).ConfigureAwait(false);
    }

    public override async Task<string> UploadAsync(string folderUri, string fileName, Stream content, long length, IProgress<long>? progress = null, CancellationToken ct = default)
    {
        var (bucket, prefix) = Split(folderUri);
        var key = (prefix.Length > 0 ? prefix.TrimEnd('/') + "/" : "") + FileSystemSourceBase.SanitizeName(fileName);
        if (length < 0) throw new SourceException("S3 uploads need a known content length.");
        var body = new ProgressStreamContent(content, length, progress, AudioFormats.MimeTypeFromExtension(fileName));
        using var _ = await SendAsync(HttpMethod.Put, ObjectUrl(bucket, key), ct, body).ConfigureAwait(false);
        return UriOf(bucket, key);
    }
}

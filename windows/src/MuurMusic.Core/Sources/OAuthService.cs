using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Models;
using MuurMusic.Core.Security;

namespace MuurMusic.Core.Sources;

/// <summary>OAuth 2.0 endpoints of a cloud provider.</summary>
public sealed record OAuthProviderInfo(
    string Name,
    string AuthorizeUrl,
    string TokenUrl,
    string Scopes,
    IReadOnlyDictionary<string, string> ExtraAuthorizeParameters,
    bool SupportsRefresh = true);

/// <summary>Stored OAuth token set (serialized as JSON in the credential store).</summary>
public sealed class OAuthToken
{
    [JsonPropertyName("access_token")] public string AccessToken { get; set; } = "";
    [JsonPropertyName("refresh_token")] public string? RefreshToken { get; set; }
    [JsonPropertyName("expires_at")] public DateTimeOffset? ExpiresAt { get; set; }
    [JsonPropertyName("extra")] public Dictionary<string, string> Extra { get; set; } = new();
    [JsonIgnore] public bool IsExpiring => ExpiresAt is { } e && e <= DateTimeOffset.UtcNow.AddMinutes(2);
}

/// <summary>
/// OAuth 2.0 authorization-code flow with PKCE and a loopback redirect (http://localhost:&lt;port&gt;/callback).
/// Client ids come from configuration key <c>OAuth:&lt;Provider&gt;:ClientId</c> (optional <c>ClientSecret</c>, <c>RedirectPort</c>).
/// </summary>
public interface IOAuthService
{
    IReadOnlyList<OAuthProviderInfo> Providers { get; }
    OAuthProviderInfo GetProvider(string name);
    /// <summary>True when a client id is configured for the provider.</summary>
    bool IsConfigured(string provider);
    /// <summary>Opens the system browser, waits for the redirect and exchanges the code. Throws <see cref="OAuthNotConfiguredException"/> if no client id.</summary>
    Task<OAuthToken> AuthorizeAsync(string provider, CancellationToken ct = default);
    Task<OAuthToken> RefreshAsync(string provider, OAuthToken token, CancellationToken ct = default);
    /// <summary>Runs <see cref="AuthorizeAsync"/> and stores the token for the source.</summary>
    Task AuthorizeSourceAsync(SourceConfig config, CancellationToken ct = default);
    /// <summary>Returns the stored token for a source, refreshing and persisting it when it is about to expire.</summary>
    Task<OAuthToken> GetTokenAsync(SourceConfig config, bool forceRefresh = false, CancellationToken ct = default);
    /// <summary>Replaces how the authorization URL is opened (defaults to the system browser).</summary>
    Func<Uri, Task>? BrowserLauncher { get; set; }
}

public static class OAuthProviders
{
    public const string Dropbox = "Dropbox", GoogleDrive = "GoogleDrive", OneDrive = "OneDrive", Box = "Box", PCloud = "PCloud";

    public static string ForKind(SourceKind kind) => kind switch
    {
        SourceKind.Dropbox => Dropbox,
        SourceKind.GoogleDrive => GoogleDrive,
        SourceKind.OneDrive => OneDrive,
        SourceKind.Box => Box,
        SourceKind.PCloud => PCloud,
        _ => throw new ArgumentOutOfRangeException(nameof(kind), $"{kind} does not use OAuth.")
    };

    public static IReadOnlyList<OAuthProviderInfo> All { get; } = new[]
    {
        new OAuthProviderInfo(Dropbox, "https://www.dropbox.com/oauth2/authorize", "https://api.dropboxapi.com/oauth2/token",
            "files.metadata.read files.content.read files.content.write", new Dictionary<string, string> { ["token_access_type"] = "offline" }),
        new OAuthProviderInfo(GoogleDrive, "https://accounts.google.com/o/oauth2/v2/auth", "https://oauth2.googleapis.com/token",
            "https://www.googleapis.com/auth/drive", new Dictionary<string, string> { ["access_type"] = "offline", ["prompt"] = "consent" }),
        new OAuthProviderInfo(OneDrive, "https://login.microsoftonline.com/common/oauth2/v2.0/authorize", "https://login.microsoftonline.com/common/oauth2/v2.0/token",
            "Files.ReadWrite.All offline_access User.Read", new Dictionary<string, string>()),
        new OAuthProviderInfo(Box, "https://account.box.com/api/oauth2/authorize", "https://api.box.com/oauth2/token",
            "root_readwrite", new Dictionary<string, string>()),
        new OAuthProviderInfo(PCloud, "https://my.pcloud.com/oauth2/authorize", "https://api.pcloud.com/oauth2_token",
            "", new Dictionary<string, string>(), SupportsRefresh: false),
    };
}

public sealed class OAuthService(IConfiguration configuration, ICredentialStore credentials, IHttpClientFactory httpFactory, ILogger<OAuthService> logger) : IOAuthService
{
    private readonly SemaphoreSlim _refreshLock = new(1, 1);

    public IReadOnlyList<OAuthProviderInfo> Providers => OAuthProviders.All;
    public Func<Uri, Task>? BrowserLauncher { get; set; }

    public OAuthProviderInfo GetProvider(string name) =>
        OAuthProviders.All.FirstOrDefault(p => p.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) ?? throw new ArgumentException($"Unknown OAuth provider {name}");

    private string? ClientId(string provider) => configuration[$"OAuth:{provider}:ClientId"] is { Length: > 0 } id ? id : null;
    private string? ClientSecret(string provider) => configuration[$"OAuth:{provider}:ClientSecret"] is { Length: > 0 } s ? s : null;

    public bool IsConfigured(string provider) => ClientId(provider) is not null;

    public async Task<OAuthToken> AuthorizeAsync(string provider, CancellationToken ct = default)
    {
        var info = GetProvider(provider);
        var clientId = ClientId(info.Name) ?? throw new OAuthNotConfiguredException(info.Name);
        var verifier = Base64Url(RandomNumberGenerator.GetBytes(48));
        var challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
        var state = Base64Url(RandomNumberGenerator.GetBytes(16));
        var fixedPort = int.TryParse(configuration[$"OAuth:{info.Name}:RedirectPort"], out var p) ? p : 0;

        using var loopback = new LoopbackReceiver(fixedPort);
        var redirectUri = $"http://localhost:{loopback.Port}/callback";
        var query = new Dictionary<string, string>
        {
            ["response_type"] = "code",
            ["client_id"] = clientId,
            ["redirect_uri"] = redirectUri,
            ["state"] = state,
            ["code_challenge"] = challenge,
            ["code_challenge_method"] = "S256"
        };
        if (info.Scopes.Length > 0) query["scope"] = info.Scopes;
        foreach (var (k, v) in info.ExtraAuthorizeParameters) query[k] = v;
        var authUrl = new Uri(info.AuthorizeUrl + "?" + string.Join('&', query.Select(kv => kv.Key + "=" + Uri.EscapeDataString(kv.Value))));

        if (BrowserLauncher is { } launcher) await launcher(authUrl).ConfigureAwait(false);
        else Process.Start(new ProcessStartInfo(authUrl.AbsoluteUri) { UseShellExecute = true });

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromMinutes(5));
        var callback = await loopback.WaitAsync(timeout.Token).ConfigureAwait(false);
        if (callback.TryGetValue("error", out var error))
            throw new SourceAuthenticationException($"{info.Name} authorization failed: {callback.GetValueOrDefault("error_description", error)}");
        if (!callback.TryGetValue("state", out var gotState) || gotState != state)
            throw new SourceAuthenticationException("OAuth state mismatch; please try again.");
        var code = callback.GetValueOrDefault("code") ?? throw new SourceAuthenticationException("No authorization code was returned.");

        var form = new Dictionary<string, string>
        {
            ["grant_type"] = "authorization_code",
            ["code"] = code,
            ["redirect_uri"] = redirectUri,
            ["client_id"] = clientId,
            ["code_verifier"] = verifier
        };
        if (ClientSecret(info.Name) is { } secret) form["client_secret"] = secret;
        var tokenUrl = info.TokenUrl;
        // pCloud tells us which regional API host owns the account.
        if (info.Name == OAuthProviders.PCloud && callback.TryGetValue("hostname", out var host) && host.EndsWith("pcloud.com", StringComparison.OrdinalIgnoreCase))
            tokenUrl = $"https://{host}/oauth2_token";
        var token = await ExchangeAsync(tokenUrl, form, null, ct).ConfigureAwait(false);
        if (info.Name == OAuthProviders.PCloud)
            token.Extra["apiHost"] = callback.GetValueOrDefault("hostname") is { Length: > 0 } h ? h : "api.pcloud.com";
        return token;
    }

    public async Task<OAuthToken> RefreshAsync(string provider, OAuthToken token, CancellationToken ct = default)
    {
        var info = GetProvider(provider);
        if (!info.SupportsRefresh) return token;
        if (string.IsNullOrEmpty(token.RefreshToken)) throw new SourceAuthenticationException($"{info.Name} session expired; please sign in again.");
        var clientId = ClientId(info.Name) ?? throw new OAuthNotConfiguredException(info.Name);
        var form = new Dictionary<string, string>
        {
            ["grant_type"] = "refresh_token",
            ["refresh_token"] = token.RefreshToken!,
            ["client_id"] = clientId
        };
        if (ClientSecret(info.Name) is { } secret) form["client_secret"] = secret;
        var fresh = await ExchangeAsync(info.TokenUrl, form, token, ct).ConfigureAwait(false);
        fresh.RefreshToken ??= token.RefreshToken;
        foreach (var (k, v) in token.Extra) fresh.Extra.TryAdd(k, v);
        return fresh;
    }

    private async Task<OAuthToken> ExchangeAsync(string url, Dictionary<string, string> form, OAuthToken? previous, CancellationToken ct)
    {
        var http = httpFactory.CreateClient(HttpClientNames.Default);
        using var resp = await http.PostAsync(url, new FormUrlEncodedContent(form), ct).ConfigureAwait(false);
        var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        JsonElement json;
        try { json = JsonDocument.Parse(body).RootElement; }
        catch (JsonException) { throw new SourceAuthenticationException($"Token endpoint returned HTTP {(int)resp.StatusCode}."); }
        if (!resp.IsSuccessStatusCode || json.TryGetProperty("error", out _) && !json.TryGetProperty("access_token", out _))
        {
            var msg = json.TryGetProperty("error_description", out var d) ? d.GetString() : json.TryGetProperty("error", out var e) ? e.ToString() : $"HTTP {(int)resp.StatusCode}";
            logger.LogWarning("OAuth token exchange failed: {Message}", msg);
            throw new SourceAuthenticationException($"Sign-in failed: {msg}");
        }
        var token = new OAuthToken
        {
            AccessToken = json.GetProperty("access_token").GetString() ?? "",
            RefreshToken = json.TryGetProperty("refresh_token", out var r) ? r.GetString() : previous?.RefreshToken,
        };
        if (json.TryGetProperty("expires_in", out var exp) && exp.TryGetInt64(out var secs))
            token.ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(secs);
        if (json.TryGetProperty("account_id", out var acc)) token.Extra["accountId"] = acc.ToString();
        if (json.TryGetProperty("userid", out var uid)) token.Extra["userId"] = uid.ToString();
        return token;
    }

    public async Task AuthorizeSourceAsync(SourceConfig config, CancellationToken ct = default)
    {
        var token = await AuthorizeAsync(OAuthProviders.ForKind(config.Kind), ct).ConfigureAwait(false);
        await SaveAsync(config, token, ct).ConfigureAwait(false);
    }

    public async Task<OAuthToken> GetTokenAsync(SourceConfig config, bool forceRefresh = false, CancellationToken ct = default)
    {
        var token = await LoadAsync(config, ct).ConfigureAwait(false)
            ?? throw new SourceAuthenticationException($"{config.Name} is not signed in.");
        if (!forceRefresh && !token.IsExpiring) return token;
        await _refreshLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            token = await LoadAsync(config, ct).ConfigureAwait(false) ?? token;
            if (!forceRefresh && !token.IsExpiring) return token;
            var fresh = await RefreshAsync(OAuthProviders.ForKind(config.Kind), token, ct).ConfigureAwait(false);
            await SaveAsync(config, fresh, ct).ConfigureAwait(false);
            return fresh;
        }
        finally { _refreshLock.Release(); }
    }

    private async Task<OAuthToken?> LoadAsync(SourceConfig config, CancellationToken ct)
    {
        var json = await credentials.GetSourceSecretAsync(config.Id, SourceKeys.SecretOAuth, ct).ConfigureAwait(false);
        return string.IsNullOrEmpty(json) ? null : JsonSerializer.Deserialize<OAuthToken>(json);
    }

    private Task SaveAsync(SourceConfig config, OAuthToken token, CancellationToken ct) =>
        credentials.SetSourceSecretAsync(config.Id, SourceKeys.SecretOAuth, JsonSerializer.Serialize(token), ct);

    internal static string Base64Url(byte[] data) => Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    /// <summary>Minimal HTTP listener on 127.0.0.1 and ::1 that captures the OAuth redirect query string.</summary>
    private sealed class LoopbackReceiver : IDisposable
    {
        private readonly TcpListener _v4;
        private readonly TcpListener? _v6;

        public LoopbackReceiver(int port)
        {
            _v4 = new TcpListener(IPAddress.Loopback, port);
            _v4.Start();
            Port = ((IPEndPoint)_v4.LocalEndpoint).Port;
            try
            {
                _v6 = new TcpListener(IPAddress.IPv6Loopback, Port);
                _v6.Start();
            }
            catch (SocketException) { _v6 = null; }
        }

        public int Port { get; }

        public async Task<Dictionary<string, string>> WaitAsync(CancellationToken ct)
        {
            while (true)
            {
                var accepts = new List<Task<TcpClient>> { _v4.AcceptTcpClientAsync(ct).AsTask() };
                if (_v6 is not null) accepts.Add(_v6.AcceptTcpClientAsync(ct).AsTask());
                var done = await Task.WhenAny(accepts).ConfigureAwait(false);
                using var client = await done.ConfigureAwait(false);
                await using var stream = client.GetStream();
                using var reader = new StreamReader(stream, Encoding.ASCII, false, 4096, leaveOpen: true);
                var requestLine = await reader.ReadLineAsync(ct).ConfigureAwait(false) ?? "";
                string? line;
                while (!string.IsNullOrEmpty(line = await reader.ReadLineAsync(ct).ConfigureAwait(false))) { }
                var parts = requestLine.Split(' ');
                var target = parts.Length > 1 ? parts[1] : "/";
                var isCallback = target.StartsWith("/callback", StringComparison.Ordinal);
                var html = isCallback
                    ? "<html><body style=\"font-family:Segoe UI;background:#17122B;color:#F5F2FF;text-align:center;padding-top:20vh\"><h2>MuurMusic is connected</h2><p>You can close this tab and return to the app.</p></body></html>"
                    : "<html><body>Not found</body></html>";
                var bytes = Encoding.UTF8.GetBytes(html);
                var header = $"HTTP/1.1 {(isCallback ? "200 OK" : "404 Not Found")}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {bytes.Length}\r\nConnection: close\r\n\r\n";
                await stream.WriteAsync(Encoding.ASCII.GetBytes(header), ct).ConfigureAwait(false);
                await stream.WriteAsync(bytes, ct).ConfigureAwait(false);
                if (!isCallback) continue;
                var q = target.IndexOf('?');
                var result = new Dictionary<string, string>(StringComparer.Ordinal);
                if (q >= 0)
                    foreach (var kv in target[(q + 1)..].Split('&', StringSplitOptions.RemoveEmptyEntries))
                    {
                        var eq = kv.IndexOf('=');
                        var k = Uri.UnescapeDataString(eq < 0 ? kv : kv[..eq]);
                        var v = eq < 0 ? "" : Uri.UnescapeDataString(kv[(eq + 1)..].Replace('+', ' '));
                        result[k] = v;
                    }
                return result;
            }
        }

        public void Dispose()
        {
            _v4.Stop();
            _v6?.Stop();
        }
    }
}

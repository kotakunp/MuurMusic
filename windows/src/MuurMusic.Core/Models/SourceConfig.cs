namespace MuurMusic.Core.Models;

/// <summary>All supported source types.</summary>
public enum SourceKind
{
    Local, Smb, WebDav, Ftp, Sftp, Upnp, S3,
    Dropbox, GoogleDrive, OneDrive, Box, PCloud,
    Subsonic, Jellyfin, Emby, Plex, Zip
}

/// <summary>
/// Persisted configuration of a source. Only non-secret settings live in <see cref="Settings"/>; passwords, tokens and keys
/// are stored in <see cref="Security.ICredentialStore"/> keyed by the source id.
/// </summary>
public sealed class SourceConfig
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public SourceKind Kind { get; set; }
    public string Name { get; set; } = "";
    public Dictionary<string, string> Settings { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public DateTimeOffset Created { get; set; } = DateTimeOffset.UtcNow;
    public int SortOrder { get; set; }
    public bool Enabled { get; set; } = true;

    public string? Get(string key) => Settings.TryGetValue(key, out var v) && !string.IsNullOrEmpty(v) ? v : null;
    public string Get(string key, string fallback) => Get(key) ?? fallback;
    public int GetInt(string key, int fallback) => int.TryParse(Get(key), out var v) ? v : fallback;
    public bool GetBool(string key, bool fallback = false) => bool.TryParse(Get(key), out var v) ? v : fallback;
    public SourceConfig Set(string key, string? value)
    {
        if (value is null) Settings.Remove(key); else Settings[key] = value;
        return this;
    }
}

/// <summary>Well-known keys for <see cref="SourceConfig.Settings"/> and secret names.</summary>
public static class SourceKeys
{
    public const string Host = "host";
    public const string Port = "port";
    public const string Path = "path";
    public const string Share = "share";
    public const string Domain = "domain";
    public const string Username = "username";
    public const string BaseUrl = "baseUrl";
    public const string Preset = "preset";
    public const string UseTls = "useTls";
    public const string ImplicitTls = "implicitTls";
    public const string AcceptAnyCertificate = "acceptAnyCertificate";
    public const string AuthMode = "authMode";
    public const string Endpoint = "endpoint";
    public const string Region = "region";
    public const string Bucket = "bucket";
    public const string PathStyle = "pathStyle";
    public const string DeviceLocation = "deviceLocation";
    public const string ServerId = "serverId";
    public const string ServerUrl = "serverUrl";
    public const string UserId = "userId";
    public const string ArchiveUri = "archiveUri";
    public const string LegacyAuth = "legacyAuth";

    // Secret names (ICredentialStore)
    public const string SecretPassword = "password";
    public const string SecretPrivateKey = "privateKey";
    public const string SecretPassphrase = "passphrase";
    public const string SecretAccessKey = "accessKeyId";
    public const string SecretSecretKey = "secretAccessKey";
    public const string SecretToken = "token";
    public const string SecretOAuth = "oauth";
}

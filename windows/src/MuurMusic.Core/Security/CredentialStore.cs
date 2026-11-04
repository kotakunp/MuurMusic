using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace MuurMusic.Core.Security;

/// <summary>
/// Secret storage (passwords, OAuth tokens, keys). Secrets never go into SQLite, settings or logs.
/// The default implementation encrypts with Windows DPAPI (current user scope).
/// </summary>
public interface ICredentialStore
{
    Task<string?> GetAsync(string key, CancellationToken ct = default);
    Task SetAsync(string key, string value, CancellationToken ct = default);
    Task RemoveAsync(string key, CancellationToken ct = default);
    Task RemoveByPrefixAsync(string prefix, CancellationToken ct = default);
}

public static class CredentialStoreExtensions
{
    public static string SourceKey(Guid sourceId, string name) => $"source:{sourceId:N}:{name}";
    public static Task<string?> GetSourceSecretAsync(this ICredentialStore store, Guid sourceId, string name, CancellationToken ct = default) => store.GetAsync(SourceKey(sourceId, name), ct);
    public static Task SetSourceSecretAsync(this ICredentialStore store, Guid sourceId, string name, string? value, CancellationToken ct = default) =>
        value is null ? store.RemoveAsync(SourceKey(sourceId, name), ct) : store.SetAsync(SourceKey(sourceId, name), value, ct);
    public static Task RemoveSourceSecretsAsync(this ICredentialStore store, Guid sourceId, CancellationToken ct = default) => store.RemoveByPrefixAsync($"source:{sourceId:N}:", ct);
}

/// <summary>DPAPI-encrypted JSON dictionary stored in %LOCALAPPDATA%\MuurMusic\credentials.dat.</summary>
public sealed class DpapiCredentialStore : ICredentialStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("MuurMusic.Credentials.v1");
    private readonly string _path;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private Dictionary<string, string>? _cache;

    public DpapiCredentialStore(string path) => _path = path;

    public async Task<string?> GetAsync(string key, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try { return (await LoadAsync(ct).ConfigureAwait(false)).GetValueOrDefault(key); }
        finally { _lock.Release(); }
    }

    public async Task SetAsync(string key, string value, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var d = await LoadAsync(ct).ConfigureAwait(false);
            d[key] = value;
            await SaveAsync(d, ct).ConfigureAwait(false);
        }
        finally { _lock.Release(); }
    }

    public async Task RemoveAsync(string key, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var d = await LoadAsync(ct).ConfigureAwait(false);
            if (d.Remove(key)) await SaveAsync(d, ct).ConfigureAwait(false);
        }
        finally { _lock.Release(); }
    }

    public async Task RemoveByPrefixAsync(string prefix, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var d = await LoadAsync(ct).ConfigureAwait(false);
            var keys = d.Keys.Where(k => k.StartsWith(prefix, StringComparison.Ordinal)).ToList();
            foreach (var k in keys) d.Remove(k);
            if (keys.Count > 0) await SaveAsync(d, ct).ConfigureAwait(false);
        }
        finally { _lock.Release(); }
    }

    private async Task<Dictionary<string, string>> LoadAsync(CancellationToken ct)
    {
        if (_cache is not null) return _cache;
        if (!File.Exists(_path)) return _cache = new(StringComparer.Ordinal);
        var bytes = await File.ReadAllBytesAsync(_path, ct).ConfigureAwait(false);
        try
        {
            var plain = ProtectedData.Unprotect(bytes, Entropy, DataProtectionScope.CurrentUser);
            _cache = JsonSerializer.Deserialize<Dictionary<string, string>>(plain) ?? new();
        }
        catch (CryptographicException)
        {
            // Unreadable (different user / machine) – start over rather than crash.
            _cache = new(StringComparer.Ordinal);
        }
        return _cache;
    }

    private async Task SaveAsync(Dictionary<string, string> d, CancellationToken ct)
    {
        var plain = JsonSerializer.SerializeToUtf8Bytes(d);
        var enc = ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser);
        Array.Clear(plain);
        var tmp = _path + ".tmp";
        await File.WriteAllBytesAsync(tmp, enc, ct).ConfigureAwait(false);
        File.Move(tmp, _path, overwrite: true);
    }
}

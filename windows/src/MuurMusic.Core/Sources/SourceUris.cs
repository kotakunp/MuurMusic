using MuurMusic.Core.Models;

namespace MuurMusic.Core.Sources;

/// <summary>
/// Builds and parses source URIs (see SHARED_FORMATS "Source URIs"). Credentials never appear in URIs.
/// </summary>
public static class SourceUris
{
    public const string File = "file", Smb = "smb", WebDav = "webdav", WebDavs = "webdavs", Ftp = "ftp", Ftps = "ftps", Sftp = "sftp",
        S3 = "s3", Dropbox = "dropbox", GDrive = "gdrive", OneDrive = "onedrive", Box = "box", PCloud = "pcloud",
        Subsonic = "subsonic", Jellyfin = "jellyfin", Emby = "emby", Plex = "plex", Upnp = "upnp", Zip = "zip", Http = "http", Https = "https";

    public static string SchemeOf(string uri)
    {
        var i = uri.IndexOf("://", StringComparison.Ordinal);
        return i <= 0 ? "" : uri[..i].ToLowerInvariant();
    }

    /// <summary>file:///C:/a/b.flac for drive paths, smb://host/share/path for UNC paths.</summary>
    public static string FromLocalPath(string path)
    {
        var full = Path.GetFullPath(path);
        if (full.StartsWith(@"\\", StringComparison.Ordinal) && !full.StartsWith(@"\\?\", StringComparison.Ordinal))
        {
            var parts = full.TrimStart('\\').Split('\\', StringSplitOptions.RemoveEmptyEntries);
            return "smb://" + parts[0] + "/" + string.Join('/', parts.Skip(1).Select(Uri.EscapeDataString));
        }
        return new Uri(full).AbsoluteUri;
    }

    /// <summary>Resolves file:// and smb:// URIs to a local or UNC path.</summary>
    public static bool TryGetLocalPath(string uri, out string path)
    {
        path = "";
        var scheme = SchemeOf(uri);
        if (scheme == File)
        {
            if (!Uri.TryCreate(uri, UriKind.Absolute, out var u)) return false;
            path = u.IsUnc ? u.LocalPath : u.LocalPath;
            return true;
        }
        if (scheme == Smb)
        {
            var rest = uri["smb://".Length..];
            var segs = rest.Split('/', StringSplitOptions.RemoveEmptyEntries);
            if (segs.Length < 2) return false;
            path = @"\\" + segs[0] + @"\" + string.Join('\\', segs.Skip(1).Select(Uri.UnescapeDataString));
            return true;
        }
        if (scheme == "" && (Path.IsPathFullyQualified(uri)))
        {
            path = uri;
            return true;
        }
        return false;
    }

    public static string SchemeFor(SourceKind kind, bool secure = false) => kind switch
    {
        SourceKind.Local => File,
        SourceKind.Smb => Smb,
        SourceKind.WebDav => secure ? WebDavs : WebDav,
        SourceKind.Ftp => secure ? Ftps : Ftp,
        SourceKind.Sftp => Sftp,
        SourceKind.S3 => S3,
        SourceKind.Dropbox => Dropbox,
        SourceKind.GoogleDrive => GDrive,
        SourceKind.OneDrive => OneDrive,
        SourceKind.Box => Box,
        SourceKind.PCloud => PCloud,
        SourceKind.Subsonic => Subsonic,
        SourceKind.Jellyfin => Jellyfin,
        SourceKind.Emby => Emby,
        SourceKind.Plex => Plex,
        SourceKind.Upnp => Upnp,
        SourceKind.Zip => Zip,
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };

    /// <summary>Encodes a slash-separated path keeping the slashes.</summary>
    public static string EscapePath(string path) =>
        string.Join('/', path.Split('/').Select(s => Uri.EscapeDataString(s)));

    public static string UnescapePath(string path) =>
        string.Join('/', path.Split('/').Select(Uri.UnescapeDataString));

    /// <summary>scheme://&lt;sourceId&gt;/&lt;escaped item id or path&gt;</summary>
    public static string ForSourceScoped(string scheme, Guid sourceId, string itemId) =>
        $"{scheme}://{sourceId:D}/{EscapePath(itemId.TrimStart('/'))}";

    public static bool TryParseSourceScoped(string uri, out string scheme, out Guid sourceId, out string itemId)
    {
        scheme = SchemeOf(uri);
        sourceId = Guid.Empty;
        itemId = "";
        if (scheme.Length == 0) return false;
        var rest = uri[(scheme.Length + 3)..];
        var slash = rest.IndexOf('/');
        var idPart = slash < 0 ? rest : rest[..slash];
        if (!Guid.TryParse(idPart, out sourceId)) return false;
        itemId = slash < 0 ? "" : UnescapePath(rest[(slash + 1)..]);
        return true;
    }

    /// <summary>scheme://host[:port]/path for host-based sources (smb, webdav, ftp, sftp).</summary>
    public static string ForHost(string scheme, string host, int? port, string path)
    {
        var p = port is > 0 ? $":{port}" : "";
        return $"{scheme}://{host}{p}/{EscapePath(path.TrimStart('/'))}";
    }

    public static bool TryParseHost(string uri, out string scheme, out string host, out int? port, out string path)
    {
        scheme = SchemeOf(uri);
        host = "";
        port = null;
        path = "/";
        if (scheme.Length == 0) return false;
        var rest = uri[(scheme.Length + 3)..];
        var slash = rest.IndexOf('/');
        var authority = slash < 0 ? rest : rest[..slash];
        path = "/" + (slash < 0 ? "" : UnescapePath(rest[(slash + 1)..]));
        var colon = authority.LastIndexOf(':');
        if (colon > 0 && int.TryParse(authority[(colon + 1)..], out var prt) && !authority.StartsWith('['))
        {
            host = authority[..colon];
            port = prt;
        }
        else host = authority;
        return host.Length > 0;
    }

    public static string ForZip(string archiveUri, string entryPath) => $"zip://{archiveUri}!/{entryPath.Replace('\\', '/').TrimStart('/')}";

    public static bool TryParseZip(string uri, out string archiveUri, out string entryPath)
    {
        archiveUri = entryPath = "";
        if (!uri.StartsWith("zip://", StringComparison.OrdinalIgnoreCase)) return false;
        var body = uri[6..];
        var bang = body.LastIndexOf("!/", StringComparison.Ordinal);
        if (bang < 0) return false;
        archiveUri = body[..bang];
        entryPath = body[(bang + 2)..];
        return true;
    }

    /// <summary>Best-effort display file name from any source URI.</summary>
    public static string FileNameOf(string uri)
    {
        if (TryParseZip(uri, out _, out var entry)) return Path.GetFileName(entry);
        if (TryGetLocalPath(uri, out var p)) return Path.GetFileName(p);
        var q = uri.IndexOf('?');
        var s = q >= 0 ? uri[..q] : uri;
        var slash = s.LastIndexOf('/');
        return slash >= 0 ? Uri.UnescapeDataString(s[(slash + 1)..]) : s;
    }
}

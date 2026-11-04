using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Infrastructure;

namespace MuurMusic.Core.Tags;

/// <summary>Content-addressed artwork cache: originals named by SHA-1 hash plus downsized JPEG thumbnails.</summary>
public interface IArtworkCache
{
    /// <summary>Stores image bytes (deduplicated) and returns the artwork hash.</summary>
    Task<string> StoreAsync(byte[] data, CancellationToken ct = default);
    /// <summary>Downloads an image URL into the cache; null on failure.</summary>
    Task<string?> StoreFromUrlAsync(string url, IReadOnlyDictionary<string, string>? headers = null, CancellationToken ct = default);
    /// <summary>Full-size image path for a hash, or null if missing.</summary>
    string? GetPath(string? hash);
    /// <summary>Square-bounded JPEG thumbnail (generated on demand) for a hash, or null.</summary>
    string? GetThumbnailPath(string? hash, int size = 256);
    /// <summary>Looks for cover.jpg / folder.jpg / front.png ... in a folder.</summary>
    string? FindFolderImage(string folder);
    Task<long> GetSizeAsync(CancellationToken ct = default);
}

public sealed class ArtworkCache(AppPaths paths, IHttpClientFactory httpFactory, ILogger<ArtworkCache> logger) : IArtworkCache
{
    public const int DefaultThumbnailSize = 256;
    private static readonly string[] FolderImageNames = { "cover", "folder", "front", "albumart", "album", "artwork", "albumartsmall", "thumb" };

    public static string Hash(byte[] data) => Convert.ToHexString(SHA1.HashData(data)).ToLowerInvariant();

    public static string SniffMime(byte[] d)
    {
        if (d.Length > 3 && d[0] == 0xFF && d[1] == 0xD8) return "image/jpeg";
        if (d.Length > 8 && d[0] == 0x89 && d[1] == 0x50 && d[2] == 0x4E && d[3] == 0x47) return "image/png";
        if (d.Length > 12 && d[0] == 'R' && d[1] == 'I' && d[2] == 'F' && d[3] == 'F' && d[8] == 'W' && d[9] == 'E' && d[10] == 'B' && d[11] == 'P') return "image/webp";
        if (d.Length > 6 && d[0] == 'G' && d[1] == 'I' && d[2] == 'F') return "image/gif";
        if (d.Length > 2 && d[0] == 'B' && d[1] == 'M') return "image/bmp";
        return "image/jpeg";
    }

    private static string ExtensionFor(string mime) => mime switch
    {
        "image/png" => ".png",
        "image/webp" => ".webp",
        "image/gif" => ".gif",
        "image/bmp" => ".bmp",
        _ => ".jpg"
    };

    public async Task<string> StoreAsync(byte[] data, CancellationToken ct = default)
    {
        var hash = Hash(data);
        if (GetPath(hash) is null)
        {
            var target = Path.Combine(paths.ArtworkDirectory, hash + ExtensionFor(SniffMime(data)));
            var tmp = target + "." + Guid.NewGuid().ToString("N")[..8] + ".tmp";
            await File.WriteAllBytesAsync(tmp, data, ct).ConfigureAwait(false);
            try { File.Move(tmp, target, overwrite: false); }
            catch (IOException) { File.Delete(tmp); }
        }
        GetThumbnailPath(hash, DefaultThumbnailSize);
        return hash;
    }

    public async Task<string?> StoreFromUrlAsync(string url, IReadOnlyDictionary<string, string>? headers = null, CancellationToken ct = default)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            if (headers is not null) foreach (var (k, v) in headers) req.Headers.TryAddWithoutValidation(k, v);
            using var resp = await httpFactory.CreateClient("muur").SendAsync(req, ct).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode) return null;
            var bytes = await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
            return bytes.Length > 64 ? await StoreAsync(bytes, ct).ConfigureAwait(false) : null;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or IOException)
        {
            logger.LogDebug(ex, "Artwork download failed for {Url}", url);
            return null;
        }
    }

    public string? GetPath(string? hash)
    {
        if (string.IsNullOrEmpty(hash)) return null;
        foreach (var ext in new[] { ".jpg", ".png", ".webp", ".gif", ".bmp" })
        {
            var p = Path.Combine(paths.ArtworkDirectory, hash + ext);
            if (File.Exists(p)) return p;
        }
        return null;
    }

    public string? GetThumbnailPath(string? hash, int size = DefaultThumbnailSize)
    {
        var original = GetPath(hash);
        if (original is null) return null;
        var thumb = Path.Combine(paths.ThumbnailDirectory, $"{hash}_{size}.jpg");
        if (File.Exists(thumb)) return thumb;
        try
        {
            using (var img = Image.FromFile(original))
            {
                var scale = Math.Min(1.0, size / (double)Math.Max(img.Width, img.Height));
                var w = Math.Max(1, (int)Math.Round(img.Width * scale));
                var h = Math.Max(1, (int)Math.Round(img.Height * scale));
                using var bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb);
                using (var g = Graphics.FromImage(bmp))
                {
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.SmoothingMode = SmoothingMode.HighQuality;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.CompositingQuality = CompositingQuality.HighQuality;
                    g.Clear(Color.Black);
                    using var attrs = new ImageAttributes();
                    attrs.SetWrapMode(WrapMode.TileFlipXY);
                    g.DrawImage(img, new Rectangle(0, 0, w, h), 0, 0, img.Width, img.Height, GraphicsUnit.Pixel, attrs);
                }
                var codec = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
                using var ep = new EncoderParameters(1);
                ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 88L);
                var tmp = thumb + ".tmp";
                bmp.Save(tmp, codec, ep);
                File.Move(tmp, thumb, overwrite: true);
            }
            return thumb;
        }
        catch (Exception ex) when (ex is OutOfMemoryException or ArgumentException or ExternalException or IOException or PlatformNotSupportedException)
        {
            // GDI+ cannot decode some formats (e.g. WebP); fall back to the original image.
            logger.LogDebug(ex, "Thumbnail generation failed for {Hash}", hash);
            return original;
        }
    }

    public string? FindFolderImage(string folder)
    {
        try
        {
            if (!Directory.Exists(folder)) return null;
            var images = Directory.EnumerateFiles(folder).Where(f => Models.AudioFormats.ImageExtensions.Contains(Path.GetExtension(f))).ToList();
            foreach (var name in FolderImageNames)
            {
                var hit = images.FirstOrDefault(f => Path.GetFileNameWithoutExtension(f).Equals(name, StringComparison.OrdinalIgnoreCase));
                if (hit is not null) return hit;
            }
            var partial = images.FirstOrDefault(f => FolderImageNames.Any(n => Path.GetFileNameWithoutExtension(f).Contains(n, StringComparison.OrdinalIgnoreCase)));
            return partial ?? (images.Count == 1 ? images[0] : null);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public Task<long> GetSizeAsync(CancellationToken ct = default) => Task.Run(() =>
        new DirectoryInfo(paths.ArtworkDirectory).EnumerateFiles("*", SearchOption.AllDirectories).Sum(f => f.Length), ct);
}

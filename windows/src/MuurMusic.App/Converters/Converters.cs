using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace MuurMusic.App.Converters;

/// <summary>Converts a bool to configurable strings (TrueValue / FalseValue).</summary>
public sealed class BoolToStringConverter : IValueConverter
{
    public string TrueValue { get; set; } = "True";
    public string FalseValue { get; set; } = "";

    public object Convert(object value, Type targetType, object parameter, string language) =>
        value is true ? TrueValue : FalseValue;

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Inverts a boolean (or collapses visibility when false for Visibility targets).</summary>
public sealed class InverseBoolConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        value is bool b ? !b : value;

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        value is bool b ? !b : value;
}

/// <summary>Formats a byte count as KB/MB/GB.</summary>
public sealed class BytesConverter : IValueConverter
{
    public static string Format(long bytes) => bytes switch
    {
        < 1024 => $"{bytes} B",
        < 1024L * 1024 => $"{bytes / 1024.0:0.#} KB",
        < 1024L * 1024 * 1024 => $"{bytes / 1048576.0:0.#} MB",
        _ => $"{bytes / 1073741824.0:0.##} GB",
    };

    public object Convert(object value, Type targetType, object parameter, string language) =>
        value switch
        {
            long l => Format(l),
            int i => Format(i),
            double d => Format((long)d),
            _ => "",
        };

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Formats milliseconds / TimeSpan as m:ss or h:mm:ss.</summary>
public sealed class DurationConverter : IValueConverter
{
    public static string FormatMs(long ms)
    {
        var t = TimeSpan.FromMilliseconds(ms);
        return t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{t.Minutes}:{t.Seconds:00}";
    }

    public object Convert(object value, Type targetType, object parameter, string language) => value switch
    {
        long ms => FormatMs(ms),
        TimeSpan t => FormatMs((long)t.TotalMilliseconds),
        _ => "",
    };

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Formats DateTimeOffset as a local friendly date/time.</summary>
public sealed class DateTimeConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        DateTimeOffset? dto = value is DateTimeOffset d ? d : null;
        if (dto is null) return "";
        var local = dto.Value.LocalDateTime;
        return local.Date == DateTime.Today
            ? $"Today {local:t}"
            : local.Date == DateTime.Today.AddDays(-1)
                ? $"Yesterday {local:t}"
                : $"{local:g}";
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>0-5 rating to a star string.</summary>
public sealed class RatingStarsConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var r = value is int i ? i : 0;
        return new string('\u2605', r) + new string('\u2606', 5 - r);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Artwork hash to a thumbnail file Uri (default artwork when missing).</summary>
public sealed class ArtworkThumbConverter : IValueConverter
{
    public object? Convert(object value, Type targetType, object parameter, string language)
    {
        var hash = value as string;
        string? path = null;
        try
        {
            if (!string.IsNullOrEmpty(hash) && App.Services is not null)
            {
                var cache = Microsoft.Extensions.DependencyInjection.ServiceProviderServiceExtensions
                    .GetRequiredService<MuurMusic.Core.Tags.IArtworkCache>(App.Services);
                var size = 256;
                if (parameter is string p && int.TryParse(p, out var s)) size = s;
                path = cache.GetThumbnailPath(hash, size);
            }
        }
        catch (Exception) { }
        path ??= System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "default-artwork.png");
        return new Uri(path);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Dim unavailable/missing items.</summary>
public sealed class MissingOpacityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) => value is true ? 0.4 : 1.0;
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>Image path string to Uri, default artwork when null/empty.</summary>
public sealed class PathOrDefaultArtConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var path = value as string;
        if (string.IsNullOrEmpty(path))
            path = System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "default-artwork.png");
        return new Uri(path);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Empty-string / null to Visibility.</summary>
public sealed class EmptyToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        value is string s && !string.IsNullOrEmpty(s) ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

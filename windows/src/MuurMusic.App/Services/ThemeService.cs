using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using MuurMusic.Core.Settings;

namespace MuurMusic.App.Services;

/// <summary>Applies the theme (dark/light/system) and the accent color app-wide.</summary>
public sealed class ThemeService
{
    public static readonly IReadOnlyList<(string Name, string DarkHex, string LightTextHex)> Accents = new[]
    {
        ("Amber", "#FFB23F", "#C77C00"),
        ("Violet", "#8B6CFF", "#6B4FD8"),
        ("Mint", "#5EE0C0", "#0E8A70"),
        ("Rose", "#FF7BA9", "#D13A72"),
        ("Sky", "#5CB8FF", "#1A6FBF"),
    };

    private readonly ISettingsService _settings;

    public ThemeService(ISettingsService settings)
    {
        _settings = settings;
        settings.Changed += (_, e) =>
        {
            if (e.New.Theme != e.Old.Theme) ApplyTheme(e.New.Theme);
            if (e.New.Accent != e.Old.Accent) ApplyAccent(e.New.Accent);
        };
    }

    public ElementTheme CurrentTheme => _settings.Current.Theme switch
    {
        ThemeMode.Dark => ElementTheme.Dark,
        ThemeMode.Light => ElementTheme.Light,
        _ => ElementTheme.Default,
    };

    public void ApplyCurrent()
    {
        ApplyTheme(_settings.Current.Theme);
        ApplyAccent(_settings.Current.Accent);
    }

    public void ApplyTheme(ThemeMode mode)
    {
        var theme = mode switch
        {
            ThemeMode.Dark => ElementTheme.Dark,
            ThemeMode.Light => ElementTheme.Light,
            _ => ElementTheme.Default,
        };
        if (App.CurrentWindow?.Content is FrameworkElement root)
            root.RequestedTheme = theme;
    }

    public void ApplyAccent(string name)
    {
        var accent = Accents.FirstOrDefault(a => string.Equals(a.Name, name, StringComparison.OrdinalIgnoreCase));
        var hex = accent.DarkHex ?? "#FFB23F";
        var textHex = accent.LightTextHex ?? "#C77C00";
        MutateBrush("MuurAccentBrush", Parse(hex));
        // Secondary accent stays violet unless the user picked violet (then amber keeps contrast).
        MutateBrush("MuurAccentSecondaryBrush",
            Parse(string.Equals(name, "Violet", StringComparison.OrdinalIgnoreCase) ? "#FFB23F" : "#8B6CFF"));
        MutateThemeColor("MuurAccentTextColor", "Dark", Parse(hex));
        MutateThemeColor("MuurAccentTextColor", "Light", Parse(textHex));
        // Re-resolve theme-dependent brushes that reference MuurAccentTextColor.
        if (App.CurrentWindow?.Content is FrameworkElement root)
        {
            var current = root.RequestedTheme;
            root.RequestedTheme = current == ElementTheme.Dark ? ElementTheme.Light : ElementTheme.Dark;
            root.RequestedTheme = current;
        }
    }

    private static void MutateBrush(string key, Windows.UI.Color color)
    {
        if (Application.Current.Resources.TryGetValue(key, out var v) && v is SolidColorBrush brush)
            brush.Color = color;
    }

    private static void MutateThemeColor(string key, string theme, Windows.UI.Color color)
    {
        foreach (var dict in Application.Current.Resources.MergedDictionaries)
        {
            if (dict.ThemeDictionaries.TryGetValue(theme, out var themed) && themed is ResourceDictionary rd
                && rd.TryGetValue(key, out var v) && v is Windows.UI.Color)
                rd[key] = color;
        }
    }

    private static Windows.UI.Color Parse(string hex)
    {
        hex = hex.TrimStart('#');
        return new Windows.UI.Color
        {
            A = 255,
            R = Convert.ToByte(hex.Substring(0, 2), 16),
            G = Convert.ToByte(hex.Substring(2, 2), 16),
            B = Convert.ToByte(hex.Substring(4, 2), 16),
        };
    }
}

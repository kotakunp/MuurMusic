using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using MuurMusic.App.ViewModels;
using MuurMusic.Core.Discovery;
using MuurMusic.Core.Models;
using MuurMusic.Core.Sources;

namespace MuurMusic.App.Views;

/// <summary>Result of the source editor: config plus any secrets to store.</summary>
public sealed record SourceEditResult(SourceConfig Config, Dictionary<string, string?> Secrets);

/// <summary>
/// Dynamic add/edit dialog for every source kind. Fields come from <see cref="SourceCatalog.FieldsFor"/>;
/// OAuth providers and Plex get their own connect flows inside the dialog.
/// </summary>
public sealed partial class SourceEditDialog : ContentDialog
{
    private readonly SourceKind _kind;
    private readonly SourceConfig _config;
    private readonly Dictionary<string, FrameworkElement> _fields = new();
    private readonly Dictionary<FrameworkElement, SourceFieldSpec> _specs = new();
    private readonly TextBlock _status;
    private readonly ProgressRing _spinner;
    private SourceEditResult? _result;
    private string? _plexToken;
    private bool _oauthConnected;
    private readonly bool _isExisting;

    private SourceEditDialog(SourceKind kind, SourceConfig? existing)
    {
        _kind = kind;
        _isExisting = existing is not null;
        _config = existing ?? new SourceConfig { Kind = kind };
        Title = existing is null ? $"Add {SourceCatalog.LabelFor(kind)}" : $"Edit {_config.Name}";
        PrimaryButtonText = existing is null ? "Add" : "Save";
        CloseButtonText = "Cancel";
        DefaultButton = ContentDialogButton.Primary;

        var panel = new StackPanel { Spacing = 10, MinWidth = 420 };
        panel.Children.Add(new TextBlock { Text = "Name", FontSize = 12, Opacity = 0.7 });
        var nameBox = new TextBox { Text = _config.Name, PlaceholderText = SourceCatalog.LabelFor(kind) };
        panel.Children.Add(nameBox);
        _fields["__name"] = nameBox;

        if (SourceCatalog.IsOAuth(kind))
        {
            BuildOAuthPanel(panel);
        }
        else if (kind == SourceKind.Plex)
        {
            BuildPlexPanel(panel);
        }

        foreach (var spec in SourceCatalog.FieldsFor(kind))
        {
            panel.Children.Add(new TextBlock { Text = spec.Label, FontSize = 12, Opacity = 0.7 });
            FrameworkElement field = spec.Kind switch
            {
                SourceFieldKind.Password => new PasswordBox { Password = "", PlaceholderText = existing is null ? "" : "Leave empty to keep the stored value" },
                SourceFieldKind.Number => new NumberBox { Value = double.TryParse(spec.Default, out var dv) ? dv : double.NaN, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Hidden, Minimum = 0, Maximum = 65535 },
                SourceFieldKind.Toggle => new ToggleSwitch { IsOn = spec.Default == "true" || _config.GetBool(spec.Key) },
                SourceFieldKind.Choice => BuildPresetCombo(),
                SourceFieldKind.FilePath => BuildFilePicker(spec),
                _ => new TextBox { Text = _config.Get(spec.Key) ?? spec.Default ?? "", PlaceholderText = spec.Placeholder },
            };
            _fields[spec.Key] = field;
            _specs[field] = spec;
            panel.Children.Add(field);
            if (kind == SourceKind.WebDav && spec.Key == SourceKeys.Preset)
            {
                var note = new TextBlock { FontSize = 11, Opacity = 0.6, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, -6, 0, 0) };
                if (field is ComboBox combo)
                {
                    combo.SelectionChanged += (_, _) => note.Text = WebDavPresets.Find(combo.SelectedItem as string)?.Notes ?? "";
                    note.Text = WebDavPresets.Find(combo.SelectedItem as string)?.Notes ?? "";
                }
                panel.Children.Add(note);
            }
        }

        _status = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = (Brush)Application.Current.Resources["MuurSecondaryBrush"] };
        _spinner = new ProgressRing { IsActive = false, Width = 18, Height = 18, Visibility = Visibility.Collapsed };
        var statusRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        statusRow.Children.Add(_spinner);
        statusRow.Children.Add(_status);
        panel.Children.Add(statusRow);

        Content = new ScrollViewer { Content = panel, MaxHeight = 560, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        PrimaryButtonClick += OnSave;
    }

    private ComboBox BuildPresetCombo()
    {
        var combo = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var p in WebDavPresets.All) combo.Items.Add(p.Id);
        combo.SelectedItem = _config.Get(SourceKeys.Preset) ?? "custom";
        return combo;
    }

    private FrameworkElement BuildFilePicker(SourceFieldSpec spec)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var box = new TextBox { MinWidth = 260, IsReadOnly = true, PlaceholderText = spec.Placeholder, Text = _config.Get(spec.Key) ?? "" };
        var button = new Button { Content = "Browse\u2026" };
        button.Click += async (_, _) =>
        {
            var dialogs = App.Services.GetRequiredService<Services.DialogService>();
            var path = spec.Key == SourceKeys.ArchiveUri
                ? await dialogs.PickOpenFileAsync("Open", ".zip")
                : await dialogs.PickOpenFileAsync("Open", "*");
            if (path is not null) box.Text = path;
        };
        row.Children.Add(box);
        Grid.SetColumn(button, 1);
        row.Children.Add(button);
        row.Tag = box; // value lives on the inner text box
        return row;
    }

    private void BuildOAuthPanel(StackPanel panel)
    {
        var oauth = App.Services.GetRequiredService<IOAuthService>();
        var provider = OAuthProviders.ForKind(_kind);
        var configured = oauth.IsConfigured(provider);
        var info = new InfoBar
        {
            IsOpen = true,
            Severity = configured ? InfoBarSeverity.Informational : InfoBarSeverity.Warning,
            Message = configured
                ? "Connect your account; MuurMusic opens your browser for sign-in and stores the token in Windows Credential Manager."
                : "This provider needs an OAuth client id in appsettings.Local.json (see BUILD.md) before sign-in works.",
        };
        panel.Children.Add(info);
        var button = new Button
        {
            Content = _oauthConnected ? "Connected \u2713" : $"Connect {SourceCatalog.LabelFor(_kind)}",
            IsEnabled = configured,
        };
        // New OAuth sources must connect before they can be added.
        if (!_isExisting) IsPrimaryButtonEnabled = false;
        button.Click += async (_, _) =>
        {
            button.IsEnabled = false;
            _spinner.Visibility = Visibility.Visible;
            _spinner.IsActive = true;
            _status.Text = "Waiting for the browser sign-in\u2026";
            try
            {
                await oauth.AuthorizeSourceAsync(_config);
                _oauthConnected = true; // credentials are stored by the OAuth service
                button.Content = "Connected \u2713";
                _status.Text = "Account connected. Press Add to finish.";
                IsPrimaryButtonEnabled = true;
            }
            catch (OAuthNotConfiguredException ex)
            {
                _status.Text = ex.Message;
            }
            catch (OperationCanceledException)
            {
                _status.Text = "Sign-in canceled.";
                button.IsEnabled = true;
            }
            catch (Exception ex)
            {
                _status.Text = ex.Message;
                button.IsEnabled = true;
            }
            finally
            {
                _spinner.IsActive = false;
                _spinner.Visibility = Visibility.Collapsed;
            }
        };
        panel.Children.Add(button);
    }

    private void BuildPlexPanel(StackPanel panel)
    {
        var signIn = new Button { Content = "Sign in with Plex" };
        var codeText = new TextBlock { FontSize = 22, FontWeight = Microsoft.UI.Text.FontWeights.Bold, Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Center };
        var openLink = new HyperlinkButton { Content = "Open plex.tv/link", Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Center };
        var serverCombo = new ComboBox { PlaceholderText = "Pick a server\u2026", Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Stretch };
        var servers = new List<PlexServer>();
        panel.Children.Add(signIn);
        panel.Children.Add(codeText);
        panel.Children.Add(openLink);
        panel.Children.Add(serverCombo);

        IsPrimaryButtonEnabled = false;

        signIn.Click += async (_, _) =>
        {
            var plex = App.Services.GetRequiredService<PlexAuthService>();
            signIn.IsEnabled = false;
            _spinner.Visibility = Visibility.Visible;
            _spinner.IsActive = true;
            try
            {
                var pin = await plex.CreatePinAsync(_config.Id.ToString("N"));
                codeText.Text = pin.Code;
                codeText.Visibility = Visibility.Visible;
                openLink.NavigateUri = new Uri(pin.AuthUrl);
                openLink.Visibility = Visibility.Visible;
                _status.Text = "Enter the code at plex.tv/link, then come back here.";
                var token = await plex.WaitForPinAsync(pin);
                servers.Clear();
                foreach (var s in await plex.GetServersAsync(token, pin.ClientIdentifier)) servers.Add(s);
                _plexToken = token;
                serverCombo.ItemsSource = servers.Select(s => s.Name).ToList();
                serverCombo.SelectedIndex = 0;
                serverCombo.Visibility = Visibility.Visible;
                _status.Text = "Signed in. Pick your server and press Add.";
                IsPrimaryButtonEnabled = servers.Count > 0;
            }
            catch (Exception ex)
            {
                _status.Text = ex.Message;
                signIn.IsEnabled = true;
            }
            finally
            {
                _spinner.IsActive = false;
                _spinner.Visibility = Visibility.Collapsed;
            }
        };

        serverCombo.SelectionChanged += (_, _) =>
        {
            if (serverCombo.SelectedIndex >= 0 && serverCombo.SelectedIndex < servers.Count)
            {
                var server = servers[serverCombo.SelectedIndex];
                var plex = App.Services.GetRequiredService<PlexAuthService>();
                _ = Task.Run(async () =>
                {
                    var token = await plex.ConfigureSourceAsync(_config, server);
                    _plexToken = token;
                    DispatcherQueue.TryEnqueue(() =>
                    {
                        if (string.IsNullOrEmpty(_config.Name) && _fields.TryGetValue("__name", out var nb) && nb is TextBox t)
                            t.Text = _config.Name;
                    });
                });
            }
        };
    }

    private static string FieldValue(FrameworkElement field) => field switch
    {
        TextBox t => t.Text.Trim(),
        PasswordBox p => p.Password,
        NumberBox n => double.IsNaN(n.Value) ? "" : ((int)n.Value).ToString(),
        ToggleSwitch t => t.IsOn ? "true" : "false",
        ComboBox c => c.SelectedItem as string ?? "",
        Grid g when g.Tag is TextBox inner => inner.Text.Trim(),
        _ => "",
    };

    private async void OnSave(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var deferral = args.GetDeferral();
        args.Cancel = true; // close only after the connection check passes
        try
        {
            if (_fields.TryGetValue("__name", out var nb) && nb is TextBox nameBox)
                _config.Name = string.IsNullOrWhiteSpace(nameBox.Text) ? SourceCatalog.LabelFor(_kind) : nameBox.Text.Trim();

            var secrets = new Dictionary<string, string?>();
            foreach (var (field, spec) in _specs)
            {
                var value = FieldValue(field);
                if (spec.SecretKey is { } secretKey)
                {
                    // Empty secret on edit = keep the stored one.
                    if (!string.IsNullOrEmpty(value))
                    {
                        if (spec.Kind == SourceFieldKind.FilePath && spec.Key == SourceKeys.SecretPrivateKey)
                            secrets[secretKey] = await File.ReadAllTextAsync(value);
                        else
                            secrets[secretKey] = value;
                    }
                }
                else if (spec.Key != SourceKeys.SecretPrivateKey)
                {
                    _config.Set(spec.Key, value);
                }
            }

            if (_kind == SourceKind.WebDav)
            {
                var preset = WebDavPresets.Find(_config.Get(SourceKeys.Preset)) ?? WebDavPresets.All[0];
                var host = _config.Get(SourceKeys.Host) ?? "";
                if (preset.Id == "custom" || !preset.NeedsHost)
                    _config.Set(SourceKeys.BaseUrl, host.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? host : $"https://{host}/");
                else
                    _config.Set(SourceKeys.BaseUrl, WebDavPresets.BuildUrl(preset, host, _config.Get(SourceKeys.Username) ?? ""));
            }

            if (_kind == SourceKind.Plex && _plexToken is not null)
                secrets[SourceKeys.SecretToken] = _plexToken;

            // Test the connection before saving; OAuth sources already passed the browser round-trip.
            if (!SourceCatalog.IsOAuth(_kind))
            {
                IsPrimaryButtonEnabled = false;
                _spinner.Visibility = Visibility.Visible;
                _spinner.IsActive = true;
                _status.Text = "Checking the connection\u2026";
                var sources = App.Services.GetRequiredService<ISourceManager>();
                try
                {
                    var probe = sources.Create(_config);
                    await probe.TestConnectionAsync();
                }
                catch (Exception ex)
                {
                    _status.Text = $"Connection failed: {ex.Message}";
                    return;
                }
                finally
                {
                    _spinner.IsActive = false;
                    _spinner.Visibility = Visibility.Collapsed;
                    IsPrimaryButtonEnabled = true;
                }
            }

            _result = new SourceEditResult(_config, secrets);
            Hide();
        }
        finally
        {
            deferral.Complete();
        }
    }

    /// <summary>Shows the dialog; null when canceled.</summary>
    public static async Task<SourceEditResult?> ShowForAsync(SourceKind kind, SourceConfig? existing = null)
    {
        var dialog = new SourceEditDialog(kind, existing);
        dialog.XamlRoot = App.CurrentWindow!.Content.XamlRoot;
        await dialog.ShowAsync();
        return dialog._result;
    }

    /// <summary>Shows the dialog pre-filled from a discovered server.</summary>
    public static Task<SourceEditResult?> ShowForAsync(DiscoveredServer server) =>
        ShowForAsync(server.Kind switch
        {
            DiscoveredServerKind.Smb => SourceKind.Smb,
            DiscoveredServerKind.WebDav => SourceKind.WebDav,
            DiscoveredServerKind.Sftp => SourceKind.Sftp,
            DiscoveredServerKind.Ftp => SourceKind.Ftp,
            DiscoveredServerKind.Upnp => SourceKind.Upnp,
            DiscoveredServerKind.Jellyfin => SourceKind.Jellyfin,
            DiscoveredServerKind.Emby => SourceKind.Emby,
            DiscoveredServerKind.Plex => SourceKind.Plex,
            _ => SourceKind.WebDav,
        }, server.ToSourceConfig());
}

using System.Text.Json;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Infrastructure;

namespace MuurMusic.Core.Settings;

public sealed class SettingsChangedEventArgs(AppSettings oldSettings, AppSettings newSettings) : EventArgs
{
    public AppSettings Old { get; } = oldSettings;
    public AppSettings New { get; } = newSettings;
}

/// <summary>Loads and saves <see cref="AppSettings"/>. <see cref="Current"/> is an immutable snapshot; use <see cref="Update"/> to change.</summary>
public interface ISettingsService
{
    AppSettings Current { get; }
    /// <summary>Applies a mutation to a copy of the settings, persists it and raises <see cref="Changed"/>.</summary>
    void Update(Action<AppSettings> mutate);
    /// <summary>Raised after settings change (through <see cref="IEventDispatcher"/>).</summary>
    event EventHandler<SettingsChangedEventArgs>? Changed;
    Task FlushAsync();
}

public sealed class SettingsService : ISettingsService, IDisposable
{
    private readonly AppPaths _paths;
    private readonly IEventDispatcher _dispatcher;
    private readonly ILogger<SettingsService> _logger;
    private readonly object _gate = new();
    private readonly Timer _saveTimer;
    private AppSettings _current;
    private bool _dirty;

    public SettingsService(AppPaths paths, IEventDispatcher dispatcher, ILogger<SettingsService> logger)
    {
        _paths = paths;
        _dispatcher = dispatcher;
        _logger = logger;
        _current = Load();
        _saveTimer = new Timer(_ => Save(), null, Timeout.Infinite, Timeout.Infinite);
    }

    public AppSettings Current { get { lock (_gate) return _current; } }

    public event EventHandler<SettingsChangedEventArgs>? Changed;

    public void Update(Action<AppSettings> mutate)
    {
        AppSettings old, updated;
        lock (_gate)
        {
            old = _current;
            updated = old.Clone();
            mutate(updated);
            _current = updated;
            _dirty = true;
        }
        _saveTimer.Change(500, Timeout.Infinite);
        _dispatcher.Post(() => Changed?.Invoke(this, new SettingsChangedEventArgs(old, updated)));
    }

    public Task FlushAsync()
    {
        Save();
        return Task.CompletedTask;
    }

    private AppSettings Load()
    {
        try
        {
            if (File.Exists(_paths.SettingsPath))
            {
                var json = File.ReadAllText(_paths.SettingsPath);
                var s = JsonSerializer.Deserialize<AppSettings>(json, SettingsJson.Options);
                if (s is not null)
                {
                    if (s.EqBands is null || s.EqBands.Length != 10) s.EqBands = new double[10];
                    return s;
                }
            }
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            _logger.LogWarning(ex, "Settings file unreadable; using defaults");
            try { File.Copy(_paths.SettingsPath, _paths.SettingsPath + ".bad", true); } catch (IOException) { }
        }
        return new AppSettings();
    }

    private void Save()
    {
        AppSettings snapshot;
        lock (_gate)
        {
            if (!_dirty) return;
            snapshot = _current;
            _dirty = false;
        }
        try
        {
            var tmp = _paths.SettingsPath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(snapshot, SettingsJson.Options));
            File.Move(tmp, _paths.SettingsPath, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _logger.LogError(ex, "Failed to save settings");
            lock (_gate) _dirty = true;
        }
    }

    public void Dispose()
    {
        _saveTimer.Dispose();
        Save();
    }
}

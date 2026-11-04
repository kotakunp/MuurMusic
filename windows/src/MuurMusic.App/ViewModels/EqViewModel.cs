using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using MuurMusic.App.Services;
using MuurMusic.Core.Dsp;
using MuurMusic.Core.Models;
using MuurMusic.Core.Settings;

namespace MuurMusic.App.ViewModels;

public sealed partial class EqBandItem : ObservableObject
{
    public required string Label { get; init; }
    public int Index { get; init; }

    [ObservableProperty] private double _value;

    partial void OnValueChanged(double value) => Changed?.Invoke(Index, value);

    public event Action<int, double>? Changed;
}

/// <summary>10-band graphic equalizer with presets and live write-through to playback.</summary>
public sealed partial class EqViewModel : ObservableObject, IDisposable
{
    private readonly ISettingsService _settings;
    private readonly IPresetService _presets;
    private readonly NotificationService _notifications;
    private readonly DialogService _dialogs;
    private readonly Audio.Playback.IPlaybackService _playback;
    private readonly DispatcherQueueTimer _meterTimer;
    private bool _suppressWrite;

    public EqViewModel(ISettingsService settings, IPresetService presets, NotificationService notifications, DialogService dialogs, Audio.Playback.IPlaybackService playback)
    {
        _settings = settings;
        _presets = presets;
        _notifications = notifications;
        _dialogs = dialogs;
        _playback = playback;

        var current = settings.Current;
        _enabled = current.EqEnabled;
        _preamp = current.EqPreampDb;
        for (var i = 0; i < EqPreset.IsoFrequencies.Count; i++)
        {
            var hz = EqPreset.IsoFrequencies[i];
            var item = new EqBandItem
            {
                Label = hz >= 1000 ? $"{hz / 1000:0.#}k" : $"{hz:0}",
                Index = i,
                Value = i < current.EqBands.Length ? current.EqBands[i] : 0,
            };
            item.Changed += OnBandChanged;
            Bands.Add(item);
        }
        _meterTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _meterTimer.Interval = TimeSpan.FromMilliseconds(50);
        _meterTimer.Tick += (_, _) =>
        {
            var m = _playback.Engine.Meter.Read();
            PeakLeft = Math.Clamp(m.PeakLeft, 0f, 1f);
            PeakRight = Math.Clamp(m.PeakRight, 0f, 1f);
        };
    }

    public ObservableCollection<EqBandItem> Bands { get; } = new();
    public ObservableCollection<string> PresetNames { get; } = new();

    [ObservableProperty] private bool _enabled;
    [ObservableProperty] private double _preamp;
    [ObservableProperty] private string? _selectedPreset;
    [ObservableProperty] private bool _canModifyPreset;
    [ObservableProperty] private float _peakLeft;
    [ObservableProperty] private float _peakRight;

    public async Task LoadAsync()
    {
        var presets = await _presets.GetEqPresetsAsync();
        PresetNames.Clear();
        foreach (var p in presets) PresetNames.Add(p.Name);
        SelectedPreset = _settings.Current.EqPresetName;
    }

    public void StartMeters() => _meterTimer.Start();
    public void StopMeters() => _meterTimer.Stop();

    partial void OnEnabledChanged(bool value) => _settings.Update(s => s.EqEnabled = value);

    partial void OnPreampChanged(double value)
    {
        if (_suppressWrite) return;
        _settings.Update(s => s.EqPreampDb = Math.Round(value, 1));
    }

    partial void OnSelectedPresetChanged(string? value)
    {
        if (value is null) return;
        _ = ApplyPresetAsync(value);
    }

    private void OnBandChanged(int index, double value)
    {
        if (_suppressWrite) return;
        _settings.Update(s => s.EqBands[index] = Math.Round(value, 1));
    }

    private async Task ApplyPresetAsync(string name)
    {
        var preset = await _presets.FindEqPresetAsync(name);
        if (preset is null) return;
        _suppressWrite = true;
        Preamp = preset.PreampDb;
        var gains = preset.GainsArray();
        for (var i = 0; i < Bands.Count && i < gains.Length; i++) Bands[i].Value = gains[i];
        _suppressWrite = false;
        CanModifyPreset = !preset.IsBuiltIn;
        _settings.Update(s =>
        {
            s.EqPresetName = name;
            s.EqPreampDb = preset.PreampDb;
            s.EqBands = gains;
        });
    }

    [RelayCommand]
    private void Reset()
    {
        _suppressWrite = true;
        Preamp = 0;
        foreach (var b in Bands) b.Value = 0;
        _suppressWrite = false;
        SelectedPreset = "Flat";
        _settings.Update(s =>
        {
            s.EqPresetName = "Flat";
            s.EqPreampDb = 0;
            s.EqBands = new double[10];
        });
    }

    [RelayCommand]
    private async Task SavePreset()
    {
        var name = await _dialogs.PromptAsync("Save EQ preset", "Preset name:", SelectedPreset ?? "My preset");
        if (string.IsNullOrWhiteSpace(name)) return;
        name = name.Trim();
        try
        {
            await _presets.SaveEqPresetAsync(new EqPreset
            {
                Name = name,
                PreampDb = Preamp,
                Bands = EqPreset.IsoFrequencies.Select((f, i) => new EqBand(f, Bands[i].Value)).ToArray(),
            });
            if (!PresetNames.Contains(name)) PresetNames.Add(name);
            SelectedPreset = name;
            CanModifyPreset = true;
            _settings.Update(s => s.EqPresetName = name);
            _notifications.Success("Preset saved", name);
        }
        catch (InvalidOperationException ex)
        {
            _notifications.Error("Cannot save", ex.Message);
        }
    }

    [RelayCommand]
    private async Task RenamePreset()
    {
        if (SelectedPreset is not { } oldName) return;
        var name = await _dialogs.PromptAsync("Rename preset", "New name:", oldName);
        if (string.IsNullOrWhiteSpace(name) || name.Trim() == oldName) return;
        try
        {
            await _presets.RenameEqPresetAsync(oldName, name.Trim());
            var idx = PresetNames.IndexOf(oldName);
            if (idx >= 0) PresetNames[idx] = name.Trim();
            SelectedPreset = name.Trim();
            _settings.Update(s => s.EqPresetName = name.Trim());
        }
        catch (InvalidOperationException ex)
        {
            _notifications.Error("Cannot rename", ex.Message);
        }
    }

    [RelayCommand]
    private async Task DeletePreset()
    {
        if (SelectedPreset is not { } name) return;
        if (!await _dialogs.ConfirmAsync("Delete preset", $"Delete \u201C{name}\u201D? This cannot be undone.", "Delete")) return;
        await _presets.DeleteEqPresetAsync(name);
        PresetNames.Remove(name);
        Reset();
    }

    [RelayCommand]
    private async Task ImportPresets()
    {
        var path = await _dialogs.PickOpenFileAsync("Open", ".json");
        if (path is null) return;
        try
        {
            var imported = await _presets.ImportEqPresetsAsync(path);
            await LoadAsync();
            _notifications.Success("Presets imported", $"{imported.Count} preset{(imported.Count == 1 ? "" : "s")} added.");
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _notifications.Error("Import failed", ex.Message);
        }
    }

    [RelayCommand]
    private async Task ExportPresets()
    {
        var path = await _dialogs.PickSaveFileAsync("muur-eq.json", ".json");
        if (path is null) return;
        try
        {
            var all = await _presets.GetEqPresetsAsync();
            await _presets.ExportEqPresetsAsync(path, all.Where(p => !p.IsBuiltIn));
            _notifications.Success("Presets exported", path);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _notifications.Error("Export failed", ex.Message);
        }
    }

    public void Dispose() => _meterTimer.Stop();
}

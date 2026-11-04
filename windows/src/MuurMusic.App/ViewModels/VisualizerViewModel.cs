using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using MuurMusic.App.Controls;
using MuurMusic.Core.Settings;

namespace MuurMusic.App.ViewModels;

/// <summary>Visualizer page: preset picker, auto-cycle, live meters.</summary>
public sealed partial class VisualizerViewModel : ObservableObject, IDisposable
{
    private readonly ISettingsService _settings;
    private readonly DispatcherQueueTimer _cycleTimer;
    private readonly DispatcherQueueTimer _meterTimer;
    private readonly Audio.Playback.IPlaybackService _playback;

    public VisualizerViewModel(ISettingsService settings, Audio.Playback.IPlaybackService playback)
    {
        _settings = settings;
        _playback = playback;
        _preset = VisualizerControl.ParsePreset(settings.Current.VisualizerPreset);
        _autoCycle = settings.Current.VisualizerAutoCycle;
        _autoCycleSeconds = settings.Current.VisualizerAutoCycleSeconds;

        _cycleTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _cycleTimer.Tick += (_, _) => Preset = NextPreset();
        _meterTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _meterTimer.Interval = TimeSpan.FromMilliseconds(50);
        _meterTimer.Tick += (_, _) => UpdateMeters();
        ApplyCycleTimer();
    }

    public static string[] PresetNames => Enum.GetNames<VisualizerPreset>();

    [ObservableProperty] private VisualizerPreset _preset;
    [ObservableProperty] private bool _autoCycle;
    [ObservableProperty] private double _autoCycleSeconds = 30;
    [ObservableProperty] private float _peakLeft;
    [ObservableProperty] private float _peakRight;
    [ObservableProperty] private string _outputInfo = "";

    partial void OnPresetChanged(VisualizerPreset value) => _settings.Update(s => s.VisualizerPreset = value.ToString());

    partial void OnAutoCycleChanged(bool value)
    {
        _settings.Update(s => s.VisualizerAutoCycle = value);
        ApplyCycleTimer();
    }

    partial void OnAutoCycleSecondsChanged(double value)
    {
        _settings.Update(s => s.VisualizerAutoCycleSeconds = (int)Math.Clamp(value, 5, 300));
        ApplyCycleTimer();
    }

    private void ApplyCycleTimer()
    {
        _cycleTimer.Stop();
        if (AutoCycle)
        {
            _cycleTimer.Interval = TimeSpan.FromSeconds(Math.Clamp(AutoCycleSeconds, 5, 300));
            _cycleTimer.Start();
        }
    }

    private VisualizerPreset NextPreset()
    {
        var all = Enum.GetValues<VisualizerPreset>();
        return all[(Array.IndexOf(all, Preset) + 1) % all.Length];
    }

    [RelayCommand]
    private void SelectPreset(string name)
    {
        if (Enum.TryParse<VisualizerPreset>(name, out var p)) Preset = p;
    }

    public void Start()
    {
        _meterTimer.Start();
        var o = _playback.Output;
        OutputInfo = o.IsOpen
            ? $"{o.Format?.SampleRate / 1000.0 ?? 0:0.#} kHz \u00B7 {o.Format?.Channels ?? 2} ch \u00B7 {(o.Format?.Exclusive == true ? "exclusive" : "shared")} \u00B7 {o.DeviceName}"
            : "Output not open yet \u2014 press play.";
    }

    public void Stop() => _meterTimer.Stop();

    private void UpdateMeters()
    {
        var reading = _playback.Engine.Meter.Read();
        PeakLeft = Math.Clamp(reading.PeakLeft, 0f, 1f);
        PeakRight = Math.Clamp(reading.PeakRight, 0f, 1f);
    }

    public void Dispose()
    {
        _cycleTimer.Stop();
        _meterTimer.Stop();
    }
}

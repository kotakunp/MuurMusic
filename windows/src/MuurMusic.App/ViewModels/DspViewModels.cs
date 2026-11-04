using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using MuurMusic.App.Services;
using MuurMusic.Core.Dsp;
using MuurMusic.Core.Models;
using MuurMusic.Core.Settings;

namespace MuurMusic.App.ViewModels;

/// <summary>One editable numeric DSP parameter; logarithmic specs map through a log slider.</summary>
public sealed partial class DspParamItem : ObservableObject
{
    private readonly DspNode _node;
    private bool _suppress;

    public DspParamItem(DspNode node, DspParamSpec spec)
    {
        _node = node;
        Spec = spec;
        _value = node.Get(spec.Name);
        _suppress = true;
        _slider = ValueToSlider(_value);
        _suppress = false;
    }

    public DspParamSpec Spec { get; }
    public string Label => Spec.Label;
    public string Unit => Spec.Unit;

    [ObservableProperty] private double _value;
    /// <summary>0..1000 slider position (log-mapped when the spec is logarithmic).</summary>
    [ObservableProperty] private double _slider;
    /// <summary>False while the owning node/card is bypassed or off.</summary>
    [ObservableProperty] private bool _isEffectivelyEnabled = true;

    public string DisplayValue => Spec.IsInteger ? $"{Value:0} {Unit}".Trim() : $"{Value:0.##} {Unit}".Trim();

    private double ValueToSlider(double value)
    {
        if (Spec.Logarithmic)
        {
            var min = Math.Log(Math.Max(Spec.Min, 0.0001));
            var max = Math.Log(Math.Max(Spec.Max, 0.0001));
            return (Math.Log(Math.Max(value, 0.0001)) - min) / (max - min) * 1000.0;
        }
        return (value - Spec.Min) / (Spec.Max - Spec.Min) * 1000.0;
    }

    private double SliderToValue(double slider)
    {
        var t = Math.Clamp(slider / 1000.0, 0, 1);
        double v;
        if (Spec.Logarithmic)
        {
            var min = Math.Log(Math.Max(Spec.Min, 0.0001));
            var max = Math.Log(Math.Max(Spec.Max, 0.0001));
            v = Math.Exp(min + t * (max - min));
        }
        else v = Spec.Min + t * (Spec.Max - Spec.Min);
        v = Math.Clamp(v, Spec.Min, Spec.Max);
        if (Spec.IsInteger) v = Math.Round(v);
        return v;
    }

    partial void OnSliderChanged(double value)
    {
        if (_suppress) return;
        _suppress = true;
        Value = SliderToValue(value);
        _suppress = false;
        Commit();
    }

    partial void OnValueChanged(double value)
    {
        OnPropertyChanged(nameof(DisplayValue));
        if (_suppress) return;
        _suppress = true;
        Slider = ValueToSlider(value);
        _suppress = false;
        Commit();
    }

    private void Commit()
    {
        _node.Params[Spec.Name] = Value;
        Changed?.Invoke();
    }

    public event Action? Changed;
}

/// <summary>One node row in the DSP chain editor.</summary>
public sealed partial class DspNodeItem : ObservableObject
{
    public DspNodeItem(DspNode node)
    {
        Node = node;
        _enabled = node.Enabled;
        foreach (var spec in DspNodeTypes.GetParams(node.Type))
            Params.Add(new DspParamItem(node, spec) { IsEffectivelyEnabled = node.Enabled });
    }

    public DspNode Node { get; }
    public string Label => DspNodeTypes.GetLabel(Node.Type);
    public bool IsSupported => Node.IsSupported;
    public ObservableCollection<DspParamItem> Params { get; } = new();
    [ObservableProperty] private bool _enabled;

    partial void OnEnabledChanged(bool value)
    {
        Node.Enabled = value;
        foreach (var prm in Params) prm.IsEffectivelyEnabled = value;
        Changed?.Invoke();
    }

    public event Action? Changed;

    // Command proxies so DataTemplates can reach the parent view model.
    public CommunityToolkit.Mvvm.Input.IRelayCommand<DspNodeItem>? MoveUpCommand { get; set; }
    public CommunityToolkit.Mvvm.Input.IRelayCommand<DspNodeItem>? MoveDownCommand { get; set; }
    public CommunityToolkit.Mvvm.Input.IRelayCommand<DspNodeItem>? RemoveCommand { get; set; }

    public void WireParams(Action onChanged)
    {
        foreach (var p in Params) p.Changed += onChanged;
    }
}

public sealed record DspNodeTypeItem(string Type, string Label);

/// <summary>DSP chain builder: ordered nodes, per-param editors, presets, live write-through.</summary>
public sealed partial class DspChainViewModel : ObservableObject
{
    private readonly ISettingsService _settings;
    private readonly IPresetService _presets;
    private readonly NotificationService _notifications;
    private readonly DialogService _dialogs;
    private bool _suppress;

    public DspChainViewModel(ISettingsService settings, IPresetService presets, NotificationService notifications, DialogService dialogs)
    {
        _settings = settings;
        _presets = presets;
        _notifications = notifications;
        _dialogs = dialogs;
        _chainEnabled = settings.Current.DspChainEnabled;
        LoadFromJson(settings.Current.DspChainJson);
    }

    public ObservableCollection<DspNodeItem> Nodes { get; } = new();
    public ObservableCollection<string> SavedChainNames { get; } = new();

    [ObservableProperty] private bool _chainEnabled;
    [ObservableProperty] private string _chainName = "Default";
    [ObservableProperty] private string? _selectedSavedChain;
    [ObservableProperty] private string _summary = "";

    public IReadOnlyList<DspNodeTypeItem> AvailableTypes { get; } =
        DspNodeTypes.All.Select(t => new DspNodeTypeItem(t, DspNodeTypes.GetLabel(t))).ToList();

    private void LoadFromJson(string? json)
    {
        Nodes.Clear();
        DspChain? chain = null;
        if (!string.IsNullOrWhiteSpace(json))
        {
            try { chain = DspJson.ReadDspChain(json); }
            catch (Exception) { chain = null; }
        }
        chain ??= new DspChain();
        ChainName = chain.Name;
        foreach (var node in chain.Nodes) AddNodeItem(node);
        UpdateSummary();
    }

    private DspNodeItem AddNodeItem(DspNode node)
    {
        var item = new DspNodeItem(node);
        item.Changed += SaveToSettings;
        item.WireParams(SaveToSettings);
        item.MoveUpCommand = MoveUpCommand;
        item.MoveDownCommand = MoveDownCommand;
        item.RemoveCommand = RemoveNodeCommand;
        Nodes.Add(item);
        return item;
    }

    private DspChain BuildChain() => new()
    {
        Name = ChainName,
        Nodes = Nodes.Select(n => n.Node.Clone()).ToList(),
    };

    private void SaveToSettings()
    {
        if (_suppress) return;
        var chain = BuildChain();
        _settings.Update(s => s.DspChainJson = DspJson.WriteDspChain(chain));
        UpdateSummary();
    }

    private void UpdateSummary()
    {
        var active = Nodes.Count(n => n.Enabled);
        Summary = Nodes.Count == 0
            ? "Empty chain \u2014 add an effect below."
            : $"{active} of {Nodes.Count} node{(Nodes.Count == 1 ? "" : "s")} active";
    }

    partial void OnChainEnabledChanged(bool value) => _settings.Update(s => s.DspChainEnabled = value);

    [RelayCommand]
    private void AddNode(string type)
    {
        if (string.IsNullOrEmpty(type)) return;
        AddNodeItem(DspNode.Create(type));
        SaveToSettings();
    }

    [RelayCommand]
    private void RemoveNode(DspNodeItem? item)
    {
        if (item is null) return;
        Nodes.Remove(item);
        SaveToSettings();
    }

    [RelayCommand]
    private void MoveUp(DspNodeItem? item)
    {
        if (item is null) return;
        var i = Nodes.IndexOf(item);
        if (i > 0) { Nodes.Move(i, i - 1); SaveToSettings(); }
    }

    [RelayCommand]
    private void MoveDown(DspNodeItem? item)
    {
        if (item is null) return;
        var i = Nodes.IndexOf(item);
        if (i >= 0 && i < Nodes.Count - 1) { Nodes.Move(i, i + 1); SaveToSettings(); }
    }

    [RelayCommand]
    private void Clear()
    {
        Nodes.Clear();
        SaveToSettings();
    }

    public async Task LoadSavedChainsAsync()
    {
        var chains = await _presets.GetDspChainsAsync();
        SavedChainNames.Clear();
        foreach (var c in chains) SavedChainNames.Add(c.Name);
    }

    [RelayCommand]
    private async Task LoadSavedChain()
    {
        if (SelectedSavedChain is null) return;
        var chains = await _presets.GetDspChainsAsync();
        if (chains.FirstOrDefault(c => c.Name == SelectedSavedChain) is not { } chain) return;
        _suppress = true;
        LoadFromJson(DspJson.WriteDspChain(chain));
        _suppress = false;
        SaveToSettings();
        _notifications.Success("Chain loaded", chain.Name);
    }

    [RelayCommand]
    private async Task SaveChainAs()
    {
        var name = await _dialogs.PromptAsync("Save DSP chain", "Chain name:", ChainName);
        if (string.IsNullOrWhiteSpace(name)) return;
        ChainName = name.Trim();
        await _presets.SaveDspChainAsync(BuildChain());
        if (!SavedChainNames.Contains(ChainName)) SavedChainNames.Add(ChainName);
        SaveToSettings();
        _notifications.Success("Chain saved", ChainName);
    }

    [RelayCommand]
    private async Task DeleteSavedChain()
    {
        if (SelectedSavedChain is not { } name) return;
        if (!await _dialogs.ConfirmAsync("Delete chain", $"Delete saved chain \u201C{name}\u201D?", "Delete")) return;
        await _presets.DeleteDspChainAsync(name);
        SavedChainNames.Remove(name);
        SelectedSavedChain = null;
    }

    [RelayCommand]
    private async Task ImportChain()
    {
        var path = await _dialogs.PickOpenFileAsync("Open", ".json");
        if (path is null) return;
        try
        {
            var chain = await _presets.ImportDspChainAsync(path);
            _suppress = true;
            LoadFromJson(DspJson.WriteDspChain(chain));
            _suppress = false;
            SaveToSettings();
            _notifications.Success("Chain imported", chain.Name);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _notifications.Error("Import failed", ex.Message);
        }
    }

    [RelayCommand]
    private async Task ExportChain()
    {
        var path = await _dialogs.PickSaveFileAsync("muur-dsp.json", ".json");
        if (path is null) return;
        try
        {
            await _presets.ExportDspChainAsync(path, BuildChain());
            _notifications.Success("Chain exported", path);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _notifications.Error("Export failed", ex.Message);
        }
    }
}

/// <summary>
/// Effects page: one friendly card per effect type, editing the same live DSP chain.
/// Toggling a card inserts/removes the node; sliders edit its parameters.
/// </summary>
public sealed partial class EffectsViewModel : ObservableObject
{
    private static readonly string[] FilterTypes =
    {
        DspNodeTypes.LowPass, DspNodeTypes.HighPass, DspNodeTypes.BandPass, DspNodeTypes.Notch,
        DspNodeTypes.Peaking, DspNodeTypes.LowShelf, DspNodeTypes.HighShelf, DspNodeTypes.Gain,
    };

    private readonly ISettingsService _settings;

    public EffectsViewModel(ISettingsService settings)
    {
        _settings = settings;
        Rebuild();
    }

    public ObservableCollection<EffectCardItem> Cards { get; } = new();
    [ObservableProperty] private bool _chainEnabled;

    public void Rebuild()
    {
        ChainEnabled = _settings.Current.DspChainEnabled;
        var chain = ReadChain();
        Cards.Clear();
        foreach (var type in DspNodeTypes.All.Except(FilterTypes))
        {
            var node = chain.Nodes.FirstOrDefault(n => n.Type == type);
            var card = new EffectCardItem(type, node, Commit);
            Cards.Add(card);
        }
    }

    private DspChain ReadChain()
    {
        var json = _settings.Current.DspChainJson;
        if (string.IsNullOrWhiteSpace(json)) return new DspChain();
        try { return DspJson.ReadDspChain(json); }
        catch (Exception) { return new DspChain(); }
    }

    private void Commit()
    {
        // Rebuild the chain from the cards: keep any filter-section nodes untouched.
        var chain = ReadChain();
        var kept = chain.Nodes.Where(n => FilterTypes.Contains(n.Type)).Select(n => n.Clone()).ToList();
        var effectNodes = Cards.Where(c => c.IsOn).Select(c => c.Node.Clone()).ToList();
        // Preserve existing order where possible: effects follow their card order.
        chain.Nodes = kept.Concat(effectNodes).ToList();
        _settings.Update(s => s.DspChainJson = DspJson.WriteDspChain(chain));
    }

    partial void OnChainEnabledChanged(bool value) => _settings.Update(s => s.DspChainEnabled = value);
}

/// <summary>One effect card on the Effects page.</summary>
public sealed partial class EffectCardItem : ObservableObject
{
    private readonly Action _commit;

    public EffectCardItem(string type, DspNode? existing, Action commit)
    {
        _commit = commit;
        Node = existing ?? DspNode.Create(type);
        _isOn = existing is { Enabled: true };
        foreach (var spec in DspNodeTypes.GetParams(type))
        {
            var p = new DspParamItem(Node, spec) { IsEffectivelyEnabled = IsOn };
            p.Changed += () => { if (IsOn) _commit(); };
            Params.Add(p);
        }
    }

    public DspNode Node { get; }
    public string Type => Node.Type;
    public string Label => DspNodeTypes.GetLabel(Node.Type);
    public ObservableCollection<DspParamItem> Params { get; } = new();

    [ObservableProperty] private bool _isOn;

    partial void OnIsOnChanged(bool value)
    {
        Node.Enabled = value;
        foreach (var prm in Params) prm.IsEffectivelyEnabled = value;
        _commit();
    }
}

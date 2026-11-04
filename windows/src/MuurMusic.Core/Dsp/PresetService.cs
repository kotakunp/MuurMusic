using System.Reflection;
using MuurMusic.Core.Data;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Dsp;

/// <summary>Built-in (embedded) and custom EQ presets plus named DSP chains, with JSON import/export.</summary>
public interface IPresetService
{
    IReadOnlyList<EqPreset> BuiltInEqPresets { get; }
    Task<IReadOnlyList<EqPreset>> GetEqPresetsAsync(CancellationToken ct = default);
    Task<EqPreset?> FindEqPresetAsync(string name, CancellationToken ct = default);
    /// <summary>Creates or overwrites a custom preset. Built-in names are rejected.</summary>
    Task SaveEqPresetAsync(EqPreset preset, CancellationToken ct = default);
    Task RenameEqPresetAsync(string oldName, string newName, CancellationToken ct = default);
    Task DeleteEqPresetAsync(string name, CancellationToken ct = default);
    /// <summary>Imports presets from a .muureq.json file; returns the imported presets (renamed when names clash).</summary>
    Task<IReadOnlyList<EqPreset>> ImportEqPresetsAsync(string path, CancellationToken ct = default);
    Task ExportEqPresetsAsync(string path, IEnumerable<EqPreset> presets, CancellationToken ct = default);

    Task<IReadOnlyList<DspChain>> GetDspChainsAsync(CancellationToken ct = default);
    Task SaveDspChainAsync(DspChain chain, CancellationToken ct = default);
    Task DeleteDspChainAsync(string name, CancellationToken ct = default);
    Task<DspChain> ImportDspChainAsync(string path, CancellationToken ct = default);
    Task ExportDspChainAsync(string path, DspChain chain, CancellationToken ct = default);
}

public sealed class PresetService(IPresetRepository repository) : IPresetService
{
    private static readonly Lazy<IReadOnlyList<EqPreset>> BuiltIns = new(LoadBuiltIns);

    public IReadOnlyList<EqPreset> BuiltInEqPresets => BuiltIns.Value;

    public static IReadOnlyList<EqPreset> LoadBuiltIns()
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("MuurMusic.Core.eq-presets.json")
                      ?? throw new InvalidOperationException("Embedded eq-presets.json missing");
        using var reader = new StreamReader(s);
        return DspJson.ReadEqPresets(reader.ReadToEnd()).Select(p => p with { IsBuiltIn = true }).ToList();
    }

    public async Task<IReadOnlyList<EqPreset>> GetEqPresetsAsync(CancellationToken ct = default)
    {
        var custom = await repository.GetEqPresetsAsync(ct).ConfigureAwait(false);
        return BuiltInEqPresets.Concat(custom).ToList();
    }

    public async Task<EqPreset?> FindEqPresetAsync(string name, CancellationToken ct = default) =>
        (await GetEqPresetsAsync(ct).ConfigureAwait(false)).FirstOrDefault(p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase));

    private bool IsBuiltInName(string name) => BuiltInEqPresets.Any(p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase));

    public Task SaveEqPresetAsync(EqPreset preset, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(preset.Name)) throw new ArgumentException("Preset name is required.");
        if (IsBuiltInName(preset.Name)) throw new InvalidOperationException($"'{preset.Name}' is a built-in preset; choose another name.");
        return repository.SaveEqPresetAsync(preset with { IsBuiltIn = false }, ct);
    }

    public Task RenameEqPresetAsync(string oldName, string newName, CancellationToken ct = default)
    {
        if (IsBuiltInName(oldName)) throw new InvalidOperationException("Built-in presets cannot be renamed.");
        if (IsBuiltInName(newName)) throw new InvalidOperationException($"'{newName}' is a built-in preset name.");
        return repository.RenameEqPresetAsync(oldName, newName, ct);
    }

    public Task DeleteEqPresetAsync(string name, CancellationToken ct = default)
    {
        if (IsBuiltInName(name)) throw new InvalidOperationException("Built-in presets cannot be deleted.");
        return repository.DeleteEqPresetAsync(name, ct);
    }

    public async Task<IReadOnlyList<EqPreset>> ImportEqPresetsAsync(string path, CancellationToken ct = default)
    {
        var presets = DspJson.ReadEqPresets(await File.ReadAllTextAsync(path, ct).ConfigureAwait(false));
        var existing = (await GetEqPresetsAsync(ct).ConfigureAwait(false)).Select(p => p.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var imported = new List<EqPreset>();
        foreach (var p in presets)
        {
            var name = p.Name;
            for (var i = 2; existing.Contains(name); i++) name = $"{p.Name} ({i})";
            existing.Add(name);
            var saved = p with { Name = name, IsBuiltIn = false };
            await repository.SaveEqPresetAsync(saved, ct).ConfigureAwait(false);
            imported.Add(saved);
        }
        return imported;
    }

    public Task ExportEqPresetsAsync(string path, IEnumerable<EqPreset> presets, CancellationToken ct = default) =>
        File.WriteAllTextAsync(path, DspJson.WriteEqPresets(presets), ct);

    public async Task<IReadOnlyList<DspChain>> GetDspChainsAsync(CancellationToken ct = default) =>
        (await repository.GetDspChainsAsync(ct).ConfigureAwait(false)).Select(x =>
        {
            var c = DspJson.ReadDspChain(x.Json);
            c.Name = x.Name;
            return c;
        }).ToList();

    public Task SaveDspChainAsync(DspChain chain, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(chain.Name)) throw new ArgumentException("Chain name is required.");
        return repository.SaveDspChainAsync(chain.Name, DspJson.WriteDspChain(chain), ct);
    }

    public Task DeleteDspChainAsync(string name, CancellationToken ct = default) => repository.DeleteDspChainAsync(name, ct);

    public async Task<DspChain> ImportDspChainAsync(string path, CancellationToken ct = default)
    {
        var chain = DspJson.ReadDspChain(await File.ReadAllTextAsync(path, ct).ConfigureAwait(false));
        await SaveDspChainAsync(chain, ct).ConfigureAwait(false);
        return chain;
    }

    public Task ExportDspChainAsync(string path, DspChain chain, CancellationToken ct = default) =>
        File.WriteAllTextAsync(path, DspJson.WriteDspChain(chain), ct);
}

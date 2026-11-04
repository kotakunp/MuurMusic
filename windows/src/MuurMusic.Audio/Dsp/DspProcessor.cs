using System.Collections.Concurrent;
using MuurMusic.Core.Dsp;
using MuurMusic.Core.Models;

namespace MuurMusic.Audio.Dsp;

/// <summary>
/// The post-mix processing stage: 10-band EQ → DSP chain → loudness boost + look-ahead limiter. Settings can be changed from
/// any thread without locks: changes are prepared on the calling thread (new effect objects are allocated and configured
/// there) and handed to the render thread through a lock-free command queue that is drained at the start of each block.
/// </summary>
public sealed class DspProcessor
{
    private readonly ConcurrentQueue<Action> _commands = new();
    private readonly ConcurrentDictionary<Guid, IDspEffect> _registry = new();
    private readonly GraphicEqualizer _eq = new();
    private readonly LookaheadLimiter _limiter = new();
    private (DspNode Node, IDspEffect Effect)[] _chain = Array.Empty<(DspNode, IDspEffect)>();
    private bool _chainEnabled;
    private bool _loudnessEnabled;
    private bool _limiterActive;
    private volatile int _sampleRate = 48000;
    private volatile int _channels = 2;

    public int SampleRate => _sampleRate;
    public int Channels => _channels;
    /// <summary>True when any stage alters the signal (used for the bit-perfect indicator).</summary>
    public bool IsActive { get; private set; }
    public float LimiterGainReductionDb => _limiterActive ? _limiter.GainReductionDb : 0f;

    /// <summary>Applies a new output format. Must be called on the render thread or while rendering is stopped.</summary>
    public void Configure(int sampleRate, int channels)
    {
        DrainCommands();
        _sampleRate = sampleRate;
        _channels = channels;
        _eq.Configure(sampleRate, channels);
        _limiter.Configure(sampleRate, channels);
        foreach (var (node, effect) in _chain)
        {
            effect.Configure(sampleRate, channels);
            effect.SetParams(node);
        }
        UpdateActive();
    }

    public void SetEqualizer(bool enabled, double preampDb, IReadOnlyList<double> gains)
    {
        var g = gains.ToArray();
        _commands.Enqueue(() =>
        {
            _eq.Enabled = enabled;
            _eq.Set(preampDb, g);
            UpdateActive();
        });
    }

    public void SetEqualizer(bool enabled, EqPreset preset) => SetEqualizer(enabled, preset.PreampDb, preset.GainsArray());

    public void SetLoudness(bool enabled, double boostDb)
    {
        var gain = (float)Math.Pow(10, Math.Clamp(boostDb, 0, 12) / 20);
        _commands.Enqueue(() =>
        {
            _loudnessEnabled = enabled;
            _limiter.InputGain = enabled ? gain : 1f;
            UpdateActive();
        });
    }

    /// <summary>Replaces the DSP chain. Nodes keep their processor (and reverb/delay tails) when their InstanceId and type are unchanged.</summary>
    public void SetChain(bool enabled, DspChain? chain)
    {
        var rate = _sampleRate;
        var channels = _channels;
        var nodes = chain?.Nodes.Select(n => n.Clone()).ToList() ?? new List<DspNode>();
        var plan = new (DspNode Node, IDspEffect Effect)[nodes.Count];
        var keep = new HashSet<Guid>();
        for (var i = 0; i < nodes.Count; i++)
        {
            var node = nodes[i];
            keep.Add(node.InstanceId);
            if (!_registry.TryGetValue(node.InstanceId, out var effect) || effect.Type != node.Type)
            {
                effect = DspEffectFactory.Create(node.Type);
                effect.Configure(rate, channels);
                effect.SetParams(node);
                _registry[node.InstanceId] = effect;
            }
            plan[i] = (node, effect);
        }
        foreach (var id in _registry.Keys.Where(k => !keep.Contains(k)).ToList()) _registry.TryRemove(id, out _);
        _commands.Enqueue(() =>
        {
            foreach (var (node, effect) in plan)
            {
                if (_sampleRate != rate || _channels != channels) effect.Configure(_sampleRate, _channels);
                effect.SetParams(node);
            }
            _chain = plan;
            _chainEnabled = enabled;
            UpdateActive();
        });
    }

    /// <summary>Updates one node's parameters (e.g. while a slider is dragged) without rebuilding the chain.</summary>
    public void UpdateNode(DspNode node)
    {
        var snapshot = node.Clone();
        _commands.Enqueue(() =>
        {
            foreach (var (n, effect) in _chain)
            {
                if (n.InstanceId != snapshot.InstanceId) continue;
                n.Enabled = snapshot.Enabled;
                foreach (var (k, v) in snapshot.Params) n.Params[k] = v;
                if (effect.Type == snapshot.Type) effect.SetParams(n);
            }
            UpdateActive();
        });
    }

    public void Reset() => _commands.Enqueue(() =>
    {
        _eq.Reset();
        _limiter.Reset();
        foreach (var (_, e) in _chain) e.Reset();
    });

    private void DrainCommands()
    {
        while (_commands.TryDequeue(out var cmd)) cmd();
    }

    private void UpdateActive()
    {
        var chainActive = _chainEnabled && _chain.Any(c => c.Node.Enabled && c.Node.IsSupported);
        _limiterActive = _loudnessEnabled || (_eq.Enabled && _eq.HasPositiveGain) || chainActive;
        IsActive = (_eq.Enabled && (_eq.Gains.Any(g => g != 0) || _eq.PreampDb != 0)) || chainActive || _loudnessEnabled;
    }

    /// <summary>Processes one block in place (render thread).</summary>
    public void Process(Span<float> interleaved)
    {
        DrainCommands();
        _eq.Process(interleaved);
        if (_chainEnabled)
            foreach (var (node, effect) in _chain)
                if (node.Enabled) effect.Process(interleaved);
        if (_limiterActive) _limiter.Process(interleaved);
    }

    /// <summary>Parses and applies a muur-dsp JSON chain.</summary>
    public void SetChainJson(bool enabled, string? json) => SetChain(enabled, string.IsNullOrWhiteSpace(json) ? null : DspJson.ReadDspChain(json));
}

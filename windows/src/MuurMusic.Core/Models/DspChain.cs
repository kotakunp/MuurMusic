using System.Text.Json.Nodes;

namespace MuurMusic.Core.Models;

/// <summary>A node of a DSP chain. Unknown node types are preserved verbatim (<see cref="RawParams"/>) and passed through untouched.</summary>
public sealed class DspNode
{
    /// <summary>Runtime identity used by the UI and the audio engine (not serialized).</summary>
    public Guid InstanceId { get; set; } = Guid.NewGuid();
    public string Type { get; set; } = "";
    public bool Enabled { get; set; } = true;
    /// <summary>Numeric parameters keyed by the names defined in <see cref="DspNodeTypes"/>.</summary>
    public Dictionary<string, double> Params { get; set; } = new(StringComparer.Ordinal);
    /// <summary>Original "params" JSON object; written back unchanged for unsupported node types.</summary>
    public JsonObject? RawParams { get; set; }

    public bool IsSupported => DspNodeTypes.IsKnown(Type);

    public double Get(string name)
    {
        if (Params.TryGetValue(name, out var v)) return v;
        var spec = DspNodeTypes.GetParam(Type, name);
        return spec?.Default ?? 0;
    }

    public DspNode Clone() => new()
    {
        InstanceId = InstanceId,
        Type = Type,
        Enabled = Enabled,
        Params = new Dictionary<string, double>(Params, StringComparer.Ordinal),
        RawParams = RawParams?.DeepClone() as JsonObject
    };

    public static DspNode Create(string type)
    {
        var node = new DspNode { Type = type };
        foreach (var p in DspNodeTypes.GetParams(type)) node.Params[p.Name] = p.Default;
        return node;
    }
}

/// <summary>An ordered DSP chain in the shared <c>muur-dsp</c> format.</summary>
public sealed class DspChain
{
    public string Name { get; set; } = "Default";
    public List<DspNode> Nodes { get; set; } = new();
    public DspChain Clone() => new() { Name = Name, Nodes = Nodes.Select(n => n.Clone()).ToList() };
}

/// <summary>Description of a DSP parameter for building editors.</summary>
public sealed record DspParamSpec(string Name, string Label, double Min, double Max, double Default, string Unit = "", bool IsInteger = false, bool Logarithmic = false);

/// <summary>Catalog of DSP node types defined in SHARED_FORMATS.md.</summary>
public static class DspNodeTypes
{
    public const string LowPass = "lowPass", HighPass = "highPass", BandPass = "bandPass", Notch = "notch";
    public const string Peaking = "peaking", LowShelf = "lowShelf", HighShelf = "highShelf";
    public const string Gain = "gain", SoftClip = "softClip", BitCrusher = "bitCrusher", Tremolo = "tremolo";
    public const string Delay = "delay", RingModulator = "ringModulator", StereoWidth = "stereoWidth";
    public const string Reverb = "reverb", Chorus = "chorus", Flanger = "flanger", Phaser = "phaser";
    public const string AutoWah = "autoWah", Distortion = "distortion", Compressor = "compressor", Crossfeed = "crossfeed";

    private static readonly DspParamSpec Freq = new("frequencyHz", "Frequency", 20, 20000, 1000, "Hz", Logarithmic: true);
    private static readonly DspParamSpec Q = new("q", "Q", 0.1, 18, 0.707);
    private static readonly DspParamSpec GainDb = new("gainDb", "Gain", -24, 24, 0, "dB");
    private static readonly DspParamSpec Mix = new("mix", "Mix", 0, 1, 0.5);

    private static readonly Dictionary<string, (string Label, DspParamSpec[] Params)> Catalog = new(StringComparer.Ordinal)
    {
        [LowPass] = ("Low-pass", new[] { Freq with { Default = 8000 }, Q }),
        [HighPass] = ("High-pass", new[] { Freq with { Default = 40 }, Q }),
        [BandPass] = ("Band-pass", new[] { Freq, Q with { Default = 1 } }),
        [Notch] = ("Notch", new[] { Freq, Q with { Default = 4 } }),
        [Peaking] = ("Peaking", new[] { Freq, GainDb, Q with { Default = 1.41 } }),
        [LowShelf] = ("Low shelf", new[] { Freq with { Default = 120 }, GainDb, Q }),
        [HighShelf] = ("High shelf", new[] { Freq with { Default = 8000 }, GainDb, Q }),
        [Gain] = ("Gain", new[] { GainDb }),
        [SoftClip] = ("Soft clip", new[] { new DspParamSpec("drive", "Drive", 0, 1, 0.3) }),
        [BitCrusher] = ("Bit crusher", new[] { new DspParamSpec("bits", "Bits", 1, 16, 8, IsInteger: true), new DspParamSpec("downsample", "Downsample", 1, 32, 1, "x", IsInteger: true) }),
        [Tremolo] = ("Tremolo", new[] { new DspParamSpec("rateHz", "Rate", 0.1, 20, 5, "Hz"), new DspParamSpec("depth", "Depth", 0, 1, 0.5) }),
        [Delay] = ("Delay / echo", new[] { new DspParamSpec("timeMs", "Time", 1, 2000, 350, "ms"), new DspParamSpec("feedback", "Feedback", 0, 0.95, 0.35), Mix with { Default = 0.3 } }),
        [RingModulator] = ("Ring modulator", new[] { Freq with { Default = 440, Min = 1, Max = 5000 }, Mix }),
        [StereoWidth] = ("Stereo width", new[] { new DspParamSpec("width", "Width", 0, 2, 1) }),
        [Reverb] = ("Reverb", new[] { new DspParamSpec("roomSize", "Room size", 0, 1, 0.5), new DspParamSpec("damping", "Damping", 0, 1, 0.5), Mix with { Default = 0.25 } }),
        [Chorus] = ("Chorus", new[] { new DspParamSpec("rateHz", "Rate", 0.05, 5, 0.8, "Hz"), new DspParamSpec("depth", "Depth", 0, 1, 0.5), Mix, new DspParamSpec("feedback", "Feedback", 0, 0.9, 0.1) }),
        [Flanger] = ("Flanger", new[] { new DspParamSpec("rateHz", "Rate", 0.05, 5, 0.25, "Hz"), new DspParamSpec("depth", "Depth", 0, 1, 0.7), Mix, new DspParamSpec("feedback", "Feedback", 0, 0.95, 0.5) }),
        [Phaser] = ("Phaser", new[] { new DspParamSpec("rateHz", "Rate", 0.05, 5, 0.5, "Hz"), new DspParamSpec("depth", "Depth", 0, 1, 0.7), new DspParamSpec("stages", "Stages", 2, 12, 6, IsInteger: true), new DspParamSpec("feedback", "Feedback", 0, 0.95, 0.3), Mix }),
        [AutoWah] = ("Auto-wah", new[] { new DspParamSpec("sensitivity", "Sensitivity", 0, 1, 0.5), new DspParamSpec("minHz", "Min frequency", 50, 2000, 300, "Hz", Logarithmic: true), new DspParamSpec("maxHz", "Max frequency", 500, 10000, 3000, "Hz", Logarithmic: true), Q with { Default = 2.5, Max = 10 }, Mix with { Default = 0.8 } }),
        [Distortion] = ("Distortion", new[] { new DspParamSpec("drive", "Drive", 0, 1, 0.5), new DspParamSpec("tone", "Tone", 0, 1, 0.5), Mix with { Default = 0.7 } }),
        [Compressor] = ("Compressor", new[] { new DspParamSpec("thresholdDb", "Threshold", -60, 0, -18, "dB"), new DspParamSpec("ratio", "Ratio", 1, 20, 4, ":1"), new DspParamSpec("attackMs", "Attack", 0.1, 200, 10, "ms"), new DspParamSpec("releaseMs", "Release", 5, 2000, 120, "ms"), new DspParamSpec("makeupDb", "Makeup", 0, 24, 0, "dB") }),
        [Crossfeed] = ("Crossfeed", new[] { new DspParamSpec("amount", "Amount", 0, 1, 0.3) }),
    };

    public static IReadOnlyList<string> All { get; } = Catalog.Keys.ToArray();
    public static bool IsKnown(string type) => Catalog.ContainsKey(type);
    public static string GetLabel(string type) => Catalog.TryGetValue(type, out var e) ? e.Label : $"{type} (unsupported)";
    public static IReadOnlyList<DspParamSpec> GetParams(string type) => Catalog.TryGetValue(type, out var e) ? e.Params : Array.Empty<DspParamSpec>();
    public static DspParamSpec? GetParam(string type, string name) => GetParams(type).FirstOrDefault(p => p.Name == name);
}

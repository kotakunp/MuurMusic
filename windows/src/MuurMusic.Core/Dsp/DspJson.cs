using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Dsp;

/// <summary>(De)serialization of the shared <c>muur-eq</c> and <c>muur-dsp</c> formats.</summary>
public static class DspJson
{
    public const string EqFormat = "muur-eq";
    public const string DspFormat = "muur-dsp";
    public const string SmartFormat = "muur-smart";

    private static readonly JsonSerializerOptions Indented = new() { WriteIndented = true };

    public static IReadOnlyList<EqPreset> ReadEqPresets(string json)
    {
        var root = JsonNode.Parse(json, documentOptions: new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true }) as JsonObject
                   ?? throw new FormatException("EQ preset file must be a JSON object.");
        var format = root["format"]?.GetValue<string>();
        if (format != EqFormat) throw new FormatException($"Not a muur-eq file (format '{format}').");
        var version = root["version"]?.GetValue<int>() ?? 1;
        if (version > 1) throw new FormatException($"Unsupported muur-eq version {version}.");
        var list = new List<EqPreset>();
        foreach (var p in root["presets"] as JsonArray ?? new JsonArray())
        {
            if (p is not JsonObject o) continue;
            var bands = new List<EqBand>();
            foreach (var b in o["bands"] as JsonArray ?? new JsonArray())
                if (b is JsonObject bo)
                    bands.Add(new EqBand(Num(bo["frequencyHz"]), Num(bo["gainDb"])));
            list.Add(new EqPreset { Name = o["name"]?.GetValue<string>() ?? "Preset", PreampDb = Num(o["preampDb"]), Bands = bands }.Normalize());
        }
        return list;
    }

    public static string WriteEqPresets(IEnumerable<EqPreset> presets)
    {
        var arr = new JsonArray();
        foreach (var p in presets.Select(x => x.Normalize()))
        {
            var bands = new JsonArray();
            foreach (var b in p.Bands)
                bands.Add(new JsonObject { ["frequencyHz"] = NumNode(b.FrequencyHz), ["gainDb"] = NumNode(b.GainDb) });
            arr.Add(new JsonObject { ["name"] = p.Name, ["preampDb"] = NumNode(p.PreampDb), ["bands"] = bands });
        }
        var root = new JsonObject { ["format"] = EqFormat, ["version"] = 1, ["presets"] = arr };
        return root.ToJsonString(Indented);
    }

    public static DspChain ReadDspChain(string json)
    {
        var root = JsonNode.Parse(json, documentOptions: new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true }) as JsonObject
                   ?? throw new FormatException("DSP chain file must be a JSON object.");
        var format = root["format"]?.GetValue<string>();
        if (format != DspFormat) throw new FormatException($"Not a muur-dsp file (format '{format}').");
        var version = root["version"]?.GetValue<int>() ?? 1;
        if (version > 1) throw new FormatException($"Unsupported muur-dsp version {version}.");
        var chain = new DspChain { Name = root["name"]?.GetValue<string>() ?? "Chain" };
        foreach (var n in root["nodes"] as JsonArray ?? new JsonArray())
        {
            if (n is not JsonObject o) continue;
            var node = new DspNode
            {
                Type = o["type"]?.GetValue<string>() ?? "",
                Enabled = o["enabled"]?.GetValue<bool>() ?? true,
                RawParams = (o["params"] as JsonObject)?.DeepClone() as JsonObject
            };
            if (node.RawParams is not null)
                foreach (var (k, v) in node.RawParams)
                    if (v is JsonValue jv && TryNum(jv, out var d)) node.Params[k] = d;
            if (node.IsSupported)
            {
                foreach (var spec in DspNodeTypes.GetParams(node.Type))
                {
                    var value = node.Params.TryGetValue(spec.Name, out var v) ? v : spec.Default;
                    node.Params[spec.Name] = Math.Clamp(value, spec.Min, spec.Max);
                }
            }
            chain.Nodes.Add(node);
        }
        return chain;
    }

    public static string WriteDspChain(DspChain chain)
    {
        var nodes = new JsonArray();
        foreach (var n in chain.Nodes)
        {
            JsonObject ps;
            if (!n.IsSupported && n.RawParams is not null) ps = (JsonObject)n.RawParams.DeepClone();
            else
            {
                ps = new JsonObject();
                foreach (var spec in DspNodeTypes.GetParams(n.Type)) ps[spec.Name] = NumNode(n.Get(spec.Name));
                foreach (var (k, v) in n.Params) if (!ps.ContainsKey(k)) ps[k] = NumNode(v);
            }
            nodes.Add(new JsonObject { ["type"] = n.Type, ["enabled"] = n.Enabled, ["params"] = ps });
        }
        var root = new JsonObject { ["format"] = DspFormat, ["version"] = 1, ["name"] = chain.Name, ["nodes"] = nodes };
        return root.ToJsonString(Indented);
    }

    public static SmartPlaylistDefinition ReadSmartPlaylist(string json)
    {
        var def = JsonSerializer.Deserialize<SmartPlaylistDefinition>(json, new JsonSerializerOptions { ReadCommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true })
                  ?? throw new FormatException("Empty smart playlist file.");
        if (def.Format != SmartFormat) throw new FormatException($"Not a muur-smart file (format '{def.Format}').");
        return def;
    }

    public static string WriteSmartPlaylist(SmartPlaylistDefinition def) => JsonSerializer.Serialize(def, Indented);

    private static double Num(JsonNode? n) => n is JsonValue v && TryNum(v, out var d) ? d : 0;

    private static bool TryNum(JsonValue v, out double d)
    {
        if (v.GetValueKind() == JsonValueKind.Number) { d = v.GetValue<double>(); return true; }
        if (v.GetValueKind() == JsonValueKind.String && double.TryParse(v.GetValue<string>(), NumberStyles.Float, CultureInfo.InvariantCulture, out d)) return true;
        d = 0;
        return false;
    }

    private static JsonNode NumNode(double d) =>
        d == Math.Floor(d) && Math.Abs(d) < 1e15 ? JsonValue.Create((long)d) : JsonValue.Create(Math.Round(d, 6));
}

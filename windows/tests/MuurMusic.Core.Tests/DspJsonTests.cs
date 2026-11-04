using MuurMusic.Core.Dsp;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Tests;

public class DspJsonTests
{
    private static string PresetsJson => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "TestData", "eq-presets.json"));

    [Fact]
    public void Shipped_Presets_Parse_And_Are_WellFormed()
    {
        var presets = DspJson.ReadEqPresets(PresetsJson);
        Assert.True(presets.Count >= 10);
        Assert.Contains(presets, p => p.Name == "Flat");
        foreach (var p in presets)
        {
            Assert.Equal(10, p.Bands.Count);
            Assert.All(p.Bands, b => Assert.InRange(b.GainDb, -EqPreset.MaxGainDb, EqPreset.MaxGainDb));
            Assert.Equal(EqPreset.IsoFrequencies, p.Bands.Select(b => b.FrequencyHz));
        }
    }

    [Fact]
    public void EqPresets_RoundTrip()
    {
        var presets = DspJson.ReadEqPresets(PresetsJson);
        var again = DspJson.ReadEqPresets(DspJson.WriteEqPresets(presets));
        Assert.Equal(presets.Count, again.Count);
        for (var i = 0; i < presets.Count; i++)
        {
            Assert.Equal(presets[i].Name, again[i].Name);
            Assert.Equal(presets[i].PreampDb, again[i].PreampDb);
            Assert.Equal(presets[i].Bands.Select(b => b.GainDb), again[i].Bands.Select(b => b.GainDb));
        }
    }

    [Fact]
    public void DspChain_RoundTrips_All_Parameters()
    {
        var chain = new DspChain();
        chain.Nodes.Add(DspNode.Create(DspNodeTypes.Peaking));
        chain.Nodes.Add(DspNode.Create(DspNodeTypes.Reverb));
        chain.Nodes[0].Params["frequencyHz"] = 1200.0;
        chain.Nodes[0].Params["gainDb"] = -4.5;
        chain.Nodes[1].Params["roomSize"] = 0.7;
        chain.Nodes[1].Enabled = false;

        var json = DspJson.WriteDspChain(chain);
        Assert.Contains("\"format\": \"muur-dsp\"", json);
        var back = DspJson.ReadDspChain(json);
        Assert.Equal(2, back.Nodes.Count);
        Assert.Equal(chain.Nodes[0].Type, back.Nodes[0].Type); // InstanceId is runtime-only and not serialized
        Assert.Equal(1200.0, back.Nodes[0].Params["frequencyHz"]);
        Assert.Equal(-4.5, back.Nodes[0].Params["gainDb"]);
        Assert.False(back.Nodes[1].Enabled);
        Assert.Equal(0.7, back.Nodes[1].Params["roomSize"]);
    }

    [Fact]
    public void Rejects_Wrong_Format_Markers()
    {
        Assert.Throws<FormatException>(() => DspJson.ReadEqPresets("{\"format\":\"other\"}"));
        Assert.Throws<FormatException>(() => DspJson.ReadDspChain("{\"format\":\"muur-eq\"}"));
    }
}

using System.Text.Json.Serialization;

namespace MuurMusic.Core.Models;

/// <summary>One band of the 10-band graphic equalizer.</summary>
public sealed record EqBand(
    [property: JsonPropertyName("frequencyHz")] double FrequencyHz,
    [property: JsonPropertyName("gainDb")] double GainDb);

/// <summary>A 10-band EQ preset in the shared <c>muur-eq</c> format.</summary>
public sealed record EqPreset
{
    public const double MaxGainDb = 12.0;
    public const double BandQ = 1.41;
    public static readonly IReadOnlyList<double> IsoFrequencies = new double[] { 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 };

    [JsonPropertyName("name")] public string Name { get; init; } = "";
    [JsonPropertyName("preampDb")] public double PreampDb { get; init; }
    [JsonPropertyName("bands")] public IReadOnlyList<EqBand> Bands { get; init; } = IsoFrequencies.Select(f => new EqBand(f, 0)).ToArray();
    /// <summary>True for the presets shipped with the app (read-only).</summary>
    [JsonIgnore] public bool IsBuiltIn { get; init; }

    public static EqPreset Flat(string name = "Flat") => new() { Name = name };

    /// <summary>Returns a copy with gains clamped to ±12 dB and bands normalized to the 10 ISO frequencies.</summary>
    public EqPreset Normalize()
    {
        var gains = new double[IsoFrequencies.Count];
        foreach (var band in Bands)
        {
            var idx = NearestIsoIndex(band.FrequencyHz);
            gains[idx] = Math.Clamp(band.GainDb, -MaxGainDb, MaxGainDb);
        }
        return this with
        {
            PreampDb = Math.Clamp(PreampDb, -MaxGainDb, MaxGainDb),
            Bands = IsoFrequencies.Select((f, i) => new EqBand(f, gains[i])).ToArray()
        };
    }

    public double[] GainsArray() => Normalize().Bands.Select(b => b.GainDb).ToArray();

    private static int NearestIsoIndex(double hz)
    {
        var best = 0;
        var bestDist = double.MaxValue;
        for (var i = 0; i < IsoFrequencies.Count; i++)
        {
            var d = Math.Abs(Math.Log(Math.Max(hz, 1) / IsoFrequencies[i]));
            if (d < bestDist) { bestDist = d; best = i; }
        }
        return best;
    }
}

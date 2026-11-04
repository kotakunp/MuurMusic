using MuurMusic.Audio.Engine;
using NAudio.Wave;

namespace MuurMusic.Audio.Output;

/// <summary>NAudio provider that renders from the <see cref="AudioEngine"/> and converts to the device format.</summary>
internal sealed class EngineWaveProvider : IWaveProvider
{
    private readonly AudioEngine _engine;
    private readonly OutputFormatInfo _format;
    private float[] _scratch = new float[16384];

    public EngineWaveProvider(AudioEngine engine, OutputFormatInfo format)
    {
        _engine = engine;
        _format = format;
        WaveFormat = format.ToWaveFormat();
    }

    public WaveFormat WaveFormat { get; }

    public int Read(Span<byte> buffer)
    {
        var frames = buffer.Length / _format.BlockAlign;
        if (frames == 0) return 0;
        var samples = frames * _format.Channels;
        if (_scratch.Length < samples) _scratch = new float[samples];
        var floats = _scratch.AsSpan(0, samples);
        _engine.Render(floats);
        return SampleConverter.Write(floats, buffer, _format);
    }
}

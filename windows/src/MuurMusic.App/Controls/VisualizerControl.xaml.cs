using System.Numerics;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using MuurMusic.Audio.Playback;
using Windows.UI;

namespace MuurMusic.App.Controls;

/// <summary>Visualizer preset kinds; persisted in settings by name.</summary>
public enum VisualizerPreset { SpectrumBars, MirrorBars, CircleSpectrum, Waveform, Particles, CatEyes, Starfield, Vinyl }

/// <summary>
/// Realtime audio visualizer fed by the playback engine's FFT spectrum analyzer.
/// Renders at display refresh via Win2D's CanvasAnimatedControl.
/// </summary>
public sealed partial class VisualizerControl : UserControl
{
    private const int BandCount = 64;
    private readonly float[] _bands = new float[BandCount];
    private readonly float[] _wave = new float[256];
    private readonly Random _random = new();
    private Particle[] _particles = Array.Empty<Particle>();
    private Star[] _stars = Array.Empty<Star>();
    private float _energy;
    private double _blinkTimer = 2.5;
    private double _blink;
    private double _time;

    public VisualizerControl() => InitializeComponent();

    public static readonly DependencyProperty PresetProperty =
        DependencyProperty.Register(nameof(Preset), typeof(VisualizerPreset), typeof(VisualizerControl),
            new PropertyMetadata(VisualizerPreset.SpectrumBars));

    public VisualizerPreset Preset
    {
        get => (VisualizerPreset)GetValue(PresetProperty);
        set => SetValue(PresetProperty, value);
    }

    public static VisualizerPreset ParsePreset(string? name) =>
        Enum.TryParse<VisualizerPreset>(name, out var p) ? p : VisualizerPreset.SpectrumBars;

    private static MuurMusic.Audio.Engine.AudioEngine? Engine =>
        App.Services.GetService<IPlaybackService>()?.Engine;

    private Color Accent => ((SolidColorBrush)Application.Current.Resources["MuurAccentBrush"]).Color;
    private Color AccentSecondary => ((SolidColorBrush)Application.Current.Resources["MuurAccentSecondaryBrush"]).Color;
    private Color ForegroundColor => ((SolidColorBrush)Application.Current.Resources["MuurForegroundBrush"]).Color;

    private void Canvas_Loaded(object sender, RoutedEventArgs e) => Canvas.Paused = false;
    private void Canvas_Unloaded(object sender, RoutedEventArgs e) => Canvas.Paused = true;

    private void Canvas_Update(ICanvasAnimatedControl sender, CanvasAnimatedUpdateEventArgs args)
    {
        var dt = args.Timing.ElapsedTime.TotalSeconds;
        _time += dt;
        var engine = Engine;
        if (engine is null)
        {
            Array.Clear(_bands);
            Array.Clear(_wave);
            _energy = 0;
            return;
        }
        engine.Spectrum.GetSpectrum(_bands, dt);
        engine.Spectrum.GetWaveform(_wave);
        var meter = engine.Meter.Read();
        _energy = Math.Clamp((meter.RmsLeft + meter.RmsRight) * 0.5f * 2.2f, 0f, 1f);

        // Cat-eye blink state machine.
        _blinkTimer -= dt;
        if (_blinkTimer <= 0) { _blink = 0.12; _blinkTimer = 2 + _random.NextDouble() * 3.5; }
        if (_blink > 0) _blink -= dt;

        if (Preset == VisualizerPreset.Particles) UpdateParticles(dt);
        if (Preset == VisualizerPreset.Starfield) UpdateStars(dt);
    }

    private void Canvas_Draw(ICanvasAnimatedControl sender, CanvasAnimatedDrawEventArgs args)
    {
        var size = sender.Size;
        if (size.Width < 4 || size.Height < 4) return;
        var ds = args.DrawingSession;
        switch (Preset)
        {
            case VisualizerPreset.SpectrumBars: DrawBars(ds, size, mirror: false); break;
            case VisualizerPreset.MirrorBars: DrawBars(ds, size, mirror: true); break;
            case VisualizerPreset.CircleSpectrum: DrawCircle(ds, size); break;
            case VisualizerPreset.Waveform: DrawWave(ds, size); break;
            case VisualizerPreset.Particles: DrawParticles(ds, size); break;
            case VisualizerPreset.CatEyes: DrawCatEyes(ds, size); break;
            case VisualizerPreset.Starfield: DrawStars(ds, size); break;
            case VisualizerPreset.Vinyl: DrawVinyl(ds, size); break;
        }
    }

    private void DrawBars(CanvasDrawingSession ds, Windows.Foundation.Size size, bool mirror)
    {
        var n = BandCount;
        var gap = 3f;
        var barW = (float)(size.Width - gap * (n - 1)) / n;
        var accent = Accent;
        var secondary = AccentSecondary;
        var midY = (float)size.Height / 2f;
        for (var i = 0; i < n; i++)
        {
            var level = Math.Clamp(_bands[i], 0f, 1f);
            var h = Math.Max(2f, level * (float)size.Height * (mirror ? 0.48f : 0.92f));
            var x = i * (barW + gap);
            var color = Color.FromArgb(255,
                (byte)(secondary.R + (accent.R - secondary.R) * i / (float)n),
                (byte)(secondary.G + (accent.G - secondary.G) * i / (float)n),
                (byte)(secondary.B + (accent.B - secondary.B) * i / (float)n));
            if (mirror)
            {
                ds.FillRoundedRectangle(x, midY - h, barW, h, 3, 3, color);
                ds.FillRoundedRectangle(x, midY, barW, h, 3, 3, Color.FromArgb(140, color.R, color.G, color.B));
            }
            else
            {
                ds.FillRoundedRectangle(x, (float)size.Height - h, barW, h, 3, 3, color);
            }
        }
    }

    private void DrawCircle(CanvasDrawingSession ds, Windows.Foundation.Size size)
    {
        var cx = (float)size.Width / 2f;
        var cy = (float)size.Height / 2f;
        var baseR = (float)Math.Min(size.Width, size.Height) * 0.28f;
        var n = BandCount;
        var accent = Accent;
        ds.DrawCircle(cx, cy, baseR - 6, Color.FromArgb(90, accent.R, accent.G, accent.B), 1.5f);
        for (var i = 0; i < n; i++)
        {
            var level = Math.Clamp(_bands[i], 0f, 1f);
            var angle = (float)(i / (double)n * Math.PI * 2 - Math.PI / 2);
            var len = 4f + level * baseR * 0.85f;
            var inner = new Vector2(cx + MathF.Cos(angle) * baseR, cy + MathF.Sin(angle) * baseR);
            var outer = new Vector2(cx + MathF.Cos(angle) * (baseR + len), cy + MathF.Sin(angle) * (baseR + len));
            ds.DrawLine(inner, outer, Color.FromArgb((byte)(120 + level * 135), accent.R, accent.G, accent.B), 3f);
        }
    }

    private void DrawWave(CanvasDrawingSession ds, Windows.Foundation.Size size)
    {
        var midY = (float)size.Height / 2f;
        var stepX = (float)size.Width / (_wave.Length - 1);
        var amp = midY * 0.9f;
        using var builder = new CanvasPathBuilder(Canvas);
        var started = false;
        for (var i = 0; i < _wave.Length; i++)
        {
            var y = midY + Math.Clamp(_wave[i], -1f, 1f) * amp;
            var pt = new Vector2(i * stepX, y);
            if (!started) { builder.BeginFigure(pt); started = true; }
            else builder.AddLine(pt);
        }
        builder.EndFigure(CanvasFigureLoop.Open);
        using var geo = CanvasGeometry.CreatePath(builder);
        ds.DrawGeometry(geo, Accent, 2.5f);
        // Mirrored ghost, drawn through a flipped transform.
        var ghost = Color.FromArgb(60, AccentSecondary.R, AccentSecondary.G, AccentSecondary.B);
        var previous = ds.Transform;
        ds.Transform = Matrix3x2.CreateScale(1, -0.6f, new Vector2(0, midY));
        ds.DrawGeometry(geo, ghost, 1.2f);
        ds.Transform = previous;
    }

    private sealed class Particle { public Vector2 Pos; public float Speed; public float Size; public int Band; public float Hue; }

    private void EnsureParticles()
    {
        if (_particles.Length != 90)
            _particles = Enumerable.Range(0, 90).Select(_ => new Particle
            {
                Pos = new Vector2((float)_random.NextDouble(), (float)_random.NextDouble()),
                Speed = 0.1f + (float)_random.NextDouble() * 0.5f,
                Size = 1.5f + (float)_random.NextDouble() * 4f,
                Band = _random.Next(BandCount),
                Hue = (float)_random.NextDouble(),
            }).ToArray();
    }

    private void UpdateParticles(double dt)
    {
        EnsureParticles();
        foreach (var p in _particles)
        {
            var boost = 0.3f + Math.Clamp(_bands[p.Band], 0f, 1f) * 2.4f;
            p.Pos -= new Vector2(0, p.Speed * boost * (float)dt);
            if (p.Pos.Y < -0.05f)
            {
                p.Pos = new Vector2((float)_random.NextDouble(), 1.05f);
                p.Band = _random.Next(BandCount);
            }
        }
    }

    private void DrawParticles(CanvasDrawingSession ds, Windows.Foundation.Size size)
    {
        EnsureParticles();
        var accent = Accent;
        var secondary = AccentSecondary;
        foreach (var p in _particles)
        {
            var level = Math.Clamp(_bands[p.Band], 0f, 1f);
            var r = p.Size * (0.6f + level * 2.2f);
            var color = Color.FromArgb((byte)(60 + level * 195),
                (byte)(secondary.R + (accent.R - secondary.R) * p.Hue),
                (byte)(secondary.G + (accent.G - secondary.G) * p.Hue),
                (byte)(secondary.B + (accent.B - secondary.B) * p.Hue));
            ds.FillCircle(p.Pos.X * (float)size.Width, p.Pos.Y * (float)size.Height, r, color);
        }
    }

    private void DrawCatEyes(CanvasDrawingSession ds, Windows.Foundation.Size size)
    {
        // Bass widens the pupils; mids tilt them; a blink now and then. Muur.
        var bass = Math.Clamp((_bands[0] + _bands[1] + _bands[2]) / 3f * 1.6f, 0f, 1f);
        var mids = Math.Clamp((_bands[BandCount / 2 - 2] + _bands[BandCount / 2] + _bands[BandCount / 2 + 2]) / 3f, 0f, 1f);
        var blink = _blink > 0 ? 1f : 0f;
        var cx = (float)size.Width / 2f;
        var cy = (float)size.Height / 2f;
        var eyeDX = (float)Math.Min(size.Width, size.Height) * 0.24f;
        var eyeR = (float)Math.Min(size.Width, size.Height) * 0.16f;
        var accent = Accent;
        var fg = ForegroundColor;
        foreach (var side in new[] { -1f, 1f })
        {
            var ex = cx + side * eyeDX;
            var open = 1f - blink;
            // Sclera
            ds.FillEllipse(ex, cy, eyeR, eyeR * open, Color.FromArgb(230, fg.R, fg.G, fg.B));
            if (blink > 0) continue;
            // Iris follows the mids a little.
            var tilt = (mids - 0.5f) * eyeR * 0.5f;
            var irisR = eyeR * (0.62f + bass * 0.25f);
            ds.FillEllipse(ex + tilt, cy, irisR, irisR, Color.FromArgb(255, accent.R, accent.G, accent.B));
            // Slit pupil narrows with energy.
            var pupilW = eyeR * (0.16f + (1f - bass) * 0.18f);
            ds.FillEllipse(ex + tilt, cy, pupilW, irisR * 0.94f, Colors.Black);
            // Glint.
            ds.FillCircle(ex + tilt - irisR * 0.3f, cy - irisR * 0.3f, eyeR * 0.09f, Color.FromArgb(220, 255, 255, 255));
        }
    }

    private sealed class Star { public Vector3 Pos; public float PrevZ; }

    private void EnsureStars()
    {
        if (_stars.Length != 220)
            _stars = Enumerable.Range(0, 220).Select(_ => new Star
            {
                Pos = new Vector3((float)(_random.NextDouble() * 2 - 1), (float)(_random.NextDouble() * 2 - 1), (float)_random.NextDouble() + 0.05f),
            }).ToArray();
    }

    private void UpdateStars(double dt)
    {
        EnsureStars();
        var speed = 0.25f + _energy * 2.2f;
        foreach (var s in _stars)
        {
            s.PrevZ = s.Pos.Z;
            s.Pos -= new Vector3(0, 0, speed * (float)dt);
            if (s.Pos.Z <= 0.03f)
            {
                s.Pos = new Vector3((float)(_random.NextDouble() * 2 - 1), (float)(_random.NextDouble() * 2 - 1), 1f);
                s.PrevZ = 1f;
            }
        }
    }

    private void DrawStars(CanvasDrawingSession ds, Windows.Foundation.Size size)
    {
        EnsureStars();
        var cx = (float)size.Width / 2f;
        var cy = (float)size.Height / 2f;
        var scale = (float)Math.Min(size.Width, size.Height) * 0.62f;
        var accent = Accent;
        foreach (var s in _stars)
        {
            var p1 = new Vector2(cx + s.Pos.X / s.Pos.Z * scale * 0.4f, cy + s.Pos.Y / s.Pos.Z * scale * 0.4f);
            var p2 = new Vector2(cx + s.Pos.X / s.PrevZ * scale * 0.4f, cy + s.Pos.Y / s.PrevZ * scale * 0.4f);
            var brightness = (byte)Math.Clamp((1f - s.Pos.Z) * 255 + 60, 0, 255);
            ds.DrawLine(p2, p1, Color.FromArgb(brightness, accent.R, accent.G, accent.B), 1.6f);
        }
    }

    private void DrawVinyl(CanvasDrawingSession ds, Windows.Foundation.Size size)
    {
        var cx = (float)size.Width / 2f;
        var cy = (float)size.Height / 2f;
        var maxR = (float)Math.Min(size.Width, size.Height) * 0.42f;
        var accent = Accent;
        var fg = ForegroundColor;
        var rotation = (float)(_time * (0.4 + _energy));
        // Disc
        ds.FillCircle(cx, cy, maxR, Color.FromArgb(255, 24, 20, 38));
        for (var ring = 0; ring < 6; ring++)
        {
            var r = maxR * (0.35f + ring * 0.11f);
            ds.DrawCircle(cx, cy, r, Color.FromArgb(40, fg.R, fg.G, fg.B), 1f);
        }
        // Rotating level ticks around the rim.
        var n = BandCount;
        for (var i = 0; i < n; i++)
        {
            var level = Math.Clamp(_bands[i], 0f, 1f);
            var angle = rotation + (float)(i / (double)n * Math.PI * 2);
            var len = 3f + level * maxR * 0.18f;
            var r0 = maxR * 0.98f;
            ds.DrawLine(
                new Vector2(cx + MathF.Cos(angle) * r0, cy + MathF.Sin(angle) * r0),
                new Vector2(cx + MathF.Cos(angle) * (r0 + len), cy + MathF.Sin(angle) * (r0 + len)),
                Color.FromArgb((byte)(100 + level * 155), accent.R, accent.G, accent.B), 2.4f);
        }
        // Label.
        ds.FillCircle(cx, cy, maxR * 0.3f, accent);
        ds.FillCircle(cx, cy, maxR * 0.045f, Color.FromArgb(255, 24, 20, 38));
    }
}

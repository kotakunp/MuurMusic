using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MuurMusic.App.Controls;

/// <summary>Animated paw-print loading indicator.</summary>
public sealed partial class PawLoadingIndicator : UserControl, IDisposable
{
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _timer;
    private int _step;

    public PawLoadingIndicator()
    {
        InitializeComponent();
        _timer = DispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(280);
        _timer.Tick += (_, _) => Advance();
        Loaded += (_, _) => { if (IsActive) _timer.Start(); };
        Unloaded += (_, _) => _timer.Stop();
    }

    public static readonly DependencyProperty IsActiveProperty =
        DependencyProperty.Register(nameof(IsActive), typeof(bool), typeof(PawLoadingIndicator),
            new PropertyMetadata(true, (d, _) => ((PawLoadingIndicator)d).OnActiveChanged()));

    public bool IsActive
    {
        get => (bool)GetValue(IsActiveProperty);
        set => SetValue(IsActiveProperty, value);
    }

    public static readonly DependencyProperty PawSizeProperty =
        DependencyProperty.Register(nameof(PawSize), typeof(double), typeof(PawLoadingIndicator), new PropertyMetadata(20.0));

    public double PawSize
    {
        get => (double)GetValue(PawSizeProperty);
        set => SetValue(PawSizeProperty, value);
    }

    private void OnActiveChanged()
    {
        if (IsActive) _timer.Start();
        else { _timer.Stop(); SetOpacities(-1); }
    }

    private void Advance()
    {
        _step = (_step + 1) % 4; // 3 paws + one all-dim beat
        SetOpacities(_step);
    }

    private void SetOpacities(int active)
    {
        Paw1.Opacity = active == 0 ? 1 : 0.25;
        Paw2.Opacity = active == 1 ? 1 : 0.25;
        Paw3.Opacity = active == 2 ? 1 : 0.25;
    }

    public void Dispose() => _timer.Stop();
}

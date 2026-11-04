using System.Collections.Concurrent;

namespace MuurMusic.Audio.Engine;

/// <summary>Runs callbacks in order on one background thread so the render thread never executes event handlers or disposals.</summary>
internal sealed class EventPump : IDisposable
{
    private readonly BlockingCollection<Action> _queue = new();
    private readonly Thread _thread;
    private readonly Action<Exception>? _onError;

    public EventPump(string name, Action<Exception>? onError = null)
    {
        _onError = onError;
        _thread = new Thread(Run) { IsBackground = true, Name = name };
        _thread.Start();
    }

    public void Post(Action action)
    {
        try { _queue.Add(action); }
        catch (InvalidOperationException) { }
    }

    private void Run()
    {
        foreach (var action in _queue.GetConsumingEnumerable())
        {
            try { action(); }
            catch (Exception ex) { _onError?.Invoke(ex); }
        }
    }

    public void Dispose()
    {
        _queue.CompleteAdding();
        if (Thread.CurrentThread != _thread) _thread.Join(3000);
    }
}

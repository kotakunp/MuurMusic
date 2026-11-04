namespace MuurMusic.Core.Infrastructure;

/// <summary>
/// Marshals service events to a chosen thread. By default events are raised inline on the background thread that
/// produced them; the UI calls <see cref="SetPoster"/> once (e.g. with <c>DispatcherQueue.TryEnqueue</c>) so every
/// MuurMusic event and PropertyChanged notification arrives on the UI thread.
/// </summary>
public interface IEventDispatcher
{
    void Post(Action action);
    void SetPoster(Action<Action>? poster);
    bool HasPoster { get; }
}

public sealed class EventDispatcher : IEventDispatcher
{
    private volatile Action<Action>? _poster;

    public bool HasPoster => _poster is not null;

    public void SetPoster(Action<Action>? poster) => _poster = poster;

    public void Post(Action action)
    {
        var poster = _poster;
        if (poster is null)
        {
            action();
            return;
        }
        poster(action);
    }
}

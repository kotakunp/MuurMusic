using CommunityToolkit.Mvvm.ComponentModel;

namespace MuurMusic.App.Services;

public enum NotificationKind { Info, Success, Warning, Error }

/// <summary>One in-app notification shown in the main window's InfoBar.</summary>
public sealed partial class AppNotification : ObservableObject
{
    public required string Title { get; init; }
    public string? Message { get; init; }
    public NotificationKind Kind { get; init; } = NotificationKind.Info;
    [ObservableProperty] private bool _isOpen = true;
}

/// <summary>Queues user-facing notifications (InfoBar in the main window).</summary>
public sealed class NotificationService
{
    private const int MaxVisible = 3;

    private readonly List<AppNotification> _queue = new();

    /// <summary>Raised on the UI thread when the currently visible notification should change.</summary>
    public event EventHandler<AppNotification?>? CurrentChanged;

    public AppNotification? Current { get; private set; }

    public void Info(string title, string? message = null) => Show(title, message, NotificationKind.Info);
    public void Success(string title, string? message = null) => Show(title, message, NotificationKind.Success);
    public void Warning(string title, string? message = null) => Show(title, message, NotificationKind.Warning);
    public void Error(string title, string? message = null) => Show(title, message, NotificationKind.Error);

    public void Show(string title, string? message, NotificationKind kind)
    {
        var n = new AppNotification { Title = title, Message = message, Kind = kind };
        if (App.CurrentWindow is { } w)
        {
            w.DispatcherQueue.TryEnqueue(() => Enqueue(n));
        }
        else Enqueue(n);
    }

    private void Enqueue(AppNotification n)
    {
        lock (_queue)
        {
            _queue.Add(n);
            if (_queue.Count > 12) _queue.RemoveAt(0);
        }
        if (Current is null || !Current.IsOpen) ShowNext();
    }

    /// <summary>The user dismissed the visible notification; advance the queue.</summary>
    public void DismissCurrent()
    {
        lock (_queue)
        {
            if (Current is not null)
            {
                _queue.Remove(Current);
                Current = null;
            }
        }
        ShowNext();
    }

    private void ShowNext()
    {
        AppNotification? next;
        lock (_queue) next = _queue.FirstOrDefault();
        Current = next;
        CurrentChanged?.Invoke(this, next);
    }
}

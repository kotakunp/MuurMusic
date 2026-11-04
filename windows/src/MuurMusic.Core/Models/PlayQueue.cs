namespace MuurMusic.Core.Models;

public enum RepeatMode { Off, All, One }

/// <summary>An entry in the play queue. <see cref="EntryId"/> stays stable when the queue is reordered.</summary>
public sealed record QueueEntry(Guid EntryId, Track Track)
{
    public static QueueEntry For(Track track) => new(Guid.NewGuid(), track);
}

/// <summary>
/// Unlimited play queue with shuffle and repeat. Not thread-safe; callers serialize access.
/// Shuffle keeps a permutation of entries so "previous" walks back through the shuffled order.
/// </summary>
public sealed class PlayQueue
{
    private readonly List<QueueEntry> _items = new();
    private List<int> _order = new();
    private int _orderPos = -1;
    private readonly Random _random;

    public PlayQueue(Random? random = null) => _random = random ?? new Random();

    public IReadOnlyList<QueueEntry> Items => _items;
    public int Count => _items.Count;
    public bool Shuffle { get; private set; }
    public RepeatMode Repeat { get; set; }

    /// <summary>Index into <see cref="Items"/> of the current entry, or -1.</summary>
    public int CurrentIndex => _orderPos >= 0 && _orderPos < _order.Count ? _order[_orderPos] : -1;
    public QueueEntry? Current => CurrentIndex >= 0 ? _items[CurrentIndex] : null;

    /// <summary>Shuffled play order as indexes into <see cref="Items"/> (identity when shuffle is off).</summary>
    public IReadOnlyList<int> Order => _order;
    public int OrderPosition => _orderPos;

    public event EventHandler? Changed;

    public void Set(IEnumerable<Track> tracks, int startIndex = 0)
    {
        _items.Clear();
        _items.AddRange(tracks.Select(QueueEntry.For));
        RebuildOrder(_items.Count == 0 ? -1 : Math.Clamp(startIndex, 0, _items.Count - 1));
        OnChanged();
    }

    /// <summary>Restores a persisted queue state.</summary>
    public void Restore(IEnumerable<QueueEntry> entries, IReadOnlyList<int>? order, int orderPosition, bool shuffle, RepeatMode repeat)
    {
        _items.Clear();
        _items.AddRange(entries);
        Shuffle = shuffle;
        Repeat = repeat;
        if (order is not null && order.Count == _items.Count && order.Distinct().Count() == order.Count && order.All(i => i >= 0 && i < _items.Count))
        {
            _order = order.ToList();
            _orderPos = _items.Count == 0 ? -1 : Math.Clamp(orderPosition, 0, _items.Count - 1);
        }
        else
        {
            _order = Enumerable.Range(0, _items.Count).ToList();
            _orderPos = _items.Count == 0 ? -1 : Math.Clamp(orderPosition, 0, _items.Count - 1);
        }
        OnChanged();
    }

    public void SetShuffle(bool enabled)
    {
        if (Shuffle == enabled) return;
        Shuffle = enabled;
        RebuildOrder(CurrentIndex);
        OnChanged();
    }

    /// <summary>Inserts tracks right after the current entry.</summary>
    public void PlayNext(IEnumerable<Track> tracks)
    {
        var list = tracks.Select(QueueEntry.For).ToList();
        if (list.Count == 0) return;
        var insertAt = CurrentIndex < 0 ? _items.Count : CurrentIndex + 1;
        InsertEntries(insertAt, list, playNext: true);
    }

    /// <summary>Appends tracks to the end of the queue ("play later").</summary>
    public void AddToEnd(IEnumerable<Track> tracks)
    {
        var list = tracks.Select(QueueEntry.For).ToList();
        if (list.Count == 0) return;
        InsertEntries(_items.Count, list, playNext: false);
    }

    public void Insert(int index, IEnumerable<Track> tracks)
    {
        var list = tracks.Select(QueueEntry.For).ToList();
        if (list.Count == 0) return;
        InsertEntries(Math.Clamp(index, 0, _items.Count), list, playNext: false);
    }

    private void InsertEntries(int insertAt, List<QueueEntry> list, bool playNext)
    {
        var wasEmpty = _items.Count == 0;
        _items.InsertRange(insertAt, list);
        for (var i = 0; i < _order.Count; i++)
            if (_order[i] >= insertAt) _order[i] += list.Count;
        var newIdx = Enumerable.Range(insertAt, list.Count).ToList();
        if (wasEmpty)
        {
            _order = newIdx;
            if (Shuffle) ShuffleList(_order, 0);
            _orderPos = 0;
        }
        else if (Shuffle && !playNext)
        {
            // Spread "play later" items randomly over the not-yet-played part of the shuffled order.
            foreach (var idx in newIdx)
                _order.Insert(_random.Next(_orderPos + 1, _order.Count + 1), idx);
        }
        else if (Shuffle && playNext)
        {
            _order.InsertRange(_orderPos + 1, newIdx);
        }
        else
        {
            _order = Enumerable.Range(0, _items.Count).ToList();
        }
        OnChanged();
    }

    public void RemoveAt(int index)
    {
        if (index < 0 || index >= _items.Count) return;
        var current = CurrentIndex;
        _items.RemoveAt(index);
        var pos = _order.IndexOf(index);
        _order.RemoveAt(pos);
        for (var i = 0; i < _order.Count; i++)
            if (_order[i] > index) _order[i]--;
        if (_items.Count == 0) _orderPos = -1;
        else if (pos < _orderPos) _orderPos--;
        else if (pos == _orderPos) _orderPos = Math.Min(_orderPos, _order.Count - 1);
        _ = current;
        OnChanged();
    }

    public void RemoveEntries(IEnumerable<Guid> entryIds)
    {
        var set = entryIds.ToHashSet();
        for (var i = _items.Count - 1; i >= 0; i--)
            if (set.Contains(_items[i].EntryId)) RemoveAt(i);
    }

    /// <summary>Moves an entry (drag reorder). The current entry stays current.</summary>
    public void Move(int from, int to)
    {
        if (from < 0 || from >= _items.Count || to < 0 || to >= _items.Count || from == to) return;
        var currentEntry = Current;
        var item = _items[from];
        _items.RemoveAt(from);
        _items.Insert(to, item);
        if (!Shuffle)
        {
            _order = Enumerable.Range(0, _items.Count).ToList();
            _orderPos = currentEntry is null ? -1 : _items.IndexOf(currentEntry);
        }
        else
        {
            for (var i = 0; i < _order.Count; i++)
            {
                var idx = _order[i];
                if (idx == from) _order[i] = to;
                else if (from < to && idx > from && idx <= to) _order[i] = idx - 1;
                else if (from > to && idx >= to && idx < from) _order[i] = idx + 1;
            }
        }
        OnChanged();
    }

    public void Clear()
    {
        _items.Clear();
        _order.Clear();
        _orderPos = -1;
        OnChanged();
    }

    /// <summary>Makes the entry at <paramref name="index"/> current.</summary>
    public bool JumpTo(int index)
    {
        if (index < 0 || index >= _items.Count) return false;
        var pos = _order.IndexOf(index);
        if (Shuffle && pos > _orderPos + 1)
        {
            // Bring the chosen entry right after the current one so the rest of the shuffle stays intact.
            _order.RemoveAt(pos);
            _order.Insert(_orderPos + 1, index);
            pos = _orderPos + 1;
        }
        _orderPos = pos;
        OnChanged();
        return true;
    }

    /// <summary>Returns the entry that would play after the current one without moving.</summary>
    public QueueEntry? PeekNext(bool userInitiated = false)
    {
        var pos = NextPosition(userInitiated);
        return pos < 0 ? null : _items[_order[pos]];
    }

    /// <summary>Returns the entry <paramref name="ahead"/> steps after the current one in play order (0 = immediate next), honoring repeat, without moving.</summary>
    public QueueEntry? PeekAhead(int ahead)
    {
        if (_items.Count == 0 || ahead < 0) return null;
        var pos = _orderPos;
        if (ahead == 0 && Repeat == RepeatMode.One && pos >= 0) return _items[_order[pos]];
        if (Repeat == RepeatMode.One) ahead++; // the immediate next is the current track; step over it
        for (var i = 0; i <= ahead; i++)
        {
            if (pos + 1 < _order.Count) pos++;
            else if (Repeat != RepeatMode.Off) pos = 0;
            else return null;
        }
        return _items[_order[pos]];
    }

    /// <summary>Advances to the next entry. <paramref name="userInitiated"/> ignores repeat-one (Next button).</summary>
    public QueueEntry? MoveNext(bool userInitiated = false)
    {
        var pos = NextPosition(userInitiated);
        if (pos < 0) return null;
        if (pos <= _orderPos && Shuffle && Repeat == RepeatMode.All && pos == 0 && _orderPos == _order.Count - 1)
        {
            var current = CurrentIndex;
            ShuffleList(_order, 0);
            // Avoid playing the same track twice in a row across reshuffles.
            if (_order.Count > 1 && _order[0] == current) (_order[0], _order[1]) = (_order[1], _order[0]);
        }
        _orderPos = pos;
        OnChanged();
        return Current;
    }

    public QueueEntry? MovePrevious()
    {
        if (_items.Count == 0) return null;
        if (_orderPos > 0) _orderPos--;
        else if (Repeat == RepeatMode.All) _orderPos = _order.Count - 1;
        else return Current;
        OnChanged();
        return Current;
    }

    private int NextPosition(bool userInitiated)
    {
        if (_items.Count == 0) return -1;
        if (!userInitiated && Repeat == RepeatMode.One && _orderPos >= 0) return _orderPos;
        if (_orderPos + 1 < _order.Count) return _orderPos + 1;
        return Repeat == RepeatMode.Off ? -1 : 0;
    }

    private void RebuildOrder(int currentIndex)
    {
        _order = Enumerable.Range(0, _items.Count).ToList();
        if (Shuffle && _order.Count > 0)
        {
            if (currentIndex >= 0)
            {
                _order.Remove(currentIndex);
                ShuffleList(_order, 0);
                _order.Insert(0, currentIndex);
            }
            else ShuffleList(_order, 0);
            _orderPos = currentIndex >= 0 ? 0 : (_order.Count > 0 ? 0 : -1);
        }
        else
        {
            _orderPos = currentIndex;
        }
    }

    private void ShuffleList(List<int> list, int from)
    {
        for (var i = list.Count - 1; i > from; i--)
        {
            var j = _random.Next(from, i + 1);
            (list[i], list[j]) = (list[j], list[i]);
        }
    }

    private void OnChanged() => Changed?.Invoke(this, EventArgs.Empty);
}

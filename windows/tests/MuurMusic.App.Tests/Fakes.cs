using MuurMusic.Core.Data;
using MuurMusic.Core.Models;
using MuurMusic.Core.Playlists;

namespace MuurMusic.App.Tests;

/// <summary>In-memory ITrackRepository; only QuerySmartAsync is functional (simplified evaluator for VM tests).</summary>
internal sealed class FakeTrackRepository : ITrackRepository
{
    private readonly List<Track> _tracks = new();

    public void Seed(params Track[] tracks) => _tracks.AddRange(tracks);

    public Task<IReadOnlyList<Track>> QuerySmartAsync(SmartPlaylistDefinition definition, bool availableOnly = false, CancellationToken ct = default)
    {
        IEnumerable<Track> result = _tracks;
        foreach (var rule in definition.Rules)
        {
            var captured = rule;
            if (definition.Match == "any")
            {
                result = result.Where(t => definition.Rules.Any(r => Matches(t, r)));
                break;
            }
            result = result.Where(t => Matches(t, captured));
        }
        if (definition.Limit > 0) result = result.Take(definition.Limit);
        return Task.FromResult<IReadOnlyList<Track>>(result.ToList());
    }

    private static bool Matches(Track t, SmartRule r)
    {
        var value = r.Value?.ToString() ?? "";
        var value2 = r.Value2?.ToString() ?? "";
        double Num(string s) => double.TryParse(s, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : 0;
        return (r.Field, r.Op) switch
        {
            ("genre", "is") => string.Equals(t.Genre, value, StringComparison.OrdinalIgnoreCase),
            ("genre", "isNot") => !string.Equals(t.Genre, value, StringComparison.OrdinalIgnoreCase),
            ("genre", "contains") => (t.Genre ?? "").Contains(value, StringComparison.OrdinalIgnoreCase),
            ("artist", "contains") => (t.Artist ?? "").Contains(value, StringComparison.OrdinalIgnoreCase),
            ("title", "contains") => (t.Title ?? "").Contains(value, StringComparison.OrdinalIgnoreCase),
            ("rating", "gt") => t.Rating > Num(value),
            ("rating", "lt") => t.Rating < Num(value),
            ("rating", "between") => t.Rating >= Num(value) && t.Rating <= Num(value2),
            ("playCount", "gt") => t.PlayCount > Num(value),
            ("favorite", "is") => t.Favorite == (value is "true" or "1"),
            _ => true,
        };
    }

    public Task<IReadOnlyList<Track>> QueryAsync(TrackQuery query, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<Track>>(_tracks);
    public Task<int> CountAsync(TrackQuery query, CancellationToken ct = default) => Task.FromResult(_tracks.Count);

    public Task<Track?> GetByIdAsync(long id, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<Track>> GetByIdsAsync(IEnumerable<long> ids, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<Track?> GetBySourceUriAsync(string sourceUri, long cueStartMs = 0, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<Track>> GetByFilePathAsync(string filePath, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<Album>> GetAlbumsAsync(AlbumQuery query, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<Album?> GetAlbumAsync(string albumKey, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<Track>> GetAlbumTracksAsync(string albumKey, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<Artist>> GetArtistsAsync(bool albumArtists, string? search = null, bool availableOnly = false, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<Genre>> GetGenresAsync(bool availableOnly = false, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<Composer>> GetComposersAsync(bool availableOnly = false, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<FolderContents> GetFolderContentsAsync(string folderPath, TrackSortField sort = TrackSortField.FileName, bool availableOnly = false, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<LibraryFolder>> GetRootFoldersAsync(IEnumerable<string> roots, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<LibraryStats> GetStatsAsync(CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<Track>> GetRecentlyPlayedAsync(int limit = 50, bool availableOnly = false, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<Track>> GetRecentlyAddedAsync(int limit = 50, bool availableOnly = false, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<Track>> GetMostPlayedAsync(int limit = 50, bool availableOnly = false, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<Track>> GetFavoritesAsync(TrackSortField sort = TrackSortField.Artist, bool availableOnly = false, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<long>> UpsertAsync(IReadOnlyList<Track> tracks, CancellationToken ct = default) => throw new NotSupportedException();
    public Task UpdateTagsAsync(IReadOnlyList<Track> tracks, CancellationToken ct = default) => throw new NotSupportedException();
    public Task DeleteAsync(IEnumerable<long> ids, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<int> DeleteByFilePathsAsync(IEnumerable<string> filePaths, CancellationToken ct = default) => throw new NotSupportedException();
    public Task DeleteStaleCueTracksAsync(string sourceUri, IReadOnlyCollection<long> keepCueStarts, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<Dictionary<string, (long Mtime, long Size)>> GetFileIndexAsync(string folderPrefix, CancellationToken ct = default) => throw new NotSupportedException();
    public Task SetRatingAsync(long trackId, int rating, CancellationToken ct = default) => throw new NotSupportedException();
    public Task SetFavoriteAsync(long trackId, bool favorite, CancellationToken ct = default) => throw new NotSupportedException();
    public Task SetLocalCopyAsync(string sourceUri, string? localPath, CancellationToken ct = default) => throw new NotSupportedException();
    public Task SetArtworkAsync(IEnumerable<long> trackIds, string? artworkHash, CancellationToken ct = default) => throw new NotSupportedException();
    public Task SetHasLyricsAsync(long trackId, bool hasLyrics, CancellationToken ct = default) => throw new NotSupportedException();
    public Task RecordPlayAsync(Track track, long playedMs, bool completed, CancellationToken ct = default) => throw new NotSupportedException();
    public Task RecordSkipAsync(long trackId, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<PlayHistoryEntry>> GetHistoryAsync(int limit = 200, int offset = 0, CancellationToken ct = default) => throw new NotSupportedException();
    public Task ClearHistoryAsync(CancellationToken ct = default) => throw new NotSupportedException();
}

/// <summary>In-memory IPlaylistRepository supporting create/update/get for smart playlists.</summary>
internal sealed class FakePlaylistRepository : IPlaylistRepository
{
    private readonly Dictionary<long, (Playlist Playlist, SmartPlaylistDefinition? Smart)> _playlists = new();
    private long _nextId = 1;

    public Task<Playlist> CreateAsync(string name, SmartPlaylistDefinition? smart = null, CancellationToken ct = default)
    {
        var playlist = new Playlist { Id = _nextId++, Name = name, Kind = smart is null ? PlaylistKind.Normal : PlaylistKind.Smart, Smart = smart };
        _playlists[playlist.Id] = (playlist, smart);
        return Task.FromResult(playlist);
    }

    public Task UpdateSmartAsync(long id, SmartPlaylistDefinition smart, CancellationToken ct = default)
    {
        if (_playlists.TryGetValue(id, out var row))
        {
            row.Playlist.Smart = smart;
            row.Playlist.Name = smart.Name;
            _playlists[id] = (row.Playlist, smart);
        }
        return Task.CompletedTask;
    }

    public Task<Playlist?> GetAsync(long id, CancellationToken ct = default) =>
        Task.FromResult(_playlists.TryGetValue(id, out var row) ? row.Playlist : null);

    public Task<IReadOnlyList<Playlist>> GetAllAsync(CancellationToken ct = default) =>
        Task.FromResult<IReadOnlyList<Playlist>>(_playlists.Values.Select(v => v.Playlist).ToList());

    public Task RenameAsync(long id, string name, CancellationToken ct = default)
    {
        if (_playlists.TryGetValue(id, out var row)) row.Playlist.Name = name;
        return Task.CompletedTask;
    }
    public Task<Playlist> DuplicateAsync(long id, string newName, CancellationToken ct = default) => throw new NotSupportedException();
    public Task DeleteAsync(long id, CancellationToken ct = default) => throw new NotSupportedException();
    public Task SetSortOrderAsync(IReadOnlyList<long> playlistIdsInOrder, CancellationToken ct = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<PlaylistEntry>> GetEntriesAsync(long playlistId, CancellationToken ct = default) => throw new NotSupportedException();
    public Task AddTracksAsync(long playlistId, IEnumerable<Track> tracks, int? position = null, CancellationToken ct = default) => throw new NotSupportedException();
    public Task RemoveEntriesAsync(long playlistId, IEnumerable<long> entryIds, CancellationToken ct = default) => throw new NotSupportedException();
    public Task MoveEntryAsync(long playlistId, int fromPosition, int toPosition, CancellationToken ct = default) => throw new NotSupportedException();
    public Task ReorderAsync(long playlistId, IReadOnlyList<long> entryIdsInOrder, CancellationToken ct = default) => throw new NotSupportedException();
    public Task ClearAsync(long playlistId, CancellationToken ct = default) => throw new NotSupportedException();
}

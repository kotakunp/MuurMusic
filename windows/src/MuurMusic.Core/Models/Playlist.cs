using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace MuurMusic.Core.Models;

public enum PlaylistKind { Normal, Smart }

/// <summary>A user playlist (normal or smart).</summary>
public sealed class Playlist
{
    public long Id { get; set; }
    public string Name { get; set; } = "";
    public PlaylistKind Kind { get; set; }
    /// <summary>Rules for smart playlists; null for normal playlists.</summary>
    public SmartPlaylistDefinition? Smart { get; set; }
    public int TrackCount { get; set; }
    public long DurationMs { get; set; }
    public DateTimeOffset Created { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset Updated { get; set; } = DateTimeOffset.UtcNow;
    public int SortOrder { get; set; }
    public string? ArtworkHash { get; set; }
    public bool IsSmart => Kind == PlaylistKind.Smart;
}

/// <summary>An entry of a normal playlist. <see cref="Track"/> is populated when the entry resolves to a library track.</summary>
public sealed class PlaylistEntry
{
    public long Id { get; set; }
    public long PlaylistId { get; set; }
    public int Position { get; set; }
    public long? TrackId { get; set; }
    public string SourceUri { get; set; } = "";
    public long CueStartMs { get; set; }
    public string? Title { get; set; }
    public string? Artist { get; set; }
    public long DurationMs { get; set; }
    public Track? Track { get; set; }
}

/// <summary>Smart playlist definition, serialized exactly as the shared <c>muur-smart</c> format.</summary>
public sealed class SmartPlaylistDefinition
{
    [JsonPropertyName("format")] public string Format { get; set; } = "muur-smart";
    [JsonPropertyName("version")] public int Version { get; set; } = 1;
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    /// <summary>"all" or "any".</summary>
    [JsonPropertyName("match")] public string Match { get; set; } = "all";
    [JsonPropertyName("rules")] public List<SmartRule> Rules { get; set; } = new();
    [JsonPropertyName("sort")] public string? Sort { get; set; }
    [JsonPropertyName("limit")] public int Limit { get; set; }
}

/// <summary>One smart playlist rule. <c>field</c>: genre|artist|albumArtist|album|composer|year|rating|playCount|dateAdded|format|bitDepth|sampleRate|duration.
/// <c>op</c>: is|isNot|contains|startsWith|gt|lt|between|inLast.</summary>
public sealed class SmartRule
{
    [JsonPropertyName("field")] public string Field { get; set; } = "";
    [JsonPropertyName("op")] public string Op { get; set; } = "is";
    [JsonPropertyName("value")] public JsonNode? Value { get; set; }
    [JsonPropertyName("value2")] [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public JsonNode? Value2 { get; set; }
}

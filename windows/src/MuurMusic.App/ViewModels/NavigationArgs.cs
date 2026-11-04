using MuurMusic.Core.Data;

namespace MuurMusic.App.ViewModels;

/// <summary>Navigation argument for the artist detail page.</summary>
public sealed record ArtistNavigation(string Name, bool AlbumArtists);

/// <summary>Navigation argument for the generic filtered track list page (genre/composer taps).</summary>
public sealed record TrackListNavigation(string Title, TrackQuery Query);

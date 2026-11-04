using Microsoft.Extensions.DependencyInjection;
using MuurMusic.Core.Data;

namespace MuurMusic.App.ViewModels;

/// <summary>Title-bar search suggestions; the full results page is <c>SearchResultsPage</c>.</summary>
public sealed class SearchViewModel
{
    /// <summary>Fast suggestion list (distinct matching titles, artists, albums) for the AutoSuggestBox.</summary>
    public static async Task<IReadOnlyList<string>> SuggestAsync(string text)
    {
        if (string.IsNullOrWhiteSpace(text) || text.Trim().Length < 2 || App.Services is null) return Array.Empty<string>();
        try
        {
            var repo = App.Services.GetRequiredService<ITrackRepository>();
            var tracks = await repo.QueryAsync(new TrackQuery { Search = text.Trim(), Limit = 8 });
            var suggestions = new List<string>();
            foreach (var t in tracks)
            {
                if (!string.IsNullOrWhiteSpace(t.Title) && !suggestions.Contains(t.Title)) suggestions.Add(t.Title);
                if (suggestions.Count >= 8) break;
            }
            return suggestions;
        }
        catch (Exception)
        {
            return Array.Empty<string>();
        }
    }
}

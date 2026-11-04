using MuurMusic.Core.Models;
using MuurMusic.Core.Playlists;

namespace MuurMusic.Core.Tests;

public class M3uTests
{
    [Fact]
    public void Parses_ExtInf_And_Plain_Entries()
    {
        var text = """
            #EXTM3U
            #EXTINF:241,Artist Name - Song Title
            Music\song.flac
            #EXTINF:-1,
            ..\other.mp3
            https://stream.example.com/radio
            # a comment

            C:\Absolute\path.wav
            """;
        var entries = M3uFormat.Parse(text);
        Assert.Equal(4, entries.Count);
        Assert.Equal(241, entries[0].DurationSeconds);
        Assert.Equal("Artist Name", entries[0].Artist);
        Assert.Equal("Song Title", entries[0].Title);
        Assert.Equal(@"Music\song.flac", entries[0].Location);
        Assert.Equal(@"..\other.mp3", entries[1].Location);
        Assert.Equal("https://stream.example.com/radio", entries[2].Location);
        Assert.Equal(@"C:\Absolute\path.wav", entries[3].Location);
    }

    [Fact]
    public void Resolve_Handles_Relative_Parent_And_Unc_Paths()
    {
        var dir = @"D:\Playlists\Sub";
        Assert.Equal(@"D:\Playlists\Music\song.flac", M3uFormat.Resolve(@"..\Music\song.flac", dir));
        Assert.Equal(@"D:\Playlists\Sub\Music\song.flac", M3uFormat.Resolve("Music/song.flac", dir));
        Assert.Equal(@"D:\rooted.flac", M3uFormat.Resolve(@"\rooted.flac", dir));
        Assert.Equal(@"E:\elsewhere.flac", M3uFormat.Resolve(@"E:\elsewhere.flac", dir));
        Assert.Equal("https://example.com/a.mp3", M3uFormat.Resolve("https://example.com/a.mp3", dir));
    }

    [Fact]
    public async Task Write_Uses_Relative_Paths_When_Possible_And_RoundTrips()
    {
        var dir = Path.Combine(Path.GetTempPath(), "muur-m3u-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var playlistPath = Path.Combine(dir, "list.m3u");
            var tracks = new[]
            {
                new Track { FilePath = Path.Combine(dir, "a.flac"), SourceUri = "file:///" + Path.Combine(dir, "a.flac").Replace('\\', '/'), Title = "A", Artist = "X", DurationMs = 61000 },
                new Track { FilePath = Path.Combine(dir, "sub", "b.flac"), SourceUri = "", Title = "B", Artist = "Y" },
                new Track { SourceUri = "spotless://remote/song", Title = "R", Artist = "Z" }
            };
            await M3uFormat.WriteFileAsync(tracks, playlistPath);
            var text = File.ReadAllText(playlistPath);
            Assert.Contains("a.flac", text);
            Assert.Contains("sub/b.flac", text);
            Assert.DoesNotContain(dir, text.Split('\n').First(l => l.EndsWith("a.flac")));
            Assert.Contains("#EXTINF:61,X - A", text);

            var entries = M3uFormat.Read(playlistPath);
            Assert.Equal(3, entries.Count);
            Assert.Equal(Path.Combine(dir, "sub", "b.flac"), M3uFormat.Resolve(entries[1].Location, dir));
            Assert.Equal("spotless://remote/song", entries[2].Location);
        }
        finally
        {
            Directory.Delete(dir, true);
        }
    }
}

using MuurMusic.Core.Playlists;

namespace MuurMusic.Core.Tests;

public class CueSheetTests
{
    private const string MultiFileCue = """
        REM GENRE "Rock"
        REM DATE 1997
        PERFORMER "The Example Band"
        TITLE "Example Album"
        FILE "CD1\side-a.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Intro"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Second Song"
            PERFORMER "Guest Singer"
            INDEX 00 02:30:00
            INDEX 01 02:31:37
        FILE "CD1\side-b.flac" WAVE
          TRACK 03 AUDIO
            TITLE "Third Song"
            INDEX 01 00:00:00
          TRACK 04 AUDIO
            TITLE "Finale"
            INDEX 01 05:00:00
        """;

    [Fact]
    public void Parses_MultiFile_Sheet()
    {
        var sheet = CueSheet.Parse(MultiFileCue);
        Assert.Equal("The Example Band", sheet.Performer);
        Assert.Equal("Example Album", sheet.Title);
        Assert.Equal("Rock", sheet.Genre);
        Assert.Equal(2, sheet.Files.Count);
        Assert.Equal(@"CD1\side-a.flac", sheet.Files[0].FileName);
        Assert.Equal("WAVE", sheet.Files[0].FileType);
        Assert.Equal(2, sheet.Files[0].Tracks.Count);
        Assert.Equal("Second Song", sheet.Files[0].Tracks[1].Title);
        Assert.Equal(3, sheet.Files[1].Tracks[0].Number);
    }

    [Fact]
    public void Frames_Are_Converted_To_Milliseconds_At_75_Fps()
    {
        Assert.Equal(6750, CueSheet.ParseMsf("01:30:00")); // 1 minute, 30 seconds, 0 frames
        Assert.Equal(90_000, CueSheet.FramesToMs(6750));
        Assert.Equal(1000, CueSheet.FramesToMs(75));
        Assert.Equal(520, CueSheet.FramesToMs(39));
        Assert.Equal("02:31:37", CueSheet.FormatMsf(CueSheet.ParseMsf("02:31:37")));
        Assert.Equal(37, CueSheet.ParseMsf("00:00:37"));

        var sheet = CueSheet.Parse(MultiFileCue);
        var track2 = sheet.Files[0].Tracks[1];
        Assert.Equal(CueSheet.FramesToMs((2 * 60 + 31) * 75 + 37), track2.StartMs);
    }

    [Fact]
    public void VirtualTracks_Span_Files_And_End_At_Next_Index()
    {
        var sheet = CueSheet.Parse(MultiFileCue);
        var tracks = sheet.ToVirtualTracks(name => @"D:\Music\" + name);
        Assert.Equal(4, tracks.Count);

        Assert.Equal(@"D:\Music\CD1\side-a.flac", tracks[0].AudioFile);
        Assert.Equal(0, tracks[0].StartMs);
        Assert.Equal(tracks[1].StartMs, tracks[0].EndMs);
        Assert.Null(tracks[1].EndMs); // last track of the file plays to the end of the file
        Assert.Equal("Guest Singer", tracks[1].Performer);
        Assert.Equal(@"D:\Music\CD1\side-b.flac", tracks[2].AudioFile);
        Assert.Equal(0, tracks[2].StartMs); // each FILE restarts at 0
        Assert.Equal(CueSheet.FramesToMs(5 * 60 * 75), tracks[3].StartMs);
        Assert.Equal(4, tracks[3].TrackCount);
    }

    [Fact]
    public void Write_RoundTrips()
    {
        var sheet = CueSheet.Parse(MultiFileCue);
        var reparsed = CueSheet.Parse(sheet.Write());
        Assert.Equal(sheet.Title, reparsed.Title);
        Assert.Equal(sheet.Performer, reparsed.Performer);
        Assert.Equal(2, reparsed.Files.Count);
        Assert.Equal(sheet.Files[0].Tracks[1].Index01Frames, reparsed.Files[0].Tracks[1].Index01Frames);
        Assert.Equal(sheet.Files[1].Tracks[0].Index01Frames, reparsed.Files[1].Tracks[0].Index01Frames);
    }
}

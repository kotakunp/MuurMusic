using MuurMusic.Core.Lyrics;

namespace MuurMusic.Core.Tests;

public class LrcParserTests
{
    [Fact]
    public void Parses_Synced_Lyrics_With_Tags()
    {
        var doc = LrcParser.Parse("""
            [ti:Song Title]
            [ar:The Artist]
            [offset:+250]
            [00:12.50]First line
            [00:15.00][00:20.00]Repeated line
            [01:02.75]Third line
            """);
        Assert.True(doc.IsSynced);
        Assert.Equal("Song Title", doc.Title);
        Assert.Equal("The Artist", doc.Artist);
        Assert.Equal(250, doc.OffsetMs);
        Assert.Equal(4, doc.Lines.Count);
        // The offset tag is applied to the line times at parse time (positive offset = lyrics sooner).
        Assert.Equal(12_250, doc.Lines[0].TimeMs);
        Assert.Equal("Repeated line", doc.Lines[1].Text);
        Assert.Equal(19_750, doc.Lines[2].TimeMs);
        Assert.Equal(62_500, doc.Lines[3].TimeMs);
    }

    [Fact]
    public void LineIndexAt_Tracks_Position()
    {
        var doc = LrcParser.Parse("[00:10.00]A\n[00:20.00]B\n[00:30.00]C");
        Assert.Equal(-1, doc.LineIndexAt(5_000));
        Assert.Equal(0, doc.LineIndexAt(10_000));
        Assert.Equal(0, doc.LineIndexAt(19_999));
        Assert.Equal(1, doc.LineIndexAt(20_000));
        Assert.Equal(2, doc.LineIndexAt(999_000));
    }

    [Fact]
    public void Parses_Enhanced_Word_Timing()
    {
        var doc = LrcParser.Parse("[00:10.00]<00:10.00>Hello <00:10.50>beautiful <00:11.00>world");
        Assert.True(doc.IsSynced);
        var line = Assert.Single(doc.Lines);
        Assert.True(line.HasWordTiming);
        Assert.Equal("Hello beautiful world", line.Text);
        Assert.Equal(3, line.Words.Count);
        Assert.Equal(10_500, line.Words[1].TimeMs);
        Assert.Equal("beautiful ", line.Words[1].Text);
    }

    [Fact]
    public void Plain_Text_Becomes_Unsynced_Document()
    {
        var doc = LrcParser.Parse("just some words\nmore words");
        Assert.False(doc.IsSynced);
        Assert.Equal(2, doc.Lines.Count);
        Assert.Null(doc.Lines[0].TimeMs);
        Assert.Equal("just some words" + Environment.NewLine + "more words", doc.ToPlainText());
    }

    [Fact]
    public void RoundTrips_And_Shift_Applies()
    {
        var doc = LrcParser.Parse("[offset:100]\n[00:12.00]A line\n[00:14.00]Another");
        Assert.Equal(11_900, doc.Lines[0].TimeMs); // 12.00s - 100ms offset
        var reparsed = LrcParser.Parse(doc.ToLrc());
        // ToLrc writes the effective times, so no [offset:] tag is needed on the way back.
        Assert.Equal(0, reparsed.OffsetMs);
        Assert.Equal(doc.Lines.Select(l => (l.TimeMs, l.Text)), reparsed.Lines.Select(l => (l.TimeMs, l.Text)));
        var shifted = doc.Shift(1000);
        Assert.Equal(12_900, shifted.Lines[0].TimeMs);
        Assert.True(LrcParser.LooksSynced("[00:01.00]x"));
        Assert.False(LrcParser.LooksSynced("no tags here"));
    }
}

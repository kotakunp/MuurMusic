using MuurMusic.Core.Playlists;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Tests;

public class SmartPlaylistCompilerTests
{
    private static SmartPlaylistDefinition Def(params SmartRule[] rules) => new()
    {
        Name = "Test",
        Match = "all",
        Rules = rules.ToList(),
        Sort = "title",
        Limit = 50
    };

    [Fact]
    public void Compiles_Text_Number_Date_And_Format_Rules()
    {
        var now = new DateTimeOffset(2024, 6, 1, 0, 0, 0, TimeSpan.Zero);
        var compiled = SmartPlaylistCompiler.Compile(Def(
            new SmartRule { Field = "genre", Op = "is", Value = "Rock" },
            new SmartRule { Field = "artist", Op = "contains", Value = "Cat" },
            new SmartRule { Field = "rating", Op = "gt", Value = 3 },
            new SmartRule { Field = "year", Op = "between", Value = 1990, Value2 = 1999 },
            new SmartRule { Field = "dateAdded", Op = "inLast", Value = "30d" },
            new SmartRule { Field = "format", Op = "is", Value = "flac" },
            new SmartRule { Field = "duration", Op = "lt", Value = 600 }
        ), now);

        var sql = compiled.ToSelectSql();
        Assert.Contains("WHERE", sql);
        Assert.Contains("t.genre = @s0 COLLATE NOCASE", sql);
        Assert.Contains("t.artist LIKE @s1 ESCAPE '^'", sql);
        Assert.Contains("t.rating > @s2", sql);
        Assert.Contains("t.year BETWEEN @s3 AND @s3b", sql);
        Assert.Contains("t.date_added >= @s4", sql);
        Assert.Contains("t.codec", sql); // format rules match container and codec
        Assert.Contains("t.duration_ms < @s6", sql);
        Assert.Contains("ORDER BY", sql);
        Assert.Contains("LIMIT 50", sql);

        Assert.Equal("Rock", compiled.Parameters["@s0"]);
        Assert.Equal("%Cat%", compiled.Parameters["@s1"]);
        Assert.Equal(3d, compiled.Parameters["@s2"]);
        Assert.Equal(1990d, compiled.Parameters["@s3"]);
        Assert.Equal(1999d, compiled.Parameters["@s3b"]);
        Assert.Equal(now.AddDays(-30).ToUnixTimeMilliseconds(), compiled.Parameters["@s4"]);
        Assert.Equal(600_000d, compiled.Parameters["@s6"]); // seconds are scaled to ms
    }

    [Fact]
    public void MatchAny_Uses_Or()
    {
        var def = Def(new SmartRule { Field = "genre", Op = "is", Value = "A" }, new SmartRule { Field = "genre", Op = "is", Value = "B" });
        def.Match = "any";
        Assert.Contains(" OR ", SmartPlaylistCompiler.Compile(def).WhereSql);
    }

    [Fact]
    public void Duration_Is_Seconds_In_Json_And_Milliseconds_In_Sql()
    {
        var compiled = SmartPlaylistCompiler.Compile(Def(new SmartRule { Field = "duration", Op = "between", Value = 60, Value2 = 120 }));
        Assert.Equal(60_000d, compiled.Parameters["@s0"]);
        Assert.Equal(120_000d, compiled.Parameters["@s0b"]);
    }

    [Fact]
    public void Unknown_Field_And_Wrong_Op_Are_Rejected()
    {
        Assert.Throws<FormatException>(() => SmartPlaylistCompiler.Compile(Def(new SmartRule { Field = "nope", Op = "is", Value = 1 })));
        Assert.Throws<FormatException>(() => SmartPlaylistCompiler.Compile(Def(new SmartRule { Field = "rating", Op = "inLast", Value = 1 })));
    }

    [Fact]
    public void Json_RoundTrip_Through_Shared_Format()
    {
        var def = Def(new SmartRule { Field = "playCount", Op = "gt", Value = 5 });
        var json = Core.Dsp.DspJson.WriteSmartPlaylist(def);
        var back = Core.Dsp.DspJson.ReadSmartPlaylist(json);
        Assert.Equal("muur-smart", back.Format);
        Assert.Equal(def.Name, back.Name);
        var rule = Assert.Single(back.Rules);
        Assert.Equal("playCount", rule.Field);
        Assert.Equal(5, rule.Value!.GetValue<int>());
    }
}

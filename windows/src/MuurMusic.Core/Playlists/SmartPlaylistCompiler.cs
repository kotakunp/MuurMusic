using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using MuurMusic.Core.Data;
using MuurMusic.Core.Models;

namespace MuurMusic.Core.Playlists;

/// <summary>SQL produced from a smart playlist definition. Table alias for tracks is <c>t</c>.</summary>
public sealed record CompiledSmartQuery(string WhereSql, IReadOnlyDictionary<string, object?> Parameters, string OrderBySql, int Limit)
{
    public string ToSelectSql(string columns = "t.*")
    {
        var sql = $"SELECT {columns} FROM tracks t WHERE {WhereSql} ORDER BY {OrderBySql}";
        return Limit > 0 ? sql + $" LIMIT {Limit}" : sql;
    }
}

/// <summary>Compiles <see cref="SmartPlaylistDefinition"/> rules (shared muur-smart format) into parameterized SQL.</summary>
public static class SmartPlaylistCompiler
{
    private enum FieldType { Text, Number, Date, Format }

    private sealed record FieldDef(string Sql, FieldType Type, double Scale = 1);

    private static readonly Dictionary<string, FieldDef> Fields = new(StringComparer.OrdinalIgnoreCase)
    {
        ["genre"] = new("t.genre", FieldType.Text),
        ["artist"] = new("t.artist", FieldType.Text),
        ["albumArtist"] = new("coalesce(nullif(t.album_artist, ''), t.artist)", FieldType.Text),
        ["album"] = new("t.album", FieldType.Text),
        ["composer"] = new("t.composer", FieldType.Text),
        ["title"] = new("t.title", FieldType.Text),
        ["comment"] = new("t.comment", FieldType.Text),
        ["path"] = new("coalesce(t.file_path, t.source_uri)", FieldType.Text),
        ["year"] = new("t.year", FieldType.Number),
        ["rating"] = new("t.rating", FieldType.Number),
        ["playCount"] = new("t.play_count", FieldType.Number),
        ["bpm"] = new("t.bpm", FieldType.Number),
        ["bitrate"] = new("t.bitrate", FieldType.Number),
        ["bitDepth"] = new("t.bit_depth", FieldType.Number),
        ["sampleRate"] = new("t.sample_rate", FieldType.Number),
        ["favorite"] = new("t.favorite", FieldType.Number),
        // Duration values are expressed in seconds in the shared format; the column is milliseconds.
        ["duration"] = new("t.duration_ms", FieldType.Number, 1000),
        ["dateAdded"] = new("t.date_added", FieldType.Date),
        ["lastPlayed"] = new("t.last_played", FieldType.Date),
        ["format"] = new("t.format", FieldType.Format),
    };

    public static IReadOnlyCollection<string> SupportedFields => Fields.Keys;
    public static readonly IReadOnlyList<string> SupportedOps = new[] { "is", "isNot", "contains", "startsWith", "gt", "lt", "between", "inLast" };

    public static CompiledSmartQuery Compile(SmartPlaylistDefinition def, DateTimeOffset? now = null, bool availableOnly = false)
    {
        var clock = now ?? DateTimeOffset.UtcNow;
        var parameters = new Dictionary<string, object?>();
        var parts = new List<string>();
        var i = 0;
        foreach (var rule in def.Rules)
        {
            parts.Add(CompileRule(rule, $"@s{i}", $"@s{i}b", parameters, clock));
            i++;
        }
        var joiner = string.Equals(def.Match, "any", StringComparison.OrdinalIgnoreCase) ? " OR " : " AND ";
        var where = parts.Count == 0 ? "1 = 1" : "(" + string.Join(joiner, parts.Select(p => "(" + p + ")")) + ")";
        if (availableOnly) where += " AND " + TrackSql.AvailableFilter;
        var order = TrackSql.TryParseSort(def.Sort, out var field, out var desc) ? TrackSql.OrderBy(field, desc) : TrackSql.OrderBy(TrackSortField.Artist, false);
        return new CompiledSmartQuery(where, parameters, order, Math.Max(0, def.Limit));
    }

    private static string CompileRule(SmartRule rule, string p1, string p2, Dictionary<string, object?> ps, DateTimeOffset now)
    {
        if (!Fields.TryGetValue(rule.Field, out var f))
            throw new FormatException($"Unknown smart playlist field '{rule.Field}'.");
        var op = rule.Op;
        switch (f.Type)
        {
            case FieldType.Text:
            case FieldType.Format:
            {
                var cols = f.Type == FieldType.Format ? new[] { "t.format", "t.codec" } : new[] { f.Sql };
                string Each(Func<string, string> build, string combine) => "(" + string.Join(combine, cols.Select(build)) + ")";
                switch (op)
                {
                    case "is":
                        ps[p1] = TextOf(rule.Value);
                        return Each(c => $"{c} = {p1} COLLATE NOCASE", " OR ");
                    case "isNot":
                        ps[p1] = TextOf(rule.Value);
                        return Each(c => $"({c} IS NULL OR {c} <> {p1} COLLATE NOCASE)", " AND ");
                    case "contains":
                        ps[p1] = "%" + Db.EscapeLike(TextOf(rule.Value)) + "%";
                        return Each(c => $"{c} LIKE {p1} ESCAPE '^'", " OR ");
                    case "startsWith":
                        ps[p1] = Db.EscapeLike(TextOf(rule.Value)) + "%";
                        return Each(c => $"{c} LIKE {p1} ESCAPE '^'", " OR ");
                    case "gt":
                        ps[p1] = TextOf(rule.Value);
                        return $"{cols[0]} > {p1} COLLATE NOCASE";
                    case "lt":
                        ps[p1] = TextOf(rule.Value);
                        return $"{cols[0]} < {p1} COLLATE NOCASE";
                    case "between":
                        ps[p1] = TextOf(rule.Value);
                        ps[p2] = TextOf(rule.Value2);
                        return $"{cols[0]} COLLATE NOCASE BETWEEN {p1} AND {p2}";
                    default:
                        throw new FormatException($"Operator '{op}' is not valid for field '{rule.Field}'.");
                }
            }
            case FieldType.Number:
            {
                double V(JsonNode? n) => NumberOf(n) * f.Scale;
                switch (op)
                {
                    case "is": ps[p1] = V(rule.Value); return $"{f.Sql} = {p1}";
                    case "isNot": ps[p1] = V(rule.Value); return $"({f.Sql} IS NULL OR {f.Sql} <> {p1})";
                    case "gt": ps[p1] = V(rule.Value); return $"{f.Sql} > {p1}";
                    case "lt": ps[p1] = V(rule.Value); return $"{f.Sql} < {p1}";
                    case "between":
                    {
                        var a = V(rule.Value);
                        var b = V(rule.Value2);
                        ps[p1] = Math.Min(a, b);
                        ps[p2] = Math.Max(a, b);
                        return $"{f.Sql} BETWEEN {p1} AND {p2}";
                    }
                    case "contains":
                        ps[p1] = "%" + Db.EscapeLike(TextOf(rule.Value)) + "%";
                        return $"CAST({f.Sql} AS TEXT) LIKE {p1} ESCAPE '^'";
                    case "startsWith":
                        ps[p1] = Db.EscapeLike(TextOf(rule.Value)) + "%";
                        return $"CAST({f.Sql} AS TEXT) LIKE {p1} ESCAPE '^'";
                    default:
                        throw new FormatException($"Operator '{op}' is not valid for field '{rule.Field}'.");
                }
            }
            case FieldType.Date:
            {
                switch (op)
                {
                    case "inLast":
                    {
                        var span = ParseSpan(rule.Value, rule.Value2);
                        ps[p1] = (now - span).ToUnixTimeMilliseconds();
                        return $"{f.Sql} >= {p1}";
                    }
                    case "gt": ps[p1] = DateOf(rule.Value).ToUnixTimeMilliseconds(); return $"{f.Sql} > {p1}";
                    case "lt": ps[p1] = DateOf(rule.Value).ToUnixTimeMilliseconds(); return $"{f.Sql} < {p1}";
                    case "is":
                    {
                        var d = DateOf(rule.Value);
                        var start = new DateTimeOffset(d.UtcDateTime.Date, TimeSpan.Zero);
                        ps[p1] = start.ToUnixTimeMilliseconds();
                        ps[p2] = start.AddDays(1).ToUnixTimeMilliseconds();
                        return $"({f.Sql} >= {p1} AND {f.Sql} < {p2})";
                    }
                    case "isNot":
                    {
                        var d = DateOf(rule.Value);
                        var start = new DateTimeOffset(d.UtcDateTime.Date, TimeSpan.Zero);
                        ps[p1] = start.ToUnixTimeMilliseconds();
                        ps[p2] = start.AddDays(1).ToUnixTimeMilliseconds();
                        return $"({f.Sql} IS NULL OR {f.Sql} < {p1} OR {f.Sql} >= {p2})";
                    }
                    case "between":
                    {
                        var a = DateOf(rule.Value).ToUnixTimeMilliseconds();
                        var b = DateOf(rule.Value2).ToUnixTimeMilliseconds();
                        ps[p1] = Math.Min(a, b);
                        ps[p2] = Math.Max(a, b);
                        return $"{f.Sql} BETWEEN {p1} AND {p2}";
                    }
                    default:
                        throw new FormatException($"Operator '{op}' is not valid for field '{rule.Field}'.");
                }
            }
        }
        throw new FormatException($"Unsupported rule {rule.Field} {op}.");
    }

    private static string TextOf(JsonNode? n) => n switch
    {
        null => "",
        JsonValue v when v.TryGetValue(out string? s) => s ?? "",
        JsonValue v when v.TryGetValue(out double d) => d.ToString(CultureInfo.InvariantCulture),
        JsonValue v when v.TryGetValue(out bool b) => b ? "1" : "0",
        _ => n.ToJsonString()
    };

    private static double NumberOf(JsonNode? n)
    {
        if (n is JsonValue v)
        {
            if (v.TryGetValue(out double d)) return d;
            if (v.TryGetValue(out long l)) return l;
            if (v.TryGetValue(out int i)) return i;
            if (v.TryGetValue(out bool b)) return b ? 1 : 0;
            if (v.TryGetValue(out string? s) && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var p)) return p;
            if (v.GetValueKind() == JsonValueKind.Number) return v.GetValue<double>();
        }
        throw new FormatException($"Expected a number but got '{n?.ToJsonString() ?? "null"}'.");
    }

    private static DateTimeOffset DateOf(JsonNode? n)
    {
        var s = TextOf(n);
        if (DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d)) return d;
        if (long.TryParse(s, out var ms)) return DateTimeOffset.FromUnixTimeMilliseconds(ms);
        throw new FormatException($"Expected a date but got '{s}'.");
    }

    /// <summary>"inLast" value: a number of days, or a number with unit suffix (h, d, w, m, y), or value2 holding the unit.</summary>
    internal static TimeSpan ParseSpan(JsonNode? value, JsonNode? unitNode)
    {
        var text = TextOf(value).Trim().ToLowerInvariant();
        var unit = unitNode is null ? "" : TextOf(unitNode).Trim().ToLowerInvariant();
        var numEnd = 0;
        while (numEnd < text.Length && (char.IsDigit(text[numEnd]) || text[numEnd] == '.')) numEnd++;
        var amount = double.Parse(numEnd == 0 ? "0" : text[..numEnd], CultureInfo.InvariantCulture);
        if (unit.Length == 0) unit = text[numEnd..].Trim();
        return unit switch
        {
            "h" or "hour" or "hours" => TimeSpan.FromHours(amount),
            "w" or "week" or "weeks" => TimeSpan.FromDays(amount * 7),
            "m" or "month" or "months" => TimeSpan.FromDays(amount * 30),
            "y" or "year" or "years" => TimeSpan.FromDays(amount * 365),
            _ => TimeSpan.FromDays(amount)
        };
    }
}

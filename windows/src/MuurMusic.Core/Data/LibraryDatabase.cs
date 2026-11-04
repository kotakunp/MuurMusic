using System.Collections.Concurrent;
using System.Globalization;
using System.Reflection;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using MuurMusic.Core.Infrastructure;

namespace MuurMusic.Core.Data;

/// <summary>Owns the SQLite library file (library.sqlite): connection creation and forward-only migrations (PRAGMA user_version).</summary>
public sealed class LibraryDatabase
{
    private readonly string _connectionString;
    private readonly ILogger _logger;
    private int _migrated;

    public LibraryDatabase(AppPaths paths, ILogger<LibraryDatabase>? logger = null) : this(paths.DatabasePath, logger) { }

    public LibraryDatabase(string path, ILogger<LibraryDatabase>? logger = null)
    {
        Path = path;
        _logger = (ILogger?)logger ?? NullLogger.Instance;
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Private,
            Pooling = true,
            DefaultTimeout = 30
        }.ToString();
    }

    public string Path { get; }

    public int SchemaVersion { get; private set; }

    public SqliteConnection Open()
    {
        EnsureMigrated();
        return OpenRaw();
    }

    public async Task<SqliteConnection> OpenAsync(CancellationToken ct = default)
    {
        EnsureMigrated();
        var c = new SqliteConnection(_connectionString);
        await c.OpenAsync(ct).ConfigureAwait(false);
        ConfigureConnection(c);
        return c;
    }

    private SqliteConnection OpenRaw()
    {
        var c = new SqliteConnection(_connectionString);
        c.Open();
        ConfigureConnection(c);
        return c;
    }

    private static void ConfigureConnection(SqliteConnection c)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=10000; PRAGMA synchronous=NORMAL;";
        cmd.ExecuteNonQuery();
    }

    public void EnsureMigrated()
    {
        if (Volatile.Read(ref _migrated) == 1) return;
        lock (this)
        {
            if (_migrated == 1) return;
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(Path))!);
            using var c = OpenRaw();
            using (var wal = c.CreateCommand())
            {
                wal.CommandText = "PRAGMA journal_mode=WAL;";
                wal.ExecuteNonQuery();
            }
            var version = Convert.ToInt32(new SqliteCommand("PRAGMA user_version;", c).ExecuteScalar(), CultureInfo.InvariantCulture);
            for (var v = version; v < Schema.Migrations.Count; v++)
            {
                using var tx = c.BeginTransaction();
                using (var cmd = c.CreateCommand())
                {
                    cmd.Transaction = tx;
                    cmd.CommandText = Schema.Migrations[v] + $"\nPRAGMA user_version = {v + 1};";
                    cmd.ExecuteNonQuery();
                }
                tx.Commit();
                _logger.LogInformation("Library database migrated to schema {Version}", v + 1);
            }
            SchemaVersion = Schema.Migrations.Count;
            Volatile.Write(ref _migrated, 1);
        }
    }
}

/// <summary>Small ADO.NET helpers (parameter binding from anonymous objects, typed reads).</summary>
internal static class Db
{
    private static readonly ConcurrentDictionary<Type, PropertyInfo[]> PropCache = new();

    public static SqliteCommand Command(this SqliteConnection c, string sql, object? args = null, SqliteTransaction? tx = null)
    {
        var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        cmd.Transaction = tx;
        Bind(cmd, args);
        return cmd;
    }

    public static void Bind(SqliteCommand cmd, object? args)
    {
        if (args is null) return;
        if (args is IEnumerable<KeyValuePair<string, object?>> dict)
        {
            foreach (var (k, v) in dict) cmd.Parameters.AddWithValue(k.StartsWith('@') ? k : "@" + k, ToDb(v));
            return;
        }
        foreach (var p in PropCache.GetOrAdd(args.GetType(), t => t.GetProperties(BindingFlags.Public | BindingFlags.Instance)))
            cmd.Parameters.AddWithValue("@" + p.Name, ToDb(p.GetValue(args)));
    }

    public static object ToDb(object? v) => v switch
    {
        null => DBNull.Value,
        bool b => b ? 1 : 0,
        DateTimeOffset d => d.ToUnixTimeMilliseconds(),
        DateTime dt => new DateTimeOffset(dt.ToUniversalTime()).ToUnixTimeMilliseconds(),
        Guid g => g.ToString("D"),
        Enum e => e.ToString(),
        TimeSpan ts => (long)ts.TotalMilliseconds,
        _ => v
    };

    public static async Task<List<T>> QueryAsync<T>(this SqliteConnection c, string sql, Func<SqliteDataReader, T> map, object? args = null, CancellationToken ct = default, SqliteTransaction? tx = null)
    {
        await using var cmd = c.Command(sql, args, tx);
        await using var r = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
        var list = new List<T>();
        while (await r.ReadAsync(ct).ConfigureAwait(false)) list.Add(map(r));
        return list;
    }

    public static async Task<int> ExecAsync(this SqliteConnection c, string sql, object? args = null, CancellationToken ct = default, SqliteTransaction? tx = null)
    {
        await using var cmd = c.Command(sql, args, tx);
        return await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    public static async Task<T?> ScalarAsync<T>(this SqliteConnection c, string sql, object? args = null, CancellationToken ct = default, SqliteTransaction? tx = null)
    {
        await using var cmd = c.Command(sql, args, tx);
        var v = await cmd.ExecuteScalarAsync(ct).ConfigureAwait(false);
        if (v is null || v is DBNull) return default;
        var target = Nullable.GetUnderlyingType(typeof(T)) ?? typeof(T);
        return (T)Convert.ChangeType(v, target, CultureInfo.InvariantCulture);
    }

    public static string? Str(this SqliteDataReader r, int i) => r.IsDBNull(i) ? null : r.GetString(i);
    public static long Long(this SqliteDataReader r, int i) => r.IsDBNull(i) ? 0 : r.GetInt64(i);
    public static long? LongN(this SqliteDataReader r, int i) => r.IsDBNull(i) ? null : r.GetInt64(i);
    public static int Int(this SqliteDataReader r, int i) => r.IsDBNull(i) ? 0 : r.GetInt32(i);
    public static int? IntN(this SqliteDataReader r, int i) => r.IsDBNull(i) ? null : r.GetInt32(i);
    public static double? DoubleN(this SqliteDataReader r, int i) => r.IsDBNull(i) ? null : r.GetDouble(i);
    public static bool Bool(this SqliteDataReader r, int i) => !r.IsDBNull(i) && r.GetInt64(i) != 0;
    public static DateTimeOffset Date(this SqliteDataReader r, int i) => r.IsDBNull(i) ? DateTimeOffset.UnixEpoch : DateTimeOffset.FromUnixTimeMilliseconds(r.GetInt64(i));
    public static DateTimeOffset? DateN(this SqliteDataReader r, int i) => r.IsDBNull(i) ? null : DateTimeOffset.FromUnixTimeMilliseconds(r.GetInt64(i));

    /// <summary>Escapes a value for use with LIKE ... ESCAPE '^'.</summary>
    public static string EscapeLike(string s) => s.Replace("^", "^^").Replace("%", "^%").Replace("_", "^_");
}

using System.Collections.Concurrent;
using System.Text;
using Microsoft.Extensions.Logging;

namespace MuurMusic.Core.Infrastructure;

/// <summary>Rolling file logger: one file per day, rolled over at <see cref="MaxFileBytes"/>, old files pruned.</summary>
[ProviderAlias("MuurFile")]
public sealed class FileLoggerProvider : ILoggerProvider
{
    public const long MaxFileBytes = 10 * 1024 * 1024;
    public const int MaxFiles = 20;

    private readonly string _directory;
    private readonly LogLevel _minLevel;
    private readonly BlockingCollection<string> _queue = new(new ConcurrentQueue<string>(), 10_000);
    private readonly Thread _writer;
    private readonly ConcurrentDictionary<string, FileLogger> _loggers = new();
    private StreamWriter? _stream;
    private string? _currentPath;
    private DateOnly _currentDay;

    public FileLoggerProvider(string directory, LogLevel minLevel = LogLevel.Information)
    {
        _directory = directory;
        _minLevel = minLevel;
        Directory.CreateDirectory(directory);
        _writer = new Thread(WriteLoop) { IsBackground = true, Name = "MuurMusic log writer" };
        _writer.Start();
    }

    public ILogger CreateLogger(string categoryName) => _loggers.GetOrAdd(categoryName, n => new FileLogger(n, this));

    internal bool IsEnabled(LogLevel level) => level >= _minLevel && level != LogLevel.None;

    internal void Enqueue(string line)
    {
        if (!_queue.IsAddingCompleted) _queue.TryAdd(line);
    }

    private void WriteLoop()
    {
        try
        {
            foreach (var line in _queue.GetConsumingEnumerable())
            {
                try
                {
                    EnsureStream();
                    _stream!.WriteLine(line);
                    if (_queue.Count == 0) _stream.Flush();
                }
                catch (IOException)
                {
                    _stream?.Dispose();
                    _stream = null;
                }
            }
        }
        finally
        {
            _stream?.Dispose();
        }
    }

    private void EnsureStream()
    {
        var today = DateOnly.FromDateTime(DateTime.Now);
        if (_stream is not null && today == _currentDay && _stream.BaseStream.Length < MaxFileBytes) return;
        _stream?.Dispose();
        _currentDay = today;
        var baseName = $"muur-{today:yyyyMMdd}";
        var index = 0;
        string path;
        do
        {
            path = Path.Combine(_directory, index == 0 ? $"{baseName}.log" : $"{baseName}-{index}.log");
            index++;
        } while (File.Exists(path) && new FileInfo(path).Length >= MaxFileBytes);
        _currentPath = path;
        _stream = new StreamWriter(new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false));
        Prune();
    }

    private void Prune()
    {
        try
        {
            var files = new DirectoryInfo(_directory).GetFiles("muur-*.log").OrderByDescending(f => f.LastWriteTimeUtc).ToList();
            foreach (var f in files.Skip(MaxFiles)) f.Delete();
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public string? CurrentLogFile => _currentPath;

    public void Dispose()
    {
        _queue.CompleteAdding();
        _writer.Join(TimeSpan.FromSeconds(2));
    }

    private sealed class FileLogger(string category, FileLoggerProvider provider) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => provider.IsEnabled(logLevel);

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            if (!IsEnabled(logLevel)) return;
            var sb = new StringBuilder(256);
            sb.Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff")).Append(' ')
              .Append(logLevel switch
              {
                  LogLevel.Trace => "TRC", LogLevel.Debug => "DBG", LogLevel.Information => "INF",
                  LogLevel.Warning => "WRN", LogLevel.Error => "ERR", _ => "CRT"
              })
              .Append(' ').Append(category).Append(": ").Append(formatter(state, exception));
            if (exception is not null) sb.AppendLine().Append(exception);
            provider.Enqueue(sb.ToString());
        }
    }
}

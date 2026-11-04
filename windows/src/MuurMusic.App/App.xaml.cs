using System.IO.Pipes;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.UI.Xaml;
using MuurMusic.App.Services;
using MuurMusic.App.ViewModels;
using MuurMusic.Audio;
using MuurMusic.Audio.Playback;
using MuurMusic.Core;
using MuurMusic.Core.Infrastructure;
using MuurMusic.Core.Settings;
using WinRT.Interop;

namespace MuurMusic.App;

/// <summary>
/// Application entry: single instance (mutex + named-pipe activation forwarding), DI bootstrap
/// (MuurMusic.Core + MuurMusic.Audio + app services) and main-window lifetime.
/// </summary>
public partial class App : Application
{
    private const string MutexName = "MuurMusic.1.0.SingleInstance";
    private const string PipeName = "MuurMusic.1.0.Activate";

    private static Mutex? _singleInstanceMutex;
    private CancellationTokenSource? _pipeCts;

    public App()
    {
        InitializeComponent();
        UnhandledException += OnUnhandledException;
    }

    public static IServiceProvider Services { get; private set; } = null!;
    public static MainWindow? CurrentWindow { get; internal set; }
    public static IntPtr MainWindowHandle { get; internal set; }

    /// <summary>True while the process is shutting down; view models suppress notifications then.</summary>
    public static bool IsShuttingDown { get; private set; }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _singleInstanceMutex = new Mutex(initiallyOwned: true, MutexName, out var createdNew);
        if (!createdNew)
        {
            ForwardActivationToRunningInstance();
            Environment.Exit(0);
            return;
        }

        var services = new ServiceCollection();
        services.AddMuurCore();
        services.AddMuurAudio();
        AppServices.Register(services);
        Services = services.BuildServiceProvider();

        var window = new MainWindow();
        CurrentWindow = window;
        MainWindowHandle = WindowNative.GetWindowHandle(window);

        // Marshal all service events onto the UI thread.
        Services.GetRequiredService<IEventDispatcher>()
            .SetPoster(action => window.DispatcherQueue.TryEnqueue(() => action()));

        window.Activate();
        StartActivationPipeServer();
        _ = InitializeBackendAsync();
    }

    private async Task InitializeBackendAsync()
    {
        var log = Services.GetRequiredService<ILoggerFactory>().CreateLogger("MuurMusic.App");
        try
        {
            await MuurCoreStartup.InitializeAsync(Services).ConfigureAwait(false);
            var playback = Services.GetRequiredService<IPlaybackService>();
            await playback.InitializeAsync(MainWindowHandle).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            log.LogError(ex, "Backend initialization failed");
            try
            {
                Services.GetRequiredService<NotificationService>()
                    .Error("Startup problem", "Some background services failed to start: " + ex.Message);
            }
            catch (InvalidOperationException) { /* window already gone */ }
        }
    }

    /// <summary>Graceful shutdown: persist queue/settings, then dispose the container. Called by MainWindow on close.</summary>
    public static async Task ShutdownAsync()
    {
        if (IsShuttingDown) return;
        IsShuttingDown = true;
        try
        {
            var playback = Services.GetService<IPlaybackService>();
            if (playback is not null) await playback.FlushAsync().ConfigureAwait(false);
            var settings = Services.GetService<ISettingsService>();
            if (settings is not null) await settings.FlushAsync().ConfigureAwait(false);
        }
        catch (Exception) { /* best effort during shutdown */ }
        finally
        {
            if (Services is IAsyncDisposable asyncDisposable) await asyncDisposable.DisposeAsync().ConfigureAwait(false);
            else (Services as IDisposable)?.Dispose();
        }
    }

    private void OnUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs e)
    {
        try
        {
            Services?.GetService<ILoggerFactory>()?.CreateLogger("MuurMusic.App")
                .LogError(e.Exception, "Unhandled UI exception");
            e.Handled = true;
            Services?.GetService<NotificationService>()?.Error("Something went wrong", e.Exception.Message);
        }
        catch (Exception) { /* never crash the handler */ }
    }

    private static void ForwardActivationToRunningInstance()
    {
        try
        {
            using var client = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
            client.Connect(1500);
            using var writer = new StreamWriter(client);
            writer.WriteLine("activate");
            writer.Flush();
        }
        catch (Exception)
        {
            // No live server despite the mutex (crashed earlier instance): start anyway.
            _singleInstanceMutex?.Dispose();
            _singleInstanceMutex = null;
            // Fall through to a normal launch by restarting ourselves is overkill; just exit quietly.
        }
    }

    private void StartActivationPipeServer()
    {
        _pipeCts = new CancellationTokenSource();
        var ct = _pipeCts.Token;
        Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    using var server = new NamedPipeServerStream(PipeName, PipeDirection.In, 1,
                        PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                    await server.WaitForConnectionAsync(ct).ConfigureAwait(false);
                    using var reader = new StreamReader(server);
                    var message = await reader.ReadLineAsync(ct).ConfigureAwait(false);
                    if (message == "activate")
                        CurrentWindow?.DispatcherQueue.TryEnqueue(() => CurrentWindow.BringToForeground());
                }
                catch (OperationCanceledException) { break; }
                catch (IOException) { /* client vanished; keep listening */ }
            }
        }, ct);
    }
}

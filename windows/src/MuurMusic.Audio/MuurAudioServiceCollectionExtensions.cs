using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using MuurMusic.Audio.Casting;
using MuurMusic.Audio.Engine;
using MuurMusic.Audio.FFmpeg;
using MuurMusic.Audio.Output;
using MuurMusic.Audio.Playback;
using MuurMusic.Core.Tags;

namespace MuurMusic.Audio;

public static class MuurAudioServiceCollectionExtensions
{
    /// <summary>
    /// Registers the audio layer: <see cref="IMediaProbe"/> (FFmpeg, picked up by the Core library scanner), the
    /// <see cref="AudioEngine"/> mixer, <see cref="IAudioOutput"/> (WASAPI), the cast HTTP server, <see cref="ICastManager"/>
    /// and the <see cref="IPlaybackService"/> facade. Call after <c>AddMuurCore()</c> and before building the provider,
    /// then call <c>MuurCoreStartup.InitializeAsync(sp)</c> and <c>IPlaybackService.InitializeAsync(hwnd)</c> at startup.
    /// </summary>
    public static IServiceCollection AddMuurAudio(this IServiceCollection services)
    {
        services.TryAddSingleton<IMediaProbe, FFmpegMediaProbe>();
        services.TryAddSingleton<AudioEngine>();
        services.TryAddSingleton<IAudioOutput, WasapiOutput>();
        services.TryAddSingleton<LocalHttpServer>();
        services.TryAddSingleton<ICastManager, CastManager>();
        services.TryAddSingleton<IPlaybackService, PlaybackService>();
        return services;
    }
}

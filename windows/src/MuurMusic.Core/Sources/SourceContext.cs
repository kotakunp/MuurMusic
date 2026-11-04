using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using MuurMusic.Core.Infrastructure;
using MuurMusic.Core.Models;
using MuurMusic.Core.Security;
using MuurMusic.Core.Settings;

namespace MuurMusic.Core.Sources;

/// <summary>Shared services handed to every source instance.</summary>
public sealed class SourceContext(
    ICredentialStore credentials,
    IHttpClientFactory httpFactory,
    ILoggerFactory loggerFactory,
    IConfiguration configuration,
    AppPaths paths,
    ISettingsService settings,
    IOAuthService oauth)
{
    public ICredentialStore Credentials { get; } = credentials;
    public IHttpClientFactory HttpFactory { get; } = httpFactory;
    public ILoggerFactory LoggerFactory { get; } = loggerFactory;
    public IConfiguration Configuration { get; } = configuration;
    public AppPaths Paths { get; } = paths;
    public ISettingsService Settings { get; } = settings;
    public IOAuthService OAuth { get; } = oauth;

    /// <summary>Shared HTTP client (named "muur") with the app User-Agent.</summary>
    public HttpClient Http => HttpFactory.CreateClient(HttpClientNames.Default);

    public Task<string?> SecretAsync(SourceConfig config, string name, CancellationToken ct = default) =>
        Credentials.GetSourceSecretAsync(config.Id, name, ct);

    /// <summary>Creates an HttpClient for sources that need their own handler (digest auth, self-signed certificates).</summary>
    public HttpClient CreateCustomClient(System.Net.ICredentials? credentials = null, bool acceptAnyCertificate = false, TimeSpan? timeout = null)
    {
        var handler = new SocketsHttpHandler
        {
            Credentials = credentials,
            PreAuthenticate = credentials is not null,
            AutomaticDecompression = System.Net.DecompressionMethods.All,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            ConnectTimeout = TimeSpan.FromSeconds(15)
        };
        if (acceptAnyCertificate)
            handler.SslOptions.RemoteCertificateValidationCallback = (_, _, _, _) => true;
        var client = new HttpClient(handler, disposeHandler: true) { Timeout = timeout ?? TimeSpan.FromSeconds(100) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd(HttpClientNames.UserAgent);
        return client;
    }
}

public static class HttpClientNames
{
    public const string Default = "muur";
    public const string UserAgent = "MuurMusic/1.0 ( https://muur.app )";
}

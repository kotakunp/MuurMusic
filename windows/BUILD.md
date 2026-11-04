# MuurMusic for Windows — build guide

MuurMusic is a cat-approved, ad-free hi-res music player (Flacbox replacement) built with **WinUI 3 / Windows App SDK 2.6.5** on **.NET 10**, running **unpackaged and self-contained** on Windows 10 17763+ (x64).

## Projects

| Project | Purpose |
| --- | --- |
| `src/MuurMusic.Core` | Library (SQLite + FTS), scanner, tags, playlists (normal/smart/M3U/CUE), lyrics (LRCLIB), MusicBrainz, 17 source kinds (local, SMB, WebDAV, FTP/SFTP, UPnP, S3, cloud drives, Subsonic, Jellyfin, Emby, Plex, ZIP), OAuth PKCE, downloads/caching, settings. |
| `src/MuurMusic.Audio` | FFmpeg 7.1 decoding, WASAPI shared/exclusive output, gapless/crossfade, DSP chain + 10-band EQ, WSOLA tempo, spectrum/waveform analysis, SMTC, Chromecast/DLNA casting, `IPlaybackService` facade. |
| `src/MuurMusic.App` | The WinUI 3 app (shell, pages, view models, theming). |
| `tests/MuurMusic.Core.Tests` | Core unit tests (25). |
| `tests/MuurMusic.Audio.Tests` | Audio unit tests (23). |
| `tests/MuurMusic.App.Tests` | View-model unit tests (8) — VMs under test are UI-thread-free by design. |

## Prerequisites

- Windows 10/11 x64 with the .NET SDK 10.0.4xx (`dotnet --version`).
- Everything else (Windows App SDK runtime, FFmpeg DLLs, Win2D) is restored from NuGet and shipped self-contained — no separate runtime installs needed.

## Build

```powershell
dotnet build windows\MuurMusic.sln -c Release
```

## Run from the build tree

```powershell
windows\src\MuurMusic.App\bin\Release\net10.0-windows10.0.19041.0\win-x64\MuurMusic.exe
```

## Test

```powershell
dotnet test windows\MuurMusic.sln -c Release
```

## Publish (distributable folder)

```powershell
dotnet publish windows\src\MuurMusic.App\MuurMusic.App.csproj -c Release -r win-x64 --self-contained true -o publish\MuurMusic-win-x64
publish\MuurMusic-win-x64\MuurMusic.exe
```

The publish folder is fully portable: it contains the .NET runtime, the Windows App SDK runtime (`WindowsAppSDKSelfContained=true`), and the FFmpeg DLLs (`avcodec-61.dll`, `avformat-61.dll`, `avutil-59.dll`, `avfilter-10.dll`, `avdevice-61.dll`, `swresample-5.dll`, `swscale-8.dll`, `postproc-58.dll`).

> Note: the app csproj contains an `IncludeCompiledXamlInPublish` target that injects the compiled XAML (`.xbf`) files and `MuurMusic.pri` into the publish output. Without it, `dotnet publish` of an unpackaged WinUI app omits them and every page crashes with `XamlParseException`.

## Data locations

All state lives under `%LOCALAPPDATA%\MuurMusic\` (settings.json, library.sqlite, artwork/audio caches, lyrics, downloads queue, logs in `Logs\`).

## Configuration

- User settings are managed in the app's Settings page (persisted to `settings.json`).
- `appsettings.Local.json` (git-ignored) can override Core options next to the exe for development.
- OAuth-based sources (Dropbox, Google Drive, OneDrive, Box, pCloud) need client IDs; without them the app shows a "not configured" error and skips authorization gracefully.

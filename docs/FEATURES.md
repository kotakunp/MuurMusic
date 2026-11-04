# MuurMusic feature spec

MuurMusic is a hi-res, ad-free music player for iOS, macOS (one SwiftUI codebase in `apple/`) and Windows (WinUI 3 / .NET 10 in `windows/`). Its feature set mirrors Flacbox (researched Nov 2026) minus ads, paywalls and limits. Every limit in Flacbox's free tier (10 playlists, 3 clouds, 750-song queue…) is unlimited here.

Legend: **A** = Apple (iOS + macOS), **W** = Windows. `iOS` / `mac` = only that Apple platform.

## 1. Playback engine
| Feature | A | W | Notes |
|---|---|---|---|
| Lossless / hi-res: FLAC, ALAC, WAV, AIFF, DSF/DFF (DSD), APE, WavPack, TTA | ✓ | ✓ | A: SFBAudioEngine (DSD → PCM or DoP). W: FFmpeg decoders |
| Lossy: MP3, AAC, OGG Vorbis, Opus, MPC, AC3, WMA | ✓ (WMA: no) | ✓ | |
| Containers: M4A, M4V, MP4, MKV/MKA, MOV, MPEG | ✓ | ✓ | |
| Tracker: MOD, XM, IT, S3M | ✓ | ✓ | |
| Sample rates 8 kHz – 384 kHz, 1–7+ channels | ✓ | ✓ | |
| Gapless playback (next track pre-decoded) | ✓ | ✓ | |
| Crossfade (0–12 s, off by default) | ✓ | ✓ | |
| ReplayGain (track / album / off, preamp, clipping prevention) | ✓ | ✓ | |
| Playback speed 0.5×–2.0× without pitch change | ✓ | ✓ | |
| Output: shared/mixed vs exclusive (bit-perfect) mode, output sample rate choice | iOS: mixWithOthers toggle; mac: device + sample rate | WASAPI shared/exclusive, device picker | |
| Shuffle, repeat (off/all/one), stop after current track | ✓ | ✓ | |
| Skip back/forward interval (5/10/15/30/60 s) | ✓ | ✓ | |
| Sleep timer (minutes, end of track, fade out last 30 s) | ✓ | ✓ | |
| Save/restore queue + position on relaunch | ✓ | ✓ | |
| Unlimited play queue, drag reorder, play next / play later | ✓ | ✓ | |
| Background playback | ✓ | ✓ | |
| System media controls | Now Playing, lock screen, remote commands, media keys (mac) | SMTC overlay + media keys | |
| CUE sheets: single-file albums split into virtual tracks | ✓ | ✓ | |
| Bookmarks: save a position inside a track and jump back | ✓ | ✓ | |

## 2. Sound (DSP)
| Feature | A | W |
|---|---|---|
| 10-band graphic EQ (31 Hz–16 kHz, ±12 dB) + preamp | ✓ | ✓ |
| Genre presets (Flat, Rock, Pop, Jazz, Classical, Electronic, Hip-Hop, Vocal, Bass Boost, Treble Boost, Loudness, Acoustic, Late Night) | ✓ | ✓ |
| Save / rename / delete custom presets; import/export JSON (shared format, see `specs/SHARED_FORMATS.md`) | ✓ | ✓ |
| Loudness boost ("make it louder") with limiter | ✓ | ✓ |
| Effects: reverb, delay/echo, chorus, flanger, phaser, auto-wah, distortion, compressor, crossfeed | ✓ | ✓ |
| DSP chain builder: ordered list of nodes — low-pass, high-pass, band-pass, notch, peaking, low-shelf, high-shelf, gain, soft-clip, bit crusher, tremolo, delay, ring modulator, stereo width. Add/remove/reorder/bypass | ✓ | ✓ |
| Level meters (live peak/RMS) | ✓ | ✓ |

## 3. Library
| Feature | A | W |
|---|---|---|
| Auto-updating library from watched folders + downloaded/offline files | ✓ | ✓ |
| Browse: Songs, Albums, Artists, Album Artists, Genres, Composers, Folders, Playlists | ✓ | ✓ |
| Sort by title, album, artist, album artist, genre, composer, rating, year, BPM, play count, bitrate, length, date added | ✓ | ✓ |
| Smart search (instant, across title/artist/album/genre/composer/path, diacritic-insensitive) | ✓ | ✓ |
| Favorites, 5-star ratings, play counts, Recently Played, Recently Added, Most Played | ✓ | ✓ |
| Tag editor (title, artist, album, album artist, genre, composer, year, track/disc #, BPM, comment, lyrics, artwork) incl. batch edit | ✓ | ✓ |
| Automatic tag + artwork lookup (MusicBrainz + Cover Art Archive) | ✓ | ✓ |
| Hi-res badges (format, bit depth, sample rate, bitrate) on track info | ✓ | ✓ |

## 4. Playlists
| Feature | A | W |
|---|---|---|
| Unlimited playlists, unlimited songs, reorder, duplicate, rename | ✓ | ✓ |
| Smart playlists (rules: genre/artist/year/rating/play count/added date/format) | ✓ | ✓ |
| Import / export M3U, M3U8, CUE (M3U export uses relative paths when possible) | ✓ | ✓ |

## 5. Sources (local, network, cloud, media servers)
All sources share one abstraction: list directory → items (folder / audio file / playlist / archive), get playback stream or URL, download. Credentials go in the OS keychain (Keychain / Windows Credential Locker), never in the database.

| Source | A | W | Notes |
|---|---|---|---|
| Local folders | ✓ (iOS: app Documents + security-scoped folders via Files app; mac: any folder) | ✓ | |
| iCloud Drive | ✓ | – | Via Files / document picker bookmarks |
| External drives / memory cards / USB | ✓ (Files) | ✓ (drives) | |
| SMB (SMB2/3) | ✓ (AMSMB2) | ✓ (UNC paths + SMBLibrary for credentials) | |
| WebDAV (HTTP/HTTPS) | ✓ | ✓ | Presets: Nextcloud, ownCloud, Synology, QNAP, Yandex Disk, Koofr, InfiniCLOUD (TeraCLOUD), HiDrive, pCloud WebDAV |
| FTP / FTPS | ✓ | ✓ | |
| SFTP (password or private key) | ✓ (Citadel) | ✓ (SSH.NET) | |
| DLNA / UPnP media servers (SSDP discovery + ContentDirectory browse) | ✓ (manual URL if multicast entitlement missing) | ✓ | |
| S3-compatible (AWS, B2, Wasabi, R2, MinIO, Spaces) | ✓ | ✓ | SigV4 |
| Dropbox, Google Drive, OneDrive, Box, pCloud | ✓ | ✓ | OAuth2 PKCE; client IDs in `Config` (see README) |
| Subsonic / Navidrome / Airsonic / Gonic / Funkwhale / Ampache (Subsonic API) | ✓ | ✓ | |
| Jellyfin / Emby | ✓ | ✓ | |
| Plex (plex.tv PIN sign-in or manual token) | ✓ | ✓ | |
| Bonjour / mDNS + SSDP "Available devices" discovery | ✓ | ✓ | |
| ZIP archives: browse and play audio inside | ✓ | ✓ | |

## 6. Offline & cache
| Feature | A | W |
|---|---|---|
| Stream with smart buffering (prefetch next track) | ✓ | ✓ |
| Download tracks / albums / artists / playlists / folders for offline | ✓ | ✓ |
| Download manager (queue, progress, pause/resume, retry, cancel) | ✓ | ✓ |
| Automatic audio cache of recently played remote songs with size limit + one-tap clear | ✓ | ✓ |
| Offline mode toggle (hide unavailable remote items) | ✓ | ✓ |

## 7. File manager
Browse local and remote sources, create folder, rename, move, copy, delete, share/export, multi-select, "add to library", "play folder", "download folder". (A + W)

## 8. Lyrics
Embedded lyrics (USLT / LYRICS / ©lyr), sidecar `.lrc`/`.txt`, synced LRC with karaoke-style auto-scroll and tap-to-seek, online fetch from LRCLIB (`https://lrclib.net/api/get`), per-track comments/notes. (A + W). iOS Lyrics widget.

## 9. Visualizer
Full-screen, live FFT-reactive visualizer with presets (Spectrum Bars, Mirror Bars, Circle Spectrum, Waveform, Particles, Cat Eyes, Starfield, Vinyl) and auto-cycle. (A + W)

## 10. Output & casting
| Feature | A | W |
|---|---|---|
| AirPlay / AirPlay 2 (route picker, long-form audio) | ✓ | – |
| Chromecast | – | ✓ |
| DLNA / UPnP renderer output | ✓ | ✓ |

## 11. Platform integration
| Feature | Where |
|---|---|
| CarPlay audio app (browse Library / Playlists / Recently Played, Now Playing) | iOS (needs Apple CarPlay audio entitlement) |
| Home Screen widgets: Now Playing / queue, Resume, Lyrics | iOS + mac (WidgetKit) |
| Wi-Fi transfer: built-in web server so a browser on the same network can upload/download files | iOS (+ mac) |
| iTunes/Finder File Sharing (Documents visible in Files and Finder) | iOS |
| Menu bar commands, keyboard shortcuts, mini player window | mac, W |
| Siri / Shortcuts App Intents (play, pause, next, play playlist) | A |
| Taskbar thumbnail buttons, jump list, toast on track change (optional) | W |

## 12. Personalization
Dark / light / system theme, accent color choices (Amber default, Violet, Mint, Rose, Sky), Now Playing styles (artwork, vinyl spin, visualizer), configurable tabs order, VoiceOver / Narrator labels everywhere. Cat theme throughout: cat-themed empty states, paw-print loading indicator, "purr" haptic on favorite (iOS).

## Not included (and why)
- MEGA, Proton Drive, Internxt, Baidu, Mail.ru, AliDrive, MediaFire, Put.io, OpenDrive, MyDrive, IceDrive: proprietary or end-to-end encrypted APIs with no stable public SDK for Swift/C#. Several of them offer WebDAV, which works through the WebDAV source.
- NFS: neither iOS nor WinUI has a user-space NFS client library worth shipping. Mount it at OS level on mac/Windows and add it as a local folder.
- WMA on Apple: no free decoder in the Apple stack.
- Chromecast on Apple: the Google Cast SDK does not support SwiftPM properly. Use AirPlay or DLNA output.

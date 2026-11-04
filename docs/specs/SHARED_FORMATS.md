# Shared formats

Both apps read and write these formats so files can move between devices.

## Brand tokens
| Token | Hex | Use |
|---|---|---|
| `bg` | `#17122B` | App background (matches illustrations) |
| `bgElevated` | `#211A3D` | Cards, sidebars, sheets |
| `bgHighlight` | `#2C2350` | Hover / selected rows |
| `accent` | `#FFB23F` | Primary accent ("cat eye amber") |
| `accentSecondary` | `#8B6CFF` | Secondary accent (violet) |
| `textPrimary` | `#F5F2FF` | |
| `textSecondary` | `#A79FC7` | |
| `danger` | `#FF6B6B` | |
| `success` | `#5EE0A0` | |
Light theme: `bg #F7F5FC`, `bgElevated #FFFFFF`, `bgHighlight #ECE7FA`, `textPrimary #1B1630`, `textSecondary #5E5780`, accents unchanged (amber text on light uses `#C77C00`).
Alternative accents: Violet `#8B6CFF`, Mint `#5EE0C0`, Rose `#FF7BA9`, Sky `#5CB8FF`.
Corner radius: 8 (rows), 14 (cards), 22 (artwork large). Font: system (SF Pro / Segoe UI Variable).

## EQ preset file (`*.muureq.json`)
```json
{
  "format": "muur-eq",
  "version": 1,
  "presets": [
    {
      "name": "Late Night",
      "preampDb": -2.0,
      "bands": [
        { "frequencyHz": 31, "gainDb": 2.0 },
        { "frequencyHz": 62, "gainDb": 1.5 },
        { "frequencyHz": 125, "gainDb": 1.0 },
        { "frequencyHz": 250, "gainDb": 0.0 },
        { "frequencyHz": 500, "gainDb": -0.5 },
        { "frequencyHz": 1000, "gainDb": 0.0 },
        { "frequencyHz": 2000, "gainDb": 0.5 },
        { "frequencyHz": 4000, "gainDb": 1.0 },
        { "frequencyHz": 8000, "gainDb": 0.5 },
        { "frequencyHz": 16000, "gainDb": 0.0 }
      ]
    }
  ]
}
```
Bands are always the 10 ISO frequencies above, Q = 1.41, gains clamped to ±12 dB. Built-in presets live in `docs/specs/eq-presets.json` (same format); both apps embed a copy.

## DSP chain file (`*.muurdsp.json`)
```json
{ "format": "muur-dsp", "version": 1, "name": "Warm headphones",
  "nodes": [
    { "type": "highPass", "enabled": true, "params": { "frequencyHz": 25, "q": 0.707 } },
    { "type": "lowShelf", "enabled": true, "params": { "frequencyHz": 120, "gainDb": 3, "q": 0.707 } },
    { "type": "crossfeed", "enabled": true, "params": { "amount": 0.3 } },
    { "type": "softClip", "enabled": false, "params": { "drive": 0.2 } }
  ] }
```
Node `type` values and params:
- `lowPass`, `highPass`, `bandPass`, `notch`: `frequencyHz`, `q`
- `peaking`, `lowShelf`, `highShelf`: `frequencyHz`, `gainDb`, `q`
- `gain`: `gainDb`
- `softClip`: `drive` (0–1)
- `bitCrusher`: `bits` (1–16), `downsample` (1–32)
- `tremolo`: `rateHz`, `depth` (0–1)
- `delay`: `timeMs`, `feedback` (0–0.95), `mix` (0–1)
- `ringModulator`: `frequencyHz`, `mix`
- `stereoWidth`: `width` (0 = mono, 1 = normal, 2 = wide)
- `reverb`: `roomSize` (0–1), `damping` (0–1), `mix`
- `chorus`, `flanger`: `rateHz`, `depth`, `mix`, `feedback`
- `phaser`: `rateHz`, `depth`, `stages` (2–12), `feedback`, `mix`
- `autoWah`: `sensitivity`, `minHz`, `maxHz`, `q`, `mix`
- `distortion`: `drive`, `tone` (0–1), `mix`
- `compressor`: `thresholdDb`, `ratio`, `attackMs`, `releaseMs`, `makeupDb`
- `crossfeed`: `amount` (0–1)
Biquad formulas: RBJ Audio EQ Cookbook. Unknown node types are kept and shown as unsupported, not dropped.

## Playlists
- M3U/M3U8: `#EXTM3U`, `#EXTINF:<seconds>,<artist> - <title>`, UTF-8 for `.m3u8`. Paths relative to the playlist file when the track is under the same root; otherwise absolute path or source URI.
- CUE: standard `FILE` / `TRACK nn AUDIO` / `INDEX 01 mm:ss:ff` (75 frames/s), `PERFORMER`, `TITLE`, `REM GENRE`, `REM DATE`. A CUE track ends at the next track's `INDEX 01` or end of file.
- Smart playlist file (`*.muursmart.json`): `{ "format": "muur-smart", "version": 1, "name": "...", "match": "all"|"any", "rules": [{ "field": "genre|artist|albumArtist|album|composer|year|rating|playCount|dateAdded|format|bitDepth|sampleRate|duration", "op": "is|isNot|contains|startsWith|gt|lt|between|inLast", "value": ..., "value2": ... }], "sort": "title|...", "limit": 0 }`

## Source URIs
Tracks are identified by a source URI so playlists survive moving between sources:
`file:///…`, `smb://host/share/path`, `webdav(s)://host/path`, `ftp(s)://host/path`, `sftp://host/path`, `s3://<sourceId>/bucket/key`, `dropbox://<sourceId>/path`, `gdrive://<sourceId>/<fileId>`, `onedrive://<sourceId>/<itemId>`, `box://<sourceId>/<fileId>`, `pcloud://<sourceId>/<fileId>`, `subsonic://<sourceId>/<songId>`, `jellyfin://<sourceId>/<itemId>`, `plex://<sourceId>/<ratingKey>`, `upnp://<sourceId>/<objectId>`, `zip://<inner source URI>!/<entry path>`.
`<sourceId>` is a UUID of a configured source. Credentials never appear in URIs.

## Library database
SQLite, one file per device (`library.sqlite`). Tables: `tracks`, `albums` (derived view acceptable), `playlists`, `playlist_items`, `sources`, `bookmarks`, `play_history`, `downloads`, `eq_presets`, `dsp_chains`, `settings`. Schema version stored in `PRAGMA user_version`; migrations are forward-only. Each app owns its schema; the formats above are the interchange layer.

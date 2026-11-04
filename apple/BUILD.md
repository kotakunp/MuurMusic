# Building the MuurMusic Apple apps

One Xcode project (`MuurMusic.xcodeproj`) builds the iOS app, the macOS app and
the shared WidgetKit extension from a single codebase.

## Prerequisites

- Xcode 15.4+ (Swift 5.10 toolchain) on macOS 14+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Generate and build

```sh
cd apple
xcodegen generate          # creates MuurMusic.xcodeproj from project.yml
open MuurMusic.xcodeproj   # or use xcodebuild below
```

There is a single scheme, **MuurMusic**. Both the app and the widget extension
targets are multi-platform targets (`supportedDestinations: [iOS, macOS]` in
`project.yml`), so the same scheme builds either platform depending on the
destination:

```sh
# iOS (Simulator)
xcodebuild build -project MuurMusic.xcodeproj -scheme MuurMusic \
  -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO

# macOS
xcodebuild build -project MuurMusic.xcodeproj -scheme MuurMusic \
  -destination "generic/platform=macOS" CODE_SIGNING_ALLOWED=NO
```

That is exactly what CI (`.github/workflows/apple.yml`) runs. Regenerate the
project after adding or removing files: `xcodegen generate` again.

## Current status

Checked on a Mac (Xcode 27.2, Swift 6.4):

- `swift build` and `swift test` in `Packages/MuurKit` pass (38 tests).
- The **MuurMusic** scheme (app + widgets) builds for `generic/platform=iOS Simulator`
  and `generic/platform=macOS` with the exact CI commands above.
- iOS Simulator: library scanning (including folders added while the app runs),
  gapless album playback, queue edit / reorder / delete, synced sidecar LRC
  lyrics, EQ presets, loudness and DSP chain, sleep timer, playlist M3U import /
  export / edit, tag editing (written to the file), Wi-Fi transfer uploads with
  and without a PIN, and the level meters.
- iPhone 15 Pro (free Personal Team, `MUUR_PERSONAL_TEAM = YES`): the app installs
  and launches.
- macOS: the app launches and stays up (unsigned build, so no sandbox or app group).

Not tested yet:

1. Widgets on a device (they need a second App ID; see "Signing" below).
2. On device / signed Mac build: lock-screen controls, network sources, SSDP /
   Bonjour discovery (needs the multicast entitlement), CarPlay.

## Secrets (optional cloud sources)

OAuth sign-in for Dropbox / Google Drive / OneDrive / Box / pCloud reads client
IDs from build settings, which come from xcconfig variables:

```sh
cp apple/Secrets.xcconfig.example apple/Secrets.xcconfig
# edit Secrets.xcconfig and fill in the client IDs
```

`Config.xcconfig` includes `Secrets.xcconfig` if present (the file is
git-ignored). Missing keys simply disable the corresponding "Sign in" buttons
in the app — the build works fine without them.

Google additionally needs its reversed client ID URL scheme; set
`MUUR_GOOGLE_CLIENT_ID` and the scheme is derived automatically
(`MUUR_GOOGLE_URL_SCHEME` in Config.xcconfig).

## Signing

`Signing.xcconfig` (applied to every target) holds the bundle ID, App Group and
entitlement switches. To run on your own device, override them in a git-ignored
`Signing.local.xcconfig`:

```sh
cp apple/Signing.local.xcconfig.example apple/Signing.local.xcconfig
# set DEVELOPMENT_TEAM, MUUR_BUNDLE_ID and the switches below
cd apple && xcodegen generate
```

| Setting | Effect |
| --- | --- |
| `MUUR_BUNDLE_ID` | App bundle ID; the widgets use `$(MUUR_BUNDLE_ID).widgets`. Use your own ID for personal builds. |
| `MUUR_APP_GROUP` | Shared app/widget container, default `group.$(MUUR_BUNDLE_ID)`. Read at runtime from Info.plist (`MuurAppGroup`). |
| `MUUR_CARPLAY` | `YES` signs with `MuurMusic-iOS-CarPlay.entitlements`. Needs Apple's CarPlay audio approval on the profile. Default `NO`. |
| `MUUR_PERSONAL_TEAM` | `YES` signs with `MuurMusic-iOS-Personal.entitlements` (App Group only) for free Personal Teams, which cannot sign Multicast Networking or CarPlay. SSDP discovery is then unavailable. |

Simulator builds always use the App Group-only entitlements. The CarPlay code
compiles either way; without the entitlement the CarPlay scene never activates.

Free Personal Teams can register at most 10 App IDs per 7 days, and the app
plus widgets need two. If you hit the limit, build without the widget extension
or wait for the limit to reset.

## macOS sandbox

The macOS entitlements enable the App Sandbox with network client/server,
multicast (SSDP/Bonjour discovery), user-selected file access (library
folders) and read-write access to `~/Music`. The app group
`group.app.muur.music` is shared with the widget extension.

## App Intents

Siri/Shortcuts intents (`PlayPauseIntent`, `NextTrackIntent`,
`PlayPlaylistIntent`, …) operate on the running app instance. Playlist
suggestions are available while the app is running; the transport intents work
whenever the app (or a playback session) is alive.

## Layout

```
apple/
  project.yml               XcodeGen spec (see header comment for the target strategy)
  Config.xcconfig           shared build settings (+ optional Secrets.xcconfig include)
  Secrets.xcconfig.example  OAuth client ID template
  Packages/MuurKit/         Swift package: MuurCore, MuurAudio, MuurWidgetKitSupport
  MuurMusic/                app sources (App/, Views/, CarPlay/, Intents/, Resources/)
  MuurWidgets/              WidgetKit extension sources
```

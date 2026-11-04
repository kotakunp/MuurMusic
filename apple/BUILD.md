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
targets are multi-platform targets (`SDKROOT=auto`,
`SUPPORTED_PLATFORMS="iphoneos iphonesimulator macosx"`), so the same scheme
builds either platform depending on the destination:

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

## CarPlay entitlement

The repo ships `MuurMusic/MuurMusic-iOS.entitlements` **with** the
`com.apple.developer.carplay-audio` entitlement, which requires Apple's
CarPlay approval to code-sign. For local development or CI without approval,
remove (or comment out) that key — everything else keeps working; the CarPlay
scene simply never activates. The CarPlay code itself compiles either way.

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

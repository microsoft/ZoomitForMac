# Sysinternals ZoomIt for Mac

Sysinternals ZoomIt for Mac is a macOS menu-bar utility modeled after Sysinternals ZoomIt. It provides screen zoom, live zoom, drawing and typing annotations, screenshots, snips, recording, webcam picture-in-picture, and scrolling panorama capture.

## Install

Install ZoomIt from the [Homebrew Sysinternals tap](https://github.com/microsoft/homebrew-sysinternalstap):

```sh
brew install --cask microsoft/sysinternalstap/zoomit
```

If the tap is already configured, the shorter form also works:

```sh
brew install --cask zoomit
```

ZoomIt requires macOS 14 Sonoma or newer. It runs in the menu bar and requests Screen Recording permission when a capture feature is first used.

## Features

- Static zoom over a frozen ScreenCaptureKit display capture.
- Live zoom of the running screen, with click-through interaction when not drawing.
- Draw-without-zoom mode for annotating the screen at 1x.
- Pen, line, rectangle, ellipse, arrow, highlighter, undo, erase, blank-screen sketch pads, and typing annotations.
- Viewport screenshot copy/save and region snip copy/save.
- OCR snip: select a screen region and copy its recognized text to the clipboard.
- Break timer with a configurable countdown, colors, opacity, background, and optional sound.
- MP4 screen recording for the whole screen or a selected region, with optional system audio, microphone audio, and fixed webcam picture-in-picture.
- Post-recording video editor with preview, trim, append, fades, playback controls, volume mute/slider, and export before save.
- Scrolling panorama capture with alignment, fixed header/footer suppression, progress, cancellation, and copy/save output.
- Tabbed Settings dialog for hotkeys, zoom, draw, type, snip, record, webcam, panorama, and launch-at-login preferences.
- Single-instance app behavior, menu-bar status, permission checks, and optional launch at login.

## Requirements

- macOS 14 or newer.
- Xcode command-line tools.
- Screen Recording permission for capture.
- Microphone and Camera permissions are required only for those recording options.

## Build, Test, Run

```sh
swift build
swift run ZoomItMacSelfTest
swift run ZoomIt
```

The self-test covers viewport math, annotation lifecycle/rendering, settings persistence, and panorama stitcher regressions.

Launch at login requires running ZoomIt as an app bundle so macOS attributes the login item to ZoomIt instead of the host process used for development. Build the bundle with:

```sh
zsh Scripts/build-app.sh
open ".build/ZoomIt (Dev).app"
```

The contributor build is named `ZoomIt (Dev).app` (bundle id `com.sysinternals.zoomitmac.dev`) so it stays distinct from an installed official `ZoomIt.app` in the Screen Recording list. See [Bundle identity](#bundle-identity-dev-vs-official) below.

## Default Hotkeys

| Action | Shortcut |
| --- | --- |
| Static zoom | `Control+1` |
| Draw without zoom | `Control+2` |
| Break timer | `Control+3` |
| Live zoom | `Control+4` |
| Record screen | `Control+5` |
| Record region | `Control+Shift+5` |
| Snip region to clipboard | `Control+6` |
| Snip region to file | `Control+Shift+6` |
| OCR region to clipboard | `Control+Option+6` |
| Panorama to clipboard | `Control+8` |
| Panorama to file | `Control+Shift+8` |

All global hotkeys are configurable in Settings. While zoomed, use `Option+Up` and `Option+Down` to change zoom level, mouse wheel to zoom or resize tools depending on mode, `Command+S` / `Command+C` to save or copy the viewport, and `Esc` or right click to exit the active overlay mode.

## Drawing And Typing

- Left click enters drawing mode; drag to draw.
- Hold `Shift` for a line, `Control` for a rectangle, `Control+Shift` for an arrow, or `Tab` for an ellipse.
- Press `R/G/B/O/Y/P/W/K` for red, green, blue, orange, yellow, pink, white, or black; hold `Shift` with a color for highlighter ink.
- Press `T` for typing mode, `Shift+T` for right-aligned typing, and `Up` / `Down` or the mouse wheel to adjust font size.
- Use `Command+Z` to undo and `E` to erase annotations.

## Snip And OCR

Press the snip shortcut (`Control+6`) and drag a rectangle to copy that region of the screen to the clipboard; hold `Shift` (`Control+Shift+6`) to save it to a PNG file instead. Snip also works while zoomed, capturing the magnified view.

Press the OCR shortcut (`Control+Option+6`) and drag a rectangle to recognize the text inside it and copy that text to the clipboard. OCR uses Apple's on-device Vision text recognition, runs entirely on-device, and needs no extra permissions. Both shortcuts are configurable on the Snip tab in Settings.

## Recording

Recording uses ScreenCaptureKit and AVAssetWriter. Static zoom and drawing overlays are captured even when ScreenCaptureKit omits ZoomIt's own windows; live zoom remains excluded from its own capture to avoid feedback. Webcam picture-in-picture stays fixed in the recorded viewport and is composited into overlay recordings instead of being zoomed into the source image.

When recording stops, ZoomItMac opens the built-in editor before the save panel so the clip can be trimmed, appended to another clip, faded, muted, and exported.

## Panorama

Panorama capture records a selected scroll region while you scroll, then stitches the frames into one image. It filters repeated frames, handles vertical or horizontal scrolls, suppresses fixed headers and footers, shows stitch progress, and can be canceled with `Esc`.

## Settings And Permissions

Settings are saved immediately to `UserDefaults`. The app includes permission checks for Screen Recording, Microphone, and Camera. Running from SwiftPM is supported for development; launch at login and production distribution are intended for the bundled app form.

## Distributing To Testers

Testers should run the bundled app, not `swift run`. Build a release app bundle:

```sh
zsh Scripts/build-app.sh release
```

Local bundles default to version `1.0`. Set `ZOOMIT_VERSION` to stamp a
specific dotted-numeric version into both `CFBundleShortVersionString` and
`CFBundleVersion`:

```sh
ZOOMIT_VERSION=1.2.0 zsh Scripts/build-app.sh release
defaults read "$PWD/.build/ZoomIt (Dev).app/Contents/Info" CFBundleShortVersionString
defaults read "$PWD/.build/ZoomIt (Dev).app/Contents/Info" CFBundleVersion
```

The official Azure DevOps build supplies `ZOOMIT_VERSION` from the version
entered when the pipeline is queued. Values must contain two or three numeric
components, such as `1.2` or `1.2.0`; malformed values fail before compilation
or signing begins.

By default this produces `.build/ZoomIt (Dev).app` with the app icon, bundled resources, and an `Info.plist` declaring the microphone and camera usage descriptions. `release` builds are **Universal** (Apple Silicon + Intel) by default; `debug` builds are native to the build machine for speed. Override the architectures with `ZOOMIT_ARCHS` (e.g. `ZOOMIT_ARCHS=arm64`). A Universal build routes through Xcode's build system, so it requires a **full Xcode** install — with only the Command Line Tools the script warns and falls back to a native build. The build summary prints the resulting architectures.

### Create and install a local development DMG

Build the Universal development app, stage it with an Applications shortcut, and create a compressed disk image using macOS's built-in `hdiutil`:

```sh
zsh Scripts/build-app.sh release

STAGE="$(mktemp -d)"
ditto ".build/ZoomIt (Dev).app" "$STAGE/ZoomIt (Dev).app"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
  -volname "ZoomIt Dev" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  ".build/ZoomIt-Dev.dmg"
rm -rf "$STAGE"

hdiutil verify ".build/ZoomIt-Dev.dmg"
open ".build/ZoomIt-Dev.dmg"
```

Drag **ZoomIt (Dev)** to the Applications shortcut in the mounted image, then launch the installed copy:

```sh
open "/Applications/ZoomIt (Dev).app"
```

A `.dmg` is a disk image, not an executable; use `open path/to/file.dmg` rather than invoking the path directly. Do **not** override a local ad-hoc build to use `com.sysinternals.zoomitmac` or the `ZoomIt.app` name. That identity is reserved for the officially Developer ID-signed release; an ad-hoc app using it conflicts with the official app's macOS privacy (TCC) grants even when System Settings shows Screen Recording as enabled.

### Bundle identity: dev vs. official

`Scripts/build-app.sh` picks the bundle identity from the signing identity so a locally built copy never fights the officially distributed app over macOS privacy (TCC) grants, which are keyed by bundle id **and** code-signing requirement:

- **Contributor / ad-hoc build (default):** app bundle `ZoomIt (Dev).app`, bundle id `com.sysinternals.zoomitmac.dev`, display name “ZoomIt (Dev)”, ad-hoc signed. Both the distinct file name and bundle id keep it separate from an installed official `ZoomIt.app`, so its Screen Recording grant is its own row in System Settings and the two never clobber each other.
- **Official build:** pass a real Developer ID identity and it keeps the canonical `com.sysinternals.zoomitmac` id:

  ```sh
  ZOOMIT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
    zsh Scripts/build-app.sh release
  ```

Override any field explicitly with `ZOOMIT_SIGN_IDENTITY`, `ZOOMIT_BUNDLE_ID`, and `ZOOMIT_DISPLAY_NAME`. Because a real signing identity has a stable, team-based designated requirement, the official app keeps its Screen Recording permission across updates; an ad-hoc build cannot share that grant since contributors don't have the certificate.

### Entitlements (camera & microphone)

`build-app.sh` signs the bundle with `Scripts/ZoomIt.entitlements`, which grants `com.apple.security.device.camera` and `com.apple.security.device.audio-input`. Under the hardened runtime (used by notarized builds) these are **required** for the webcam overlay and microphone recording — without them macOS denies both even after the user approves the TCC prompt. Screen Recording is pure TCC and needs no entitlement. The entitlements are embedded even for ad-hoc builds so that when the official pipeline re-signs the bundle with ESRP (`MacAppDeveloperSign`), the existing entitlements are preserved. Verify on the first signed build with `codesign -d --entitlements :- ZoomIt.app`.

### Signing options

- **Distributing widely (recommended):** sign with a Developer ID Application certificate, notarize with Apple, and staple the ticket, then zip or wrap the app in a `.dmg`:

  ```sh
  ZOOMIT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
    zsh Scripts/build-app.sh release
  ditto -c -k --keepParent .build/ZoomIt.app ZoomIt.zip
  xcrun notarytool submit ZoomIt.zip --apple-id you@example.com \
    --team-id TEAMID --password APP_SPECIFIC_PASSWORD --wait
  xcrun stapler staple .build/ZoomIt.app
  ```

  A notarized app opens with a normal double-click and keeps its Screen Recording permission across updates.

- **Quick internal testing (unsigned/ad-hoc):** use the development identity and `ZoomIt-Dev.dmg` procedure above. If another Mac downloads the unnotarized DMG, Gatekeeper may block it. After copying the app to `/Applications`, testers can clear the quarantine flag:

  ```sh
  xattr -dr com.apple.quarantine "/Applications/ZoomIt (Dev).app"
  open "/Applications/ZoomIt (Dev).app"
  ```

  Note that rebuilding an ad-hoc/unsigned app can reset its Screen Recording permission, so testers may need to re-grant it after an update.

### First run

1. Move `ZoomIt (Dev).app` (local testing) or `ZoomIt.app` (official release) to `/Applications` and open it. It runs as a menu-bar item (no Dock icon).
2. macOS prompts for **Screen Recording** the first time a capture feature is used; enable the matching **ZoomIt (Dev)** or **ZoomIt** row in System Settings ▸ Privacy & Security ▸ Screen Recording, then relaunch that same app.
3. **Microphone** and **Camera** are only requested when those recording options are enabled.
4. Use the menu-bar icon or the default hotkeys above to drive the app, and the Settings dialog to customize shortcuts and behavior.

### Clear stale Screen Recording permissions

macOS privacy permissions (TCC) are tied to both an app's bundle identifier and its code-signing requirement. If an ad-hoc build previously used the official `com.sysinternals.zoomitmac` identifier, System Settings can show **ZoomIt** as enabled while macOS rejects the currently installed Developer ID-signed app. Typical symptoms are:

- `Control+1` repeatedly opens Screen Recording settings even though ZoomIt is enabled.
- Closing the permission dialog and pressing `Control+1` again does nothing.
- A newly installed, correctly signed build still cannot capture the screen.

Reset only the Screen Recording record for the identity you are running. This removes the stale grant; it does not uninstall the app or clear ZoomIt settings.

For the **officially signed** `/Applications/ZoomIt.app`:

```sh
pkill -f "/Applications/ZoomIt.app/Contents/MacOS/ZoomIt" 2>/dev/null || true
tccutil reset ScreenCapture com.sysinternals.zoomitmac

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "/Applications/ZoomIt.app"
open "/Applications/ZoomIt.app"
```

For the local **development** `/Applications/ZoomIt (Dev).app`:

```sh
pkill -f "/Applications/ZoomIt (Dev).app/Contents/MacOS/ZoomIt" 2>/dev/null || true
tccutil reset ScreenCapture com.sysinternals.zoomitmac.dev

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "/Applications/ZoomIt (Dev).app"
open "/Applications/ZoomIt (Dev).app"
```

After relaunching:

1. Press `Control+1` once to request Screen Recording access.
2. Enable the matching **ZoomIt** or **ZoomIt (Dev)** row in System Settings.
3. Use macOS's **Quit & Reopen** button, or quit and reopen that same app manually.
4. Press `Control+1` again.

Static zoom requires **Screen Recording** only. Microphone and Camera permissions are unrelated unless their optional recording features are enabled. If the problem immediately returns after the reset, verify that the installed app has the expected identity:

```sh
codesign -dv --verbose=2 "/Applications/ZoomIt.app" 2>&1 \
  | grep -E "Identifier=|Authority=Developer ID Application|TeamIdentifier="
```

The official app should report identifier `com.sysinternals.zoomitmac` and a Developer ID authority. Never distribute or install an ad-hoc-signed app under that official identifier; local builds must remain `ZoomIt (Dev).app` with identifier `com.sysinternals.zoomitmac.dev`.

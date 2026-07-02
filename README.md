# ZoomItMac

ZoomItMac is a macOS menu-bar utility modeled after Sysinternals ZoomIt. It provides screen zoom, live zoom, drawing and typing annotations, screenshots, snips, recording, webcam picture-in-picture, and scrolling panorama capture.

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
open .build/ZoomIt.app
```

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

This produces `.build/ZoomIt.app` with the app icon, the bundled resources, and an `Info.plist` (bundle id `com.sysinternals.zoomitmac`) declaring the microphone and camera usage descriptions. The build is for the architecture of the build machine; build on Apple Silicon for Apple Silicon testers.

### Signing options

- **Distributing widely (recommended):** sign with a Developer ID Application certificate, notarize with Apple, and staple the ticket, then zip or wrap the app in a `.dmg`:

  ```sh
  codesign --deep --force --options runtime \
    --sign "Developer ID Application: Your Name (TEAMID)" .build/ZoomIt.app
  ditto -c -k --keepParent .build/ZoomIt.app ZoomIt.zip
  xcrun notarytool submit ZoomIt.zip --apple-id you@example.com \
    --team-id TEAMID --password APP_SPECIFIC_PASSWORD --wait
  xcrun stapler staple .build/ZoomIt.app
  ```

  A notarized app opens with a normal double-click and keeps its Screen Recording permission across updates.

- **Quick internal testing (unsigned/ad-hoc):** if you skip notarization, Gatekeeper blocks the app on other Macs. Testers can clear the quarantine flag after copying it to `/Applications`:

  ```sh
  xattr -dr com.apple.quarantine /Applications/ZoomIt.app
  open /Applications/ZoomIt.app
  ```

  Note that rebuilding an ad-hoc/unsigned app can reset its Screen Recording permission, so testers may need to re-grant it after an update.

### First run

1. Move `ZoomIt.app` to `/Applications` and open it. It runs as a menu-bar item (no Dock icon).
2. macOS prompts for **Screen Recording** the first time a capture feature is used; grant it in System Settings ▸ Privacy & Security ▸ Screen Recording, then relaunch ZoomIt.
3. **Microphone** and **Camera** are only requested when those recording options are enabled.
4. Use the menu-bar icon or the default hotkeys above to drive the app, and the Settings dialog to customize shortcuts and behavior.

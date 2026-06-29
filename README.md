# ZoomItMac

ZoomItMac is a macOS utility modeled after Sysinternals ZoomIt. It provides static zoom over a frozen screen capture, interactive live zoom of the running screen, draw-without-zoom, on-screen drawing and typing annotations, and runs as a configurable menu-bar app.

## Current Status

- Menu-bar app shell with the ZoomIt icon (a black template version of the Windows icon).
- Static zoom over a frozen capture, and interactive live zoom of the running screen.
- Draw-without-zoom mode that annotates the current screen at 1×.
- Smooth telescoping zoom-in/zoom-out animations (ZoomIt's 1.1x/0.8x step model).
- ScreenCaptureKit single-display capture, plus a live capture stream for live zoom.
- AppKit full-screen overlay window with Core Graphics canvas rendering.
- Drawing tools: pen, line, rectangle, ellipse, arrow (with arrowhead), and highlighter, with undo and erase.
- Text annotations in typing mode.
- Configurable global hotkeys (Carbon `RegisterEventHotKey`): zoom (`Control+1`), draw-without-zoom (`Control+2`), and live zoom (`Control+4`).
- Screenshot save/copy of the zoomed viewport (`Command+S` / `Command+C`) and a region snip (`Control+6` / `Control+Shift+6`) to the clipboard or a file.
- Screen recording to MP4 (`Control+5` whole screen / `Control+Shift+5` region) with optional system audio, microphone, and a webcam picture-in-picture overlay.
- Optional launch at login.

## Requirements

- macOS 14 or newer.
- Xcode command-line tools.
- Screen Recording permission for capture.

## Build

```sh
swift build
```

## Test

```sh
swift run ZoomItMacSelfTest
```

The self-test validates viewport zoom math, coordinate mapping, drawing annotation lifecycle, undo/clear behavior, typing annotation edits, and offscreen drawing rendering.

## Run

```sh
swift run ZoomIt
```

The app appears as a menu-bar item showing the ZoomIt icon. Press the global hotkey (default `Control+1`) or use the menu to start static zoom. Live zoom (default `Control+4`) magnifies the live screen instead of a frozen snapshot. The hotkeys are configurable in Settings. The executable form is useful for development; a later packaging pass should produce a signed and notarized `.app` bundle.

## Settings

Open the **Settings…** item from the menu-bar menu (or `Command+,`) to configure ZoomIt. The window mirrors the Windows ZoomIt options dialog with tabbed panes, includes the same kind of descriptive help text on each tab, and shows a `Sysinternals ZoomIt` version/copyright footer. Changes are saved immediately to `UserDefaults`:

- **General**: launch ZoomIt at login (requires the bundled `.app`; see Packaging).
- **Zoom**: the global zoom-toggle hotkey (click the button and type a new shortcut), the live-zoom hotkey (default `Control+4`), initial magnification level (`1.25×`–`4×`), animate zoom in/out, and smooth (interpolated) zoomed image.
- **Draw**: the global draw-without-zoom hotkey (default `Control+2`) and default pen width. The pen color is chosen dynamically while drawing (R/G/B/O/Y/P/W/K), so it is not a setting.
- **Type**: typing-mode font (family and size) via the standard macOS font panel.
- **Snip**: the global region-snip hotkey (default `Control+6`), and a description of the save/copy shortcuts.
- **Record**: the global recording hotkey (default `Control+5`), capture-system-audio and capture-microphone options, microphone device selection, webcam overlay options, and instructions.

### Choosing a hotkey

The default is `Control+1` — the closest analog to Windows ZoomIt's `Ctrl+1` that is free on a stock macOS install (the `Control`+digit Mission Control desktop shortcuts are disabled by default). If you prefer a combination that can never collide, `Control+Option+1` is a safe left-hand chord. Avoid `Command+1` and `Option+1`, which are widely used or type characters.

## Overlay Shortcuts

### Zoom mode

- `Esc`: exit overlay.
- Left click: enter drawing mode (shows the pen cursor; does not draw).
- `Option+Up`: zoom in one level (snaps to 2×, then doubles up to 32×, matching Windows ZoomIt).
- `Option+Down`: zoom out one level (halves above 2×, then eases out to 1×); exits the overlay once at 1×.
- `Shift+Up` / `Shift+Down`: increase/decrease pen width.
- Mouse wheel: zoom in/out using the same steps as `Option+Up` / `Option+Down`.
- `Command+S`: save the entire viewport to a PNG file (Save dialog).
- `Command+C`: copy the entire viewport to the clipboard.
- Moving the mouse pans the zoomed view. The system cursor stays hidden while the overlay is on screen.

### Live zoom mode

Live zoom (default `Control+4`) behaves like zoom mode but the magnified content keeps updating, so motion, video, and live UI stay visible while zoomed.

- While not drawing, live zoom is **interactive**: the overlay is click-through and the real cursor stays visible, so you can keep using the system normally while the magnified view follows the cursor.
- `Option+Up` / `Option+Down`: zoom in / out (registered globally while live zoom is active; `Control+Up/Down` can't be used because macOS reserves them for Mission Control / App Exposé).
- `Control+1` or `Control+2`: toggle drawing mode on the live view without changing magnification. While drawing, the overlay captures input; `Control+1`/`Control+2` or `Esc` leaves drawing mode and returns to interactive live zoom. Annotations stay anchored in screen-content coordinates while the live image updates beneath them.
- `Control+4` exits live zoom.

Unlike Windows ZoomIt — which uses the system Magnification API — macOS exposes no equivalent third-party live-magnification API. ZoomItMac instead composites a live ScreenCaptureKit stream of the display into the overlay (with the overlay excluded from its own capture). Because the magnifier centers on the cursor (the point under the cursor maps to itself), clicks pass through to what is visually under the cursor; accuracy is best toward the center of the screen and degrades slightly near the edges where the zoom region clamps.

### Drawing mode

- Press and hold the left button to draw with the current tool; release to return to the pen cursor.
- Shape gestures (hold the modifier while dragging, matching Windows ZoomIt):
  - `Ctrl`: rectangle.
  - `Shift`: straight line.
  - `Ctrl+Shift`: arrow.
  - `Tab`: ellipse.
  - No modifier: freehand pen (or the keyboard-selected tool).
- Mouse wheel or `Shift+Up` / `Shift+Down`: resize the pen.
- `K` / `W`: blank the screen black / white (sketch pad); press the same key again to restore the live view.
- Panning is disabled while in drawing mode.
- Right click: leave drawing mode and return to zoom mode.
- `Esc`: exit overlay.

### Tools and colors

- `T`: enter typing mode (`Shift+T` enters right-justified). Type to place text; `Esc` leaves typing mode.
- In typing mode, `Up` / `Down` grow/shrink the font size.
- `Command+Z`: undo last annotation.
- `E`: erase all annotations.
- `R/G/B/Y/O/P/W/K`: set red, green, blue, yellow, orange, pink, white, black (in drawing mode, `W`/`K` blank the screen instead — see above).
- `Shift`+color (e.g. `Shift+R`): draw with a translucent highlighter of that color (50% opacity, matching Windows ZoomIt); press the color without Shift to return to a solid pen.
- `F/L/A/H`: set freehand pen, line, arrow, highlighter.
- `[` / `]`: decrease/increase pen width.

## Screenshots and Snip

- While zoomed, `Command+S` saves the entire viewport to a PNG file and `Command+C` copies it to the clipboard.
- The region snip works any time (default `Control+6`): press the shortcut, then drag a rectangle over the screen. Releasing the drag copies the selected region to the clipboard; holding `Shift` with the shortcut (`Control+Shift+6`) saves it to a PNG file instead. `Esc` cancels.
- Saved images are PNG files named `ZoomIt YYYY-MM-DD HHMMSS.png`. The snip hotkey is configurable on the Settings **Snip** tab.

## Recording

- `Control+5` records the whole screen to an MP4; `Control+Shift+5` lets you drag a rectangle and records just that region. Press the shortcut again to stop, then choose where to save the recording (named `ZoomIt YYYY-MM-DD HHMMSS.mp4`). While recording, the menu-bar icon turns into a red record indicator and an orange border outlines the recorded area (the whole screen or the selected region). The border is click-through and excluded from the capture, so it isn't part of the recording.
- Enable **Capture system audio** to record what you hear (via ScreenCaptureKit) and **Capture microphone** with a device selection to also record your voice. The recording hotkey and audio options are on the Settings **Record** tab.
- Zooming and drawing stay available while recording — start a recording, then use static zoom (`Control+1`) and draw-without-zoom (`Control+2`) and your annotations are captured in the recording. (Live zoom is excluded from its own capture, so it isn't recorded.)
- Enable the webcam picture-in-picture from the Settings **Record** tab to overlay your camera in a corner of the recorded area while recording. For region recordings the overlay is placed inside the selected region (and scaled to fit). Pick the camera, corner, size, and border shape (rectangle, rounded rectangle, rounded square, or circle — shape is ignored at full-screen size) from the webcam overlay controls on the **Record** tab. The overlay shows only while recording and is captured into the video; the camera permission is requested when you enable it (or grantable from **Check Permissions**).
- Recording uses ScreenCaptureKit for video, system audio, and (on macOS 15+) the microphone — all on the same capture clock so the audio stays in sync. On macOS 14 the microphone falls back to `AVCaptureSession`. Audio is muxed to MP4 with `AVAssetWriter`. The microphone permission can be granted from the **Check Permissions** menu item (alongside Screen Recording) or by enabling **Capture microphone** in Settings, which prompts for access. The executable embeds an `Info.plist` with `NSMicrophoneUsageDescription` so the prompt works even when run as a bare binary. Note: system audio and microphone are written as separate tracks, so if you enable both, a player may play only the first — enable just the microphone to hear your voice.

## Next Implementation Steps

1. Add precise screen-coordinate annotation anchoring so drawings stay stable across zoom and pan changes.
2. Add permission onboarding UI instead of alert-only prompting.
3. Add multi-display selection and handling for live and static zoom.
4. Add `.app` bundle packaging with privacy strings and hardened runtime signing settings (also required for launch at login to function).
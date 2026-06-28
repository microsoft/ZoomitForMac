# ZoomItMac

ZoomItMac is the initial implementation scaffold for a macOS utility modeled after Sysinternals ZoomIt. The first milestone focuses on static zoom over a frozen display image with drawing and typing annotations.

## Current Status

- Menu-bar app shell.
- Static zoom command path.
- Smooth telescoping zoom-in/zoom-out animations (ZoomIt's 1.1x/0.8x step model).
- ScreenCaptureKit single-display capture abstraction.
- AppKit full-screen overlay window.
- Core Graphics canvas rendering.
- Basic drawing tools: pen, line, rectangle, ellipse, arrow (with arrowhead), and highlighter.
- Basic text annotations in typing mode.
- Local and global key observation for `Command+Shift+1`.

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

The app appears as a menu-bar item titled `ZoomIt`. Press the global hotkey (default `Control+1`) or use the menu to start static zoom. The hotkey is configurable in Settings. The executable form is useful for development; a later packaging pass should produce a signed and notarized `.app` bundle.

## Settings

Open the **Settings…** item from the menu-bar menu (or `Command+,`) to configure ZoomIt. The window mirrors the Windows ZoomIt options dialog with tabbed panes, includes the same kind of descriptive help text on each tab, and shows a `Sysinternals ZoomIt` version/copyright footer. Changes are saved immediately to `UserDefaults`:

- **General**: launch ZoomIt at login (requires the bundled `.app`; see Packaging).
- **Zoom**: the global zoom-toggle hotkey (click the button and type a new shortcut), initial magnification level (`1.25×`–`4×`), animate zoom in/out, and smooth (interpolated) zoomed image.
- **Draw**: the global draw-without-zoom hotkey (default `Control+2`) and default pen width. The pen color is chosen dynamically while drawing (R/G/B/O/Y/P/W/K), so it is not a setting.
- **Type**: typing-mode font (family and size) via the standard macOS font panel.

### Choosing a hotkey

The default is `Control+1` — the closest analog to Windows ZoomIt's `Ctrl+1` that is free on a stock macOS install (the `Control`+digit Mission Control desktop shortcuts are disabled by default). If you prefer a combination that can never collide, `Control+Option+1` is a safe left-hand chord. Avoid `Command+1` and `Option+1`, which are widely used or type characters.

## Overlay Shortcuts

### Zoom mode

- `Esc`: exit overlay.
- Left click: enter drawing mode (shows the pen cursor; does not draw).
- `Up`: zoom in one level (snaps to 2×, then doubles up to 32×, matching Windows ZoomIt).
- `Down`: zoom out one level (halves above 2×, then eases out to 1×); exits the overlay once at 1×.
- `Shift+Up` / `Shift+Down`: increase/decrease pen width.
- Mouse wheel: zoom in/out using the same steps as `Up` / `Down`.
- Moving the mouse pans the zoomed view. The system cursor stays hidden while the overlay is on screen.

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
- `Command+C`: clear annotations.
- `R/G/B/Y/O/P/W/K`: set red, green, blue, yellow, orange, pink, white, black (in drawing mode, `W`/`K` blank the screen instead — see above).
- `F/L/A/E/H`: set freehand pen, line, arrow, ellipse, highlighter.
- `[` / `]`: decrease/increase pen width.

## Next Implementation Steps

1. Replace global key observation with a real configurable global hotkey registration/event tap layer.
2. Add precise screen-coordinate annotation anchoring so drawings stay stable across zoom and pan changes.
3. Add arrowhead rendering and rectangle shortcut mapping.
4. Add permission onboarding UI instead of alert-only prompting.
5. Add tests for viewport math and display coordinate conversion.
6. Add `.app` bundle packaging with privacy strings and hardened runtime signing settings.
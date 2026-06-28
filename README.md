# ZoomItMac

ZoomItMac is the initial implementation scaffold for a macOS utility modeled after Sysinternals ZoomIt. The first milestone focuses on static zoom over a frozen display image with drawing and typing annotations.

## Current Status

- Menu-bar app shell.
- Static zoom command path.
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
- Accessibility permission for reliable global keyboard observation.

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
swift run ZoomItMac
```

The app appears as a menu-bar item titled `ZoomIt`. Use the menu or `Command+Shift+1` to start static zoom. The executable form is useful for development; a later packaging pass should produce a signed and notarized `.app` bundle.

## Overlay Shortcuts

### Zoom mode

- `Esc`: exit overlay.
- Right click: exit overlay.
- Left click: enter drawing mode (shows the pen cursor; does not draw).
- `Up`: zoom in one level.
- `Down`: zoom out one level; exits overlay when at the default zoom level.
- `Shift+Up` / `Shift+Down`: increase/decrease pen width.
- Mouse wheel: zoom in/out.
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
- Panning is disabled while in drawing mode.
- Right click: leave drawing mode and return to zoom mode.
- `Esc`: exit overlay.

### Tools and colors

- `T`: toggle typing mode.
- `Command+Z`: undo last annotation.
- `Command+C`: clear annotations.
- `R/G/B/Y/O/P/W/K`: set red, green, blue, yellow, orange, pink, white, black.
- `F/L/A/E/H`: set freehand pen, line, arrow, ellipse, highlighter.
- `[` / `]`: decrease/increase pen width.

## Next Implementation Steps

1. Replace global key observation with a real configurable global hotkey registration/event tap layer.
2. Add precise screen-coordinate annotation anchoring so drawings stay stable across zoom and pan changes.
3. Add arrowhead rendering and rectangle shortcut mapping.
4. Add permission onboarding UI instead of alert-only prompting.
5. Add tests for viewport math and display coordinate conversion.
6. Add `.app` bundle packaging with privacy strings and hardened runtime signing settings.
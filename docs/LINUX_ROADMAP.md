# Linux Port Roadmap – ZoomIt-style Tool

## Goals

Reproduce the core ZoomIt experience on Linux (X11 + Wayland) with:

- Static zoom (frozen frame)
- Live zoom
- Full annotation set (pen, line, rect, ellipse, arrow, highlighter, text)
- Region snip + optional OCR
- Break timer
- Configurable global hotkeys
- System tray / single-instance behaviour

## Recommended Stack

| Concern              | Choice                                      | Notes |
|----------------------|---------------------------------------------|-------|
| Capture (Wayland)    | xdg-desktop-portal + PipeWire               | Standard, secure, works on GNOME/KDE/wlroots |
| Capture (X11)        | XShm / XGetImage or PipeWire where available | Fallback |
| Annotation renderer  | tiny-skia (MVP) → skia-safe + Vulkan later  | Quality + size trade-off |
| UI / Settings / Tray | iced or egui, or thin GTK                   | Keep core independent of UI toolkit |
| Hotkeys              | libinput / XGrabKey / portal where required | |
| Language             | Rust                                        | Excellent PipeWire & Skia bindings, easy FFI if needed |

## Phased Plan

### Phase 0 – Platform-agnostic core
- Port / re-implement `AppMode`, `AppCommand`, `ModeCoordinator` logic.
- Port the `Annotation` model (tools, styles, points, text).
- Unit tests that do not depend on any display server.

### Phase 1 – Capture backend
- Implement a `ScreenCapture` trait.
- Wayland path: portal request → PipeWire stream → BGRA or DMA-BUF frames.
- X11 path: simple polling or damage-driven capture.
- Cursor handling (embedded vs metadata).

### Phase 2 – Overlay + Zoom
- Full-screen (or layer-shell) overlay window.
- Viewport math (pan, zoom factor, edge clamping) – reuse the Mac math where possible.
- Static zoom first, then live zoom.

### Phase 3 – Annotations
- Map ZoomIt tools onto tiny-skia (or Skia) paths/paints.
- Undo stack, clear, colour/width shortcuts.
- Optional shape recognition later.

### Phase 4 – Polish
- Snip + clipboard / file export.
- OCR (Tesseract or similar).
- Break timer.
- Settings persistence + hotkey rebinding.
- Packaging (Flatpak, AppImage, distro packages).

## Open Questions

- Preferred UI toolkit for the settings dialog and tray icon?
- How aggressive should we be about DMA-BUF zero-copy vs simplicity?
- Do we want a pure-Rust binary or allow optional GTK/Qt for better desktop integration?

## References

- xdg-desktop-portal ScreenCast interface
- PipeWire documentation & existing Rust crates (`pipewire`, `ashpd`, `wlx-capture`, `pinray`)
- tiny-skia / skia-safe
- Existing partial ports: Zoomix, zoomme

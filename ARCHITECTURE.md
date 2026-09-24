# Architecture Analysis – ZoomIt for Mac (and Cross-Platform Path)

## Overview

Sysinternals ZoomIt for Mac is a clean, testable re-implementation of the classic Windows presentation tool. It uses a finite-state machine for modes, modern ScreenCaptureKit for capture, and a well-separated core library.

### Key Layers

| Layer              | Responsibility                                      | Main Types                                      |
|--------------------|-----------------------------------------------------|-------------------------------------------------|
| Core state machine | Mode ownership & transitions                        | `AppMode`, `ModeCoordinator`, `AppCommand`      |
| Capture            | Static/live frames, recording, snip, OCR, panorama  | `ScreenCaptureService`, `LiveCaptureSession`, `RecordingController`, `OcrService`, `PanoramaStitcher` |
| Overlay & Viewport | Full-screen windows, zoom geometry, break timer     | `OverlayWindowController`, `ZoomViewportController`, `ZoomCanvasView` |
| Annotations        | Tool model + rendering                              | `Annotation`, `AnnotationTool`, `AnnotationController` |
| Input              | Global hotkeys                                      | `HotkeyService` (Carbon)                        |
| App lifecycle      | Single-instance, permissions, settings, menu-bar    | `AppController`, `PermissionService`, `SettingsStore` |

**Strengths**
- Explicit, testable state machine.
- Pure geometry/annotation logic largely separable from AppKit.
- Built-in self-test target.
- Modern capture stack (ScreenCaptureKit).

**Platform coupling**
- Heavy reliance on AppKit, ScreenCaptureKit, Carbon hotkeys, and macOS permission model.

## Linux Path (PipeWire + Skia)

See [docs/LINUX_ROADMAP.md](docs/LINUX_ROADMAP.md) and the investigation notes below.

### PipeWire Investigation Summary

Modern Linux screen capture (especially Wayland) uses:

1. **xdg-desktop-portal** (`org.freedesktop.portal.ScreenCast`) – user consent dialog, returns a PipeWire node.
2. **PipeWire** – delivers uncompressed frames (BGRA / DMA-BUF) to the client.

Key libraries / crates examined:
- `xdg-desktop-portal` + PipeWire C API / `libpipewire`
- Rust: `ashpd` (portal), `pipewire` crate, higher-level helpers such as `wlx-capture`, `pinray`, `lamco-pipewire`
- DMA-BUF zero-copy is preferred for performance; software fallback (MemFd/MemPtr) always available.

X11 fallback remains possible via XShm / XGetImage for older environments.

### Skia Investigation Summary

Skia (and its Rust bindings) is an excellent candidate for the annotation & overlay rendering layer:

- **Full Skia** via `skia-safe` (Rust) – GPU backends (Vulkan, GL, Metal), text, advanced effects. Heavier dependency.
- **tiny-skia** – pure-Rust, CPU-only subset. Small binary, excellent quality for pens, shapes, highlighters, basic text (text still limited). Ideal for a minimal Linux MVP.
- Both support the exact drawing primitives ZoomIt needs (paths, strokes with variable width, alpha blending, shapes, arrows).

**Recommendation for Linux MVP**
- Capture: PipeWire via portal (Wayland) + X11 fallback.
- Rendering / annotations: start with `tiny-skia` (fast to integrate, tiny binary). Upgrade path to `skia-safe` + Vulkan later if GPU acceleration or rich text is required.
- UI shell: iced, egui, or a thin GTK/Qt layer for settings and tray icon.
- Keep the exact `AppMode` / command state machine so behaviour stays familiar.

## Next Concrete Steps

1. Extract platform-agnostic core (modes + annotation model) into a shared crate/library.
2. Implement Linux capture backend behind the same `ScreenCaptureService`-style trait.
3. Implement annotation renderer on top of tiny-skia (or skia-safe).
4. Add global hotkey handling (libinput / XGrab / portal RemoteDesktop where needed).
5. Ship a minimal static-zoom + draw MVP.

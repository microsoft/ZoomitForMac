# Planned Issues (Linux Port Roadmap)

> **Note:** The Issues feature is currently disabled on this repository.  
> Enable it under **Settings → General → Features → Issues**, then create the issues below (or copy the content).

---

## Issue 1 – Phase 0: Extract platform-agnostic core (AppMode + Annotation model)

**Title:** Phase 0: Extract platform-agnostic core (AppMode + Annotation model)

### Goal
Extract the mode state machine and annotation model into a platform-independent layer that can be shared between the existing macOS code and a future Linux port.

### Scope
- Port / re-implement `AppMode`, `AppCommand`, and the core of `ModeCoordinator` logic without AppKit dependencies.
- Port the `Annotation`, `AnnotationTool`, `AnnotationStyle`, and related types.
- Add unit tests that run without any display server.

### Acceptance criteria
- [ ] Pure core crate/library exists (or clearly separated module).
- [ ] Modes and transitions are fully testable offline.
- [ ] Annotation model is serializable and independent of the renderer.
- [ ] Existing Mac behaviour is not regressed.

### References
- [ARCHITECTURE.md](../ARCHITECTURE.md)
- [LINUX_ROADMAP.md](LINUX_ROADMAP.md)

**Suggested labels:** `enhancement`, `linux`, `core`

---

## Issue 2 – Phase 1: Linux screen capture backend (PipeWire + xdg-desktop-portal)

**Title:** Phase 1: Linux screen capture backend (PipeWire + xdg-desktop-portal)

### Goal
Implement a Linux screen-capture backend that matches the spirit of the Mac `ScreenCaptureService`.

### Scope
- Define a `ScreenCapture` trait (static frame + live stream).
- Wayland path: xdg-desktop-portal ScreenCast → PipeWire stream (BGRA / DMA-BUF).
- X11 fallback: XShm / XGetImage or PipeWire where available.
- Handle cursor modes (embedded / hidden / metadata) and user cancellation of the portal dialog.

### Suggested crates
- `ashpd` (portal)
- `pipewire` crate or higher-level helpers (`wlx-capture`, `pinray`, `lamco-pipewire`)

### Acceptance criteria
- [ ] Can capture a full display on Wayland via portal + PipeWire.
- [ ] Basic X11 capture works as fallback.
- [ ] Frames are delivered in a consistent format usable by the overlay/zoom layer.
- [ ] Proper error handling for permission denial / cancellation.

### References
- [PIPEWIRE_INVESTIGATION.md](PIPEWIRE_INVESTIGATION.md)
- [LINUX_ROADMAP.md](LINUX_ROADMAP.md)

**Suggested labels:** `enhancement`, `linux`, `capture`

---

## Issue 3 – Phase 2: Overlay window + static/live zoom on Linux

**Title:** Phase 2: Overlay window + static/live zoom on Linux

### Goal
Provide a full-screen (or layer-shell) overlay that supports static zoom and live zoom, reusing the viewport math from the Mac implementation where possible.

### Scope
- Create an overlay surface (Wayland layer-shell preferred, X11 override-redirect as fallback).
- Implement viewport geometry: pan, zoom factor, edge clamping.
- Static zoom first (frozen frame), then live zoom.
- Click-through behaviour when not drawing (where the compositor allows it).

### Acceptance criteria
- [ ] Static zoom activates and allows panning/zooming a frozen capture.
- [ ] Live zoom streams frames into the same viewport.
- [ ] Exit via hotkey / right-click / Esc works cleanly.
- [ ] Multi-monitor basics are considered (at least primary display).

### References
- [ARCHITECTURE.md](../ARCHITECTURE.md)
- [LINUX_ROADMAP.md](LINUX_ROADMAP.md)

**Suggested labels:** `enhancement`, `linux`, `overlay`

---

## Issue 4 – Phase 3: Annotation renderer with tiny-skia (Linux)

**Title:** Phase 3: Annotation renderer with tiny-skia (Linux)

### Goal
Render ZoomIt-style annotations on the Linux overlay using a lightweight, high-quality 2D engine.

### Scope
- Implement an `AnnotationRenderer` backed by **tiny-skia** (MVP).
- Map tools: pen, highlighter, line, rectangle, ellipse, arrow.
- Support colour / width shortcuts, undo stack, and clear.
- Keep the renderer behind a trait so a future `skia-safe` + Vulkan backend can be swapped in.

### Why tiny-skia?
Pure-Rust, small binary, excellent stroke quality, sufficient for the classic ZoomIt toolset. Full Skia can be added later for GPU acceleration and richer text.

### Acceptance criteria
- [ ] All core drawing tools work on the overlay.
- [ ] Undo / clear / colour & width changes are responsive.
- [ ] Annotation model remains independent of the concrete renderer.
- [ ] Performance is acceptable for interactive use on typical hardware.

### References
- [SKIA_INVESTIGATION.md](SKIA_INVESTIGATION.md)
- [LINUX_ROADMAP.md](LINUX_ROADMAP.md)

**Suggested labels:** `enhancement`, `linux`, `annotations`

---

## Issue 5 – Phase 4: Polish – snip, OCR, break timer, settings, packaging

**Title:** Phase 4: Polish – snip, OCR, break timer, settings, packaging

### Goal
Complete the Linux experience with the remaining ZoomIt features and make the tool distributable.

### Scope
- Region snip → clipboard and/or PNG file.
- Optional OCR (Tesseract or similar).
- Break timer with configurable duration / appearance.
- Settings persistence + rebindable global hotkeys.
- Single-instance behaviour and system-tray icon.
- Packaging: Flatpak, AppImage, and/or distro packages.

### Acceptance criteria
- [ ] Snip works both at 1× and while zoomed.
- [ ] Break timer is usable and survives focus changes where possible.
- [ ] Hotkeys are configurable and persist across launches.
- [ ] At least one packaging format is available for end users.

### References
- [LINUX_ROADMAP.md](LINUX_ROADMAP.md)
- Original Mac feature set in README

**Suggested labels:** `enhancement`, `linux`, `polish`

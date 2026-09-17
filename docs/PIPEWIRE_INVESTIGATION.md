# PipeWire Screen Capture Investigation

## Why PipeWire?

On modern Linux (especially Wayland) the only supported, secure way to capture the screen is:

1. Ask the user via **xdg-desktop-portal** (`org.freedesktop.portal.ScreenCast`).
2. Receive a **PipeWire** node that streams frames.

This is the same path used by OBS, browsers (WebRTC), Discord, etc.

## Key Components

- **Portal**: Shows the monitor/window picker, returns a file descriptor + node ID (or serial).
- **PipeWire stream**: Delivers frames in BGRA (or other formats) either as:
  - Memory-mapped buffers (MemFd / MemPtr)
  - DMA-BUF (zero-copy GPU buffers) – preferred for performance.

## Useful Libraries / Crates

| Project              | Language | Notes |
|----------------------|----------|-------|
| ashpd                | Rust     | High-level portal client |
| pipewire crate       | Rust     | Low-level PipeWire bindings |
| wlx-capture          | Rust     | PipeWire + wlr-dmabuf + XShm |
| pinray               | Rust     | Cross-platform (PipeWire/X11, ScreenCaptureKit, DXGI…) |
| lamco-pipewire       | Rust     | DMA-BUF focused, damage tracking |
| libscreencapture-wayland | C++  | Portal + PipeWire modules |

## Practical Notes

- Always handle user cancellation of the portal dialog.
- Prefer the newer `pipewire-serial` property over raw node IDs (nodes can be reused).
- Cursor can be requested as embedded, hidden, or metadata.
- Restore tokens can skip the dialog on subsequent launches (when the portal supports it).
- For X11 sessions a simpler XShm path is still valuable as a fallback.

## Recommendation for ZoomIt Linux

Implement a trait similar to the Mac `ScreenCaptureService`:

```rust
trait ScreenCapture {
    async fn capture_display(...) -> Result<CapturedFrame>;
    // plus live stream variant
}
```

Wayland implementation uses portal + PipeWire; X11 uses a polling or damage-based backend. Higher-level crates such as `pinray` or `wlx-capture` can accelerate the work significantly.

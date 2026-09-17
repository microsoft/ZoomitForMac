# ZoomIt Linux Scaffold

Early platform-agnostic core + capture abstraction for a Linux port of ZoomIt.

## Crates

| Crate | Purpose |
|-------|---------|
| `zoomit-core` | Modes (`AppMode`, `AppCommand`, `ModeCoordinator`) + annotation model |
| `zoomit-capture` | `ScreenCapture` trait, Portal+PipeWire skeleton, X11 placeholder |

## PipeWire integration (detailed)

See the source comments in `linux-capture/src/portal.rs` and the investigation doc:

- Flow: **xdg-desktop-portal ScreenCast → user consent → PipeWire node → BGRA / DMA-BUF frames**
- Enable real backend later with feature flag: `pipewire` (pulls in `ashpd` + tokio)
- Recommended supporting crates: `ashpd`, `pipewire`, optionally `wlx-capture` / `pinray`

## Build

```sh
cd linux
cargo test -p zoomit-core
cargo test -p zoomit-capture
```

The capture tests currently assert the stub returns `Unsupported` so the workspace builds on any host without libpipewire.

## Related issues

- #1 Phase 0 – core extraction
- #2 Phase 1 – PipeWire capture
- #3–#5 Overlay, annotations, polish

## Docs

- [ARCHITECTURE.md](../ARCHITECTURE.md)
- [docs/PIPEWIRE_INVESTIGATION.md](../docs/PIPEWIRE_INVESTIGATION.md)
- [docs/SKIA_INVESTIGATION.md](../docs/SKIA_INVESTIGATION.md)
- [docs/LINUX_ROADMAP.md](../docs/LINUX_ROADMAP.md)

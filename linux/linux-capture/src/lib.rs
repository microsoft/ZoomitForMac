//! Screen capture abstraction for ZoomIt Linux.
//!
//! ## Architecture
//!
//! ```text
//! ScreenCapture trait
//! ├── PortalPipeWireCapture  (Wayland – xdg-desktop-portal + PipeWire)
//! └── X11Capture             (X11 fallback – placeholder)
//! ```
//!
//! The Mac `ScreenCaptureService` maps cleanly onto this trait.
//! See docs/PIPEWIRE_INVESTIGATION.md for the full investigation.

pub mod frame;
pub mod traits;
pub mod portal;
pub mod x11;

pub use frame::{CapturedFrame, PixelFormat};
pub use traits::ScreenCapture;
pub use portal::PortalPipeWireCapture;
pub use x11::X11Capture;

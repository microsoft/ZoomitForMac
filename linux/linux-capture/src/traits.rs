//! Capture trait – mirrors the macOS ScreenCaptureService idea.

use crate::frame::CapturedFrame;
use async_trait::async_trait;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum CaptureError {
    #[error("display not found")]
    DisplayNotFound,
    #[error("permission denied or user cancelled portal dialog")]
    PermissionDenied,
    #[error("PipeWire stream failed: {0}")]
    PipeWire(String),
    #[error("X11 capture failed: {0}")]
    X11(String),
    #[error("unsupported platform or missing feature")]
    Unsupported,
    #[error(transparent)]
    Other(#[from] Box<dyn std::error::Error + Send + Sync>),
}

/// Common interface for all capture backends.
///
/// Implementations:
/// - [`crate::portal::PortalPipeWireCapture`] – Wayland via xdg-desktop-portal + PipeWire
/// - [`crate::x11::X11Capture`] – X11 fallback
#[async_trait]
pub trait ScreenCapture: Send + Sync {
    /// Capture a single frozen frame of the given display.
    async fn capture_display(&self, display_id: u32) -> Result<CapturedFrame, CaptureError>;

    /// Start a live stream (optional – not all backends need it for MVP).
    async fn start_live(&self, _display_id: u32) -> Result<(), CaptureError> {
        Err(CaptureError::Unsupported)
    }

    /// Stop any live stream.
    async fn stop_live(&self) -> Result<(), CaptureError> {
        Ok(())
    }
}

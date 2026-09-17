//! Wayland capture via xdg-desktop-portal + PipeWire.
//!
//! ## Flow
//! 1. Create a ScreenCast session through the portal (`ashpd` crate).
//! 2. Select sources (monitor / window) – user sees the system picker.
//! 3. Start the session → receive PipeWire node id / fd.
//! 4. Connect a PipeWire stream and pull BGRA (or DMA-BUF) frames.
//!
//! This module provides a complete skeleton. Enable the `pipewire` feature
//! and fill in the real PipeWire stream handling when `libpipewire` is available.

use crate::frame::CapturedFrame;
use crate::traits::{CaptureError, ScreenCapture};
use async_trait::async_trait;

/// Portal + PipeWire capture backend.
///
/// When the `pipewire` feature is disabled this is a documented stub that
/// returns `CaptureError::Unsupported` so the rest of the code compiles
/// on any host.
pub struct PortalPipeWireCapture {
    /// Preferred cursor mode: Embedded / Hidden / Metadata.
    pub cursor_embedded: bool,
}

impl Default for PortalPipeWireCapture {
    fn default() -> Self {
        Self {
            cursor_embedded: true,
        }
    }
}

impl PortalPipeWireCapture {
    pub fn new() -> Self {
        Self::default()
    }

    /// High-level description of the intended portal flow (for documentation
    /// and future implementation).
    ///
    /// ```ignore
    /// // Pseudo-code of the real implementation (feature = "pipewire"):
    /// let proxy = ashpd::desktop::screencast::ScreenCast::new().await?;
    /// let session = proxy.create_session().await?;
    /// proxy.select_sources(&session, /* monitor + cursor options */).await?;
    /// let streams = proxy.start(&session, /* parent window */).await?;
    /// // streams[0] contains node_id / pipewire fd
    /// // then connect libpipewire / pipewire crate and pull frames
    /// ```
    pub fn describe_flow() -> &'static str {
        "xdg-desktop-portal ScreenCast → user consent → PipeWire node → BGRA/DMA-BUF frames"
    }
}

#[async_trait]
impl ScreenCapture for PortalPipeWireCapture {
    async fn capture_display(&self, _display_id: u32) -> Result<CapturedFrame, CaptureError> {
        #[cfg(feature = "pipewire")]
        {
            // TODO: real implementation
            // 1. ashpd ScreenCast session
            // 2. select_sources + start
            // 3. open PipeWire remote, negotiate format
            // 4. pull one frame into CapturedFrame
            Err(CaptureError::Unsupported)
        }
        #[cfg(not(feature = "pipewire"))]
        {
            Err(CaptureError::Unsupported)
        }
    }

    async fn start_live(&self, _display_id: u32) -> Result<(), CaptureError> {
        // Same portal session can be kept open for a continuous stream.
        Err(CaptureError::Unsupported)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn stub_returns_unsupported() {
        let cap = PortalPipeWireCapture::new();
        let err = cap.capture_display(0).await.unwrap_err();
        assert!(matches!(err, CaptureError::Unsupported));
    }

    #[test]
    fn flow_description() {
        assert!(PortalPipeWireCapture::describe_flow().contains("PipeWire"));
    }
}

//! X11 capture fallback (placeholder).
//!
//! Real implementation can use XShm / XGetImage or the X11 path of
//! libraries such as `wlx-capture` / `pinray`.

use crate::frame::CapturedFrame;
use crate::traits::{CaptureError, ScreenCapture};
use async_trait::async_trait;

pub struct X11Capture;

impl X11Capture {
    pub fn new() -> Self {
        Self
    }
}

impl Default for X11Capture {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl ScreenCapture for X11Capture {
    async fn capture_display(&self, _display_id: u32) -> Result<CapturedFrame, CaptureError> {
        // Placeholder – return Unsupported until an X11 backend is wired.
        Err(CaptureError::Unsupported)
    }
}

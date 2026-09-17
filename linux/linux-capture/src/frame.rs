//! Captured frame representation.

use std::time::SystemTime;

/// Pixel layout of the frame buffer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PixelFormat {
    /// 8-bit BGRA (common PipeWire output)
    Bgra8,
    /// 8-bit RGBA
    Rgba8,
}

/// A single captured frame from a display.
#[derive(Debug, Clone)]
pub struct CapturedFrame {
    /// Raw pixel data (row-major).
    pub data: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub format: PixelFormat,
    /// Logical display identifier (for multi-monitor).
    pub display_id: u32,
    pub timestamp: SystemTime,
}

impl CapturedFrame {
    pub fn new(width: u32, height: u32, format: PixelFormat, data: Vec<u8>) -> Self {
        Self {
            data,
            width,
            height,
            format,
            display_id: 0,
            timestamp: SystemTime::now(),
        }
    }

    pub fn bytes_per_pixel(&self) -> usize {
        match self.format {
            PixelFormat::Bgra8 | PixelFormat::Rgba8 => 4,
        }
    }
}

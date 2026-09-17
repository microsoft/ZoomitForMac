//! Platform-agnostic core for ZoomIt-style presentation tools.
//!
//! Contains the mode state machine and annotation model that can be shared
//! between the existing macOS implementation and a future Linux port.

pub mod mode;
pub mod annotation;

pub use mode::{AppMode, AppCommand};
pub use annotation::{Annotation, AnnotationTool, AnnotationColor, AnnotationStyle};

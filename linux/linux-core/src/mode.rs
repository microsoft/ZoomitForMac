//! Finite-state machine for ZoomIt modes.
//! Mirrors the macOS `AppMode` / `AppCommand` design.

use serde::{Deserialize, Serialize};

/// High-level application mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AppMode {
    Idle,
    StaticZoom,
    DrawOnly,
    Typing,
    LiveZoom,
    CaptureSelection,
    PanoramaCapture,
    Recording,
    BreakTimer,
}

/// Commands that drive mode transitions and actions.
#[derive(Debug, Clone, PartialEq)]
pub enum AppCommand {
    ActivateStaticZoom,
    ActivateLiveZoom,
    ActivateDrawWithoutZoom,
    ZoomIn,
    ZoomOutOrExit,
    ToggleRecording { region: bool },
    StartPanorama { save: bool },
    ToggleBreakTimer,
    SnipRegion { save: bool },
    OcrRegion,
    Exit,
}

/// Minimal coordinator that tracks the current mode.
/// Platform-specific code (overlay, capture, hotkeys) reacts to mode changes.
#[derive(Debug, Default)]
pub struct ModeCoordinator {
    mode: AppMode,
}

impl ModeCoordinator {
    pub fn new() -> Self {
        Self { mode: AppMode::Idle }
    }

    pub fn mode(&self) -> AppMode {
        self.mode
    }

    /// Apply a command and return the new mode (if it changed).
    pub fn handle(&mut self, cmd: AppCommand) -> AppMode {
        let next = match (&self.mode, cmd) {
            (_, AppCommand::Exit) => AppMode::Idle,

            (AppMode::Idle, AppCommand::ActivateStaticZoom) => AppMode::StaticZoom,
            (AppMode::Idle, AppCommand::ActivateLiveZoom) => AppMode::LiveZoom,
            (AppMode::Idle, AppCommand::ActivateDrawWithoutZoom) => AppMode::DrawOnly,
            (AppMode::Idle, AppCommand::ToggleBreakTimer) => AppMode::BreakTimer,
            (AppMode::Idle, AppCommand::ToggleRecording { .. }) => AppMode::Recording,
            (AppMode::Idle, AppCommand::StartPanorama { .. }) => AppMode::PanoramaCapture,
            (AppMode::Idle, AppCommand::SnipRegion { .. }) => AppMode::CaptureSelection,
            (AppMode::Idle, AppCommand::OcrRegion) => AppMode::CaptureSelection,

            (AppMode::StaticZoom | AppMode::LiveZoom | AppMode::DrawOnly, AppCommand::ZoomOutOrExit) => {
                AppMode::Idle
            }
            (AppMode::BreakTimer, AppCommand::ToggleBreakTimer) => AppMode::Idle,
            (AppMode::Recording, AppCommand::ToggleRecording { .. }) => AppMode::Idle,

            // Stay in current mode for unhandled combinations
            (current, _) => *current,
        };
        self.mode = next;
        next
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn starts_idle() {
        let c = ModeCoordinator::new();
        assert_eq!(c.mode(), AppMode::Idle);
    }

    #[test]
    fn activate_static_zoom() {
        let mut c = ModeCoordinator::new();
        assert_eq!(c.handle(AppCommand::ActivateStaticZoom), AppMode::StaticZoom);
        assert_eq!(c.handle(AppCommand::ZoomOutOrExit), AppMode::Idle);
    }

    #[test]
    fn break_timer_toggle() {
        let mut c = ModeCoordinator::new();
        assert_eq!(c.handle(AppCommand::ToggleBreakTimer), AppMode::BreakTimer);
        assert_eq!(c.handle(AppCommand::ToggleBreakTimer), AppMode::Idle);
    }
}

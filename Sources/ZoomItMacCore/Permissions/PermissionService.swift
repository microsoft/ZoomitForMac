import AppKit
import AVFoundation

struct PermissionStatus: Equatable {
    var isGranted: Bool
}

/// Tri-state microphone permission, matching the system's authorization states.
enum MicrophonePermission: Equatable {
    case granted
    case denied
    case notDetermined
}

struct PermissionState: Equatable {
    var screenCapture: PermissionStatus
}

protocol PermissionService {
    func currentState() -> PermissionState
    func requestScreenCaptureAccess()
    func openSystemSettings()
    func microphoneStatus() -> MicrophonePermission
    func requestMicrophoneAccess(completion: (@MainActor @Sendable () -> Void)?)
    func openMicrophoneSettings()
    func cameraStatus() -> MicrophonePermission
    func requestCameraAccess(completion: (@MainActor @Sendable () -> Void)?)
    func openCameraSettings()
}

final class SystemPermissionService: PermissionService {
    func currentState() -> PermissionState {
        PermissionState(
            screenCapture: PermissionStatus(isGranted: CGPreflightScreenCaptureAccess())
        )
    }

    func requestScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func microphoneStatus() -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        default:
            return .denied
        }
    }

    func requestMicrophoneAccess(completion: (@MainActor @Sendable () -> Void)? = nil) {
        // Safe because the executable embeds an NSMicrophoneUsageDescription.
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            guard let completion else { return }
            Task { @MainActor in completion() }
        }
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    func cameraStatus() -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        default:
            return .denied
        }
    }

    func requestCameraAccess(completion: (@MainActor @Sendable () -> Void)? = nil) {
        // Safe because the executable embeds an NSCameraUsageDescription.
        AVCaptureDevice.requestAccess(for: .video) { _ in
            guard let completion else { return }
            Task { @MainActor in completion() }
        }
    }

    func openCameraSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Shared UI for the required Screen Recording permission. Used both at startup
/// and whenever a capture action is invoked without the permission, so the app
/// explains what is needed instead of silently doing nothing.
@MainActor
enum ScreenRecordingPrompt {
    /// Returns true if Screen Recording is granted. Otherwise it registers the
    /// app with the system, shows an explanatory alert offering to open the
    /// relevant Settings pane, and returns false.
    @discardableResult
    static func ensureGranted(_ service: PermissionService) -> Bool {
        if service.currentState().screenCapture.isGranted { return true }

        // Trigger the system prompt so ZoomIt is added to the Screen Recording
        // list even if the user dismisses the dialog below.
        service.requestScreenCaptureAccess()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Recording Permission Needed"
        alert.informativeText = """
        ZoomIt needs Screen Recording permission to zoom, snip, record, and capture panoramas.

        Enable ZoomIt under System Settings ▸ Privacy & Security ▸ Screen Recording, then relaunch ZoomIt.

        Microphone and Camera are optional and are requested only when you use voice or webcam recording.
        """
        alert.addButton(withTitle: "Open Settings…")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            service.openSystemSettings()
        }
        return false
    }
}

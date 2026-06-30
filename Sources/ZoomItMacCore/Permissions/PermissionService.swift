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
    func requestScreenCaptureAccess() -> Bool
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

    func requestScreenCaptureAccess() -> Bool {
        CGRequestScreenCaptureAccess()
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

/// Shared gate for the required Screen Recording permission. Capture hotkeys use
/// only the macOS permission prompt here; ZoomIt's explanatory UI lives in the
/// explicit Check Permissions command.
@MainActor
enum ScreenRecordingPrompt {
    /// Returns true if Screen Recording is granted. Otherwise it asks macOS to
    /// request/register the permission and returns false.
    @discardableResult
    static func ensureGranted(_ service: PermissionService) -> Bool {
        if service.currentState().screenCapture.isGranted { return true }
        _ = service.requestScreenCaptureAccess()
        return false
    }
}

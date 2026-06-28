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
    func requestMicrophoneAccess()
    func openMicrophoneSettings()
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

    func requestMicrophoneAccess() {
        // Safe because the executable embeds an NSMicrophoneUsageDescription.
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
}
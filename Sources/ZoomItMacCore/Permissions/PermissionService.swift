import AppKit
import ApplicationServices

struct PermissionStatus: Equatable {
    var isGranted: Bool
}

struct PermissionState: Equatable {
    var screenCapture: PermissionStatus
    var accessibility: PermissionStatus
}

protocol PermissionService {
    func currentState() -> PermissionState
    func requestScreenCaptureAccess()
    func requestAccessibilityAccess()
    func openSystemSettings()
}

final class SystemPermissionService: PermissionService {
    func currentState() -> PermissionState {
        PermissionState(
            screenCapture: PermissionStatus(isGranted: CGPreflightScreenCaptureAccess()),
            accessibility: PermissionStatus(isGranted: AXIsProcessTrusted())
        )
    }

    func requestScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
    }

    func requestAccessibilityAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
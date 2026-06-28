import AppKit

struct PermissionStatus: Equatable {
    var isGranted: Bool
}

struct PermissionState: Equatable {
    var screenCapture: PermissionStatus
}

protocol PermissionService {
    func currentState() -> PermissionState
    func requestScreenCaptureAccess()
    func openSystemSettings()
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
}
import Darwin
import Foundation

@MainActor
enum SingleInstance {
    static let showSettingsNotification = Notification.Name("com.sysinternals.zoomitmac.showSettings")

    private static var lockFileDescriptor: CInt = -1

    static func claimOrActivateExisting() -> Bool {
        let lockURL = lockFileURL()
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return true }

        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFileDescriptor = fd
            return true
        }

        close(fd)
        DistributedNotificationCenter.default().postNotificationName(
            showSettingsNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        return false
    }

    static func release() {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    private static func lockFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ZoomIt", isDirectory: true).appendingPathComponent("ZoomIt.lock")
    }
}
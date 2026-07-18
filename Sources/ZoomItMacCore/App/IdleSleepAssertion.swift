import Foundation
import IOKit.pwr_mgt

/// Prevents the display from idle-sleeping — and therefore the screen saver
/// from starting — while held. Windows ZoomIt keeps the screen saver from
/// kicking in during the break timer; this is the macOS equivalent using an
/// `IOPMAssertion`.
///
/// The IOKit calls are injectable so the begin/end lifecycle can be unit
/// tested without touching real power management.
final class IdleSleepAssertion {
    private let create: (String) -> IOPMAssertionID?
    private let release: (IOPMAssertionID) -> Void
    private var assertionID: IOPMAssertionID?

    /// True while the assertion is held (display sleep / screen saver blocked).
    var isActive: Bool { assertionID != nil }

    init(
        create: @escaping (String) -> IOPMAssertionID? = IdleSleepAssertion.systemCreate,
        release: @escaping (IOPMAssertionID) -> Void = IdleSleepAssertion.systemRelease
    ) {
        self.create = create
        self.release = release
    }

    deinit {
        if let assertionID {
            release(assertionID)
        }
    }

    /// Acquires the assertion if not already held. Idempotent.
    func begin(reason: String) {
        guard assertionID == nil else { return }
        assertionID = create(reason)
    }

    /// Releases the assertion if held. Idempotent.
    func end() {
        guard let assertionID else { return }
        release(assertionID)
        self.assertionID = nil
    }

    private static func systemCreate(_ reason: String) -> IOPMAssertionID? {
        var id: IOPMAssertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        return result == kIOReturnSuccess ? id : nil
    }

    private static func systemRelease(_ id: IOPMAssertionID) {
        IOPMAssertionRelease(id)
    }
}

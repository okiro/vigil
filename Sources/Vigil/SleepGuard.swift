import Foundation
import IOKit.pwr_mgt

/// Holds a single IOKit power assertion (same mechanism `caffeinate` uses).
/// Visible via: pmset -g assertions | grep Vigil
final class SleepGuard {
    private var assertionID = IOPMAssertionID(0)
    private var heldType: String?

    func update(active: Bool, display: Bool) {
        let wanted: String? = active
            ? (display ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep")
            : nil
        guard wanted != heldType else { return }

        if heldType != nil {
            IOPMAssertionRelease(assertionID)
            heldType = nil
        }
        guard let type = wanted else { return }

        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Vigil: AI agent working" as CFString,
            &newID
        )
        if result == kIOReturnSuccess {
            assertionID = newID
            heldType = type
        }
    }

    deinit { if heldType != nil { IOPMAssertionRelease(assertionID) } }
}

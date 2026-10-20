import Sparkle
import SwiftUI

/// Sparkle auto-update. The feed (SUFeedURL, written by build.sh) is the appcast.xml
/// attached to the latest GitHub release; release.sh --publish uploads it.
/// Sparkle calls the delegate on the main thread; @preconcurrency checks that at runtime.
@MainActor
final class Updater: NSObject, ObservableObject, @preconcurrency SPUStandardUserDriverDelegate {
    /// An update found by a background check that the user hasn't looked at yet.
    /// Shown in the panel instead of a window popping up over whatever they're doing.
    @Published private(set) var pendingVersion: String?

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Also brings a pending update's window to the front.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // MARK: Gentle reminders (Sparkle warns for background apps without them)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Near launch Sparkle shows its window right away; later background finds go to the panel.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { pendingVersion = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}

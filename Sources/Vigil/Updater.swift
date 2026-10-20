import Sparkle
import SwiftUI

/// Sparkle auto-update. The feed (SUFeedURL, written by build.sh) is the appcast.xml
/// attached to the latest GitHub release, which CI publishes on every push to main.
/// Sparkle calls the user driver delegate on the main thread without saying so in its
/// headers; @preconcurrency checks that at runtime.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    /// An update found by a background check that Sparkle couldn't install silently and the
    /// user hasn't looked at yet. Shown in the panel instead of a window popping up.
    @Published private(set) var pendingVersion: String?

    private var controller: SPUStandardUpdaterController!
    /// Installs a silently downloaded update and relaunches; held until Vigil is idle.
    private var installNow: (() -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    var updatesAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates && controller.updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Also brings a pending update's window to the front.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Call only while Vigil isn't keeping the Mac awake: the relaunch drops the power
    /// assertion for a moment, and a Mac that has sat idle past its sleep timer would doze off.
    func installDownloadedUpdate() {
        guard let install = installNow else { return }
        installNow = nil
        install()
    }

    // MARK: Silent install

    /// Updates download in the background (SUAutomaticallyUpdate) and would wait for a quit,
    /// which a menu-bar app rarely sees. Take them over and install at the next idle moment.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        return true
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

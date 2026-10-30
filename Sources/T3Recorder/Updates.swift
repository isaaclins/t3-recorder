import Foundation
import Sparkle

/// Sparkle looks for a new release at launch and every hour, fetches it quietly, and installs it the moment Isaac isn't
/// in the middle of something, then the app comes back by itself. Sparkle only trusts updates signed with our private key.
final class Updates: NSObject, SPUUpdaterDelegate {
    var isBusy: () -> Bool = { false }
    private var controller: SPUStandardUpdaterController?
    private var waitingInstall: (() -> Void)?
    private var retry: Timer?

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    var isAvailable: Bool { controller != nil }

    func start() {
        // Only an installed app has a feed; `swift run` and the command line checks stay without updates.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        c.updater.checkForUpdatesInBackground()
    }

    func checkNow() { controller?.checkForUpdates(nil) }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock install: @escaping () -> Void) -> Bool {
        Log.info("update \(item.displayVersionString) ready")
        waitingInstall = install
        retry = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.installIfIdle() }
        installIfIdle()
        return true
    }

    func installIfIdle() {
        guard let install = waitingInstall, !isBusy() else { return }
        waitingInstall = nil
        retry?.invalidate()
        retry = nil
        Log.info("installing update")
        install()
    }
}

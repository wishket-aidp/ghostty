import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // Phantom ships a single appcast served from its own relay, injected
        // into Info.plist as SUFeedURL at release time (scripts/release/build.sh).
        // Returning nil makes Sparkle fall back to that SUFeedURL. Upstream
        // Ghostty switched on autoUpdateChannel to hit files.ghostty.org here —
        // that would have pointed Phantom users at Ghostty's release feed.
        return nil
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: immediateInstallHandler,
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            }
        ))
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // When the updater is relaunching the application we want to get macOS
        // to invalidate and re-encode all of our restorable state so that when
        // we relaunch it uses it.
        NSApp.invalidateRestorableState()
        for window in NSApp.windows { window.invalidateRestorableState() }
    }
}

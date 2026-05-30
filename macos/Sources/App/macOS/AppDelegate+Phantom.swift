import AppKit

// MARK: - Phantom Bootstrap
//
// Phase 6 integration point. The Phantom remote-control coordinator
// (`PhantomBridge.PhantomCoordinator`) is owned by the AppDelegate for
// process lifetime and started/stopped alongside the app.
//
// The actual coordinator is brought in via the `PhantomBridge` SwiftPM
// product. Because the Ghostty Xcode project does not yet declare the
// local Swift package reference for the parent Phantom monorepo, all
// integration code is gated behind `canImport(PhantomBridge)`. The
// project currently builds and ships exactly as upstream Ghostty does;
// once the package is linked (see `macos/PhantomIntegration.md`),
// the bootstrap activates automatically.

#if canImport(PhantomBridge) && canImport(PhantomMacUI)

import PhantomBridge
import PhantomMacUI

extension AppDelegate {
    /// Process-wide Phantom coordinator. Initialised on
    /// `applicationDidFinishLaunching`, torn down on
    /// `applicationWillTerminate`.
    fileprivate static var phantomCoordinator: PhantomCoordinator?

    /// Called from `applicationDidFinishLaunching(_:)`.
    func phantomBootstrap() {
        // PhantomConfigStore persists to ~/Library/Application Support/Phantom/.
        let store = PhantomConfigStore()
        _ = store.load() // Loaded for side effects (file creation) and future
                         // wiring through to relayURL / pushEnabled / etc.

        let coordinator = PhantomCoordinator()
        AppDelegate.phantomCoordinator = coordinator

        Task {
            do {
                try await coordinator.start()
                AppDelegate.logger.info("PhantomCoordinator started")
            } catch {
                AppDelegate.logger.error("PhantomCoordinator failed to start: \(error)")
            }
        }
    }

    /// Called from `applicationWillTerminate(_:)`.
    func phantomShutdown() {
        guard let coordinator = AppDelegate.phantomCoordinator else { return }
        AppDelegate.phantomCoordinator = nil

        // Block briefly so the gateway gets a clean close. Same pattern as
        // updateController's shutdown in upstream AppDelegate.
        let sem = DispatchSemaphore(value: 0)
        Task {
            await coordinator.stop()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2.0)
    }
}

#else

extension AppDelegate {
    /// No-op stub used when `PhantomBridge` is not linked into the build.
    func phantomBootstrap() {}

    /// No-op stub used when `PhantomBridge` is not linked into the build.
    func phantomShutdown() {}
}

#endif

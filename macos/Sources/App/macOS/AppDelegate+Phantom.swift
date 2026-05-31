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
import SwiftUI

extension AppDelegate {
    /// Process-wide Phantom coordinator. Initialised on
    /// `applicationDidFinishLaunching`, torn down on
    /// `applicationWillTerminate`.
    fileprivate static var phantomCoordinator: PhantomCoordinator?

    /// Lazily created pairing window, owned by the AppDelegate so we can
    /// re-show the same instance across menu invocations rather than
    /// stacking new ones each time.
    fileprivate static var phantomPairingWindowController: NSWindowController?

    /// Strong reference to the active pairing service while the window is
    /// open. Cleared when the window closes.
    fileprivate static var phantomPairingService: MacPairingService?

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

        // Inject "Pair iPhone…" into the File menu. We do this in code so we
        // don't have to maintain a divergent MainMenu.xib against upstream.
        installPhantomPairMenuItem()
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

    // MARK: - Menu installation

    private func installPhantomPairMenuItem() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Prefer "File"; fall back to first non-app menu (index 1) if not
        // found (e.g. localization).
        let fileMenu: NSMenu? = {
            if let item = mainMenu.items.first(where: { $0.submenu?.title == "File" }) {
                return item.submenu
            }
            if mainMenu.items.count > 1 {
                return mainMenu.items[1].submenu
            }
            return nil
        }()

        guard let fileMenu else { return }

        // Avoid double-insertion if something invokes phantomBootstrap()
        // twice (defensive — Ghostty only calls it once today).
        let phantomMenuItemTag = 0x50_48_4E_4D // "PHNM" ASCII
        if fileMenu.items.contains(where: { $0.tag == phantomMenuItemTag }) { return }

        let item = NSMenuItem(
            title: "Pair iPhone…",
            action: #selector(phantomPairIPhone(_:)),
            keyEquivalent: "P"
        )
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        item.tag = phantomMenuItemTag

        // Insert a separator + the new item near the top of the File menu
        // for visibility. If the menu is empty, just add to the end.
        if fileMenu.items.isEmpty {
            fileMenu.addItem(item)
        } else {
            fileMenu.insertItem(.separator(), at: 0)
            fileMenu.insertItem(item, at: 0)
        }
    }

    // MARK: - Menu action

    @MainActor
    @objc func phantomPairIPhone(_ sender: Any?) {
        // Reuse an existing window if it's already on screen.
        if let wc = AppDelegate.phantomPairingWindowController,
           wc.window != nil {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Pick the relay URL.
        let relayURL = Self.phantomDefaultRelayHTTPURL()

        // Build the pairing service + view model.
        let code = PairingQRGenerator.randomPairingCode()
        let service = MacPairingService(relayURL: relayURL, code: code)
        AppDelegate.phantomPairingService = service

        let viewModel = PairingWindowViewModel(
            service: service,
            code: code,
            relayURL: relayURL
        )

        let hosting = NSHostingController(rootView: PairingWindowView(viewModel: viewModel))

        let window = NSWindow(contentViewController: hosting)
        window.title = "Pair iPhone"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 360, height: 500))
        window.center()

        let wc = NSWindowController(window: window)
        AppDelegate.phantomPairingWindowController = wc

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Helpers

    /// Resolve the relay URL to use for pairing. The user-visible config
    /// stores a `wss://` URL because the live gateway speaks WebSocket,
    /// but the pairing REST handshake speaks `https://`. Translate.
    fileprivate static func phantomDefaultRelayHTTPURL() -> URL {
        let store = PhantomConfigStore()
        let config = store.load()
        if let url = httpURLFromConfigString(config.relayURL) {
            return url
        }
        return URL(string: "https://phantom-relay.fly.dev")!
    }

    private static func httpURLFromConfigString(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        var s = raw
        if s.hasPrefix("wss://") {
            s = "https://" + s.dropFirst("wss://".count)
        } else if s.hasPrefix("ws://") {
            s = "http://" + s.dropFirst("ws://".count)
        }
        return URL(string: s)
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

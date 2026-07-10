import AppKit
import GhosttyKit

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

#if canImport(PhantomBridge) && canImport(PhantomMacUI) && canImport(PhantomAgent)

import PhantomAgent
import PhantomBridge
import PhantomCore
import PhantomMacUI
import SwiftUI
import Combine

fileprivate struct PhantomGatewayBoardBroadcaster: AgentBoardBroadcasting {
    var pushNotifier: BoardEventPushNotifier?

    func publish(_ message: SyncMessage) async {
        if let coordinator = AppDelegate.phantomCoordinator {
            await coordinator.sendBoard(message)
        }
        await pushNotifier?.publish(message)
    }
}

fileprivate struct PhantomHostPushDeviceTokenRegistrar: PushDeviceTokenRegistering {
    let tokenStore: DeviceTokenStore

    func register(_ token: SyncMessage.PushDeviceToken) async throws {
        try tokenStore.store(token: token.token, for: token.deviceID)
    }
}

extension AppDelegate {
    /// Process-wide Phantom coordinator. Initialised on
    /// `applicationDidFinishLaunching`, torn down on
    /// `applicationWillTerminate`.
    ///
    /// Declared `internal` (not `fileprivate`) so `AppDelegate+PhantomOverlay`
    /// can call `reclaimAll()` from the same module without a separate accessor.
    static var phantomCoordinator: PhantomCoordinator?
    static var phantomAgentPortfolio: ProjectAgentPortfolio<ProcessCommandExecutor>?
    static var phantomDeviceTokenStore: DeviceTokenStore?
    static var phantomBoardPushNotifier: BoardEventPushNotifier?

    /// Lazily created pairing window, owned by the AppDelegate so we can
    /// re-show the same instance across menu invocations rather than
    /// stacking new ones each time.
    fileprivate static var phantomPairingWindowController: NSWindowController?

    /// Strong reference to the active pairing service while the window is
    /// open. Cleared when the window closes.
    fileprivate static var phantomPairingService: MacPairingService?

    /// Process-wide paired-device store. The pairing service mutates this
    /// on successful pair; the coordinator observes its `$current` and
    /// brings up the gateway transport when a pairing lands.
    @MainActor
    fileprivate static var phantomPairedStore: PairedDeviceStore?

    /// Currently-live WebSocket transport, if any. Kept here (not just in
    /// the coordinator) so we can swap it cleanly on re-pairing.
    fileprivate static var phantomGatewayTransport: URLSessionGatewayTransport?

    /// Combine subscription on `phantomPairedStore.$current`. Stored so
    /// the lifetime matches the AppDelegate.
    fileprivate static var phantomPairedSink: AnyCancellable?

    /// Combine subscription on `PairingWindowViewModel.$phase`. Watches for
    /// `.paired` so we can auto-close the pair window — without this the
    /// QR + green checkmark just sit on screen forever after a successful
    /// handshake, which looks like the Mac is hung even though the iOS
    /// peer is already receiving snapshots.
    fileprivate static var phantomPairingPhaseSink: AnyCancellable?

    /// Called from `applicationDidFinishLaunching(_:)`.
    @MainActor
    func phantomBootstrap() {
        // PhantomConfigStore persists to ~/Library/Application Support/Phantom/.
        let store = PhantomConfigStore()
        let config = store.load()
        let tokenStore = DeviceTokenStore()
        AppDelegate.phantomDeviceTokenStore = tokenStore
        AppDelegate.phantomBoardPushNotifier = AppDelegate.makePhantomBoardPushNotifier(
            config: config,
            tokenStore: tokenStore
        )
        let portfolio = AppDelegate.makePhantomAgentPortfolio(store: store, tokenStore: tokenStore)
        AppDelegate.phantomAgentPortfolio = portfolio

        // Create the paired-device store. If a pairing already exists from
        // a prior launch we'll wire the gateway immediately below.
        let pairedStore = PairedDeviceStore()
        AppDelegate.phantomPairedStore = pairedStore

        // Build the snapshot provider. Captures a `phantom_snapshot_t*` for
        // each polled surface and converts it into a renderer-grade
        // `TerminalSnapshot`. Returns `nil` when the surface has no
        // changes since the last poll (cheap noop), or when the phantom_*
        // C symbols are not linked into the process (SPM unit tests).
        let snapshotProvider: PhantomCoordinator.SnapshotProvider = { sessionID, surface in
            return SnapshotExporter.captureLatest(surface: surface, sessionID: sessionID)
        }

        // Build the gateway adapter only if we already have a pairing.
        // Otherwise we defer until `phantomPairedSink` observes the first
        // non-nil `current`.
        let initialAdapter = AppDelegate.makePhantomGatewayAdapter(from: pairedStore)

        // Task 7 (auto-reclaim): read the surface's pixel size before a
        // phone resize so the Mac can restore it when the user types.
        // `ghostty_surface_size` returns a by-value struct (20-byte sret);
        // we call it here — in AppDelegate which imports GhosttyKit — to
        // avoid the @convention(c) sret ABI complexity in PhantomBridge.
        // ghostty_surface_t is UnsafeMutableRawPointer; PhantomBridge uses
        // OpaquePointer for surface handles to avoid importing GhosttyKit.
        // Cast via UnsafeMutableRawPointer before calling ghostty_surface_size.
        let surfaceSizeProvider: PhantomCoordinator.SurfaceSizeProvider = { surface in
            let s = ghostty_surface_size(UnsafeMutableRawPointer(surface))
            guard s.width_px > 0 && s.height_px > 0 else { return nil }
            return (s.width_px, s.height_px)
        }

        let coordinator = PhantomCoordinator(
            snapshotProvider: snapshotProvider,
            gatewayAdapter: initialAdapter,
            surfaceSizeProvider: surfaceSizeProvider,
            observedSessionHandler: { event in
                await AppDelegate.phantomObservedSessionHandler(event)
            }
        )
        AppDelegate.phantomCoordinator = coordinator

        Task { @MainActor in
            do {
                try await coordinator.start()
                _ = try await portfolio.start()
                AppDelegate.logger.info("PhantomCoordinator started (gateway=\(initialAdapter != nil ? "live" : "pending pairing"))")
                if initialAdapter != nil {
                    AppDelegate.phantomGatewayTransport?.connect()
                    _ = try? await portfolio.publishSnapshots()
                }
            } catch {
                AppDelegate.logger.error("PhantomCoordinator failed to start: \(error)")
            }
        }

        // Install the remote-control overlay. Subscribes to
        // `phantomRemoteControlChanged` and shows/hides the scrim over the
        // key window when the iPhone takes/releases width ownership.
        installPhantomOverlay()

        // Observe pairing changes so the gateway comes up after the user
        // completes a pair (no app restart needed). Idempotent: each new
        // pairing tears down the prior transport before starting the new
        // one.
        AppDelegate.phantomPairedSink = pairedStore.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] device in
                guard let self else { return }
                self.handlePhantomPairedDeviceChange(device: device, in: pairedStore)
            }

        // Inject "Pair iPhone…" into the File menu. We do this in code so we
        // don't have to maintain a divergent MainMenu.xib against upstream.
        installPhantomPairMenuItem()
    }

    // MARK: - Gateway wiring

    @MainActor
    fileprivate static func makePhantomAgentPortfolio(
        store: PhantomConfigStore,
        tokenStore: DeviceTokenStore
    ) -> ProjectAgentPortfolio<ProcessCommandExecutor> {
        let supportDirectory = store.fileURL.deletingLastPathComponent()
        return ProjectAgentPortfolio.local(
            registryURL: supportDirectory.appendingPathComponent("agent-projects.json", isDirectory: false),
            databaseDirectory: supportDirectory.appendingPathComponent("agent-boards", isDirectory: true),
            defaultProject: ProjectDescriptor(name: "Phantom"),
            legacyDefaultDatabaseURL: supportDirectory.appendingPathComponent("agent-board.json", isDirectory: false),
            deliverySyncer: ProjectDeliverySyncRunner(
                githubExecutor: ProcessGitHubCommandExecutor(),
                httpClient: URLSessionExternalServiceHTTPClient()
            ),
            broadcaster: PhantomGatewayBoardBroadcaster(pushNotifier: AppDelegate.phantomBoardPushNotifier),
            pushRegistrar: PhantomHostPushDeviceTokenRegistrar(tokenStore: tokenStore),
            agentLogDirectory: supportDirectory.appendingPathComponent("agent-logs", isDirectory: true)
        )
    }

    @MainActor
    fileprivate static func makePhantomBoardPushNotifier(
        config: PhantomConfig,
        tokenStore: DeviceTokenStore
    ) -> BoardEventPushNotifier? {
        guard config.pushEnabled else { return nil }
        let env = ProcessInfo.processInfo.environment
        guard let keyID = env["PHANTOM_APNS_KEY_ID"],
              let teamID = env["PHANTOM_APNS_TEAM_ID"] else {
            return nil
        }
        let privateKey: Data?
        if let raw = env["PHANTOM_APNS_PRIVATE_KEY"] {
            privateKey = raw.data(using: .utf8)
        } else if let path = env["PHANTOM_APNS_PRIVATE_KEY_PATH"] {
            privateKey = try? Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            privateKey = nil
        }
        guard let privateKey else { return nil }
        let topic = env["PHANTOM_APNS_TOPIC"] ?? "com.phantom.ios"
        let useSandbox = env["PHANTOM_APNS_SANDBOX"].map { $0 != "0" && $0.lowercased() != "false" } ?? true
        guard let delivery = try? APNSDelivery(
            keyID: keyID,
            teamID: teamID,
            privateKey: privateKey,
            topic: topic,
            useSandbox: useSandbox
        ) else {
            return nil
        }
        return BoardEventPushNotifier(deliverer: delivery) {
            tokenStore.allTokens().map(\.token)
        }
    }

    fileprivate static func phantomObservedSessionHandler(_ event: ObservedSessionEvent) async {
        guard let portfolio = AppDelegate.phantomAgentPortfolio else { return }
        _ = try? await portfolio.ingestObservedSession(
            sessionID: event.sessionID,
            metadata: event.metadata,
            status: event.status,
            branchName: event.branchName,
            baseBranchName: event.baseBranchName
        )
    }

    /// Build a fully-wired `PhantomGatewayAdapter` from the current
    /// `PairedDeviceStore` state, or `nil` if not yet paired. Also stashes
    /// the underlying transport on the AppDelegate so it can be closed
    /// cleanly later.
    @MainActor
    fileprivate static func makePhantomGatewayAdapter(from pairedStore: PairedDeviceStore) -> PhantomGatewayAdapter? {
        guard let device = pairedStore.current,
              let url = URL(string: device.relayURLString) else {
            return nil
        }

        let transport = URLSessionGatewayTransport(
            relayURL: url,
            deviceID: device.deviceID,
            jwtToken: device.jwtToken
        )
        AppDelegate.phantomGatewayTransport = transport

        return PhantomGatewayAdapter(
            transport: transport,
            inputRouter: { event, sessionID in
                // Route inbound input back into the live coordinator.
                if let coord = AppDelegate.phantomCoordinator {
                    _ = await coord.inject(event, into: sessionID)
                }
            },
            boardMessageRouter: { message in
                guard let portfolio = AppDelegate.phantomAgentPortfolio else { return }
                if case .manifestOperationRequest(let request) = message {
                    let result = await portfolio.executeManifestOperation(request)
                    await AppDelegate.phantomCoordinator?.sendBoard(.manifestOperationResult(result))
                    return
                }
                _ = try? await portfolio.handle(message)
            }
        )
    }

    /// Called when `PairedDeviceStore.current` changes. If we now have a
    /// pairing we (re)build the gateway adapter; if it just cleared we
    /// tear the current one down.
    @MainActor
    private func handlePhantomPairedDeviceChange(device: PairedDevice?, in store: PairedDeviceStore) {
        // If the value didn't actually change in a meaningful way (e.g.
        // load() echoing the previous value at boot) and we already have
        // a live transport, skip.
        if device == nil {
            // Pairing cleared. Disconnect existing transport, drop adapter.
            AppDelegate.phantomGatewayTransport?.disconnect()
            AppDelegate.phantomGatewayTransport = nil
            return
        }

        // If we already have a transport for THIS device, leave it alone —
        // the publisher fires once on boot with the persisted value, and
        // `phantomBootstrap` may have already brought it up.
        if let existing = AppDelegate.phantomGatewayTransport,
           existing.deviceID == device?.deviceID {
            return
        }

        // Otherwise, swap. Close the old transport (if any), construct a
        // fresh adapter on the current pairing, and rebuild the
        // coordinator with the new gateway.
        AppDelegate.phantomGatewayTransport?.disconnect()
        AppDelegate.phantomGatewayTransport = nil

        guard let newAdapter = AppDelegate.makePhantomGatewayAdapter(from: store) else { return }

        // Replace the coordinator. We can't mutate `gatewayAdapter` on the
        // existing actor (it's `let`), so we stop the old one and start a
        // fresh coordinator with the same snapshot provider.
        //
        // Critically, we carry the OLD coordinator's `SessionRegistry` into
        // the new one. SurfaceObserver only fires on the next
        // `phantomSurfaceDidCreate` notification — surfaces already open
        // when the user pairs would otherwise be invisible to the new
        // coordinator's registry, and SnapshotPoller would iterate an
        // empty session set forever. Reusing the registry preserves the
        // surface ↔ SessionID mapping built up before pairing.
        let existingRegistry = AppDelegate.phantomCoordinator?.registry
        Task { @MainActor in
            if let old = AppDelegate.phantomCoordinator {
                await old.stop()
            }
            let coordinator = PhantomCoordinator(
                registry: existingRegistry ?? SessionRegistry(),
                snapshotProvider: { sessionID, surface in
                    SnapshotExporter.captureLatest(surface: surface, sessionID: sessionID)
                },
                gatewayAdapter: newAdapter,
                surfaceSizeProvider: { surface in
                    let s = ghostty_surface_size(UnsafeMutableRawPointer(surface))
                    guard s.width_px > 0 && s.height_px > 0 else { return nil }
                    return (s.width_px, s.height_px)
                },
                observedSessionHandler: { event in
                    await AppDelegate.phantomObservedSessionHandler(event)
                }
            )
            AppDelegate.phantomCoordinator = coordinator
            do {
                try await coordinator.start()
                AppDelegate.phantomGatewayTransport?.connect()
                _ = try? await AppDelegate.phantomAgentPortfolio?.publishSnapshots()
                AppDelegate.logger.info("PhantomCoordinator restarted with live gateway after re-pairing")
            } catch {
                AppDelegate.logger.error("PhantomCoordinator restart failed: \(error)")
            }
        }
    }

    /// Called from `applicationWillTerminate(_:)`.
    @MainActor
    func phantomShutdown() {
        // Tear down the Combine subscription first so we don't react to
        // store changes during shutdown.
        AppDelegate.phantomPairedSink?.cancel()
        AppDelegate.phantomPairedSink = nil

        // Close the WebSocket cleanly before stopping the coordinator so
        // the iOS peer sees a graceful disconnect.
        AppDelegate.phantomGatewayTransport?.disconnect()
        AppDelegate.phantomGatewayTransport = nil
        let portfolio = AppDelegate.phantomAgentPortfolio
        AppDelegate.phantomAgentPortfolio = nil
        AppDelegate.phantomDeviceTokenStore = nil
        AppDelegate.phantomBoardPushNotifier = nil

        guard let coordinator = AppDelegate.phantomCoordinator else {
            Task { await portfolio?.stop() }
            return
        }
        AppDelegate.phantomCoordinator = nil

        // Block briefly so the gateway gets a clean close. Same pattern as
        // updateController's shutdown in upstream AppDelegate.
        let sem = DispatchSemaphore(value: 0)
        Task {
            await portfolio?.stop()
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

        // Build the pairing service + view model. Pass in the process-wide
        // `PairedDeviceStore` so a successful pair persists straight into
        // it and `phantomPairedSink` picks it up to bring the gateway live.
        let code = PairingQRGenerator.randomPairingCode()
        let service = MacPairingService(
            relayURL: relayURL,
            code: code,
            pairedStore: AppDelegate.phantomPairedStore
        )
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

        // Auto-close on successful pair. The view model publishes `.paired`
        // as soon as `MacPairingService.pollStatus` sees the iOS side
        // complete `/api/pair` and derives the shared key. Hold the
        // success banner for ~1.2 s so the user sees the green checkmark,
        // then close cleanly.
        AppDelegate.phantomPairingPhaseSink = viewModel.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak window] phase in
                guard case .paired = phase else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    window?.close()
                    AppDelegate.phantomPairingWindowController = nil
                    AppDelegate.phantomPairingService = nil
                    AppDelegate.phantomPairingPhaseSink = nil
                }
            }

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

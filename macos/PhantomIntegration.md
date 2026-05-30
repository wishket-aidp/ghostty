# Phantom Integration Notes

This document describes how the Ghostty-fork-based Phantom macOS app
wires into the Phantom Swift packages that live in the parent monorepo.

## Status (2026-05-30, Phase 6)

- **Source-level wiring is in place**: `AppDelegate+Phantom.swift` instantiates
  `PhantomBridge.PhantomCoordinator` on `applicationDidFinishLaunching` and
  tears it down on `applicationWillTerminate`. All references are gated
  behind `#if canImport(PhantomBridge) && canImport(PhantomMacUI)`, so the
  project builds cleanly as upstream Ghostty would.

- **Xcode project linkage is deferred**: the parent monorepo's
  `Package.swift` is two directories up (`../../Package.swift`). Adding it
  as an `XCLocalSwiftPackageReference` requires editing
  `Ghostty.xcodeproj/project.pbxproj` by hand. Modifying the submodule's
  project file makes upstream merges noisier, so this is left as a
  manual one-time step:

  1. Open `vendor/ghostty/macos/Ghostty.xcodeproj` in Xcode.
  2. File → Add Package Dependencies → Add Local… and select `../..`
     (the parent Phantom repo).
  3. On the `Ghostty` target's *General → Frameworks, Libraries, and
     Embedded Content* list, add both `PhantomBridge` and `PhantomMacUI`.
  4. Build. The `canImport(PhantomBridge)` shim in
     `AppDelegate+Phantom.swift` activates automatically.

- **Binary dependency**: `PhantomBridge` consumes
  `build/GhosttyKit.xcframework`, which is produced by
  `scripts/build-xcframework.sh` from the parent repo. That XCFramework
  wraps the *same* libghostty.a that this Xcode project links directly,
  so the runtime is the in-tree Ghostty engine — there is no duplication
  of the VT state machine.

## Coordinator API surface

```swift
PhantomCoordinator(
    registry: SessionRegistry = .init(),
    snapshotInterval: TimeInterval = 1.0 / 60.0,
    notificationCenter: NotificationCenter = .default,
    publishHook: PublishHook? = nil,
    pushBus: PushEventBus? = nil,
    snapshotProvider: SnapshotProvider? = nil,
    gatewayAdapter: PhantomGatewayAdapter? = nil
)
```

Today the bootstrap uses the defaults — no push bus, no gateway adapter —
so the coordinator is effectively a passive surface observer. Wiring
`PushEventBus` and `PhantomGatewayAdapter` is the next integration step
once `PhantomConfig` exposes the relay URL and APNs credentials.

## Branding

`macos/Branding/` contains the legacy Phantom AppIcon set (PNG
`.appiconset` format from the retired `Apps/PhantomMac/` target). The
current Xcode project still uses the upstream Ghostty `Ghostty.icon`
(Xcode 16 Icon Composer format) at `vendor/ghostty/images/Ghostty.icon`.
Swapping to Phantom branding is a separate task — see
`macos/Branding/README.md`.

Bundle ID and display name overrides are applied in
`Ghostty.xcodeproj/project.pbxproj` (build settings
`PRODUCT_BUNDLE_IDENTIFIER` and `INFOPLIST_KEY_CFBundleDisplayName`).

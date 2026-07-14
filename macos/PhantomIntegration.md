# Phantom Integration Notes

This document describes how the Ghostty-fork-based Phantom macOS app
wires into the Phantom Swift packages that live in the parent monorepo.

## Status (2026-07-13)

- **Host wiring is active**: `AppDelegate+Phantom.swift` instantiates
  `PhantomBridge.PhantomCoordinator` on `applicationDidFinishLaunching` and
  tears it down on `applicationWillTerminate`. All references are gated
  behind `#if canImport(PhantomBridge) && canImport(PhantomMacUI)`, so the
  project builds cleanly as upstream Ghostty would.

- **Xcode project linkage is committed**: `Ghostty.xcodeproj` declares the
  parent `Package.swift` as an `XCLocalSwiftPackageReference` and the
  `Ghostty` target links `PhantomBridge`, `PhantomMacUI`, and `PhantomAgent`.
  The `canImport` gate remains only so upstream-only builds can compile
  without the parent checkout.

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

At launch the app restores the paired-device Keychain record, builds an
encrypted `URLSessionGatewayTransport`, and attaches the gateway adapter to
the coordinator. Pairing and APNs configuration remain capability-gated: a
missing pairing key prevents a plaintext fallback, and APNs delivery only
activates after its credentials are configured.

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

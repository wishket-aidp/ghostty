// AppDelegate+PhantomOverlay.swift
//
// Part of the Phantom remote-control feature (Phase 6).
//
// Presents a full-window, semi-transparent overlay over the key/main terminal
// window when the iPhone has taken width-ownership of any session. The overlay
// shows "iPhone 원격 제어 중" and an "활성화" (Activate) button that calls
// PhantomCoordinator.reclaimAll() to restore all sessions at once.
//
// Design choice — contentView SwiftUI overlay (not a child NSPanel):
//   • The key window already exists and its contentView is the Metal surface.
//   • Inserting an NSHostingView on top of contentView requires zero position
//     tracking across window moves / resizes — the overlay inherits the bounds
//     of the parent view automatically via autoresizingMask.
//   • Avoids NSPanel ordering complexity with the MTK / OpenGL rendering layer.
//   • The pairing window uses NSHostingController in the same codebase, so the
//     pattern is established.
//
// Multi-window caveat (v1): the overlay is applied to NSApp.mainWindow (or
// keyWindow as fallback).  If multiple terminal windows are open, only the
// main window gets the overlay.  Future work can iterate NSApp.windows and
// cover every TerminalWindow, but v1 keeps it simple.

#if canImport(PhantomBridge) && canImport(PhantomMacUI)

import AppKit
import SwiftUI
import PhantomBridge

// MARK: - Overlay bootstrap

extension AppDelegate {

    /// Call once from `phantomBootstrap()` to wire up the
    /// `phantomRemoteControlChanged` notification and create the overlay
    /// manager.
    @MainActor
    func installPhantomOverlay() {
        // Create the singleton manager and hold it process-wide.
        let manager = PhantomOverlayManager()
        AppDelegate.phantomOverlayManager = manager

        // Subscribe to controlled-state change notifications. They are
        // already delivered on the main queue by PhantomCoordinator.
        NotificationCenter.default.addObserver(
            manager,
            selector: #selector(PhantomOverlayManager.handleControlChanged(_:)),
            name: PhantomCoordinator.remoteControlChangedNotification,
            object: nil
        )
    }

    /// Process-wide overlay manager. Kept alive for the process lifetime.
    fileprivate static var phantomOverlayManager: PhantomOverlayManager?
}

// MARK: - PhantomOverlayManager

/// Manages the lifetime of the remote-control scrim overlay.
///
/// On `phantomRemoteControlChanged` with `controlled=true` it inserts an
/// `NSHostingView` into the key/main window's `contentView`.  On `false` it
/// removes it.
@MainActor
final class PhantomOverlayManager: NSObject {

    private var hostingView: NSView?

    @objc func handleControlChanged(_ note: Notification) {
        let controlled = (note.userInfo?["controlled"] as? Bool) ?? false
        if controlled {
            showOverlay()
        } else {
            hideOverlay()
        }
    }

    func showOverlay() {
        guard hostingView == nil else { return } // already showing

        // Target the main window first (most recently focused); fall back
        // to the key window (e.g. when activated via an AppKit event).
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow,
              let contentView = window.contentView else { return }

        let overlayView = PhantomRemoteControlOverlayView {
            Task { @MainActor in
                if let coordinator = AppDelegate.phantomCoordinator {
                    await coordinator.reclaimAll()
                }
            }
        }

        let hosting = NSHostingView(rootView: overlayView)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: contentView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        hostingView = hosting
    }

    func hideOverlay() {
        hostingView?.removeFromSuperview()
        hostingView = nil
    }
}

// MARK: - SwiftUI Overlay View

/// Full-window semi-transparent scrim with the remote-control message and
/// an "활성화" (Activate) button.
private struct PhantomRemoteControlOverlayView: View {

    /// Called when the user presses "활성화".
    let onActivate: () -> Void

    var body: some View {
        ZStack {
            // Dark scrim — lets the terminal content show through so the
            // user knows where they are.
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.iphone")
                    .font(.system(size: 48))
                    .foregroundColor(.white)

                Text("iPhone 원격 제어 중")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.white)

                Text("이 Mac은 iPhone이 화면 크기를 제어하고 있어요")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button(action: onActivate) {
                    Text("활성화")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(Color.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(40)
        }
        // Pass through keyboard events so the existing keyDown reclaim path
        // still fires.  Only pointer events (button click) are captured.
        .allowsHitTesting(true)
        // The overlay itself must not prevent the key window from receiving
        // key events; we rely on the SwiftUI Button for pointer capture only.
        .focusable(false)
    }
}

#endif // canImport(PhantomBridge) && canImport(PhantomMacUI)

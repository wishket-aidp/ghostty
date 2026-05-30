# Phantom Branding Assets

Source assets carried over from the retired `Apps/PhantomMac/` target.
These PNGs are in legacy `.appiconset` format; Ghostty's project uses
Xcode 16's new `.icon` (Icon Composer) format and references
`../images/Ghostty.icon`.

To swap the app icon to Phantom:
1. Either convert these PNGs into a `Phantom.icon` Icon Composer file
   and update `Ghostty.xcodeproj` to reference it, OR
2. Restore a classic `AppIcon.appiconset` in `Assets.xcassets/` and
   point `ASSETCATALOG_COMPILER_APPICON_NAME` at it.

Deferred from Phase 6 (2026-05-30) — see `docs/superpowers/specs/2026-05-30-ghostty-fork-pivot-design.md`.

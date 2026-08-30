# Changelog

All notable changes to Transom are documented here. The release workflow publishes each version's section as the GitHub release notes and embeds it in the Sparkle appcast, so the in-app update dialog shows the same notes. A release fails early if its version has no section here.

Keep each bullet on a single line: release notes render line breaks literally (both on GitHub and in the update dialog), so wrapped lines would break mid-sentence.

## 1.2.1

### Added

- Spotlight now finds the app by its Korean name and by what it does — 트랜섬, 트랜솜, 밝기, and brightness all match.

## 1.2.0

### Fixed

- Brightness keys on Bluetooth Magic Keyboards work again: macOS 26 delivers their presses only as brightness keycodes — with no system-defined event, which is the form macOS itself acts on, so the system showed no OSD and adjusted nothing either. Transom now handles the keycode form too, adjusting the display under the cursor (the built-in panel included, since there is no native handling to defer to).
- Keyboards that send both event forms, like the built-in keyboard, are deduplicated — one press stays one brightness step.

## 1.1.1

- Fixed: installing by COPYING the app (instead of Finder-moving it) left it running from Gatekeeper's translocated read-only path, which blocked Sparkle updates — the app now detects this at launch, clears the quarantine flag, and relaunches itself from its real location.

## 1.1.0

### Added

- First-run onboarding that explains cursor-aware brightness and hosts the Accessibility permission ask — the launch-time system prompt is gone.

## 1.0.0

- Initial release: your brightness keys adjust whichever display the mouse is on — Apple displays natively, ordinary external monitors via DDC/CI.
- A custom Liquid Glass brightness HUD for redirected key presses, matching the system's own.
- Menu bar app with a hideable icon, launch at login, and Sparkle auto-updates.

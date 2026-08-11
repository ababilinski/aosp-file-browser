# Changelog

Notable changes to AOSP File Manager are recorded here. The format is inspired
by [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.0] - 2026-08-11

### New features

- Show progress for direct app installs ([#24](https://github.com/ababilinski/asop-file-browser/pull/24))
- Unify device connections and tool setup ([#27](https://github.com/ababilinski/asop-file-browser/pull/27))
- Add multi-source audio to screen recordings ([#30](https://github.com/ababilinski/asop-file-browser/pull/30))
- Rename app to AOSP File Manager ([#32](https://github.com/ababilinski/asop-file-browser/pull/32))

### Fixes and improvements

- Protect Trash records by device ([#28](https://github.com/ababilinski/asop-file-browser/pull/28))
- Polish selection search and storage analysis ([#29](https://github.com/ababilinski/asop-file-browser/pull/29))
- Use one universal app for Mac releases ([#33](https://github.com/ababilinski/asop-file-browser/pull/33))

## [1.2.0] - 2026-07-25

### New features

- Support macOS 13 and later ([#14](https://github.com/ababilinski/asop-file-browser/pull/14))
- Add guided device connectivity and Wi-Fi ADB setup ([#20](https://github.com/ababilinski/asop-file-browser/pull/20))
- Polish contextual browser toolbars and search ([#21](https://github.com/ababilinski/asop-file-browser/pull/21))

## [1.1.0] - 2026-07-22

### Added

- Install `.apk`, `.xapk`, `.apks`, and split `.zip` app packages by dragging
  them into the app, with an editable multi-package install queue, progress,
  actionable errors, and recovery choices for version and signing conflicts.
- Open Phone Control for multiple connected devices at once, with a separate
  battery and shortcut bar for each device window.
- Keep Phone Control from waking devices unless enabled, add per-device stream
  options, and allow each control bar to be repositioned.
- Choose one or more connected displays for screenshots and recordings. Captures
  from multiple devices are combined side by side with black padding.
- Show only supported actions in each Phone Control bar, with direct screenshot
  and recording buttons, battery status, a clear recording indicator, and a
  device-actions menu that can wake the display.
- Added separate Apple silicon and Intel downloads alongside the universal Mac app.

### Changed

- Load the app list before slower metadata, then fill in app names and icons as
  they become available.
- Keep Phone Control, screenshots, and recording available from app and storage views.
- Opening the app again brings its existing window forward instead of starting
  another copy.
- Treat a slow device response as a temporary command failure instead of opening
  Phone Tools setup.
- Wake each selected display immediately before screenshots and recordings begin.
- Remove the short capture warmup from combined recordings so playback starts on content.
- Keep a display's single static frame visible for the rest of a combined
  recording instead of failing the side-by-side export.
- Updated the optional managed Phone Tools download to scrcpy 4.1.

### Fixed

- Return to connection instructions when the selected device disconnects, even
  while app metadata or an app installation is still loading.
- Keep install progress and completion state in sync so finished drag-and-drop
  installs no longer leave stale progress UI behind.

## [1.0.0] - 2026-07-17

### Added

- Browse, preview, organize, and transfer Android files from a Mac.
- Drag and drop between the phone, Finder, and connected devices.
- File Transfer Mode for everyday USB transfers without Developer Options.
- USB and Wi-Fi debugging with Search Everywhere, recoverable Trash, storage
  details, and app management.
- Phone screenshots, screen recording, and phone control.
- Transfer progress, conflict handling, Quick Look, thumbnails, and preview
  cache controls.
- Signed and notarized DMG releases with a branded mounted-volume icon.
- Guarded release automation with build, test, signing, notarization, and launch
  checks before publication.

[Unreleased]: https://github.com/ababilinski/asop-file-browser/compare/1.3.0...HEAD
[1.3.0]: https://github.com/ababilinski/asop-file-browser/compare/1.2.0...1.3.0
[1.2.0]: https://github.com/ababilinski/asop-file-browser/compare/1.1.0...1.2.0
[1.1.0]: https://github.com/ababilinski/asop-file-browser/compare/1.0.0...1.1.0
[1.0.0]: https://github.com/ababilinski/asop-file-browser/releases/tag/1.0.0

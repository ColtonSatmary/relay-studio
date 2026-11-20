# Changelog

## 0.1.0-preview.1

First shareable preview of Relay Studio.

- Coordinate multiple schedules on one timeline, with 15-minute block movement and resizing, lane reordering, and a clock-synced playhead.
- Import video and image files or folders as named solutions, inspect previews and media details, and prepare USB or ViPlex schedule packages.
- Discover and alias players, reconnect saved boards, view current-output snapshots, and upload a solution or schedule to multiple boards.
- Apply individual or bulk player controls, including brightness, color temperature, mosaic layout, and clock/time-zone settings.
- Save a shared player password locally and choose light or dark appearance.
- Distribute a Windows portable ZIP with file checksums and an optional per-user installer. The macOS preview uses PowerShell 7.5 or newer and FFmpeg.

This is an unsigned preview. The release workflow gates publication on Windows checks and extracted-package installation, plus macOS runtime and extracted-package checks on Apple Silicon and Intel. Tests use generated media, simulated players and disposable disk images. Physical playback from a Mac, real USB devices and macOS downloaded-app approval still need verification on the target computer. Windows requires ViPlex components for the full feature set; see the platform installation guides for dependencies and limits.

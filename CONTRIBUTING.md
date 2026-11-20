# Contributing

Relay Studio's browser UI is plain JavaScript, CSS and HTML. The Windows service uses Windows PowerShell 5.1 and compiles the small C# helpers with `Add-Type`. See the platform installation guides for runtime requirements.

## Run the isolated checks

On Windows, install Node.js 24 and run from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\.github\scripts\Test-Windows.ps1
```

If Node is outside `PATH`, pass `-NodePath "C:\path\to\node.exe"`. The runner executes every root `*.test.cjs` file and an explicit list of Windows tests in separate processes. Test fixtures use disposable directories, fake device sessions, and loopback HTTP/UDP listeners. They do not discover or upload to physical players, erase removable drives, or eject USB devices. No ViPlex library is needed for this suite.

The GitHub Windows workflow runs this same command. It does not prove physical playback, firmware compatibility, or behavior on macOS.

The isolated suite includes `image-export.test.ps1`, which stages generated JPEG content for USB playback, network upload and ViPlex schedule import. It uses an empty catalog and Relay's own `ScheduleThumb.png`; no installed ViPlex thumbnail, media library or FFmpeg executable is required.

## Optional integration checks

Run these separately when their prerequisites are installed:

- `board-controls.test.ps1`: synthetic board controls, including IANA time-zone conversion. The current Windows implementation reads the time-zone library installed with ViPlex.
- `image-formats.test.ps1`: generated image fixtures, including formats that require an available FFmpeg executable.
- `network-staging.test.ps1` and `usb-playback.test.ps1`: read an existing ViPlex library and copy a playable solution into temporary staging folders. Pass `-ConfigRoot` to select a test library. These checks never publish to a player or open a USB volume.

Physical playback checks need a specifically selected test board and an operator able to observe the display. Record the model, firmware, operation and observed result without including passwords, player serials, private media names, or personal network details in public issues.

## Keep releases reproducible

Use generated media and synthetic serial numbers in regression tests. Keep saved passwords, player directories, workspace data, media libraries, exports, protocol captures, vendor binaries and downloaded development tools out of commits. The repository ignore file is a guardrail; review the staged files before pushing.

Release packages must use the build script's explicit file list. Include only the project's source/assets and approved redistributable dependencies, with the relevant notices. Preserve the difference between simulated tests and a feature observed working on actual hardware when documenting a release.

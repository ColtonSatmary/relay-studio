# Relay Studio for macOS — full-feature preview

This package runs the same schedule editor and board protocol as the Windows app. It includes media import and previews, 15-minute scheduling, discovery, multiple-player uploads, player controls, saved passwords, USB playback export, and eject. It is an unsigned source preview, not a notarized native application. Automated macOS checks validate software behavior; physical LED-player playback and real USB hardware still need testing on a Mac.

## Install and start

1. Install a supported **PowerShell 7** release using [Microsoft's macOS installation instructions](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-macos).
2. Install **FFmpeg** using a macOS build linked from [FFmpeg's download page](https://ffmpeg.org/download.html). If you already use Homebrew, `brew install ffmpeg` installs it. Relay looks on PATH, `/opt/homebrew/bin`, and `/usr/local/bin`.
3. Extract the entire ZIP to a normal folder, such as `Applications/Relay Studio`. Keep all its files together.
4. Open `macos/Launch Relay Studio.command`. macOS may require you to use Finder's **Open** command or Privacy & Security to approve a downloaded script. Review the source first. If an extraction tool dropped its executable permission, run `chmod +x "macos/Launch Relay Studio.command"` from the extracted folder.
5. Keep its Terminal window open. Relay opens in your default browser at `http://127.0.0.1:47833`. Press Control-C in Terminal to stop it. Reopening the launcher returns to an existing matching server.

Apple Silicon and Intel Macs use the same package; install PowerShell and FFmpeg for your Mac's architecture. No ViPlex installation or vendor DLLs are required on macOS. Relay listens only on the local computer. Allow local-network access if macOS asks, and connect the Mac and boards to the same network. Manual IP entry remains available when broadcast discovery is blocked.

## Data and password storage

The workspace, imported media, and remembered players live in `~/Library/Application Support/Relay Studio`. Folder exports default to `~/Documents/Relay Studio Exports`. The default player password is stored in your login **Keychain**, associated with the workspace path. macOS may ask you to grant the PowerShell process access to that Keychain item. Relay calls Security.framework directly, so the password is not placed in command-line arguments or a settings file. Use a separate workspace or update the default password when changing companies.

The downloadable package includes no customer media, schedules, player addresses, passwords, or ViPlex data. A project backup describes schedules but does not include its media files; import those original files on each computer. The first macOS launch starts with an empty library.

## Media and USB

Videos keep their original encoding. H.264 MP4 is the most predictable choice for both browser preview and NovaStar playback; a successful import does not mean a particular player firmware supports every codec. Supported containers include MP4, MOV, M4V, MKV, WebM, AVI, WMV/ASF, MPEG/VOB, TS/MTS/M2TS, FLV, MXF, 3GP/3G2, M2V, MPE, and OGV.

Common still images are decoded using FFmpeg and normalized to JPEG, with a black background for transparency. SVG and AVIF use browser conversion. HEIC/HEIF and specialist formats depend on the installed decoder. Camera RAW and JPEG XR files may require conversion to PNG/JPEG first. Animated image imports use their first frame. JPEG orientation is normalized before export.

USB selection lists only mounted, writable **physical external USB volumes formatted FAT/MS-DOS or exFAT**. APFS, network volumes, disk images, internal disks, and ambiguous mounts are excluded. FAT32 cannot hold a single file larger than 4 GB; player support for exFAT depends on its firmware. Use the format supported by your boards.

USB defaults are copy and play, overwrite existing, and delete files. Clearing removes user files from the selected volume after the local playback package passes validation. macOS housekeeping folders may remain. Files are addressed through a held volume descriptor; a different disk acquiring the same mount name cannot receive an interrupted export. Eject refuses a device with another mounted partition; use Finder to eject that whole device.

## Development and verification

Run the server directly with `pwsh -NoProfile -File Start-Studio.ps1`. Tests in `.github/scripts/Test-MacOS.ps1` run against temporary data, local HTTP fixtures, and a disposable test disk image; they do not contact physical boards or modify real USB drives. The CI workflow runs on both Intel and Apple Silicon macOS runners. Build a source ZIP in `dist` with `pwsh -File macos/Build-MacOSPackage.ps1 -Version 0.1.0-preview.1`.

This preview uses the same readback checks and TLS certificate pinning as the Windows app. Schedule packaging and board commands are shared implementations. A successful API response or automated test is not a substitute for checking the physical display when introducing a new Mac or player firmware.

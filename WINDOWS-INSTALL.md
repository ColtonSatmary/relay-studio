# Relay Studio for Windows

This preview package contains Relay's application files. Each coworker uses their own workspace, media library, player addresses and saved password.

## Requirements

- Windows 10 or Windows 11, x64.
- Windows PowerShell 5.1 and .NET Framework, included with supported Windows installations. PowerShell 7 is not the launcher for this release.
- A current browser. The launcher uses Microsoft Edge when available and otherwise opens the default browser.
- ViPlex Express installed on the same computer for the full feature set. The current Windows build uses its local library, FFmpeg converter and time-zone database. Relay does not bundle or install ViPlex binaries. Imported media and ordinary scheduling can be used without an existing ViPlex library; some import and publishing features still depend on the installed components.
- Access to the boards' local Wi-Fi or wired network for discovery, uploads and controls.

No Node.js, Git, developer tools, GitHub account or administrator installation is needed to run the package. This is an unsigned preview distributed as source scripts, not a signed MSI or EXE installer. Organization policies may require IT review before it can run.

## Portable use

1. Download the Windows ZIP and its `.sha256` checksum from the same release.
2. Extract the complete ZIP into a normal folder. Running individual files from inside the ZIP will not work.
3. Install ViPlex Express separately if it is not already installed.
4. Double-click **Launch Studio.cmd**. Keep the extracted application folder in place.

Relay starts a local service and opens `http://127.0.0.1:47833/`. Closing the browser leaves that local service available for queued uploads. The service ends when Windows signs out or restarts. If Windows or your organization blocks the scripts, ask the administrator to review the package instead of disabling protections.

## Optional per-user installation

Double-click **Install Studio.cmd** from the extracted package. The installer verifies the included file hashes, copies this release into `%LOCALAPPDATA%\Programs\Relay Studio\<version>`, and creates desktop and Start menu shortcuts. It does not request administrator access or modify the Windows registry. Application files stay separate from your workspace.

If the same version is already installed, the installer reuses it only when all packaged files still match. It does not overwrite a modified installation. Use a new release version for upgrades.

## First use

Enter the shared **Player password** in the top bar and choose **Save**. Password fields are visible on screen; the saved default is encrypted for the current Windows account. Open **Players**, choose **Discover players**, and give boards useful aliases. Saved players reconnect automatically when Relay opens. Connection failures remain visible per board.

Import videos or images into **Solution library**, then create **Schedules**. The package contains no example show, media or saved boards from its author. Your existing ViPlex library can appear on this computer automatically.

For USB export, **Delete all files on the selected USB** starts checked. Uncheck it to keep other files. Review the drive named by the final action before exporting.

## Data and sharing

Relay stores workspace data, imported media, aliases and encrypted settings under `%LOCALAPPDATA%\Relay Studio`. This folder is not part of the application ZIP and is not copied by the installer. Exports normally go into **Documents\Relay Studio Exports**.

To share the app, send the release ZIP. To share a show as well, export a project backup and separately provide the media it references, or create the appropriate playback package. A JSON project backup contains scheduling data and media references, not the media files themselves. Saved player passwords are specific to a Windows account and must be entered separately on each computer.

## Upgrades and removal

Save your work and let transfers finish before upgrading. Restart Windows before launching a new installed version if an older Relay service is still running; otherwise its local port may still be occupied. Keep the old application folder until the new version is verified. Your workspace remains in the same data folder.

To remove the application, remove its shortcuts and application version folder after its service has stopped. Keep `%LOCALAPPDATA%\Relay Studio` if you want to retain shows and imported media. The installer does not remove user data.

## Check the download

The `.sha256` file next to the ZIP records its SHA-256 hash. In PowerShell, run `Get-FileHash -Algorithm SHA256` with the ZIP path and compare the result. The package also includes `release-manifest.json` with individual application file hashes. Hashes detect changed or damaged files; they are not a publisher signature.

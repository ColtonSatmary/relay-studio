# Relay Studio

Relay Studio is a local schedule editor and player manager for NovaStar LED boards. Coordinate content across multiple schedules, drag blocks on a 15-minute timeline, import media, and publish by USB or over the local network. It is an independent project, not an official NovaStar product.

## Install the preview

Download a package from [GitHub Releases](https://github.com/ColtonSatmary/relay-studio/releases).

- **Windows:** extract the Windows ZIP and double-click **Launch Studio.cmd**. For desktop and Start menu shortcuts, run **Install Studio.cmd**. See [Windows installation](WINDOWS-INSTALL.md) for prerequisites and setup.
- **macOS:** the full-feature port uses PowerShell 7.5 or newer and FFmpeg. Follow [macOS setup](macos/README.md). It is a preview pending physical Mac/player testing; it is not a signed or notarized installer.

The packages contain application code and instructions. Your media, schedules, saved player addresses and passwords are separate local data and are not included. A new installation starts with its own library.

This release is **0.1.0-preview.1**, licensed under [MIT](LICENSE). See [the changelog](CHANGELOG.md) for release scope and verification limits. The Windows launcher starts a local service and opens Microsoft Edge, or the default browser when Edge is unavailable. Both platforms use the same browser interface and scheduling model.

## Coordinate schedules

Choose **Add schedule**, give the lane a name, and select **Number of boards** from 1 to 6. Each board adds 320 pixels of width at 1080 pixels tall: one board is 320 × 1080 and six are 1920 × 1080. The popup shows the resulting canvas. Editing an imported schedule with other dimensions preserves its existing canvas until you choose a board count.

1. Choose a show date on the board. Use the **schedules** button above the timeline to compare just the lanes you need.
2. Click the time ruler or enter a **Playhead** time. Enable **Sync to browser time** beside the playhead to follow today's local date and time. The setting is remembered in that browser. Choosing a different date or moving the playhead manually pauses sync.
3. Select **Coordinate schedules**. Set the switch time and choose a solution for each participating schedule. Leave the end blank to run until each schedule’s next switch or midnight.
4. Review the affected blocks and choose **Apply change**. A coordinated change applies only to the selected date. Earlier and later playback, including the other dates in a recurring series, is preserved.

Drag a schedule name up or down in the timeline or the **Schedules** sidebar. Release at the line where you want the schedule to appear. The order is saved with your workspace. When comparing a subset of schedules, dragging in the timeline reorders those visible lanes and keeps the hidden lanes in their original slots. You can also focus a schedule’s reorder handle and press the Up or Down arrow key.

Use **Add block** for one-off, weekly or overnight playback. New blocks start and end on a quarter hour and default to 15 minutes. Click an empty point on a lane for one block, or drag across an empty range for a longer one. The playhead can still inspect any minute, and imported schedules retain their original times. **Undo** restores the previous project state for the most recent edit in the current window.

Drag the middle of an existing block to move it to another time or schedule. Drag its left or right edge to change the start or end on the 15-minute grid. The preview shows the destination schedule and times before you release. Overlapping drops are rejected. Dragging a recurring block changes only the occurrence you picked. Click the block to edit its scheduling rule.

## Work with ViPlex

### View a solution

Open **Solution library** and select a solution. The side panel shows its preview, canvas size, source file, available media details and the schedules that use it. Use the video controls to play, seek or go full screen. For multi-item solutions, use **Preview item** to inspect individual media files. Local planning references show their details and schedule assignments.

### Add videos or images

Drop files or a folder onto the board or the **Solution library**, or click **Choose files** or **Choose folder** in the library. Relay searches subfolders and creates one solution per supported video or image, using its filename without the extension as the title. For example, `Doors.Open.mp4` appears as **Doors.Open** and `Lobby Welcome.png` appears as **Lobby Welcome**. Mixed folders work too. Each successful import is saved immediately. The results list shows skipped files and any decoding errors.

Choose **Show imported media**, then **Schedule** on a solution, or select it in **Coordinate schedules**. Imported images have a still preview and stay on screen for their scheduled block. They also support the solution's **USB** and **Send** buttons. Photo rotation is applied automatically so the preview and player use the same orientation. Use the library's **Imported images** filter to find them.

Media is copied into the managed local library so playback packages can be built after the source folder moves. Importing the same content under the same title reuses the solution. Two different titles can share a single stored file. Images are limited to 64 megapixels and 32768 pixels per side. Non-JPEG images are converted to a board-compatible JPEG; transparent areas become black, and animated or multipage images use their first frame/page. The original filename remains the solution label.

Supported image imports include JPG/JPEG/JPE/JFIF, PNG/APNG, GIF, BMP/DIB, TIFF, WebP, ICO, TGA, JPEG 2000, PSD, EXR, DDS and PBM/PGM/PPM/PNM. SVG and AVIF are rasterized by the browser; SVG files must be self-contained and static (no scripts, external fonts/images/styles, or foreign HTML). HEIC/HEIF, JPEG XR and camera RAW formats (DNG, CR2, NEF, ARW, ORF and RW2) use installed Windows image codecs, so availability depends on the computer and file variant. Unsupported or damaged images report an import error; export those as PNG or JPG. This is broad image support, not a guarantee for every proprietary image format.

Video containers accepted for import: MP4, M4V, MOV, MKV, WebM, AVI, WMV, ASF, MPEG/MPG/MPE, M2V, TS/MTS/M2TS, MXF, VOB, FLV, OGV, 3GP and 3G2. The installed FFmpeg decoder must be able to read the video track. Videos retain their original codec: importing a container does not guarantee browser preview or a particular player's codec support. H.264 video in MP4 is the most portable choice; convert incompatible videos before import.

The first board copies saved ViPlex schedules into named planning lanes. A lane can later be assigned to the appropriate player in ViPlex. **Solution library → Refresh from ViPlex** reads current solution references. **Project → Load ViPlex schedules** lets you replace selected lanes with fresh copies.

### USB playback

After exporting to a USB drive, choose **Eject drive and close** in the ready popup. Relay asks the operating system to safely remove that drive and closes the popup when accepted. If the drive is busy, the popup stays open so you can close the files using it and retry.

To play one solution, open **Solution library** and click **USB** next to it. The playback dialog is fixed to that solution. Planning references and missing media have a disabled USB button. **Export → USB playback** lists only schedules that have blocks.

**Copy and play** is selected initially, with **Overwrite existing** checked. Uncheck it to keep both when content on the player has the same name. **Delete all files on this USB** also starts checked for the selected drive; uncheck it to preserve existing files. The delete selection is tied to that drive's volume identity and is cleared after a failed export. Local-folder exports never erase a USB. Choose the USB drive by its letter and volume label. When that stick already carries a ViPlex player password, Relay can reuse it locally. For a new stick, enter the player password. ViPlex’s native playback command contains a recoverable copy of that password.

With **Delete all files from the USB stick before export** checked, the final action reads **Erase [drive] and export**. Relay verifies the new package and checks the selected volume again before clearing user files. Windows-managed volume metadata is preserved. With the box unchecked, other user files stay in place and replaced package files are backed up on the stick. To prepare the package without writing a drive, choose **Create a local playback folder** and later copy its `nova` folder to the USB root.

**Export → ViPlex schedule import** builds a separate folder per selected schedule under **Documents / Relay Studio Exports**. Set **Name in ViPlex** to the name you want to find in the native Schedule list. Each folder contains a `nova` directory with the selected media, playlists and schedule rules. In ViPlex Express, use **Schedule → Import** and select the folder containing `nova`. Look for the exact schedule name shown on Relay’s export receipt. Each package has distinct solution names and IDs to keep its import separate from the solutions already in ViPlex. Publish to the intended player from ViPlex.

The native adapter was developed against ViPlex Express 3.0.5.1501 and the local single-video solutions. New and moved blocks use a 15-minute grid; imported times are preserved. **Schedules** shows import notes for rules with second-level times or priority overlaps. More complex solution layouts can require a current ViPlex publish snapshot. You can also export a dated CSV run sheet, print the run sheet, or download an editable JSON project backup.

### Network playback

Connect this computer to the player's Wi-Fi or wired network. Relay runs locally and does not need internet for publishing. In **Solution library**, click **Send** next to a solution. To send a schedule, choose **Export → Network playback** and select its schedule.

Choose a remembered player or enter its current IP address, enter its player password, and click **Check connection**. Remembered addresses come from ViPlex and can be out of date. Relay verifies the responding player's serial number and shows the content canvas and player output dimensions separately. Different sizes are allowed: a 320 × 1080 mosaic tile may play part of a 1920 × 1080 solution. Relay sends the original canvas and leaves the player's mosaic configuration in place; the dimensions alone do not establish whether mosaic mode is enabled.

Click **Upload and play** to send the selected content to that player and start it. This changes active playback. Upload progress runs separately from the editor, existing matching media can be reused, and playback is requested only after the required files upload successfully. A failed transfer keeps its error visible. If status polling is interrupted, **Check upload status** reconnects to the existing job instead of starting a duplicate upload. Connection checks expire after 30 minutes; repeat the check when needed.

The network adapter supports the T50 HTTPS playback service on port 16674. It checks only the IP you choose and can read the board's identity over HTTPS when UDP discovery does not answer. Verified connections retain the serial and certificate pin. Publishing leaves player network settings and other stored programs in place. Older players without this service need USB playback or ViPlex. A live upload to a test T50 completed successfully and the operator confirmed that the display switched to the selected solution.

Network tests: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\network-transport.test.ps1`, `network-staging.test.ps1`, and `network-api.test.ps1`. Transport tests use a loopback simulator; staging tests use temporary folders and read the ViPlex library without changing it.

### Player controls

Open **Players** from the sidebar or top bar. **Discover players** searches the computer's active physical Wi-Fi and Ethernet networks, combining NovaStar discovery with read-only player identity checks. It does not change playback. Scans cover at most 254 addresses per interface (the computer's local /24 on larger networks), up to four interfaces; VPNs and virtual adapters are skipped. Use **Add by IP** for a board outside that scope.

Saved players with addresses reconnect automatically when Relay opens on any page, using the saved default password. Valid connections are reused; three checks run together. Each address is attempted once per open tab, so unavailable boards show their own errors without repeated login attempts. Saving a new password or discovering a new address triggers another relevant pass; clearing the saved password stops queued automatic attempts. Multiple tabs coordinate startup checks when Web Locks are available. Upload dialogs wait until automatic checks finish.

For a manual retry, select boards and choose **Connect selected**, or use **Connect all** for every saved address. Verified connections last 30 minutes. **Refresh status** reloads saved connection state; **Reconnect** performs a fresh connection check. Connections are available to the network playback and player-control dialogs.

Players appear as selectable cards. Use **Alias** to give a board a local name. Aliases follow its serial number when discovery finds a new IP and survive Relay restarts. **Forget** removes one board from Relay's list, and **Forget all players** removes every listed board after showing the affected count. Forgotten ViPlex entries stay hidden on refresh; discovery can add boards again and restore their aliases. These actions do not erase content or change the boards or the ViPlex database. Relay saves this directory in `players.json` beside the workspace.

Choose **Load preview** on a connected card, or **Refresh previews** to capture all connected boards. Relay reads an actual screenshot of the current output and reduces it to at most 480 pixels on its longest side. Each card shows the capture time; it is a still snapshot, refreshed on demand. Previews are kept in memory and captured two at a time. A preview failure stays on its card and leaves other previews available.

Select cards and choose **Upload selected** to send one solution or one schedule to all of them. You can also choose **Send to multiple boards** inside the existing Network playback dialog. Search for content, review the selected boards and shared password, then choose **Upload and play on N boards**. Every selected board must have a current checked connection. The queue runs up to three uploads together and reports each result independently. Boards start playback as their transfers finish; this does not synchronize their start frames.

The queue continues after the progress dialog or browser closes while the Relay service stays running. **Upload progress** reopens its status. Interrupted HTTP responses can be recovered without duplicating the same command. A service restart ends the in-memory queue and connection checks; inspect the boards before starting another upload. Credentials are never written into batch tracking files or browser storage. Player forget/connect/preview actions wait while an upload reserves that board.

Click **Controls** on a board to read its settings. All sections appear together in one scrollable view. The saved default password fills automatically and each section has its own Apply button.

Select cards and choose **Control selected** to change brightness, color temperature, multi-mosaic, or date/time on multiple boards. Every group has its own Apply button; unfinished values in another group do not affect the change. **Sync from browser** sends both the current clock and browser time zone, while **Apply time zone** leaves the clock alone. Relay applies changes two boards at a time and reports each board's readback independently. Keep the Relay tab open until this control queue finishes; the dialog may be closed and reopened through **Control progress**. Pending results can be checked without repeating writes. Ethernet addresses remain in individual board controls.

- **Brightness:** set manual brightness from 0 to 100 percent.
- **Color:** choose 4700 K, 6500 K, or 9300 K.
- **Multi-mosaic:** enable or disable mosaic, choose its direction, and set a screen count or total canvas width.
- **Date & time:** set the player's clock and IANA time zone, or copy the browser's current time. Browser sync copies the browser’s time zone as well as its current time. When automatic time synchronization is enabled, manage that source in ViPlex before manually setting the clock.
- **Ethernet:** edit DHCP or a static address, subnet, gateway, and DNS. A network change can disconnect the board; reconnect at its new address to verify it.
- **Wi-Fi:** view status and nearby networks. Changing Wi-Fi credentials is not implemented yet.

Live reads and manual brightness writes were verified on the test T50. Brightness sends only the requested percentage and checks both percentage and raw output on readback. Other configuration writes are covered by simulated tests, including validation, preserving unrelated firmware fields, and reading back accepted settings. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\board-controls.test.ps1` for those checks.

Discovery and simultaneous checked connections were verified with seven T50 boards on the local Wi-Fi on November 19, 2026. Controls and Send reuse these checked connections after a page refresh. Run `player-discovery.test.ps1`, `player-directory.test.ps1`, `player-management.test.cjs`, and `player-connection-reuse.test.cjs` for isolated discovery, saved-player and interface checks; use the same PowerShell/Node commands shown below.

## Local storage

### Default player password and appearance

Enter the shared **Default player password** in the top bar and click **Save** (or press Enter). USB and network playback dialogs fill it automatically, including when choosing another player. A saved default takes priority over a password found on a USB stick; you can still select **Use the player password already on this USB** when needed. Change and save the default when working for another company, or use the adjacent clear button to remove it. Password edits inside a playback dialog apply only to that operation.

Player password fields display their text so it can be checked while working. On Windows, the saved default is encrypted with DPAPI for the current account in `player-settings.json` beside the local workspace. On macOS it is stored in the login Keychain. It survives launcher restarts and is separate from project backups. Passwords are never stored in browser local storage. USB playback packages still contain the player credential required by the player firmware.

Use **Dark mode** in the top bar to switch appearance while keeping the lime accent. The appearance choice is remembered in this browser; **Light mode** switches back.

The launcher serves the app at `http://127.0.0.1:47833`. An older service at port 47832 can remain running with outdated upload workers even though its static interface looks new. Relay checks service compatibility before opening the workspace or automatically connecting boards. An incompatible instance shows an **Open updated Relay** link and can download its existing browser workspace copy for recovery. New services advertise an immutable runtime build; the already-verified 47833 release has a narrowly scoped compatibility check until its next restart.

On Windows the shared workspace lives in `%LOCALAPPDATA%\Relay Studio\workspace.json` and imported media lives under `%LOCALAPPDATA%\Relay Studio\Media`. On macOS the corresponding directory is `~/Library/Application Support/Relay Studio`. Saving replaces the workspace atomically and keeps the previous version as a backup. A stale window must reload before it can overwrite a newer revision. JSON project backups contain scheduling data and media references. To move a project with imported videos, keep the media folder with it or reimport the same video files. Windows can read ViPlex’s catalog and original media when creating packages; edits are saved separately from the ViPlex database. A new Mac library starts empty and can import original media directly.

## Scheduling tests

With Node.js installed, run `node --test model.test.cjs media-import.test.cjs`. The cases cover conflicting rules, date ranges, selected weekdays, overnight playback, coordinated changes across lanes, catalog relinking and nested directory drops. The Windows launcher itself requires no Node.js installation.

Image checks: run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\image-import.test.ps1`, then `image-formats.test.ps1`, `image-export.test.ps1` and `solution-preview.test.ps1` the same way. These use temporary files to check format conversion, first-frame selection, transparency, JPEG validation and rotation, HTTP import and previews, and ViPlex/USB/network packages without sending content to a player. `media-import.test.cjs` covers folder imports, SVG validation and browser conversion plumbing.

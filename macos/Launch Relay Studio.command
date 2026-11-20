#!/bin/zsh
set -eu
cd "${0:A:h}/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v pwsh >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1; then
  printf '\nRelay Studio needs PowerShell 7.5 or newer and FFmpeg.\nRead macos/README.md for installation instructions.\n\n'
  open "macos/README.md"
  read '?Press Return to close.'
  exit 1
fi
if ! pwsh -NoLogo -NoProfile -Command 'if ($PSVersionTable.PSVersion -lt [version]"7.5" -or [Environment]::Version.Major -lt 9) { exit 1 }'; then
  printf '\nPlease update PowerShell. Relay requires PowerShell 7.5+ on .NET 9+.\n'
  read '?Press Return to close.'
  exit 1
fi
printf 'Relay Studio is running. Keep this Terminal window open.\nPress Control-C here to stop the local server.\n'
exec pwsh -NoLogo -NoProfile -File './Start-Studio.ps1'

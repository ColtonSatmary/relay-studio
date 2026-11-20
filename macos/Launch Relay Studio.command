#!/bin/zsh
set -eu
cd "${0:A:h}/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v pwsh >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1; then
  printf '\nRelay Studio needs PowerShell 7 and FFmpeg.\nRead macos/README.md for installation instructions.\n\n'
  open "macos/README.md"
  read '?Press Return to close.'
  exit 1
fi
printf 'Relay Studio is running. Keep this Terminal window open.\nPress Control-C here to stop the local server.\n'
exec pwsh -NoLogo -NoProfile -File './Start-Studio.ps1'

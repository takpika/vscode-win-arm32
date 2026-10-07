#!/bin/bash
# electron.sh: downloads the files of the Electron release this VSCode is built with
# (winrt/ci/electron.env) into /home/winrt/electron-release and verifies them against
# winrt/ci/electron.sha256.
set -euo pipefail
W=/home/winrt
. "$W/repo/winrt/ci/electron.env"
R=$W/electron-release
mkdir -p "$R"
cd "$R"
while read -r sum name; do
  [ -n "$name" ] || continue
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 -o "$name" \
    "https://github.com/$ELECTRON_REPO/releases/download/$ELECTRON_TAG/$name"
done < "$W/repo/winrt/ci/electron.sha256"
sha256sum -c "$W/repo/winrt/ci/electron.sha256"

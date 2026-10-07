#!/bin/bash
# rg.sh: rg.exe for win32-arm (the ripgrep @vscode/ripgrep runs; it has no 32-bit ARM Windows
# prebuilt) from winrt/toolchains/win_mingw_fixes/build_ripgrep_winarm32.sh, into /home/winrt/rg.
set -euo pipefail
W=/home/winrt
MOUNTS="sdk/xwin-10.0.22621 sdk/llvm-mingw-winrt" . "$W/repo/winrt/ci/mounts.sh"
OUT=$W/rg sh "$W/repo/winrt/toolchains/win_mingw_fixes/build_ripgrep_winarm32.sh"

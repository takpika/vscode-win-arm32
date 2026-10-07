#!/bin/bash
# native.sh: VSCode's native modules (the 13 packages with a binding.gyp) for win32-arm, built by
# winrt/toolchains/win_mingw_fixes/vscode_native.ninja in the Electron build directory, as for the
# Electron the release was built from:
#   - out/electron is generated with that Electron's arguments (its winrt/ci/build.sh) and the
#     parts the addons take from it are built: Chromium's libc++ / libc++abi (std::Cr, which
#     electron.exe's std-typed exports carry) and the toolchain rules (toolchain.ninja);
#   - electron.lib (node.lib) and the node headers are the release's files (winrt/ci/electron.sha256);
#   - the sources are the lockfile-frozen fetch of deps.sh (out/vscode-nm-src/app).
# Run after checkout.sh and deps.sh; the modules end up in out/electron/vscode_native/.
set -euo pipefail
W=/home/winrt
S=$W/src
O=$S/out/electron
TC=$W/toolchains/win_mingw_fixes
. "$W/repo/winrt/ci/mounts.sh"
cd "$S"

mkdir -p "$O"
printf 'import("//electron/build/args/release.gn")\nimport("%s")\n' "$TC/winrt_arm_args.gni" > "$O/args.gn"
gn gen "$O"
ninja -C "$O" buildtools/third_party/libc++ buildtools/third_party/libc++abi

# The release's import library and node headers, verified against the pinned checksums.
. "$W/repo/winrt/ci/electron.env"
R=$W/electron-release
mkdir -p "$O/gen"
cp "$R/win-armv7l-node.lib" "$O/electron.lib"
rm -rf "$O/gen/node_headers"
tar -xzf "$R"/node-v*-headers.tar.gz -C "$O/gen"

if ! ninja -C "$O" -f "$TC/vscode_native.ninja" vscode_native_modules; then
  for l in "$O"/vscode_native/logs/*.log; do echo "==== $l"; tail -40 "$l"; done
  exit 1
fi
cat "$O/vscode_native/modules.stamp"

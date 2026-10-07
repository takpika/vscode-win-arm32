#!/bin/bash
# Builds the port toolchain into /home/winrt/sdk from the recipes in winrt/toolchains:
#   sysroots           Chromium's DEPS-pinned debian_bullseye sysroots: arm and the host's
#   llvm-mingw-winrt   build_llvm_winrt.sh (llvm-mingw + patched clang/lld + Chromium plugins)
#   xwin-10.0.22621    fetch_xwin_splat.sh (Windows SDK / MSVC CRT splat)
#   winrt-sdk          build_winrt_sdk.sh
#   winrt-crt          build_winrt_crt_runtimes.sh
# The Electron port's toolchain, built as its CI builds it. Runs inside the builder image after
# checkout.sh (the recipes use the patched Chromium tree:
# Chromium's clang plugins from tools/clang, and a libaom NEON source for the CodeView self-test).
set -euxo pipefail
W=/home/winrt
SDK=$W/sdk
R=$W/src
TC=$W/toolchains/win_mingw_fixes
# The recipes run with the bootstrap toolchain on PATH, never a half-installed port toolchain.
export PATH=/usr/local/bin:/opt/llvm-mingw/bin:/usr/sbin:/usr/bin:/sbin:/bin

mkdir -p "$SDK/tools" "$SDK/src" "$SDK/sysroots" "$SDK/staging"

# The sysroots are Chromium's own (build/linux/sysroot_scripts of the Chromium port commit that
# electron/DEPS pins), as the port's toolchain and build use them; Electron's sysroot.patch points
# that script at Electron's sysroot images instead, which are different images.
PORT=$(python3 -c "
ns = {'Var': lambda x: '{%s}' % x, 'Str': str}
exec(open('$R/electron/DEPS').read(), ns)
print(ns['vars']['chromium_win_arm32_commit'])")
T=$W/sysroot-scripts
rm -rf "$T"; mkdir -p "$T/build/linux/sysroot_scripts"
for f in install-sysroot.py sysroots.json; do
  git -C "$R" show "$PORT:build/linux/sysroot_scripts/$f" > "$T/build/linux/sysroot_scripts/$f"
done
# arm for the V8 snapshot tools (run under qemu-arm), and the build host's own.
case $(uname -m) in aarch64) HOSTSYS=arm64 ;; x86_64) HOSTSYS=x64 ;; esac
for a in arm $HOSTSYS; do
  python3 "$T/build/linux/sysroot_scripts/install-sysroot.py" --arch=$a
done
for d in "$T"/build/linux/debian_bullseye_*-sysroot; do
  rm -rf "$SDK/sysroots/$(basename "$d")"; mv "$d" "$SDK/sysroots/"
done
rm -rf "$T"

PIN=$(sed -n 's/^PIN=//p' "$TC/build_llvm_winrt.sh")
L=$SDK/src/llvm-project
if [ "$(git -C "$L" rev-parse HEAD 2>/dev/null)" != "$PIN" ]; then
  rm -rf "$L"; git init -q "$L"
  git -C "$L" fetch -q --depth 1 https://github.com/llvm/llvm-project.git "$PIN"
  git -C "$L" checkout -q FETCH_HEAD
fi

sh "$TC/build_llvm_winrt.sh"
rm -rf "$SDK/build"
sh "$TC/fetch_xwin_splat.sh"
rm -rf "$SDK/staging/xwin-cache"
sh "$TC/build_winrt_sdk.sh"
sh "$TC/build_winrt_crt_runtimes.sh"
rm -rf "$L" "$SDK/staging"
ln -sfn "$R" "$W/chromium"
du -sh "$SDK"/*

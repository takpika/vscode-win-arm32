# VSCode for Windows on ARM32

Visual Studio Code - Open Source ("Code - OSS") 1.80.1 for 32-bit ARM Windows (`win32-arm`):
Surface 2 (Windows RT 8.1) and ARM64 Windows devices running ARM32 code (tested on Surface
Pro X). It is packaged with the Windows on ARM32 port of Electron
([takpika/electron-win-arm32](https://github.com/takpika/electron-win-arm32), the release named in
`winrt/ci/electron.env`).

## Downloads

Releases (tags `v<version>-win-arm32`) carry `VSCode-win32-arm-<version>.zip`: unzip and run
`Code - OSS.exe`.

## Layout of this branch

- VSCode's sources carry the port's changes directly: the `win32-arm` packaging target
  (`gulp vscode-win32-arm-min`), the Electron zip's checksum in `build/checksums/electron.txt`
  (the release's zip, under the name `@electron/get` requests for `.yarnrc`'s Electron target
  and arch `arm`), Windows resource editing without rcedit's Windows-only executable
  (`build/lib/win32Resources.js`, with `resedit`), and Windows PowerShell's path for 32-bit ARM
  processes on ARM64 Windows.
- `winrt/toolchains/win_mingw_fixes/` holds the recipes VSCode adds to the Electron port's
  toolchain:
  - `vscode_native.ninja` (with `vscode_native_sources.py`, `addon_toolchain.py`,
    `gyp_make_win.py`, `winpty_cmd.py`, and backports in `vscode_native_patches/`): the 13 native
    modules, built by node-gyp in the Electron build directory with Electron's compiler, its
    configuration and Chromium's libc++, and linked against `node.lib` (`electron.lib`),
  - `build_ripgrep_winarm32.sh`: `rg.exe` (ripgrep 13.0.0, as `@vscode/ripgrep` uses; no 32-bit
    ARM Windows prebuilt exists),
  - `vscode_dist_patches/`: a patch to `@vscode/gulp-electron` for the packaging.
- `winrt/ci/` builds everything on a linux host (x86_64 or aarch64): `checkout.sh` (the
  Electron source tree), `toolchain.sh`, `electron.sh` (the Electron release files, checked against
  `electron.sha256`), `deps.sh` (npm dependencies, lockfile-frozen, no install scripts),
  `native.sh`, `rg.sh`, `package.sh`.

## Building

`.github/workflows/build.yml` runs on every push (GitHub-hosted `ubuntu-24.04` runners):
the Electron port's toolchain (built once and cached), `rg.exe`, then the native modules and the
package. Pushing a tag `v*-win-arm32` publishes the zip as a release.

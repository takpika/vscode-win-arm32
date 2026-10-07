#!/bin/sh
# ripgrep for win32-arm (Surface 2 / Surface Pro X): the rg.exe VSCode 1.80.1's
# @vscode/ripgrep 1.15.5 runs for search (lib/index.js: ../bin/rg.exe on
# win32). @vscode/ripgrep's postinstall downloads microsoft/ripgrep-prebuilt
# v13.0.0-10, which has no 32-bit ARM Windows build; this recipe builds the
# same thing the way that release builds its Windows targets
# (ripgrep-prebuilt v13.0.0-10: config.json = BurntSushi/ripgrep tag 13.0.0;
# build/windows.yml = RUSTFLAGS='-C target-feature=+crt-static',
# `cargo build --release --target $TARGET --features pcre2`).
#
# Run as `sh build_ripgrep_winarm32.sh` with OUT=<install dir> (e.g.
# /home/winrt/sdk/ripgrep-winarm32); installs $OUT/rg.exe.
#
# Target: thumbv7a-pc-windows-msvc (Rust's 32-bit ARM Windows target, tier 3:
# no prebuilt std, so std is built from rust-src with -Z build-std; the target
# specification itself sets panic_strategy Abort -- rustc_target
# spec/targets/thumbv7a_pc_windows_msvc.rs: no SEH unwinding for ARM32 yet --
# hence panic_abort in the build-std set).
# Linking: lld-link with the xwin MSVC CRT + Windows SDK libraries for
# arm, static CRT (+crt-static, as upstream) so rg.exe needs no VC++/UCRT
# redistributable (Windows RT 8.1 has none).
# pcre2 (upstream's --features pcre2, `rg -P`/--pcre2, which VSCode's search
# uses for look-around/backreferences): pcre2-sys 0.2.5 compiles PCRE2's C
# sources with the cc crate; for the msvc target cc drives clang-cl and the
# MSVC archiver, here the port toolchain's clang-cl and llvm-lib with the
# xwin headers.
set -eu

: "${OUT:?OUT must be set}"
RIPGREP_REPO=https://github.com/BurntSushi/ripgrep.git
RIPGREP_TAG=13.0.0
RIPGREP_REV=af6b6c543b224d348a8876f0c06245d9ea7929c5
TARGET=thumbv7a-pc-windows-msvc
X=/home/winrt/sdk/xwin-10.0.22621
LLVM=/home/winrt/sdk/llvm-mingw-winrt/bin
RUST=/opt/rust
RUST_TOOLCHAIN=nightly-2026-10-05
RUSTC_COMMIT=28221559263a3976766cf305940e80e30cf9ba8a

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export RUSTUP_HOME=$RUST/rustup
export CARGO_HOME=$W/cargo-home
# /usr/bin before /usr/local/bin: host artifacts (build scripts, proc macros)
# are linked by the host gcc, whose collect2 finds `ld` on PATH; in the build
# image /usr/local/bin/ld is the Windows toolchain's ld, not the host's
# binutils ld.
export PATH=$RUST/cargo/bin:/usr/bin:$PATH

export RUSTUP_TOOLCHAIN=$RUST_TOOLCHAIN
rustc -vV
cargo -vV
rustc -vV | grep -qx "commit-hash: $RUSTC_COMMIT" ||
  { echo "rustc is not $RUST_TOOLCHAIN ($RUSTC_COMMIT)" >&2; exit 1; }
[ -f "$(rustc --print sysroot)/lib/rustlib/src/rust/library/std/Cargo.toml" ] ||
  { echo "rust-src missing from $RUST_TOOLCHAIN (needed by -Z build-std)" >&2; exit 1; }

git clone --quiet --branch "$RIPGREP_TAG" --depth 1 "$RIPGREP_REPO" "$W/ripgrep"
rev=$(git -C "$W/ripgrep" rev-parse HEAD)
[ "$rev" = "$RIPGREP_REV" ] || { echo "ripgrep $RIPGREP_TAG is $rev, expected $RIPGREP_REV" >&2; exit 1; }

export CARGO_TARGET_THUMBV7A_PC_WINDOWS_MSVC_LINKER=$LLVM/lld-link
# compiler-rt builtins of the port's clang: clang-cl compiles PCRE2's JIT
# cache flush (sljit SLJIT_CACHE_FLUSH -> __builtin___clear_cache, chosen
# because clang has that builtin; MSVC's cl.exe, which upstream uses, takes the
# _WIN32 FlushInstructionCache branch instead) to a call of compiler-rt's
# __clear_cache, which on _WIN32 is FlushInstructionCache. Clang-compiled code
# needs its builtins library; lld-link takes only the members referenced.
BUILTINS=$LLVM/../lib/clang/23/lib/windows/libclang_rt.builtins-arm.a
# Reproducible output: the run's temporary paths are remapped out of panic
# locations; the link writes no PDB (/DEBUG:NONE, after rustc's /DEBUG: the
# PDB records rustc's per-run temporary linker directory, which made its GUID
# and the /Brepro stamp differ between runs) and is deterministic (/Brepro:
# the image time stamps are a hash of the output). Code is unaffected: debug
# info only fills the PDB, which is not shipped.
export RUSTFLAGS="-C target-feature=+crt-static -Lnative=$X/crt/lib/arm -Lnative=$X/sdk/lib/ucrt/arm -Lnative=$X/sdk/lib/um/arm --remap-path-prefix=$W/ripgrep=/ripgrep --remap-path-prefix=$CARGO_HOME=/cargo -C link-arg=/DEBUG:NONE -C link-arg=/Brepro -C link-arg=$BUILTINS"
export PCRE2_SYS_STATIC=1
export CC_thumbv7a_pc_windows_msvc=$LLVM/clang-cl
export AR_thumbv7a_pc_windows_msvc=$LLVM/llvm-lib
export CFLAGS_thumbv7a_pc_windows_msvc="--target=$TARGET /imsvc $X/crt/include /imsvc $X/sdk/include/ucrt /imsvc $X/sdk/include/um /imsvc $X/sdk/include/shared /clang:-ffile-prefix-map=$W/ripgrep=/ripgrep /clang:-ffile-prefix-map=$CARGO_HOME=/cargo"

cd "$W/ripgrep"
cargo build --release --locked --target "$TARGET" --features pcre2 \
  -Z build-std=std,panic_abort

RG=target/$TARGET/release/rg.exe
# The binary: ARMNT, and its import table (every DLL and function it binds at
# load) printed for the record; no CRT redistributable DLL may be imported
# (static CRT).
"$LLVM/llvm-readobj" --file-headers "$RG" | grep -q 'Machine: IMAGE_FILE_MACHINE_ARMNT' ||
  { echo "rg.exe: not an ARMNT image" >&2; exit 1; }
"$LLVM/llvm-readobj" --coff-imports "$RG" > "$W/imports.txt"
grep -E '^ *(Name|Symbol):' "$W/imports.txt"
if grep -iE '^ *Name: *(vcruntime[0-9]*|ucrtbase|msvcp[0-9]*|api-ms-win-crt-[a-z0-9-]*)\.dll' "$W/imports.txt"; then
  echo "rg.exe: imports a CRT redistributable DLL" >&2; exit 1
fi
mkdir -p "$OUT"
cp "$RG" "$OUT/rg.exe"
# Section contents, for comparing runs even where a header field differs.
"$LLVM/llvm-readobj" --sections --section-data "$RG" | sha256sum | sed 's/-$/sections/'
sha256sum "$OUT/rg.exe"

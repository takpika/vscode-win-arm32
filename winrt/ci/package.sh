#!/bin/bash
# package.sh: packages VSCode for win32-arm with the product's own task, unmodified:
#   gulp vscode-win32-arm-min   ->  src/VSCode-win32-arm   (zipped into /home/winrt/dist)
# Inputs (each must be there):
#   src/vscode                              this repository's tree, with deps.sh's dependencies
#   out/vscode-nm-src/app/node_modules      the root dependencies (deps.sh)
#   out/electron/vscode_native/             the 13 native modules (native.sh)
#   /home/winrt/rg/rg.exe                   rg.exe (rg.sh)
#   the Electron release zip                verified against build/checksums/electron.txt and fed
#                                           through @electron/get's cache, as gulp-electron
#                                           requests it
#   winrt/toolchains/.../vscode_dist_patches/@vscode+gulp-electron@1.36.0.patch
set -euo pipefail
W=/home/winrt
S=$W/src
V=$S/vscode
OUT=$S/out
NODE=$S/third_party/node/linux/node-linux-arm64/bin/node
NAT=$OUT/electron/vscode_native
PATCH=$W/toolchains/win_mingw_fixes/vscode_dist_patches/@vscode+gulp-electron@1.36.0.patch
RG=$W/rg/rg.exe
. "$W/repo/winrt/ci/electron.env"
DIST=$(ls "$W"/electron-release/electron-v*-win32-armv7l.zip)
die() { echo "package.sh: $*" >&2; exit 1; }

[ -d "$OUT/vscode-nm-src/app/node_modules" ] || die "root dependencies missing (deps.sh)"
[ -f "$NAT/modules.stamp" ] || die "native modules missing (native.sh)"
[ -f "$RG" ] || die "rg.exe missing (rg.sh)"
[ -f "$PATCH" ] || die "gulp-electron patch missing"
ver=$(sed -n 's/^target "\(.*\)"$/\1/p' "$V/.yarnrc")
[ -n "$ver" ] || die "no electron target in .yarnrc"
# The artifact name and cache directory, computed with @electron/get's own functions as its
# downloadArtifact() does (arch 'arm' -> 'armv7l').
G="$OUT/vscode-nm-src/app/node_modules/@electron/get/dist/cjs"
read -r zipname url cdir <<EOF
$("$NODE" -e "
const u=require('$G/utils'), a=require('$G/artifact-utils'), C=require('$G/Cache').Cache;
const d={version:process.argv[1],platform:'win32',arch:u.getNodeArch('arm'),artifactName:'electron'};
d.version=a.getArtifactVersion(d);
Promise.resolve(a.getArtifactRemoteURL(d)).then(url=>console.log(a.getArtifactFileName(d),url,C.getCacheDirectory(url)));" "$ver")
EOF
[ -n "$zipname" ] && [ -n "$cdir" ] || die "could not derive the electron artifact name via @electron/get"
want=$(awk -v f="*$zipname" '$2 == f {print $1}' "$V/build/checksums/electron.txt")
[ -n "$want" ] || die "build/checksums/electron.txt has no line for $zipname"
have=$(sha256sum "$DIST" | cut -d' ' -f1)
[ "$have" = "$want" ] || die "$DIST sha256 $have != $want ($zipname in build/checksums/electron.txt)"
echo "electron $ver: $DIST ($have), rg.exe $(sha256sum "$RG" | cut -c1-16)"

# node_modules: the root dependencies, with the built native modules in place of their fetched
# (unbuilt) copies (whole package directories), rg.exe, and the gulp-electron patch.
rm -rf "$V/node_modules"; cp -a "$OUT/vscode-nm-src/app/node_modules" "$V/node_modules"
n=0
while IFS= read -r g; do
  pkg=${g#"$NAT/node_modules/"}; pkg=${pkg%/binding.gyp}
  rm -rf "$V/node_modules/$pkg"; cp -a "$NAT/node_modules/$pkg" "$V/node_modules/$pkg"; n=$((n+1))
done < <(find "$NAT/node_modules" -mindepth 2 -maxdepth 3 -name binding.gyp -not -path '*/node_modules/*/node_modules/*' | sort)
[ "$n" -eq 13 ] || die "expected 13 native modules, found $n"
mkdir -p "$V/node_modules/@vscode/ripgrep/bin"; cp "$RG" "$V/node_modules/@vscode/ripgrep/bin/rg.exe"
( cd "$V/node_modules/@vscode/gulp-electron" && git apply --check -p1 "$PATCH" && git apply -p1 "$PATCH" ) \
  || die "gulp-electron patch does not apply"
# VSCode's own install-time step that the fetch skipped (--ignore-scripts): extensions/
# postinstall.mjs trims extensions/node_modules/typescript, so extension builds resolve
# 'typescript/lib/tsserverlibrary' to the root typescript, as after an upstream `yarn`.
( cd "$V/extensions" && "$NODE" ./postinstall.mjs >/dev/null ) || die "extensions/postinstall.mjs failed"
[ ! -e "$V/extensions/node_modules/typescript/lib/tsserverlibrary.d.ts" ] || die "extensions postinstall did not trim typescript"

# Electron: @electron/get's cache holds the release zip (no download; gulp-electron verifies it).
export XDG_CACHE_HOME=$W/xdg
mkdir -p "$XDG_CACHE_HOME/electron/$cdir"; cp "$DIST" "$XDG_CACHE_HOME/electron/$cdir/$zipname"

# vscode's build shells out to yarn (build/lib/dependencies.js), here under the tree's Node 16.
printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$NODE" "$W/yarn-1.22.19/bin/yarn.js" > "$W/bin/yarn"; chmod 0755 "$W/bin/yarn"
export PATH="$W/bin:$(dirname "$NODE"):$PATH" HOME=$W/home npm_config_arch=arm VSCODE_ARCH=arm
cd "$V"
echo "running: gulp vscode-win32-arm-min (node $("$NODE" --version), yarn $(yarn --version))"
"$NODE" --max_old_space_size=8192 ./node_modules/gulp/bin/gulp.js vscode-win32-arm-min
[ -d "$S/VSCode-win32-arm" ] || die "packaging finished but ../VSCode-win32-arm was not produced"

pv=$("$NODE" -p "require('$V/package.json').version")
mkdir -p "$W/dist"
(cd "$S" && zip -qr -X "$W/dist/VSCode-win32-arm-$pv.zip" VSCode-win32-arm)
ls -la "$W/dist"

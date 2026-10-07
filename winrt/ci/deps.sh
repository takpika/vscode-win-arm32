#!/bin/bash
# deps.sh: VSCode's npm dependencies, fetched exactly as its lockfiles pin them (yarn 1.22.19,
# `yarn install --ignore-scripts --frozen-lockfile`) with the Node.js VSCode's .nvmrc names (16.17;
# its dependencies' engines exclude both the tree's Node 16.13 and newer majors), without running
# any install script (the native modules are built by native.sh, rg.exe by rg.sh):
#   out/vscode-nm-src/app/node_modules   the root package (the native modules' sources)
#   <dir>/node_modules                   every other build/npm/dirs.js directory, in the
#                                        VSCode tree that package.sh packages (src/vscode)
# Run after checkout.sh; src/vscode is this repository's tree.
set -euo pipefail
W=/home/winrt
S=$W/src
V=$S/vscode
NODE_VER=16.17.1
NODE_SHA256=3dfb8fd8f6b97df69cdc56524abc906c50ef1d0bf091188616802e6c7c731389
NODE=$W/node-v$NODE_VER/bin/node
YARN_SHA256=732620bac8b1690d507274f025f3c6cfdc3627a84d9642e38a07452cc00e0f2e
Y=$W/yarn-1.22.19

if [ ! -f "$Y/bin/yarn.js" ]; then
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 -o "$W/yarn.tgz" https://registry.npmjs.org/yarn/-/yarn-1.22.19.tgz
  echo "$YARN_SHA256  $W/yarn.tgz" | sha256sum -c -
  mkdir -p "$Y"; tar -xzf "$W/yarn.tgz" -C "$Y" --strip-components=1; rm "$W/yarn.tgz"
fi
if [ ! -x "$NODE" ]; then
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 -o "$W/node.tar.xz" \
    "https://nodejs.org/dist/v$NODE_VER/node-v$NODE_VER-linux-arm64.tar.xz"
  echo "$NODE_SHA256  $W/node.tar.xz" | sha256sum -c -
  mkdir -p "$W/node-v$NODE_VER"; tar -xJf "$W/node.tar.xz" -C "$W/node-v$NODE_VER" --strip-components=1; rm "$W/node.tar.xz"
fi
[ "$(cat "$W/repo/.nvmrc")" = "${NODE_VER%.*}" ] || { echo "deps.sh: .nvmrc is not ${NODE_VER%.*}" >&2; exit 1; }
mkdir -p "$W/bin"
printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$NODE" "$Y/bin/yarn.js" > "$W/bin/yarn"; chmod 0755 "$W/bin/yarn"
export PATH="$W/bin:$(dirname "$NODE"):$PATH" HOME=$W/home
mkdir -p "$HOME"

rm -rf "$V"; cp -a "$W/repo" "$V"
fetch() {  # fetch <package dir> <dest dir>
  mkdir -p "$2"
  [ "$1" = "$2" ] || cp "$1/package.json" "$1/yarn.lock" "$2/"
  [ ! -f "$1/.yarnrc" ] || [ "$1" = "$2" ] || cp "$1/.yarnrc" "$2/"
  (cd "$2" && yarn install --ignore-scripts --frozen-lockfile --non-interactive)
}
fetch "$V" "$S/out/vscode-nm-src/app"
for d in $(node -e "console.log(require('$V/build/npm/dirs.js').dirs.filter(Boolean).join('\n'))"); do
  [ -f "$V/$d/package.json" ] || continue
  fetch "$V/$d" "$V/$d"
done

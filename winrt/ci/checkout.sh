#!/bin/bash
# checkout.sh: the Electron source tree this VSCode is built with (winrt/ci/electron.env: the
# Windows on ARM32 port of Electron at the commit of its release), checked out exactly as that
# port's own CI checks it out, into /home/winrt/src (gclient root /home/winrt): src/electron at
# the commit, with the Chromium tree it pins in DEPS and every dependency (no history); then the
# Chromium port's nested-repository patches, Electron's patches, the DEPS hooks the Windows build
# uses, Electron's npm dependencies, and the linux-arm64 host tools the DEPS hooks do not provide.
# The toolchain recipes are Electron's winrt/toolchains plus this repository's (VSCode's).
# The native modules build in the Electron build directory, src/out/electron, as on the host
# that made this port (vscode_native.ninja; its gn is ../../../../../usr/local/bin/gn).
set -euxo pipefail
W=/home/winrt
. "$W/repo/winrt/ci/electron.env"
COMMIT=$ELECTRON_COMMIT
G=$W
S=$G/src
DT=$W/depot_tools
export PATH="$PATH:$DT" DEPOT_TOOLS_UPDATE=0 DEPOT_TOOLS_METRICS=0

if [ ! -d "$DT" ]; then
  git clone -q https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DT"
  # depot_tools as of Chromium 108/109's releases
  git -C "$DT" checkout -q "$(git -C "$DT" rev-list -1 --before=2023-01-20 origin/main)"
fi

# CIPD packages with no linux-arm64 build at this Chromium version's pins: reclient (not used)
# and the host 7-Zip (installed below by winrt/toolchains/win_mingw_fixes/fetch_7z_host_platform.sh).
# gclient's custom_deps cannot drop CIPD entries, so a cipd wrapper leaves them out of `ensure`.
mkdir -p "$W/bin"
cat > "$W/bin/cipd" <<'EOF'
#!/bin/bash
args=("$@")
for i in "${!args[@]}"; do
  if [ "${args[$i]}" = -ensure-file ]; then
    f=${args[$((i + 1))]}
    sed -i -e '\#^infra/rbe/client/#d' -e '\#^infra/3pp/tools/7z/\${platform}#d' -e '\#^infra/3pp/tools/7z/linux-arm64#d' "$f"
  fi
done
exec "$DT/cipd" "$@"
EOF
chmod +x "$W/bin/cipd"
export PATH="$W/bin:$PATH" DT

mkdir -p "$G"
cat > "$G/.gclient" <<EOF
solutions = [{
  "name": "src/electron",
  "url": "https://github.com/${ELECTRON_REPO}.git@${COMMIT}",
  "deps_file": "DEPS",
  "managed": False,
  "custom_deps": {},
  "custom_vars": {"checkout_pgo_profiles": True, "use_mtime_cache": False,
                  "checkout_openxr": True, "generate_location_tags": True},
}]
target_os = ["win"]
EOF
cd "$G"
# checkout_openxr and generate_location_tags as Chromium's own DEPS sets them for a Windows
# checkout (the port's build configuration: OpenXR/VR on), not as Electron's DEPS turns them off.
gclient sync --no-history --shallow -j 8 --nohooks --revision "src/electron@${COMMIT}"

# Electron's version is the nearest tag (script/lib/get-version.js: git describe --tags). A
# shallow checkout has none, so the version this branch builds is tagged here, locally.
git -C "$S/electron" tag -f "v$(cat "$S/electron/winrt/VERSION")" HEAD
# Electron's BUILD.gn lists .git/packed-refs among the version's inputs; a missing input would
# leave build.ninja always out of date.
git -C "$S/electron" pack-refs --all

# The Chromium port's patches to DEPS-pinned dependencies, each committed in its repository (as
# the port's changes to the Chromium tree itself are), then Electron's own patches on top (what
# Electron's DEPS hook patch_chromium runs; git am needs a clean tree).
while read -r repo patch; do
  [ -n "$repo" ] || continue
  git -C "$S/$repo" apply --index --whitespace=nowarn "$S/winrt/patches/$patch"
  git -C "$S/$repo" -c user.name=winrt -c user.email=winrt@localhost -c commit.gpgsign=false \
    commit -q --no-verify -m "Windows on ARM32 port: $patch"
done < "$S/winrt/patches/series"
python3 src/electron/script/apply_all_patches.py src/electron/patches/config.json

# Only the DEPS hooks the Windows build uses. The others fetch x86-64 host tools this host
# cannot run (clang, node, rc, ciopfs, objdump: provided by winrt/toolchains and the builder
# image instead), NaCl (no aarch64 host support), test data, or the sysroots (in the sdk cache).
python3 - <<'EOF'
import subprocess
HOOKS = {"lastchange", "gpu_lists_version", "lastchange_skia", "lastchange_dawn",
         "webui_node_modules", "Fetch PGO profiles for win32"}
ns = {"Var": lambda x: "{%s}" % x, "Str": str}
exec(open("src/DEPS").read(), ns)
done = set()
for h in ns["hooks"]:
    if h.get("name") in HOOKS:
        print("hook:", h["name"], flush=True)
        subprocess.run(h["action"], check=True)
        done.add(h["name"])
assert done == HOOKS, HOOKS - done
EOF

# Electron's DEPS hook electron_npm_deps: yarn install of src/electron/package.json.
YARN=$(python3 -c "
ns = {'Var': lambda x: '{%s}' % x, 'Str': str}
exec(open('$S/electron/DEPS').read(), ns)
print(ns['vars']['yarn_version'])")
(cd "$S/electron" && python3 script/lib/npx.py "yarn@$YARN" install --frozen-lockfile)

rm -rf "$W/toolchains"; cp -a "$S/electron/winrt/toolchains" "$W/toolchains"
cp -a "$W/repo/winrt/toolchains/." "$W/toolchains/"
ln -sfn "$S" "$W/chromium"
CHROMIUM_SRC=$S sh "$W/toolchains/win_mingw_fixes/fetch_node_linux_arm64.sh"
mkdir -p "$S/third_party/lzma_sdk/bin/host_platform"
CHROMIUM_SRC=$S sh "$W/toolchains/win_mingw_fixes/fetch_7z_host_platform.sh"

# Same mtime for every source file in every job (out/ is carried between jobs with its own).
find "$S" -path "$S/out" -prune -o -print0 | xargs -0 touch -h -d "2023-01-01 00:00:00"

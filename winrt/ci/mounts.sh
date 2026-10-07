# Sourced by the build scripts: case-insensitive views (as Chromium's Linux->Windows builds see
# the SDK) of the Windows SDK splat, the port toolchain and the toolchain supplement dirs: a
# lowercase backing copy filled through ciopfs, mounted read-only over the original path (the
# same mounts as the Electron build's winrt/ci/build.sh). MOUNTS: a subset of them.
for D in ${MOUNTS:-sdk/xwin-10.0.22621 sdk/llvm-mingw-winrt toolchains/win_mingw_fixes toolchains/win_sdk_supplement}; do
  C=$W/ci/$(basename "$D")
  if [ ! -d "$C" ]; then
    mkdir -p "$C.new" /mnt/ci
    ciopfs -o use_ino "$C.new" /mnt/ci
    python3 "$W/repo/winrt/ci/ciopfs-fill" "$W/$D" /mnt/ci
    fusermount -u /mnt/ci
    mv "$C.new" "$C"
  fi
  mountpoint -q "$W/$D" ||
    ciopfs -o ro,use_ino,allow_other,nonempty,default_permissions "$C" "$W/$D"
done

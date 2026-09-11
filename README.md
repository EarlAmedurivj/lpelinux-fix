# lpe-fork — a lazily-synced vendored fork of lpe-toolkit

Upstream: https://github.com/portbuster1337/lpe-toolkit
(Base: main @ 2ecb09b, i.e. v1.4.0 + "fix false-positive success reporting")

## Why this fork

| Need | Notes |
|---|---|
| Off-GitHub delivery | Binaries are downloaded from your own server/CDN at deploy time; GitHub is only a fallback |
| Fix upstream bugs | Upstream PwnKit has a triple gcc dependency and a broken trigger (its direct `GCONV_PATH=` env var is stripped by ld.so from SUID programs); fixed here |
| Own build pipeline | `build.sh` produces all 7 architectures in one go |

## Patches (vs upstream)

1. **exploits/cve_2021_4034.c** — self-contained berdav-based rewrite:
   - embeds a per-arch prebuilt `pwnkit.so`, zero gcc dependency on the target;
   - dual trigger channel: the `PATH=GCONV_PATH=.` out-of-bounds write primitive
     (non-root SUID case) plus an explicit `GCONV_PATH=.` (root / glibc builds
     that do not strip it);
   - non-interactive: executes `PK_CMD` (injected by the toolkit in `-c` mode);
   - creates a private `/tmp/.pkXXXXXX` workdir and a parent watcher cleans it
     up after the pkexec chain exits (no residue).
2. **exploits/pwnkit_so_src/pwnkit.c** — gconv module: writes the toolkit's
   success marker `/tmp/.lpe_cve_2021_4034` and executes `PK_CMD`.
3. **copyfail** — amd64/arm64/386 ship the badsectorlabs copyfail-go binary
   (the upstream C implementation was observed failing where the Go one works);
   mips-family archs keep the upstream C implementation (no Go release exists).
   The upstream algif-module SkipCheck was removed: built-in modules are not
   visible in /proc/modules and the check wrongly skipped the exploit. Timeout
   raised to 120s.
4. **toolkit.go** — removed the pwnkit gcc SkipCheck (it blocked the
   pre-compiled path too); `-c` mode injects `PK_CMD` into exploit env;
   `pkExecuted` prevents double command execution; GTFOBins `sudo -n -l`
   stderr silenced in quiet mode.
5. **build-exploits.sh** — no longer aborts (set -e/pipefail) when a
   per-arch directory was not built; build containers get a vendored
   linux/io_uring.h v6.14 (required by pintheft).

## Build

```bash
./build.sh   # cross-compiles all 7 archs -> build_out/lpe-fork-{amd64,arm64,386,mips,mipsle,mips64,mips64le}
```

Upload the binaries to your own server/CDN for the deploy chain to use.

## Lazy sync

When upstream ships a CVE relevant to your targets:

```bash
git pull upstream main
./build.sh
# re-upload the binaries
```

Zero maintenance otherwise.

## Notes

- mips-family `pwnkit.so` is built with the cross toolchain's glibc (2.36);
  on mips targets with an older glibc the module will fail to load and pwnkit
  falls through to the other exploits.
- The exploit corpus itself (23 upstream exploits) is only as good as
  upstream; success depends on the target kernel being inside the
  vulnerable window.

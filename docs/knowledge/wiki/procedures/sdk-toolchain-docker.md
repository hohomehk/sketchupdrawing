---
id: sdk-toolchain-docker
type: procedure
market: na
tone: cantonese
confidence: 0.95
sources:
  - ref: 2026-04-29 conversation building Dockerfile + skpbuild image
    date: 2026-04-29
  - ref: ../../../../Dockerfile
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-10-29
tags: [docker, mingw, wine, sdk, toolchain]
---

# SDK Toolchain Setup（Docker + mingw + Wine 9）

## Lever

Trimble SketchUp C SDK **冇 Linux build**（官方只 ship Windows .dll／.lib + Mac .framework／.dylib）。WSL2 又冇 automount Windows-side filesystem，所以唔能直接 dlopen DLL／dylib。**唯一可行 path：用 mingw-w64 cross-compile Windows EXE，再用 Wine 跑。**

全部 sandbox 喺一個 docker image，host 完全冇裝 wine／sdk。

## 重要決定 + 點解

| 決定 | 點解 |
|---|---|
| Ubuntu 24.04 base（唔用 22.04） | Ubuntu 22.04 嘅 wine 6.0 太舊，跑 vc_redist.x64.exe installer fail；Ubuntu 24.04 嘅 wine 9.0 OK |
| 用 mingw-posix variant（唔用 win32） | C++14 thread support，避 std::strlen / std::cstring import 問題 |
| `-static -static-libgcc -static-libstdc++` build | 唔使搬 libwinpthread-1.dll、libgcc_s_seh-1.dll；EXE self-contained |
| `wine` wrapper script set `WINELOADER` env | Ubuntu 24.04 wine64 binary 喺 `/usr/lib/wine/wine64`，直接 invoke 會搵唔到 loader |
| Wine prefix 喺 container 內部（`/wineprefix`） | host bind-mount 會撞 ownership；container 內部跑 root + 自己整 prefix 最乾淨 |
| MSVCP140_CODECVT_IDS.dll 等 VC++ runtime DLL | Wine 9 builtin 已經提供（唔需要 winetricks vcrun2019，反而 wow64 fail） |

## Dockerfile

完整檔案見 [`../../../../Dockerfile`](../../../../Dockerfile)。Key sections:

```dockerfile
FROM ubuntu:24.04
RUN dpkg --add-architecture i386 && apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wine64 mingw-w64 g++-mingw-w64-x86-64 \
        cabextract p7zip-full make cmake python3 xvfb && \
    rm -rf /var/lib/apt/lists/*

# posix variant for C++14 thread support
RUN update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix && \
    update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix

# wine wrapper（Ubuntu 24.04 wine64 binary 唔喺 PATH，要設 WINELOADER）
RUN curl -sL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
        -o /usr/local/bin/winetricks && chmod +x /usr/local/bin/winetricks && \
    printf '#!/bin/sh\nexport WINELOADER=/usr/lib/wine/wine64\nexport WINESERVER=/usr/lib/wine/wineserver64\nexec /usr/lib/wine/wine64 "$@"\n' \
        > /usr/local/bin/wine && chmod +x /usr/local/bin/wine && \
    ln -s wine /usr/local/bin/wine64

ENV WINEDEBUG=-all
ENV WINEPREFIX=/wineprefix
WORKDIR /work
```

Build：
```bash
cd /home/timothy/sketchupdrawing
docker build -t skpbuild .   # 第一次大概 100s（download package）；後續 cached
```

## Compile a Sample

```bash
cd /home/timothy/sketchupdrawing
docker run --rm -v "$PWD:/work" skpbuild bash -c '
  cd /work
  x86_64-w64-mingw32-g++ -std=c++14 -O2 -Iwin/headers \
    dump_skp.cpp \
    win/binaries/sketchup/x64/SketchUpAPI.lib \
    -static -static-libgcc -static-libstdc++ \
    -o dump_skp.exe'
```

成功 build 出 ~1MB EXE。Copy 到 DLL 隔籬以方便 wine 找：
```bash
cp dump_skp.exe win/binaries/sketchup/x64/
```

## Run via Wine

```bash
docker run --rm -v "$PWD:/work" -v "/tmp/m.skp:/tmp/m.skp:ro" skpbuild bash -c '
  export WINEPREFIX=/wineprefix WINEDEBUG=-all
  wine wineboot --init >/dev/null 2>&1
  cd /work/win/binaries/sketchup/x64
  wine ./dump_skp.exe Z:/tmp/m.skp'
```

第一次 `wineboot --init` 會 init prefix（5-10s）；之後重用同一個 container 就唔再做。

## 試過行唔通嘅 path

1. ❌ **Mac SDK on Linux** — `SketchUpAPI.framework/Versions/A/SketchUpAPI` 係 Mach-O fat binary（x86_64 + arm64）。Linux 載入唔到。
2. ❌ **Wine 6.0（Ubuntu 22.04 default）** — `winetricks vcrun2019` 跑 vc_redist.x86.exe 嘅時候 syswow64 環境唔齊全。
3. ❌ **Winetricks vcrun2019 on Wine 9** — Wine 9 pure-64 mode 冇 syswow64，winetricks 32-bit fallback fail。Workaround: download vc_redist.x64.exe 直接跑（但其實 Wine 9 builtin 已經夠用）。
4. ❌ **bind-mount wineprefix 落 host folder** — wine 唔肯接受 ownership mismatch；解決方法係 prefix 留喺 container 內部。
5. ❌ **直接 ln -s wine64 to wine** — Ubuntu 24.04 wine64 binary 嘅 path discovery 會 fail；要 wrapper script set `WINELOADER`。

## 驗證 toolchain 健康

```bash
docker run --rm skpbuild bash -c '
  wine --version              # wine-9.0
  x86_64-w64-mingw32-g++ --version | head -1
  ls /usr/lib/wine/wine64'    # /usr/lib/wine/wine64 存在
```

## Cost / Footprint

- Image size：~1.5 GB（mingw + wine + dev tools）
- Build time：100s 第一次 ；rebuild 用 layer cache <5s
- Per-run wineboot：~5s
- Tool exec：1-3 秒（11 MB SKP）

## Changelog
- 2026-04-29 — Initial creation；toolchain confirmed working on `寶翠園5.skp`

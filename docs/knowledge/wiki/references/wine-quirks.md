---
id: wine-quirks
type: reference
market: na
tone: cantonese
confidence: 0.9
sources:
  - ref: 2026-04-29 build session debugging argv encoding + path encoding
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-10-29
tags: [wine, mingw, encoding, ubuntu]
---

# Wine / Encoding Quirks

跑 SketchUp Win SDK 喺 Linux 嘅環境特性。我哋撞過嘅地雷一次過記低。

## 1. Wine 9.0 pure-64 mode 冇 wow64

Ubuntu 24.04 嘅 wine64 package（version 9.0）**只 support 64-bit**，冇 32-bit fallback。

| 後果 | Workaround |
|---|---|
| `winetricks vcrun2019` 試行 vc_redist.x86.exe → fail | 跳過 winetricks，直接 download `vc_redist.x64.exe` 跑（或者直接靠 Wine 9 builtin `msvcp140`） |
| 32-bit Windows EXE 完全跑唔到 | 我哋淨係 build x64 EXE，唔影響 |

**Wine 9 builtin 嘅 `msvcp140.dll` / `vcruntime140.dll` 已經夠 SketchUp SDK 用**（無需 vc_redist）。

## 2. wine64 binary path 唔喺 PATH

Ubuntu 24.04：
```
/usr/lib/wine/wine64       ← 真 binary
/usr/bin/wine64             ← 唔存在
```

直接 invoke `/usr/lib/wine/wine64 ...` 會 `wine: could not exec the wine loader`，因為 path discovery 搵唔到 `wine-preloader`。

**Workaround**：寫 wrapper script 設 `WINELOADER`／`WINESERVER`：
```sh
#!/bin/sh
export WINELOADER=/usr/lib/wine/wine64
export WINESERVER=/usr/lib/wine/wineserver64
exec /usr/lib/wine/wine64 "$@"
```

放 `/usr/local/bin/wine` 同 `/usr/local/bin/wine64`。

## 3. 中文 argv 死路 ☠

Wine + Linux argv 之間嘅 UTF-8 ↔ wide char 轉換**會 mangle CJK**：

```
$ wine ./tool.exe 主人房衣櫃
# tool.exe 收到嘅 argv[1] = "d8;d::f?h!#f+"
```

呢個係 Wine 嘅 wide-char／locale 問題，冇辦法**直接**用 argv 傳中文。

**Workaround**：用 stdin 傳 raw UTF-8 bytes：
```cpp
int main(int argc, char** argv) {
    char buf[256] = {0};
    std::fgets(buf, sizeof(buf), stdin);
    size_t bn = std::strlen(buf);
    while (bn && (buf[bn-1] == '\n' || buf[bn-1] == '\r')) buf[--bn] = 0;
    const char* sceneName = buf;  // raw UTF-8, 唔經 Wine argv 轉換
}
```

Invocation：
```bash
printf "主人房衣櫃\n" | wine ./tool.exe model.skp
```

`printf` 寫 raw UTF-8 落 stdin，bypass 晒 Wine 嘅 argv 處理。

**或者**用 index：`printf "#2\n" | wine ./tool.exe ...`（唔涉中文）。我哋兩個 mode 都 support。

## 4. 中文 path 死路 ☠

```
$ wine ./tool.exe Z:/home/timothy/mydocs/寶翠園5.skp
SUModelCreateFromFileWithStatus failed: 7  (SU_ERROR_SERIALIZATION)
```

Wine 將 Z:\...\寶翠園5.skp 轉成 Windows wide path 嘅時候 mangling 等同 argv。SDK 收到 garbage path，搵唔到 file。

**Workaround**：copy file 去 ASCII path：
```bash
cp "/home/timothy/mydocs/寶翠園5.skp" /tmp/m.skp
wine ./tool.exe Z:/tmp/m.skp
```

每次 fresh run 都 copy 一次，係 cheap operation（11MB file <0.1s）。

## 5. wineboot init 要喺 container 內部

```
wine: '/work/wineprefix' is not owned by you
```

如果你 bind-mount host folder 做 wineprefix（`-v $PWD/wineprefix:/wineprefix`），host 嘅 ownership 同 container root user 唔 match → wine refuse start。

**Workaround**：prefix 留喺 container 內部唔 mount：
```bash
docker run --rm -v "$PWD:/work" skpbuild bash -c '
  export WINEPREFIX=/wineprefix       # ← 唔 mount，由 image 提供
  wine wineboot --init
  ...
'
```

每次 fresh container 跑一次 `wineboot --init`（5-10s）唔算貴。

## 6. mingw posix vs win32 thread variant

```
update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix
```

Win32 variant 唔支援 C++14 thread library；要 posix。Ubuntu 24.04 兩個 variant 都裝，但 default 通常係 win32。記住 update-alternatives switch 過去。

## 7. -static 全靜態 link 必須

```
err:module:import_dll Library libwinpthread-1.dll ... not found
err:module:import_dll Library libgcc_s_seh-1.dll ... not found
```

Default mingw build 會 dynamic link mingw runtime。Wine prefix 入面冇 mingw runtime DLL → 載入 fail。

**Workaround**：build flag 加 `-static -static-libgcc -static-libstdc++`。EXE size 由 ~50KB 變 ~700KB－1MB，但 self-contained。

## 8. `file` command 冇裝喺 Ubuntu 24.04 minimal image

`docker run skpbuild bash -c 'file ...'` 會 `file: command not found`。我哋冇加入 image，因為直接 hex dump 同 mingw `objdump` 已經夠用。

需要嘅話加返：`apt-get install file`。

## 9. SDK header 用 `cstdlib` / `cstring` 但唔自動 include

```cpp
size_t bn = std::strlen(buf);          // ← error: 'strlen' is not a member of 'std'
```

要顯式 `#include <cstring>` / `#include <cstdlib>`。SDK 自己嘅 header 唔 transitively expose 呢啲。

## 10. SU 嘅 entity ID 函數要 `entity.h`

```cpp
SUEntityGetID(en, &id);   // ← undeclared in scope
```

要 `#include <SketchUpAPI/model/entity.h>`。容易漏，因為其他 SU* function 通常喺更具體 header（如 `component_instance.h`）已經 include 咗。

## Changelog
- 2026-04-29 — Initial; covers Ubuntu 24.04 + Wine 9 + mingw-posix + 寶翠園5 parsing

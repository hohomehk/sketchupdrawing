---
id: parse-skp-cli
type: procedure
market: na
tone: cantonese
confidence: 0.9
sources:
  - ref: 2026-04-29 conversation
    date: 2026-04-29
  - ref: ../../../../dump_skp.cpp
    date: 2026-04-29
  - ref: ../../../../dump_dims.cpp
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-10-29
tags: [cli, sdk, dimension, component, scene]
---

# Parse SKP CLI Cookbook

開新 `.skp` 嗰陣標準 workflow。Toolchain setup 見 [SDK Toolchain](sdk-toolchain-docker.md)。

## Step 0: Pre-flight

```bash
# 1. ASCII path（避 Wine 中文 path bug）
cp "/home/timothy/mydocs/寶翠園5.skp" /tmp/m.skp

# 2. Build image 一次（已 build 過就 skip）
docker build -t skpbuild .
```

## Step 1: Inventory（整體結構）

跑 [`dump_skp`](../tools/dump-skp.md)：

```bash
docker run --rm -v "$PWD:/work" -v "/tmp/m.skp:/tmp/m.skp:ro" skpbuild bash -c '
  export WINEPREFIX=/wineprefix WINEDEBUG=-all
  wine wineboot --init >/dev/null 2>&1
  cd /work/win/binaries/sketchup/x64
  wine ./dump_skp.exe Z:/tmp/m.skp > /work/out/dump.txt'
```

睇 `out/dump.txt`：

| Section | 內容 |
|---|---|
| `MODEL` | 名 + version |
| `LAYERS (n)` | 全部 layer |
| `SCENES (n)` | 全部 scene；用嚟 cross-reference 嵌入 thumbnail PNG |
| `COMPONENT DEFINITIONS (n)` | 每個 def 嘅 name、instance count、face count、local bbox |
| `TOP-LEVEL ENTITIES` | 攞 root 落咗咩 group + instance（含 transform position） |

## Step 2: Dimensions（攞 user 標嘅實際尺寸）

```bash
docker run --rm -v "$PWD:/work" -v "/tmp/m.skp:/tmp/m.skp:ro" skpbuild bash -c '
  export WINEPREFIX=/wineprefix WINEDEBUG=-all
  wine wineboot --init >/dev/null 2>&1
  cd /work/win/binaries/sketchup/x64
  wine ./dump_dims.exe Z:/tmp/m.skp > /work/out/dims.txt'
```

`dump_dims` 遞歸全 model。每個 dim 一行：`len_mm  label  z_mid  context`。

**重要**：搵特定 cabinet 嘅 dim 要 filter XY range（`grep`／`awk`）。User 唔會喺 cabinet group 內標 dimension，會喺 root level 標。

## Step 3: 找邊個 Component 屬一個 Scene

Scene 一般係 camera angle，唔等於 component。要識別某 scene 對應邊個 component 結構：

1. 跑 `dump_dims`，filter 出該 scene 範圍嘅 dim（用 XY 範圍）
2. 攞嗰啲 dim 嘅 length 同 z_mid 對返 root-level instance 嘅 world bbox
3. World bbox match 嘅嗰個 instance 嘅 ComponentDefinition 就係佢

睇 [master-bedroom-wardrobe finding](../findings/master-bedroom-wardrobe.md) 攞完整 example。

## Step 4: 拆 Component 子樹

```bash
docker run --rm -v "$PWD:/work" -v "/tmp/m.skp:/tmp/m.skp:ro" skpbuild bash -c '
  export WINEPREFIX=/wineprefix WINEDEBUG=-all
  wine wineboot --init >/dev/null 2>&1
  cd /work/win/binaries/sketchup/x64
  printf "Component#99\n" | wine ./tree_skp.exe Z:/tmp/m.skp'
```

⚠️ **Scene／Component name 必須由 stdin 傳，唔可以用 argv**。Wine 嘅 argv UTF-8 中文會 mangling 變 `d8;d::f?h!#f+` 之類嘅 garbage。

詳見 [Wine Quirks](../references/wine-quirks.md)。

## Common Pitfalls

| 問題 | 解決 |
|---|---|
| `SU_ERROR_SERIALIZATION` (code 7) 載入 fail | 中文路徑 ── copy 去 `/tmp/m.skp` |
| `scene with name containing "d8;..." not found` | 中文 argv 中招 ── 改用 stdin（`printf "name\n" \| wine ./tool.exe ...`） |
| Linear dim length = -1 | `SUDimensionLinearGetStartPoint` 嘅 `SUInstancePathRef*` 唔可以係 NULL ── create 一個 valid path object |
| `SU_ERROR_INVALID_INPUT` | Forgot `SUInitialize()` 或者 release 咗 model 之後再用 |
| 0 dimensions found 但實際應該有 | 你只 query 咗 root entities；要遞歸落 group／instance（dim 通常喺 root group 入面） |

## Output Conventions

我哋嘅 dumper 全部用 mm 做單位（SKP 內部 inch × 25.4），統一格式方便 grep／awk。

## Changelog
- 2026-04-29 — Initial creation；based on 2026-04-29 寶翠園5.skp parsing session

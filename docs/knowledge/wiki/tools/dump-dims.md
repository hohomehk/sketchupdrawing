---
id: tool-dump-dims
type: tool
market: na
tone: cantonese
confidence: 0.95
sources:
  - ref: ../../../../dump_dims.cpp
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-10-29
tags: [tool, sdk, dimension]
---

# `dump_dims` — All SUDimension Entities

## What

遞歸全 model，print 每個 SUDimension（linear）entity 嘅實際長度、user override label、3D 中心高度、所喺嘅 group / component path。

呢個係**搵 user 標嘅尺寸**嘅權威 tool。

Source: [`dump_dims.cpp`](../../../../dump_dims.cpp)

## Build

```bash
docker run --rm -v "$PWD:/work" skpbuild bash -c '
  cd /work
  x86_64-w64-mingw32-g++ -std=c++14 -O2 -Iwin/headers \
    dump_dims.cpp \
    win/binaries/sketchup/x64/SketchUpAPI.lib \
    -static -static-libgcc -static-libstdc++ \
    -o dump_dims.exe'
cp dump_dims.exe win/binaries/sketchup/x64/
```

## Run

```bash
docker run --rm -v "$PWD:/work" -v "/tmp/m.skp:/tmp/m.skp:ro" skpbuild bash -c '
  export WINEPREFIX=/wineprefix WINEDEBUG=-all
  wine wineboot --init >/dev/null 2>&1
  cd /work/win/binaries/sketchup/x64
  wine ./dump_dims.exe Z:/tmp/m.skp > /work/out/dims.txt'
```

## Output format

```
Total linear dimension entities: N

len(mm)   label                          z_mid         context
    2042                                         2193  root
     500                                          250  root/inst[0]/grp[3]
     555  550                                       0  root          ← label override：實際 555mm，user 寫 550
    2875                                         1437  root          ← 主人房衣櫃高度
     ...
```

| Column | 意思 |
|---|---|
| `len(mm)` | 實際 start→end 距離（從 SDK 計，最準） |
| `label` | User 手動 override 嘅文字（空白 = SketchUp auto-display 嘅 measured length） |
| `z_mid` | 該 dim 嘅中點 Z 座標（mm）；用嚟篩同高度嘅 dim |
| `context` | 由 root 開始嘅 hierarchy path |

## Tip — Filter by spatial range

寶翠園5.skp 將每間房擺喺唔同 XY 位置。要搵某間房嘅 dim，加 XY filter（modify source 或者 `awk`）：

```bash
# 主人房衣櫃 area: world XY (107000-112000, 85000-92000) — 從 dump_skp top-level instances 推算
awk 'NR>4 && $NF == "root"' out/dims.txt > /tmp/root_dims.txt
# 然後手動 grep length match user 講嘅尺寸（e.g. 2875）
grep -E "^ *2875" /tmp/root_dims.txt
```

或者直接 hard-code XY range 喺 source 裡面（[master-bedroom-wardrobe finding](../findings/master-bedroom-wardrobe.md) 用咗呢個方法）。

## Pitfalls (踩過)

- **First version 全部 length=-1**：因為 `SUDimensionLinearGetStartPoint` 嘅 `SUInstancePathRef* path` 參數**唔可以 NULL**。要 `SUInstancePathCreate(&path)` 先用，用完 release。詳見 [Wine Quirks #1](../references/wine-quirks.md) 同 [SDK Cheatsheet](../references/sdk-api-cheatsheet.md#suinstancepathref-trap-).
- **Top-level only 之 query 永遠 0**：寶翠園5 將所有 dim 放喺 root group 入面，唔喺 ComponentDefinition 直接 children。一定要遞歸全 model。

## Use case

- 確認 user 實際標咗咩尺寸（vs 我哋 SDK 計嘅 bbox）
- Filter 出某 cabinet 嘅 dim 攞 ground truth（例：[找衣櫃高度 2875](../findings/master-bedroom-wardrobe.md#1-sudimension-entity最高-confidence)）

## Changelog
- 2026-04-29 — Initial；first version 漏咗 SUInstancePathRef，已修

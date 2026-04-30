---
id: tool-tree-skp
type: tool
market: na
tone: cantonese
confidence: 0.95
sources:
  - ref: ../../../../tree_skp.cpp
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-10-29
tags: [tool, sdk, component, tree]
---

# `tree_skp` — Recursive Component Tree

## What

針對一個指定 ComponentDefinition（或 root），**遞歸**列佢嘅 children — 每個 group／instance 嘅 name、local bbox、placement position。Cabinet 內部結構解剖嘅主力 tool。

Source: [`tree_skp.cpp`](../../../../tree_skp.cpp)

## Build

```bash
docker run --rm -v "$PWD:/work" skpbuild bash -c '
  cd /work
  x86_64-w64-mingw32-g++ -std=c++14 -O2 -Iwin/headers \
    tree_skp.cpp \
    win/binaries/sketchup/x64/SketchUpAPI.lib \
    -static -static-libgcc -static-libstdc++ \
    -o tree_skp.exe'
cp tree_skp.exe win/binaries/sketchup/x64/
```

## Run

ComponentDefinition name 由 stdin 傳：
```bash
docker run --rm -v "$PWD:/work" -v "/tmp/m.skp:/tmp/m.skp:ro" skpbuild bash -c '
  export WINEPREFIX=/wineprefix WINEDEBUG=-all
  wine wineboot --init >/dev/null 2>&1
  cd /work/win/binaries/sketchup/x64
  printf "Component#99\n" | wine ./tree_skp.exe Z:/tmp/m.skp'
```

3 種 query mode（stdin 第一行）：
| Input | 意思 |
|---|---|
| `Component#99`（或任何 substring） | Match 第一個 name 含此 substring 嘅 def |
| `#125` | Match index 125 嘅 def |
| `root` | 由 root entities 開始 dump |

## Output

```
== Definition "Component#99" ==
BBox local: 1900 x 501 x 2875 mm  (faces=0 edges=0)
+ Group[0] ""
  BBox local: 1792 x 0 x 730 mm  (faces=0 edges=48)
+ Inst[0] def=底托櫃桶 @ (1325,485,675)
  BBox local: 1098 x 254 x 1 mm  (faces=303 edges=843)
+ Inst[6] def=Component#204 @ (465,-15,-0)
  BBox local: 1900 x 501 x 2875 mm  (faces=57 edges=145)
  + Group[0] ""
    BBox local: 0 x 0 x 2825 mm  (faces=0 edges=71)
  + Inst[0] def=格仔櫃桶 @ (1678,500,914)
    BBox local: 1100 x 253 x 1 mm  (faces=276 edges=762)
  ...
```

| 行格式 | 意思 |
|---|---|
| `BBox local: W x D x H` | 該 entity container 嘅 axis-aligned bbox（local coords） |
| `+ Group[i] "name"` | Group child（name 通常空字串，user 唔命名） |
| `+ Inst[i] def=NAME @ (x,y,z)` | ComponentInstance child；位置係該 instance 嘅 transform translation |

## Recursion limit

Default `depth > 8` 截斷；shared component（multi-instance）淨係喺第一層 expand，避免重複 dump。Source 入面個 `if (depth < 2)` 條件控制呢個 ── 需要更深 expand 改個數字 rebuild。

## Use case

- 拆 cabinet 結構：搵晒主櫃身、抽屜、層板、門板、五金（[Component#99 + Component#157 拆解](../findings/master-bedroom-wardrobe.md#3-component99-內部結構)）
- Sanity check：confirm `local bbox` 同 user 標嘅 dim entity 對唔對得上
- 搵亂跌嘅 component（例如導入後嘅第三方 model）

## Pitfalls

- **Component name 中文 OK 過 stdin** — 同 `wardrobe_dim` 一樣方法 bypass argv encoding
- **Instance `name` 通常空** — 用 `def=` 嗰個追識別

## Changelog
- 2026-04-29 — Initial；用過嚟拆 Component#99／#157／#180 三個 cabinet

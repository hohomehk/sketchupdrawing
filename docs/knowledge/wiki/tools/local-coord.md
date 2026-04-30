---
id: tool-local-coord
type: tool
market: na
tone: cantonese
confidence: 0.95
sources:
  - ref: ../../../../local_coord.cpp
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-10-29
tags: [tool, sdk, transform, inverse]
---

# `local_coord` — World→Local Inverse Transform

## What

俾一個 world 座標同一個 ComponentDefinition name，攞返**該 def root instance 嘅 4×4 transform**，計 inverse 將 world 點轉到該 instance 嘅 local frame，並列印**到 local bbox 6 個面**嘅距離。

主要用途：搵 SUText／SUDimension anchor 喺某 cabinet 內部嘅相對位置（離櫃背、離櫃前、離地）。

Source: [`local_coord.cpp`](../../../../local_coord.cpp)

## Build

```bash
docker run --rm -v "$PWD:/work" skpbuild bash -c '
  cd /work
  x86_64-w64-mingw32-g++ -std=c++14 -O2 -Iwin/headers \
    local_coord.cpp \
    win/binaries/sketchup/x64/SketchUpAPI.lib \
    -static -static-libgcc -static-libstdc++ \
    -o local_coord.exe'
cp local_coord.exe win/binaries/sketchup/x64/
```

## Run

```bash
docker run --rm -v "$PWD:/work" -v "/tmp/m.skp:/tmp/m.skp:ro" skpbuild bash -c '
  export WINEPREFIX=/wineprefix WINEDEBUG=-all
  wine wineboot --init >/dev/null 2>&1
  cd /work/win/binaries/sketchup/x64
  wine ./local_coord.exe Z:/tmp/m.skp <def_name> <wx_mm> <wy_mm> <wz_mm>'
```

`def_name` 用 substring match。Component name e.g. `Component#157` 係純 ASCII，可以直接做 argv —— 唔需要 stdin trick（[Wine quirk](../references/wine-quirks.md) 只 affect 中文）。

## Output

```
Matched root instance: def="Component#157"

world<-local (instance transform) = [
      0.707107    -0.707107     0.000000  4318.614967
      0.707107     0.707107     0.000000  3430.025499
     -0.000000     0.000000     1.000000    -0.000000
      0.000000     0.000000     0.000000     1.000000
]

Def local bbox: X=[35, 555], Y=[-370, 1930], Z=[0, 2875] mm

local<-world (inverse) = [...]

=== World point ===
  (110128, 87034, 1260) mm
=== Same point in instance LOCAL frame ===
  (245.0, -370.4, 1260.0) mm

=== Distance to each local-bbox face (mm) ===
  to X- face (local x=35): 210.0      ← carcass 背
  to X+ face (local x=555): 310.0     ← carcass 前
  to Y- face (local y=-370): -0.4
  to Y+ face (local y=1930): 2300.4
  to Z- face (local z=0): 1260.0      ← 離地
  to Z+ face (local z=2875): 1615.0
```

## Sanity check pattern

跑同一個 world 點對唔同 def，確認 anchor 真係屬邊個 cabinet：

```bash
wine ./local_coord.exe Z:/tmp/m.skp Component#157 110128 87034 1260   # local (245, -370, 1260) ← match
wine ./local_coord.exe Z:/tmp/m.skp Component#99  110128 87034 1260   # local (2675, 2285, 1260) ← out of bbox
```

## Algorithm

1. Iterate root instances，搵第一個 def name match 嘅 instance
2. `SUComponentInstanceGetTransform` 攞 4×4 (column-major)
3. Cofactor-expansion 計 4×4 inverse（手寫，唔靠 std lib）
4. Apply inverse 到 world 點
5. 對比 def local bbox 印 6 個 face 嘅距離

## Use cases

- 離櫃前／離櫃背距離（[預埋制盒 finding](../findings/master-bedroom-electrical-box.md)）
- Confirm 一個 SUText／SUDimension anchor 屬邊個 component（cross-test 多個 def）
- 將 SUDimension start／end 轉返 local 攞「板嘅 cut list 入面 dim 嘅相對位置」

## ⚠️ 注意：Local 軸方向約定

呢個 tool 印 6 個 face 嘅 distance，**唔會自動標哪個 face 係「前」／「背」／「左」／「右」**。**唔好憑 component name 估**：Component#157 入面 Component#202 雖然係門板層，但放喺 high-X (515-555)，而 user 約定**低-X (35) 才係櫃前**。

**以 user 實測 cross-validate** 先；單靠 SDK heuristic 唔夠。

## Limitation

- 只 query**首個**符合 def name 嘅 root instance；如果同一 def 喺 root 有多個 instance（罕有），改 source 加 index argument
- 假設 root level instance；如果目標 def 嵌喺 nested group / instance 入面，要遞歸搵 + accumulate parent transforms

## Changelog
- 2026-04-29 — Initial；首次用嚟搵衣櫃預埋制盒離櫃背 210mm

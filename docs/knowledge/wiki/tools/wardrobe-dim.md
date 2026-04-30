---
id: tool-wardrobe-dim
type: tool
market: na
tone: cantonese
confidence: 0.7
sources:
  - ref: ../../../../wardrobe_dim.cpp
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-10-29
tags: [tool, sdk, scene, wardrobe]
---

# `wardrobe_dim` — Scene-Based Cabinet Bbox（Experimental）

## What

俾 scene name，攞個 scene 嘅 camera position／hidden entities，filter root entities 出嚟，計合併 world bbox。

⚠️ **呢個 tool 實際對 `寶翠園5.skp` 用唔到** — 因為 user 個 model 嘅 scene 純粹靠 camera framing isolate cabinet，**冇用 hide flag**。Camera target 又唔指住 cabinet 中心（`寶翠園5` 主人房衣櫃 scene 個 target Z = -19444mm）。

留低嚟做：
1. 試其他 model（可能有用 hide flag 嘅 user）
2. 紀錄試過嘅 dead-end approach 用 reference

Source: [`wardrobe_dim.cpp`](../../../../wardrobe_dim.cpp)

## Build / Run

```bash
docker run --rm -v "$PWD:/work" skpbuild bash -c '
  cd /work
  x86_64-w64-mingw32-g++ -std=c++14 -O2 -Iwin/headers \
    wardrobe_dim.cpp \
    win/binaries/sketchup/x64/SketchUpAPI.lib \
    -static -static-libgcc -static-libstdc++ \
    -o wardrobe_dim.exe'
cp wardrobe_dim.exe win/binaries/sketchup/x64/

docker run --rm -v "$PWD:/work" -v "/tmp/m.skp:/tmp/m.skp:ro" skpbuild bash -c '
  export WINEPREFIX=/wineprefix WINEDEBUG=-all
  wine wineboot --init >/dev/null 2>&1
  cd /work/win/binaries/sketchup/x64
  printf "主人房衣櫃\n" | wine ./wardrobe_dim.exe Z:/tmp/m.skp'
```

`#2` 之類嘅 index syntax 同 substring match 都 support；name 由 stdin 傳避中文 argv 問題。

## Output

```
Matched scene: "  主人房衣櫃"
UseHidden=1 UseHiddenGeometry=1 UseHiddenObjects=1
Scene hides 0 entities

kind    def_or_grp                pos_mm                         world_bbox_mm
inst    Component#203             (...)                          (...)
...

==== RESULT ====
Kept N, hidden-skipped M (of X instances + Y groups)
Combined visible bbox (mm):
  X: ... length=...
  Y: ... width =...
  Z: ... height=...

  L x W x H  =  ...
```

## What it tries

1. Match scene by name（substring 或 `#index`）
2. Read camera：`SUSceneGetCamera` → `SUCameraGetOrientation`
3. Read explicit hidden list：`SUSceneGetHiddenEntities`
4. Read per-entity per-scene hide：`SUSceneGetDrawingElementHidden`
5. 對 root level 每個 instance / group 應用 transform 攞 world bbox
6. Combine：union 全部「冇 hide」嘅 entity 嘅 world bbox

## Why it didn't work for 寶翠園5

| Step | Outcome |
|---|---|
| Camera target | (56886, 97845, -19444) — Y 同 Z 都唔 match wardrobe location |
| `SUSceneGetHiddenEntities` | 0 entities |
| `SUSceneGetDrawingElementHidden` | 全部 false |

→ 用 radius filter 又會撈錯 cluster；用 hidden filter 完全冇 effect。最後得 400m × 400m 嘅 unfiltered combined bbox。

## When it might work

- Model 用 `Tag`（即 Layer）配 scene 控制 visibility
- Model 用 `SUSceneSetDrawingElementHidden` 明確 hide 其他 cabinet
- Model 嘅 cabinet 真係喺 camera target 附近（typical workflow）

## What we did instead

直接 query SUDimension entity 嘅 location 反向索引到 component：見 [master-bedroom-wardrobe finding](../findings/master-bedroom-wardrobe.md#1-sudimension-entity最高-confidence)。

## Changelog
- 2026-04-29 — Initial；experimental，未通用

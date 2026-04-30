---
id: tool-dump-skp
type: tool
market: na
tone: cantonese
confidence: 0.95
sources:
  - ref: ../../../../dump_skp.cpp
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-10-29
tags: [tool, sdk, inventory]
---

# `dump_skp` — Model Inventory

## What

開一個 .skp，print 全部 layer / scene / ComponentDefinition / top-level entity 嘅 summary。第一個用嚟摸新 model 嘅工具。

Source: [`dump_skp.cpp`](../../../../dump_skp.cpp)

## Build

```bash
docker run --rm -v "$PWD:/work" skpbuild bash -c '
  cd /work
  x86_64-w64-mingw32-g++ -std=c++14 -O2 -Iwin/headers \
    dump_skp.cpp \
    win/binaries/sketchup/x64/SketchUpAPI.lib \
    -static -static-libgcc -static-libstdc++ \
    -o dump_skp.exe'
cp dump_skp.exe win/binaries/sketchup/x64/
```

## Run

```bash
docker run --rm -v "$PWD:/work" -v "/tmp/m.skp:/tmp/m.skp:ro" skpbuild bash -c '
  export WINEPREFIX=/wineprefix WINEDEBUG=-all
  wine wineboot --init >/dev/null 2>&1
  cd /work/win/binaries/sketchup/x64
  wine ./dump_skp.exe Z:/tmp/m.skp [needle]'
```

`needle` (optional) — substring 用嚟 trigger detail dump faces 嘅 component。Default: `衣櫃`（受 Wine argv mangling 影響，通常會 mismatched，但 inventory section 唔受影響）。

## Output sections

```
== MODEL ==
name=...

== LAYERS (n) ==
  L0   Layer0
  ...

== SCENES (n) ==
  S0   <name>
  ...

== COMPONENT DEFINITIONS (n) ==
  D0   name=<name>  inst=N(used=M)  faces_total=K  size_mm=(W x D x H)
  ...

== TOP-LEVEL ENTITIES ==
groups_at_root=N instances_at_root=M
  G0  <group_name>  size_mm=(...)
  ...
  I0  inst=<inst_name>  def=<def_name>  pos_mm=(x,y,z)
  ...

== DETAILED DUMP for definitions containing <needle> ==
<face/edge/vertex dump>
```

## Notable behaviour

- **Recursive face counter** — `faces_total` 包括嗰個 def 嘅 group／instance 入面遞歸出嚟嘅 face count（唔淨 top level）
- **Scene name 中文 OK** — 因為 scene name 用 `SUSceneGetName` 攞 raw UTF-8，唔經 argv
- **needle argv 中文 fail** — 受 [Wine quirk #3](../references/wine-quirks.md#3-中文-argv-死路-) 影響，需要再做嘅話改用 stdin

## Use case

開新 .skp 第一步：跑 `dump_skp` 攞 inventory 同 top-level layout，再決定下一步用 `dump_dims` / `tree_skp` / `wardrobe_dim` 邊個。

## Changelog
- 2026-04-29 — Initial; used to dump 寶翠園5.skp（48 scenes / 259 defs）

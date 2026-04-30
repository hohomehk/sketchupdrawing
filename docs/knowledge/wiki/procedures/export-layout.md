---
id: export-layout
type: procedure
market: na
tone: cantonese
confidence: 0.95
sources:
  - ref: 2026-04-29 build session — `LODocumentSaveToFile` working
    date: 2026-04-29
  - ref: ../../../../skp_to_layout.cpp
    date: 2026-04-29
  - ref: ../../../../scripts/export_layout.rb
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-10-29
tags: [layout, export, document, sdk, ruby]
---

# Export `.layout` Document from `.skp`

## Why

LayOut document（`.layout`）係 Trimble 自家可編輯嘅施工繪圖 format：
- 一頁一個 scene
- 嵌住 SKP file reference（live link，原 model update 即重新 render）
- 可加 dim、text、image、border、title block 等
- LayOut app 內**原生渲染**比我哋 Wine + Mesa swrast 路線靚 + 快
- 出 PDF / 列印質量都係 LayOut native renderer 出嘅最好

對比我哋之前嘅 [PNG vision pipeline](skp-to-pdf-via-layout.md)，呢個 procedure：
- ✅ 唔涉 rendering，純 SDK serialization
- ✅ 速度快 100×（48 scenes < 3 秒，PDF 路線要 5 分鐘）
- ✅ Output 可以 LayOut app 編輯／加 annotation
- ✅ User 喺 LayOut 出嘅 PDF 質量最好
- ⚠️ User 要有 LayOut app 先開到（要 SketchUp Pro subscription）

## 路線一：SDK 嗰邊（自動）

[`skp_to_layout.cpp`](../../../../skp_to_layout.cpp) — 自家寫，喺 Linux Docker 跑：

```bash
# Build
docker run --rm -v "$PWD:/work" skpbuild bash -c '
  cd /work
  x86_64-w64-mingw32-g++ -std=c++14 -O2 -Iwin/headers \
    skp_to_layout.cpp \
    win/binaries/layout/x64/LayOutAPI.lib \
    win/binaries/sketchup/x64/SketchUpAPI.lib \
    -static -static-libgcc -static-libstdc++ \
    -o skp_to_layout.exe'
cp skp_to_layout.exe win/binaries/layout/x64/

# Run
cp "/home/timothy/mydocs/寶翠園5.skp" /tmp/m.skp   # ASCII path
docker run --rm -v "$PWD:/work" -v "/tmp/m.skp:/tmp/m.skp:ro" skpbuild bash -c '
  export WINEPREFIX=/wineprefix WINEDEBUG=-all
  wine wineboot --init >/dev/null 2>&1
  cd /work/win/binaries/layout/x64
  wine ./skp_to_layout.exe Z:/tmp/m.skp Z:/work/out/baocui.layout'
```

Output：`out/baocui.layout`（5.1 MB for `寶翠園5.skp`）。

### Optional version override
```bash
wine ./skp_to_layout.exe Z:/tmp/m.skp Z:/work/out/file.layout 22  # = LayOut 2022
```
Default = `LODocumentVersion_Current` = LayOut 2023。`LODocumentVersion` enum: 1, 2, 3, 13, 14, ..., 23。User 嘅 LayOut version 至少要等於呢個數先開到。

## 路線二：Ruby 嗰邊（user 喺 SketchUp 入面跑）

[`scripts/export_layout.rb`](../../../../scripts/export_layout.rb) — Sketchup.active_model.send_to_layout
方法。

```ruby
model = Sketchup.active_model
src_path = model.path
out_path = src_path.sub(/\.skp$/, ".layout")
model.send_to_layout(out_path)
```

User 步驟：
1. 開 寶翠園5.skp 喺 SketchUp app
2. Window → Ruby Console
3. Paste `scripts/export_layout.rb` 內容
4. `.layout` file 喺 .skp 同 folder

## 兩條路嘅 trade-off

| | SDK 路線 | Ruby 路線 |
|---|---|---|
| 環境 | Docker container（Linux） | SketchUp app（Windows / Mac） |
| 速度 | < 3 秒 | 視乎 SU app load model 速度 |
| Trigger | CLI / CI | User 點 |
| Page 數量 | Self-controlled（all scenes） | All scenes by default |
| Page layout | Default Letter Landscape，bounds (.25, 1.) → (10.5, 7.5) | SketchUp 嘅內部 default |
| Custom template | ❌ 我哋只用 empty doc | ❌ Ruby 都用 default |
| 維護成本 | 中（要 keep Docker image） | 低（一個 .rb file） |

兩條路 output **都係**標準 `.layout` file。打開要 LayOut app（SketchUp Pro subscription 包）。

## Verify saved .layout

寫咗個小 verifier 確認 .layout file 沒 corrupt：

```cpp
LOInitialize();
LODocumentRef d;
LODocumentCreateFromFile(&d, "baocui.layout");
size_t n; LODocumentGetNumberOfPages(d, &n);
// iterate LODocumentGetPageAtIndex / LOPageGetName
```

48 pages preserved，scene name 中文 OK：
```
page 2:   主人房衣櫃
page 3: 主人房床
...
```

## 已知限制

1. **Default page layout** — 我哋用 `LODocumentCreateEmpty` + 預設 viewport bounds (.25, 1) → (10.5, 7.5) inches。User 開後可能要手動 resize viewport 配合佢自己嘅 title block。
2. **無 template** — `GenerateLayOutFromSkp` sample 用 `Letter Landscape.layout` template 提供 title page。我哋唔用 template 因為 template 入面 RTF 文字會 crash Wine 9 嘅 riched20。如果 user 喺 LayOut app 直接 edit 加 template 都得。
3. **唔包含 dim entity** — 已存喺 SKP 入面嘅 SUDimension 會 render 出嚟，但 LayOut 自己嘅 dim entity 要 user 喺 LayOut app 入面再加。

## When to use

- **Just need PDFs of all scenes**：[skp-to-pdf-via-layout](skp-to-pdf-via-layout.md) — pure CLI、Linux only
- **Need editable施工圖 + add annotations / title blocks**：呢條 procedure
- **Need quick visual check, no editing**：[scene-export-ruby](scene-export-ruby.md) — 輸出 PNG，純自動，user 要 SketchUp app

## Changelog
- 2026-04-29 — Initial；SDK 路線同 Ruby 路線都 verified。SDK 出嘅 5.1 MB .layout file (48 pages) reopens cleanly with LayOut SDK.

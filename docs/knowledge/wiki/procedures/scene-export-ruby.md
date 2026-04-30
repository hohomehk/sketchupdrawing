---
id: scene-export-ruby
type: procedure
market: na
tone: cantonese
confidence: 0.85
sources:
  - ref: 2026-04-29 conversation pivoting away from inverse-transform analysis
    date: 2026-04-29
  - ref: ../../../../scripts/export_scenes.rb
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-10-29
tags: [ruby, scene, export, png, vision]
---

# Scene → PNG Export via Ruby Console

## Lever

讀檔取 dim 易出方向錯（[預埋制盒嘅前／背 confusion](../findings/master-bedroom-electrical-box.md)）；inverse-transform、coordinate convention、heuristic 估方向呢三層都會出 bug。

**Pivot：將每個 Scene render 做高解析度 PNG，用 multimodal vision 直接讀紅色 dim 標註**。User 嘅標註語境（leader line、箭頭指邊塊板、dim 一齊嘅 note text）全部喺圖入面保留。

呢個 procedure 由 user 嘅 SketchUp app 直接做（SDK 唔會 render，要 SketchUp app 本身嘅 renderer）。

## Script

[`scripts/export_scenes.rb`](../../../../scripts/export_scenes.rb)

```ruby
# 簡化版（完整 script 見 file）
model = Sketchup.active_model
output_dir = File.join(File.dirname(model.path), "scenes")
FileUtils.mkdir_p(output_dir)

model.pages.each_with_index do |page, idx|
  model.pages.selected_page = page
  filename = "#{output_dir}/#{idx.to_s.rjust(2,'0')}_#{page.name.strip}.png"
  model.active_view.write_image(
    filename: filename, width: 2400, height: 1500,
    antialias: true, transparent: false)
end
```

## Run

User SKU 端：
1. Open .skp in SketchUp（任何 version 2017+，Make 或 Pro 都 work）
2. `Window → Ruby Console`
3. Paste script 內容
4. Enter
5. PNGs 出 `<.skp folder>/scenes/`

48 個 scene × ~2400×1500 PNG 大概要 1-2 分鐘。

## Output

每個 PNG file naming：`<index>_<scene_name>.png`，e.g.：
- `00_布局圖.png`
- `02_主人房衣櫃.png`
- `06_細房衣櫃.png`

Index prefix 確保 sort order match `dump_skp` scene index。

## Then what

將 `scenes/` folder 過 WSL `~/mydocs/scenes/`，之後直接 Read 對應 PNG 答 dim 問題：

```
[user] 衣櫃預埋制盒高度?
[ai]   reads /home/timothy/mydocs/scenes/02_主人房衣櫃.png
[ai]   sees 紅色 "1260" annotation @ 制盒 leader line
[ai]   答 1260 mm
```

對比 SDK 路線（[預埋制盒 finding 嘅 journey](../findings/master-bedroom-electrical-box.md#changelog)），唔使再走 SUText anchor → inverse transform → guess local axis 方向，三 step 變零 step。

## When to use SDK vs PNG vision

| 用途 | 走 SDK | 走 PNG vision |
|---|---|---|
| 全 model 結構 inventory（樹／count／layer） | ✅ | — |
| 抽 dim 數值（user 標嗰啲） | △ 易錯 | ✅ |
| 識別 component spatial relationship | ✅ | △ |
| 計 cut list（每塊板長闊厚） | ✅ | — |
| 某個 scene 嘅施工 spec / annotation | — | ✅ |
| 找 user 寫嘅 note（材料／燈帶／收口） | △ SUText 抽到但無 context | ✅ context 一齊睇 |

**Rule of thumb**：問題涉**幾何尺寸**用 SDK；問題涉**user 嘅施工意圖**用 PNG vision。

## Limitations

- **PNG resolution dependent**：2400×1500 可以讀大數例 1990／2875，難讀<10 點 size 嘅小註解。需要時改 script 頂部 `WIDTH=4000 HEIGHT=2500`
- **無 SketchUp app 跑唔到**：SDK 無 render；`SUSceneSaveImage` 之類 function 唔存在
- **Rendering 跟 active 嘅 visual style**：如果 user view style 係 hidden line，dim 紅色可能變灰；先確認 view style 係 default
- **Scene transition animation**：SketchUp 內定 set 過 transition 0.4s，48 個 scene = 19s 額外。如果想 instant：執行前 `Sketchup.active_model.options['PageOptions']['ShowTransition'] = false`

## Changelog
- 2026-04-29 — Initial；pivoted from SDK-only approach after 預埋制盒 direction-guessing bug

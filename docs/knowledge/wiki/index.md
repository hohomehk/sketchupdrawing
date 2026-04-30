# SketchUp Drawing Wiki — Index

呢個 wiki 跟 [marketing wiki LLM Wiki v2 pattern](../../../../.openclaw/marketing/docs/knowledge/llm-wiki-v2.md)，schema 詳見 [`schema.md`](schema.md)。涵蓋 `寶翠園5.skp` 同類似 SketchUp 設計檔嘅 reverse engineering 同 SDK 抽取流程。

## Recommended Workflow

對於 dim／施工 spec 問題，**首選 PNG vision 路線**（[skp-to-pdf-via-layout](procedures/skp-to-pdf-via-layout.md)），SDK 路線只用嚟做 inventory／cross-check。原因：
- SDK 抽 dim entity 易錯方向（[預埋制盒 case](findings/master-bedroom-electrical-box.md)）
- 視覺讀紅色標註 = user 嘅原始設計語境，唔需 inverse-transform、唔需估前後
- 已 build 完 48 張 high-res PNG (`out/scenes_png/NN_<scene_name>.png`)，直接 Read 用

## Pages

### Procedures（工作流／SOP）
- ⭐ [SDK Toolchain Setup](procedures/sdk-toolchain-docker.md) — Docker image with Ubuntu 24.04 + mingw-w64 + Wine 9 + Trimble Win SDK；點解唔能直接用 Mac SDK，點解 Wine 9 比 Wine 6 啱用，VC++ runtime 點處理
- ⭐ [Parse SKP CLI Cookbook](procedures/parse-skp-cli.md) — 標準執行流程；ASCII path requirement；scene name via stdin；常見 troubleshoot
- ⭐ [Scene → PNG Export via Ruby Console](procedures/scene-export-ruby.md) — 由 user SketchUp app 跑 Ruby script batch export 高解析度 scene PNG；之後我用 multimodal vision 直接讀紅色 dim；推薦用 vision 路線答 user 標嘅施工 spec／dim 問題
- ⭐ [SKP → PDF (→ PNG) via LayOut SDK](procedures/skp-to-pdf-via-layout.md) — Self-contained Linux pipeline：LayOut SDK + wine 11 staging + mesa swrast，全自動 batch render 唔使 SketchUp app；解決 wine 9.0 riched20 bug 同 sketchupviewerapi GL context issue
- ⭐ [Export `.layout` Document from `.skp`](procedures/export-layout.md) — 出 LayOut editable file (`.layout`)。SDK 路線（純 serialization、3 秒、48 pages）同 Ruby 路線（`Sketchup.active_model.send_to_layout`）並列。出嚟嘅 file 可以喺 LayOut app 開做後續編輯／加 dim／加 title block／導出 PDF

### Findings（拆 `寶翠園5.skp` 結果）
- ⭐ [Model Overview — 寶翠園5.skp](findings/baochuiyuen5-overview.md) — 48 scenes、259 ComponentDefinitions、5 layers、root spans 400m × 400m；user 用 Scene 做施工圖頁、用 ComponentDefinition 做 reusable 五金 library
- ⭐ [主人房衣櫃 Dimensions](findings/master-bedroom-wardrobe.md) — Component#99 + Component#157 = L 型 1900 + 2300 × 500 × 2875；journey of discovery（先估錯 Component#180）；BBox vs SUDimension entity 數值 reconcile
- ⭐ [主人房衣櫃 預埋制盒](findings/master-bedroom-electrical-box.md) — `預埋制盒` SUText anchor @ z=1260mm（離地高度）；1293mm dim 係 3D oblique 唔係 vertical；離牆距離 model 入面冇 explicit dim 標示

### References（SDK／環境 cheatsheet）
- ⭐ [SDK API Cheatsheet](references/sdk-api-cheatsheet.md) — 我用過嘅 SU* function 摘要；`SUInstancePathRef*` 唔可以 NULL；transform matrix layout（column-major 4×4）
- ⭐ [Wine / Encoding Quirks](references/wine-quirks.md) — Wine 9 PURE 64-bit mode 冇 wow64；中文 argv encoding 死路；中文 path 死路；解決方法

### Tools（自家寫嘅 SDK dumper）
- [`dump_skp`](tools/dump-skp.md) — 列 layer / scene / ComponentDefinition / top-level entity
- [`dump_dims`](tools/dump-dims.md) — 列所有 SUDimension entity（實際長度同 user override label）
- [`tree_skp`](tools/tree-skp.md) — 遞歸印 ComponentDefinition 子樹同 instance pos
- [`wardrobe_dim`](tools/wardrobe-dim.md) — 用 scene name 找衣櫃 bbox（含 hidden filter 試驗）
- ⭐ [`local_coord`](tools/local-coord.md) — World→Local inverse transform；搵點同 cabinet local bbox 6 個面嘅距離

## Maintenance

新 finding／procedure 寫落 wiki 同時 update 呢個 index。每 page 必須有 YAML frontmatter（[schema](schema.md)）。

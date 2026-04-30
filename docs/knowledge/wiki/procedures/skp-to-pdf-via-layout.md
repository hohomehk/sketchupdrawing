---
id: skp-to-pdf-via-layout
type: procedure
market: na
tone: cantonese
confidence: 0.9
sources:
  - ref: 2026-04-29 build session — LayOut SDK PDF export pipeline working
    date: 2026-04-29
  - ref: ../../../../skp_to_png.cpp
    date: 2026-04-29
  - ref: ../../../../win/samples/GenerateLayOutFromSkp/main.cpp
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-10-29
tags: [layout, render, pdf, png, vision, sdk]
---

# SKP → PDF (→ PNG) via LayOut SDK

## Lever

[`scene-export-ruby`](scene-export-ruby.md) procedure 要 user 喺自己 SketchUp app 跑 Ruby script。我哋（SDK 端）唔可以代勞，因為 SketchUp Ruby API 只喺 SketchUp app 內嵌 interpreter。

但 **Trimble LayOut SDK 包括嚟 render path**：將 SKP scene 嵌入 LayOut document，再 export 做 PDF。SDK 同 mingw-w64 cross-compile + Wine 11 staging 配合可以喺 Linux 跑。

呢個 procedure 完全 self-contained — 唔需要 user 跑任何嘢。

## Pipeline

```
SKP file
  ↓ LOSketchUpModelCreate(skp_path) per scene
LayOut Document（一頁一個 scene viewport）
  ↓ LODocumentExportToPDF
PDF（vector + 嵌入光 raster + dim annotation）
  ↓ pdftoppm -r 200 -png
PNG（一頁一張）
  ↓ Read tool
Multimodal vision 直接讀紅色 dim
```

## Critical compatibility notes

### Wine 9.0 (Ubuntu 24.04 default) 撞 riched20 bug
Crash 喺 `cfany_to_cf2w`（Wine 9 嘅 riched20 bug）→ install native MS riched20 from winetricks 但 syswow64 規則撞牆。

### Wine 11.7 staging 解決
Switch 去 WineHQ apt repo + `winehq-staging` package（wine 11.7+），bug 已修正。

```dockerfile
RUN mkdir -pm755 /etc/apt/keyrings \
    && wget -nv -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
    && wget -nv -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources \
    && apt-get update \
    && apt-get install -y --install-recommends winehq-staging
```

### Mesa software GL（OpenGL 上下文）
SketchUpViewerAPI 要 GL context render。Container 冇 GPU；用 mesa swrast / llvmpipe：
```bash
LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a -s "+extension GLX -screen 0 1920x1080x24" wine ...
```

### PDF 路線優於 ImageSet 路線
最初試 `LODocumentExportToImageSet` PNG 直接出，但 raster 路徑撞咗第二個 wine bug。**PDF 路徑乾淨**，因為 PDF 內部用 vector 嵌入 SKP scene 圖片（rasterize 喺 PDF reader / pdftoppm 端做）。

## Tool

[`skp_to_png.cpp`](../../../../skp_to_png.cpp) — name 留意 misnomer，實際 export PDF（PNG step 由 pdftoppm 做）。

```bash
# 1. Build EXE（同其他 SDK tool 一樣 cross-compile）
docker run --rm -v "$PWD:/work" skpbuild bash -c '
  cd /work
  x86_64-w64-mingw32-g++ -std=c++14 -O2 -Iwin/headers \
    skp_to_png.cpp \
    win/binaries/layout/x64/LayOutAPI.lib \
    win/binaries/sketchup/x64/SketchUpAPI.lib \
    -static -static-libgcc -static-libstdc++ \
    -o skp_to_png.exe'
cp skp_to_png.exe win/binaries/layout/x64/

# 2. Run（每 scene ~10-30s，48 scenes 大約 10 分鐘）
docker run --rm -v "$PWD:/work" -v "/tmp/m.skp:/tmp/m.skp:ro" skpbuild bash -c '
  export WINEPREFIX=/wineprefix WINEDEBUG=-all
  wine wineboot --init 2>/dev/null
  cd /work/win/binaries/layout/x64
  LIBGL_ALWAYS_SOFTWARE=1 \
    xvfb-run -a -s "+extension GLX -screen 0 1920x1080x24" \
    wine ./skp_to_png.exe Z:/tmp/m.skp Z:/work/out/scenes.pdf 200'

# 3. PDF → 一頁一張 PNG
docker run --rm -v "$PWD:/work" skpbuild bash -c '
  pdftoppm -r 200 -png /work/out/scenes.pdf /work/out/scene'
# 出 scene-1.png, scene-2.png, ..., scene-48.png
```

## Parameters worth tuning

- `dpi` argv（default 200）— 高 DPI 出更清，但 PDF 大 + render 時間增。300 適合大張圖；600 已經太多。
- `LOAxisAlignedRect2D bounds` — 預設 `{{.25, 1.}, {10.5, 7.5}}`（inches，模仿 Letter Landscape margin）。改大 bounds 可令 viewport 內容大啲。
- Page size — `LODocumentCreateEmpty` 用 default Letter 11×8.5 in。換 page size 要進入 LayOut SDK 設 `LOPageInfoSetPaperWidth/Height`。

## Trade-offs vs Ruby Console

| | LayOut SDK | Ruby Console |
|---|---|---|
| Setup | Docker + WineHQ + Mesa（~1 GB image） | 0（用緊嗰個 SketchUp） |
| 速度 | 每 scene 10-30s（軟件 GL） | <1s per scene |
| 自動化 | 完全 self-contained，可放 CI | 要用戶手動 paste |
| 圖質 | LayOut 用 line-render，未必同 SketchUp screen 一樣 | 完全跟 user view style |
| 限制 | RTF text 部份 wine bug；某啲 effect render 唔出 | 需 SketchUp install |

**建議**：CI／無 SketchUp 環境用呢條；快出 ad-hoc 圖用 Ruby Console。

## Changelog
- 2026-04-29 — Initial；wine 11.7 staging + mesa swrast + LayOut PDF export pipeline 確認跑得通

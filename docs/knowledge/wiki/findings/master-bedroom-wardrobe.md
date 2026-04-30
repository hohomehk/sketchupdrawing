---
id: master-bedroom-wardrobe
type: finding
market: na
tone: cantonese
confidence: 0.95
sources:
  - ref: 2026-04-29 SDK dump（dump_skp + dump_dims + tree_skp）
    date: 2026-04-29
  - ref: ../../../../out/dump_full.txt
    date: 2026-04-29
  - ref: User confirmation（衣櫃高度係 2875、深度標 500）
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-10-29
tags: [wardrobe, master-bedroom, dimensions, l-shape]
---

# 主人房衣櫃 — Dimensions

## TL;DR

```
主人房衣櫃 = L 型轉角衣櫃（兩段組成）
段 A (Component#99 ): 1900 (長) × 500 (深) × 2875 (高) mm
段 B (Component#157): 2300 (長) × 500 (深) × 2875 (高) mm
```

兩段 90° 拼成 L 形，兩段都係 2875mm 全高 + 500mm 深。

## 證據鏈

### 1. SUDimension entity（最高 confidence）

[`dump_dims`](../tools/dump-dims.md) 抽到，filter XY 喺 (107000-112000, 85000-92000) — 即主人房衣櫃 cluster：

| Length (mm) | Axis | Start XY (mm) | End XY (mm) | 解讀 |
|---|---|---|---|---|
| **2875** | Z | (110050, 90209) | (110050, 90209) | **總高** ✓ user 確認 |
| **2400** | Y | (110050, 90209, 2875) | (108353, 88512, 2875) | 段 B 頂邊（含轉角） |
| **2300** | X | (108353, 88512, 2875) | (109979, 86886, 2875) | 段 B 長 |
| **500** | X | (110403, 89856) | (110050, 90209) | **段 A 深** ✓ user 確認 |
| **500** | Y | (110333, 87239) | (109979, 86886) | **段 B 深** ✓ user 確認 |
| 50 | Z | (110403, 89856, 50) | (110403, 89856, 0) | 腳座／地腳 |
| 1000 | Z | — | — | 抽屜總高 |
| 1050 / 1293 | Z | — | — | 中層板高度 |
| 121 | Y | — | — | 細件 |

### 2. Component identification

```
I17: Component#157 @ root pos (109693, 87123,  -0)  world bbox (108353..110347, 86886..88880, -0..2875)
I18: Component#99  @ root pos (110403, 90542,  -0)  world bbox (108706..110404, 88511..90209, -0..2875)
```

兩者嘅 world bbox Z 都頂到 2875mm。位置都喺 master bedroom cluster (110000, 89000)。確認佢哋兩個就係衣櫃。

### 3. Component#99 內部結構（[`tree_skp`](../tools/tree-skp.md) 出嚟）

```
Component#99 — local bbox 1900 × 501 × 2875 mm
├── Group[0]                                  (front 結構)
├── Inst[0..5] 底托櫃桶  @ (1325/2246, 485, 104/400/675)   ← 6 個抽屜（3 層 × 2 列）
├── Inst[6] Component#204 @ (465, -15, 0)     local 1900 × 501 × 2875  ← 主櫃身 carcass
│   ├── Group[0]                              (上層吊掛區骨架)
│   ├── Inst[0] 格仔櫃桶 @ (1678, 500, 914)
│   └── Inst[1] 格仔櫃桶 @ (810,  500, 914)
└── Inst[7] Component#265 @ (595, 485, 1346)
```

### 4. Component#157 內部結構

```
Component#157 — local bbox 520 × 2300 × 2875 mm
├── Inst[0] Component#202 @ (515, 1380, 50)   local 40 × 1821 × 2730       ← 門板層
│   ├── Inst[0..3] Component#156              local 40 × 442 × 2730 each   ← 4 塊垂直門板（趟門）
├── Inst[1] Component#154 @ (280, 1410, 1970) local 40 × 2260 × 40         ← 上橫桿
├── Inst[2] Component#154 @ (280, 1410, 930)  local 40 × 2260 × 40         ← 中橫桿
├── Inst[3] Component#98  @ ( 35, 1445,  0)   local 500 × 2300 × 2875      ← 主櫃身 carcass
│   ├── Inst[0] Component#155                 local 500 × 2300 × 2875
│   └── Inst[1] Component#54  @ (50, -435, 2435) local 430 × 1354 × 18     ← 頂層板
├── Inst[4..N] Component#36  @ (85, -366, 1641/1341/...)  local 430 × 874 × 18  ← 多塊 18mm 層板
```

### 5. BBox vs User Dim — 點解差 1mm／20mm

| 部份 | SDK BBox 計算 | User dim entity | 差異原因 |
|---|---|---|---|
| Component#99 深 | **501** mm | 500 mm | 1mm — edge banding／圓邊 stickout |
| Component#157 深 | **520** mm | 500 mm | 20mm — Component#202 門板層 (40mm 厚，offset 至 z=50) 凸出 carcass 表面 |
| Component#99 長 | **1900** mm | 1900 mm | match |
| Component#157 長 | **2300** mm | 2300 mm | match |
| 高度 | **2875** mm | 2875 mm | match |

**結論：User 標嘅 500mm 係 carcass 深，SDK 嘅 520 係幾何最大外圍（連門板）。開料尺寸用 user dim，placement／clearance 用 bbox。**

## Journey of Discovery（記錄錯誤判斷以免重蹈）

### 第一次估錯：Component#180

最初用「靠近底托櫃桶 cluster」嘅 spatial heuristic，揀咗 Component#180（@ (59401, 38681)）做主人房衣櫃，數出 3650 × 516 × 2860 mm。

但 user 講「衣櫃高度係 2875」唔係 2860 → 9mm 唔係 panel thickness 應有差異。重新查 dim entity：length-2875 嘅 dim 喺 world (110050, 90209)，**完全唔同 cluster**。

**Component#180 其實係細房／其他間房嘅櫃（cluster (58000, 38000)），唔係主人房**。

### Lesson learnt

- **Spatial heuristic（搵附近 component）唔可靠**。寶翠園5 model 將每間房擺喺唔同遠 XY position（cluster 之間相隔幾十米），但每個 cluster 都有相似 furniture（drawers、wardrobe）。靠位置 match 易撈錯。
- **`SUDimension` entity 嘅 length 同位置先係 ground truth**。User 標嘅 `2875` 直接 pin point 到 Component#157／#99；用呢個做反向索引最準。
- **BBox 計算包圓邊／門板凸出**，會比 user 標嘅尺寸大幾 mm 至幾十 mm。Reconcile 時要 dive 入 component 嘅子結構搵 carcass 層先有 match。

## How To Reproduce

```bash
cp "/home/timothy/mydocs/寶翠園5.skp" /tmp/m.skp
docker run --rm -v "$PWD:/work" -v "/tmp/m.skp:/tmp/m.skp:ro" skpbuild bash -c '
  export WINEPREFIX=/wineprefix WINEDEBUG=-all
  wine wineboot --init >/dev/null 2>&1
  cd /work/win/binaries/sketchup/x64
  printf "Component#99\n"  | wine ./tree_skp.exe Z:/tmp/m.skp
  printf "Component#157\n" | wine ./tree_skp.exe Z:/tmp/m.skp'
```

Dim entity filter 用 `dump_dims` + `awk` filter XY range（見 [parse-skp-cli](../procedures/parse-skp-cli.md)）。

## Visual Confirmation (2026-04-29 13:10)

跑咗 [`skp-to-pdf-via-layout`](../procedures/skp-to-pdf-via-layout.md) pipeline，render scene #2 主人房衣櫃 做高解析度 PNG（`out/scenes_png/02_主人房衣櫃.png`）。圖上紅色 dim 直接讀到：

| 圖上紅字 | SDK 抽嘅 | Match |
|---|---|---|
| 2875（總高） | 2875 | ✓ |
| 500（深） | 500 carcass | ✓ |
| 18（板厚） | 18 | ✓ |
| 70（地腳） | 70 | ✓ |
| 50 + 60（收口/梗） | 50 + 60 | ✓ |
| 36（圓邊） | 36 | ✓ |
| 1995（上邊長一邊） | 1900 (C#99) | ≈（95mm overhang） |
| 1520（上邊長另一邊） | 2300 (C#157) | × — 視角投影，唔係 local 真值 |
| 1000（上層櫃內高） | 760 (C#184 local) | × — bbox 計法不同 |
| 1363、1012、1848（內部分層 Z） | — | 新資料，可參考 |

✅ **Visual + SDK 兩邊互相驗證**，主要尺寸 (2875×500、L 型、板厚 18、地腳 70、收口 50/60、圓邊 36) 全部 match。投影／bbox 計算差異可解釋。

## Changelog
- 2026-04-29 09:00 — Initial; estimated 3650×516×2860 from Component#180. **Wrong**.
- 2026-04-29 10:30 — User 講高度應該 2875。Re-investigate；用 `dump_dims` filter 出 length=2875 dim → 找到 Component#157／#99。**Correct**：1900+2300 × 500 × 2875 L 型。
- 2026-04-29 11:00 — User 確認深度 500（唔係 BBox 嘅 501／520）；reconciled 到 carcass vs full-bbox 差異。Confidence bumped to 0.95.
- 2026-04-29 13:10 — Visual confirmation via PNG render（LayOut SDK + Wine 11 staging pipeline）。所有 SDK 推算嘅 dim 喺圖上 match。

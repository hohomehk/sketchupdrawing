---
id: baochuiyuen5-overview
type: finding
market: na
tone: cantonese
confidence: 0.95
sources:
  - ref: 2026-04-29 SDK dump of /home/timothy/mydocs/寶翠園5.skp
    date: 2026-04-29
  - ref: ../../../../out/dump_full.txt
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-10-29
tags: [model-structure, scene, component, layer]
---

# Model Overview — `寶翠園5.skp`

## Header

| 項目 | 值 |
|---|---|
| File | `/home/timothy/mydocs/寶翠園5.skp` |
| Size | 11,688,479 bytes (~11 MB) |
| Format version | SketchUp 2021 (`{20.1.229}`) |
| Original WP path | `C:\Users\Timothy\Dropbox\PC (7)\Documents\Drawing 2021\寶翠園5.skp` |
| First parsed | 2026-04-29 |

## Top-level structure

| Entity type | Count |
|---|---|
| Layers | 5 |
| Scenes | 48 |
| ComponentDefinitions | 259 |
| Top-level Groups | 11 |
| Top-level Instances | 72 |
| SUDimension entities (recursive) | 370 |
| SUText entities (recursive) | 204 |
| GuideLines / GuidePoints / SectionPlanes / Images | 0 |

⚠️ All 370 dimensions + 204 texts 嘅 location 全部喺 **nested groups** 入面，**唔喺** ComponentDefinition 嘅 top-level entities。所以 dump dim entity 必須遞歸全 model，唔可以淨 query root。

## Layers

| L# | Name | 用途 |
|---|---|---|
| 0 | `Layer0` | Default |
| 1 | `LEGS` | SketchUp default template |
| 2 | `RAILS` | SketchUp default template |
| 3 | `TABLETOP` | SketchUp default template |
| 4 | `TOP` | SketchUp default template |

**User 冇用 layer 分類**。所有 cabinets／rooms 全部喺 Layer0。Layer 唔係 metadata source。

## Scenes（48）

每個 cabinet／feature 一個 scene（camera angle）。Scene 係 user 嘅「施工圖頁」單位。

| S# | Name |
|---|---|
| 0 | 布局圖 |
| 1 | 工人房 |
| **2** | **主人房衣櫃** ← [findings page](master-bedroom-wardrobe.md) |
| 3 | 主人房床 |
| 4 | 主人房床屏 |
| 5 | 細房 |
| 6 | 細房衣櫃 |
| 7 | 細房床 |
| 8 | 細房上床 |
| 9 | 細房燈 |
| 10 | 書枱頂櫃 |
| 11 | 椅背後的櫃 |
| 12 | 廳收納櫃 |
| 13 | 廳c字櫃 |
| 14 | 主廁浴室櫃 |
| 15 | 主廁邊櫃 |
| 16 | 客廁廁櫃 |
| 17 | 廚櫃 |
| 18 | 廚房地櫃 |
| 19 | 右半吊櫃 |
| 20 | 右吊櫃背 |
| 21 | 左半吊櫃及地櫃 |
| 22 | 冷氣機型號 |
| 23 | 企缸尺寸 |
| 24 | 主廁水泥台 |
| 25 | 客廳水泥台 |
| 26 | 浴屏 |
| 27 | 電制位 |
| 28 | 廚房天花圖 |
| 29 | 廁所天花 |
| 30 | 煙機岩板 |
| 31 | 碗櫃岩板 |
| 32 | 抽油煙機出風 |
| 33 | 廁所趟門 |
| 34 | 主人房門 |
| 35-46 | `Scene 19-48` (auto-named, 殘餘) |
| 47 | 窗台石 |

完整 scene → embedded thumbnail PNG mapping 喺 `out/dump_full.txt` 第 14-72 行；每個 scene 都附一張 256×155 jpeg／png 縮圖（共 50 張，包括 file thumbnail）。

## ComponentDefinitions（259）

絕大部份係 auto-named `Component#NN`（user 冇手動命名）。**用戶命名嗰啲反而係佢嘅 reusable hardware library**：

| Definition name | Used | 用途 |
|---|---|---|
| `櫃桶`, `櫃桶#1` ~ `#6` | 6-24 instances each | 抽屜變體（不同尺寸） |
| `底托櫃桶`, `底托櫃桶#1` | 12-24 used | 軟關抽屜 |
| `底托300軌`, `底托軌`, `底托軌背縮100`, `底托軌背縮200` | 4-2 used | 抽屜路軌（變體） |
| `底托路軌`, `單軌單趟`, `趟門` | 0-2 used | 趟門路軌 |
| `拉籃`, `拉 藍`, `轉角拉籃?` | 0 used | 拉籃變體（`?` 係 user 留低嘅疑問！） |
| `銀鏡`, `不銹鋼`, `灰茶鏡`, `碗櫃岩板` | 1-2 each | 飾面材料 |
| `活動生口板`, `假斗面`, `這格沒中立板` | 1 each | 細件結構或 note-as-component |
| `床高度待定`, `床高度待定#1` | 0 | TBD note |
| `>通` | 1 | 通門 marker |
| `主廁水泥台`, `客廁水泥台`, `主廁`, `客廁` | each 1-5 | 房間級組件 |
| `123dsf` | 1 | scratch 試驗 |
| `T_COM_003_001` (`few. \| Common table 200x85`) | 1 | 第三方下載 import |

## Top-level Spatial Layout

Root 入面 11 groups + 72 instances 散佈喺一個 **400 m × 400 m** 嘅 design space。User 似乎將每間房放喺唔同 X／Y position（可能係 iteration、design copies、room 分區）。

主要 cluster（按 XY centre）：

| Cluster | XY centre | 內容 |
|---|---|---|
| Master bedroom (主人房) | (110000, 89000) | Component#157 + Component#99 + 6 底托櫃桶 instances |
| 細房 area | (58000, 38000) | Component#180 + 8 底托櫃桶 instances |
| 廁所／浴室 | (185000, 150000) | 主廁／客廁 instance |
| 左下遠 group | (-176000, -213000) | 細房上床 area |

⚠️ Cluster 唔等於 scene。一個 scene 嘅 camera target **唔保證**指住佢命名嗰個 cabinet（master bedroom scene 嘅 camera target 係 (56886, 97845, -19444)，並唔喺 wardrobe XY range 入面）。所以**唔好用 camera target 做 cabinet identification**，要 match dim entity location。

## User 嘅 Workflow Pattern

從 model 結構推：

1. **Scene = 施工圖頁**（每件 cabinet 一個 camera angle，加紅色 dim entity 標尺寸 + 中文文字 note）
2. **ComponentDefinition = 散件零件 + reusable hardware library**（每塊板一個 component；抽屜／路軌／拉籃做 instance reuse）
3. **冇 layer 分類** — 全部喺 Layer0；scene 嘅切換靠 camera 鎖定
4. **用 SUDimension entity 標實際開料尺寸** — 而唔係靠 SUText（SUText 用嚟記文字 note 例如「床褥寄工廠」、「36圓邊」）
5. **散件保留 ?**——`轉角拉籃?` 個問號係 user 設計過程未拍板嘅 marker

## Changelog
- 2026-04-29 — Initial creation；confidence 0.95 from full SDK dump

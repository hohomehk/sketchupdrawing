---
id: master-bedroom-electrical-box
type: finding
market: na
tone: cantonese
confidence: 0.95
sources:
  - ref: 2026-04-29 SUText + SUDimension dump（dump_text + filtered dump_dims）
    date: 2026-04-29
  - ref: 2026-04-29 inverse-transform via local_coord.exe
    date: 2026-04-29
  - ref: ../../../../out/all_text_v2.txt
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-10-29
tags: [electrical, embedded-box, master-bedroom, wardrobe]
---

# 主人房衣櫃 — 預埋制盒位置

## TL;DR

```
預埋制盒  local 座標 = (245, -370, 1260) mm（喺 Component#157 frame）
├── 離地高度                 = 1260 mm
├── 離櫃前 (local X=35)      = 210 mm   ← user 確認過嘅實測值
├── 離 carcass 後板 (X=535)  = 290 mm
└── 離櫃最後緣 (X=555)       = 310 mm
```

歸 Component#157（段 B），Component#99（段 A）唔關事（local X = 2675，明顯 out of bbox）。

⚠️ **方向約定**：呢個 model 入面 Component#157 嘅 local X **小數一邊（X=35）係櫃前**（door 開口），**大數一邊（X=555）係櫃背**（靠牆）。Component#202（門板層，4 塊 Component#156）位置 (515, 1380, 50) 喺高 X 邊但實際係門 — 因為呢度係 carcass 後 20mm 入面 + 凸出 20mm 嘅趟門軌位。**唔好估錯 component name 推方向；要 cross-check user 實測**。

## SUText Anchor

`寶翠園5.skp` 全 model 共有 4 個「預埋」相關 SUText：

| Text | World anchor (mm) | 屬邊間房 |
|---|---|---|
| **`預埋制盒`** | **(110128, 87034, 1260)** | **主人房衣櫃 cluster** ✓ |
| `中間預埋孖制框` | (-99496, -118729, 1415) | 其他房間 |
| `預埋單制位和雙制位框 不用配插板` | (-152181, -173051, 880) | 其他房間 |
| `預埋孖制位框` | (-95175, -115088, 910) | 其他房間 |

主人房衣櫃 cluster XY 範圍 ~ (108000-110400, 86800-90200)（從 [master-bedroom-wardrobe](master-bedroom-wardrobe.md) Component#99 + Component#157 instance bbox 攞）—  `預埋制盒` 嘅 anchor 完全在內。

## 高度 = 1260 mm

直接讀 SUText anchor 嘅 z 座標：**1260 mm**（離地 floor）。

### ⚠️ 1293 mm Dim 唔係垂直高度

預埋制盒 anchor 1.5m 範圍內有條 SUDimension：
```
length = 1293 mm
start  = (110184, 87091, 1260)
end    = (109979, 86886,    0)
```

睇似 z 高度 dim，但實際係 **3D oblique**：
- Δz = 1260 mm（真實垂直距離）
- Δxy = 290 mm（沿衣櫃 45° 對角線方向偏移）
- 3D 距離 = √(205² + 205² + 1260²) = 1293 mm

Component#157 + #99 旋轉 45° 擺（[wardrobe finding](master-bedroom-wardrobe.md#5-bbox-vs-user-dim--點解差-1mm20mm)），所以衣櫃斜對角線剛好對齊 world XY 軸。User 拉 dim 嗰陣 endpoint 落咗喺 45° 邊上 → SDK 讀到 3D oblique 1293 而唔係純 vertical 1260。

**實際施工高度仍然以 z=1260 為準。**

## 離櫃背距離 = 210 mm（via inverse transform）

用 [`local_coord`](../tools/local-coord.md) tool 將 world (110128, 87034, 1260) 經 Component#157 instance 嘅 inverse transform 轉返 local frame：

```
Component#157 transform: 旋轉 45° (cos=sin=0.7071) + 平移 (4318.6, 3430.0, 0) mm
預埋制盒 local 座標: (245.0, -370.4, 1260.0) mm
```

對比 Component#157 local bbox X=[35, 555]，Y=[-370, 1930]，Z=[0, 2875]：

| Face | Local 位置 | 預埋制盒距離 (mm) | 物理意義 |
|---|---|---|---|
| **X- 面** | x=35 | **210** | **櫃前**（door 開口）— user 實測值 |
| X+ 面 | x=555 | 310 | 櫃最後緣（含 20mm 凸出） |
| X 中 (carcass 後) | x=535 | 290 | Carcass 後板內側 |
| Y- 面 | y=-370 | -0.4（落喺面上） | 端面 |
| Y+ 面 | y=1930 | 2300 | 另一端 |
| Z- 面（地） | z=0 | 1260 | 離地（match 上節）|
| Z+ 面（頂） | z=2875 | 1615 | 頂高 |

Sanity check：跑同一個世界點對 Component#99 → local (2675, 2285)，完全 out of #99 bbox，所以**預埋制盒 100% 屬 Component#157（段 B）**。

### ⚠️ 方向約定 lesson learnt
我第一次解釋估咗 Component#202（門板層）喺 X+ 高邊 → X+ 係櫃前。錯。`Component#157` 嘅趟門軌位喺 carcass 後 20mm 入面（515-555），`Component#98` 主櫃身先係 X=35-535。User 約定**低 X 面（35）= 櫃前**。
**取教訓**：Inverse transform 計到 local 座標後，**唔好用 component naming heuristic 估邊個面係前／背**。要 prompt user 確認，或者搵 model 入面有冇 explicit 標 `前` / `back panel` text annotation。

## 離真實牆面 — 估算

User 過往施工 note 顯示 carcass 後板同牆之間通常有 gap：
- `吊櫃背縮 10 走線`、`下加 6000K 燈帶 靠背裝`、`側板開凹 300×100 走喉`
- `腳線位 70`、`背避地腳 70`、`靠牆 50 收口`

即 carcass 後板（local x=535 嗰塊 face）同實際牆面通常隔 50-70 mm（俾走線／avoid 地腳線／收口）。

**離真實牆面 ≈ 290 + 50 至 70 = 340-360 mm** 或者 **310 + 50 至 70 = 360-380 mm**（取決於用 carcass 後板還是櫃最後緣）。

呢個係 estimate，視乎呢個項目實際做幾多收口決定。如果你 model 入面有 wall entity 或者額外 dim 標示，可以 confirm 確切值。

## 離牆距離 — 無直接 dim entity

Filter `預埋制盒` anchor 1.5m 範圍內 SUDimension：

| 長度 | 軸 | 用途 |
|---|---|---|
| 500 mm | Y | 段 B 櫃深（[wardrobe finding](master-bedroom-wardrobe.md)） |
| 54 mm | Z | 腳座細件 |
| 1293 mm | Z | 制盒高度 oblique（上面） |

**冇 dim 直接標離牆距離。**

### Spatial 推斷

預埋制盒 anchor (110128, 87034) vs Component#157 world bbox:

| Reference edge | Distance |
|---|---|
| C#157 max X (110347) | 219 mm |
| C#157 min X (108353) | 1775 mm |
| C#157 min Y (86886)  | 148 mm |
| C#157 max Y (88880)  | 1846 mm |

因為衣櫃旋轉 45°擺，**世界座標 X／Y 唔對應衣櫃 local 軸**。冇單純嘅「左右／前後」答案 — 要將 anchor 用 inverse transform 攞返 local frame，或者直接喺 SketchUp 入面 measure。

最 plausible 詮釋：制盒嵌入**衣櫃背面嘅牆**入面，離 carcass 後緣大約 150–220 mm（match anchor 同 cabinet edge 距離）。

## How To Reproduce

```bash
cp "/home/timothy/mydocs/寶翠園5.skp" /tmp/m.skp
docker run --rm -v "$PWD:/work" -v "/tmp/m.skp:/tmp/m.skp:ro" skpbuild bash -c '
  export WINEPREFIX=/wineprefix WINEDEBUG=-all
  wine wineboot --init >/dev/null 2>&1
  cd /work/win/binaries/sketchup/x64
  wine ./dump_text.exe Z:/tmp/m.skp | grep "預埋"
  wine ./dump_dims.exe Z:/tmp/m.skp | awk "\$1 < 1500"  # filter 細 dim 喺埋藏 box 附近'
```

## How To Reproduce（離櫃背 part）

```bash
docker run --rm -v "$PWD:/work" -v "/tmp/m.skp:/tmp/m.skp:ro" skpbuild bash -c '
  export WINEPREFIX=/wineprefix WINEDEBUG=-all
  wine wineboot --init >/dev/null 2>&1
  cd /work/win/binaries/sketchup/x64
  wine ./local_coord.exe Z:/tmp/m.skp Component#157 110128 87034 1260'
```

## Visual confirmation（2026-04-29 13:15）

從 `out/scenes_png/02_主人房衣櫃.png`（ render via [LayOut PDF pipeline](../procedures/skp-to-pdf-via-layout.md)）：

- **無直接「1260」dim 標** ── 1260 係 SUText anchor 嘅 z 坐標，唔係 dim entity 標
- 圖上見到兩個白色「**120**」格仔喺衣櫃中段，z 高度大約對應 SUText anchor 嘅 1260 ── 應該係**制盒嘅 width 標**（120 = 制盒闊度，匹配標準孖位）
- 離牆距離（離櫃前 210mm／背 290-310mm）**呢個視角睇唔到**，因為視角係正面斜視（制盒位喺櫃背一邊）

要 visually confirm 離牆距離，要：
- User 喺 SketchUp 加 Scene「主人房衣櫃 背」用 back camera angle 再 export
- 或者繼續用 SDK inverse-transform（已 cross-checked user 實測 = 210mm）

## Changelog
- 2026-04-29 09:30 — Initial finding；高度 1260 確認，離牆冇明確 dim
- 2026-04-29 11:00 — 加入 inverse-transform 計算：local (245, -370, 1260)；錯標 X+ 面為「櫃前」（confidence 0.95 但方向錯）
- 2026-04-29 11:30 — User 實測 離櫃前 = 210 反證 X- 面先係櫃前；改正方向約定；離櫃背 (carcass) = 290，離最後緣 = 310；保持 confidence 0.95
- 2026-04-29 13:15 — PNG render visual confirm：1260 係 SUText anchor，120 box width 係 dim；離牆距離呢視角睇唔到，需 back-angle scene 或 SDK 路線

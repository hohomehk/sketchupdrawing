# sketchupdrawing — SketchUp `.skp` analysis workspace

讀／拆 SketchUp 設計檔（`.skp`），抽 component、scene、dimension、material 出嚟做 cut list、draft annotation reuse、3D 預覽。原始用例：分析 `寶翠園5.skp` 度衣櫃。

主要組件係 **Trimble C SDK 跨平台（Windows DLL）+ MinGW cross-compile + Wine 9 + Docker container**。本機 Linux WSL2 完全冇裝 wine／sdk binary —— 所有嘢 sandboxed 喺一個 docker image。

## Wiki

完整 finding／procedure／reference 喺 [`docs/knowledge/wiki/`](docs/knowledge/wiki/index.md)。Index：

- [Procedures](docs/knowledge/wiki/procedures/) — 點裝 SDK toolchain、點 parse SKP
- [Findings](docs/knowledge/wiki/findings/) — 拆 `寶翠園5.skp` 結果（model 結構、衣櫃尺寸）
- [References](docs/knowledge/wiki/references/) — SDK quirks、Wine／Mingw／encoding 注意位
- [Tools](docs/knowledge/wiki/tools/) — 4 隻自家寫嘅 SDK dumper（`dump_skp` / `dump_dims` / `tree_skp` / `wardrobe_dim`）

## Quick start

```bash
docker build -t skpbuild .                          # 第一次裝 toolchain（~100s）
cp /home/timothy/mydocs/寶翠園5.skp /tmp/m.skp     # ASCII path（避 Wine 中文 path bug）
docker run --rm -v "$PWD:/work" -v "/tmp/m.skp:/tmp/m.skp:ro" skpbuild bash -c '
  export WINEPREFIX=/wineprefix WINEDEBUG=-all
  wine wineboot --init >/dev/null 2>&1
  cd /work/win/binaries/sketchup/x64
  wine ./dump_skp.exe Z:/tmp/m.skp > /work/out/dump.txt'
```

睇 [Parse SKP CLI procedure](docs/knowledge/wiki/procedures/parse-skp-cli.md) 攞完整 cookbook。

## 入面有咩

| 路徑 | 內容 |
|---|---|
| `Dockerfile` | Ubuntu 24.04 + mingw-w64 + Wine 9 + winetricks |
| `win/` | Trimble Win SDK 解壓檔（headers + DLL + `.lib`） |
| `mac/` | Trimble Mac SDK（暫時冇用，dylib 喺 Linux 跑唔到） |
| `dump_skp.cpp` | 列 component / layer / scene、計 face count |
| `dump_dims.cpp` | 列所有 SUDimension entity，計實際長度 |
| `tree_skp.cpp` | 遞歸印 ComponentDefinition 子樹 |
| `wardrobe_dim.cpp` | 用 scene name 入 stdin，找 wardrobe 尺寸 |
| `out/` | Tool 執行結果 dump |

## 來龍

呢個 workspace 由 2026-04-29 對話開始，針對 `寶翠園5.skp` 度衣櫃尺寸。最終確認**主人房衣櫃 = 1900+2300 L 型 × 500 深 × 2875 高**（詳見 [master-bedroom-wardrobe](docs/knowledge/wiki/findings/master-bedroom-wardrobe.md)）。

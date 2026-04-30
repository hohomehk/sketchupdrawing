# SketchUp Drawing Wiki — Schema

跟 [marketing wiki schema](../../../../.openclaw/marketing/docs/knowledge/schema.md) 嘅核心 pattern，**輕量化版本**：純 markdown + YAML frontmatter，git 做版本控制，confidence-scored fact。

呢個 workspace 規模細（暫時得一兩個 model 要 parse），所以唔起獨立 lint/CI、ingest pipeline；schema 只係用嚟確保人寫嘅 page 統一格式，方便日後 agent 自動 query。

---

## Frontmatter（強制）

```yaml
---
id: <unique-slug>            # e.g. master-bedroom-wardrobe
type: <page-type>            # procedure | finding | reference | tool
market: na                   # na（呢個 workspace 唔涉及市場區隔）
tone: cantonese              # cantonese | written_zh_hant | mixed | en
confidence: 0.7              # 0.0 - 1.0
sources:
  - ref: <relative path / external URL / conversation date>
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-07-29      # 90 日後 re-verify
tags: [sdk, wine, dimension]
---
```

## Page Types

| type | 寫嘅嘢 |
|---|---|
| **procedure** | 點做某件事；shell script、Docker command、step-by-step；可 reproducible |
| **finding** | 拆 model 結果；ground truth + reasoning；經過檢證 |
| **reference** | Cheatsheet、quirk list、API summary；冇 reasoning，直接攞嚟用 |
| **tool** | 一個 self-written tool 嘅文檔；input／output／usage example |

## Confidence

| 來源 | 分數 |
|---|---|
| 自己跑 SDK 直接驗證（`SUDimension` entity 讀出嘅值） | 0.95 |
| 自己 build 完 + run 過嘅 procedure（toolchain setup） | 0.9 |
| Bbox 推算（鄰邊／圓邊有 ±1mm 誤差） | 0.7 |
| 思考／hypothesis 未跑 | 0.3 |

## Supersession

新 finding 推翻舊 finding 時，舊 page **唔好刪**：在 frontmatter 加 `superseded_by: <new-id>` 並補一個 paragraph 講原因。例：[master-bedroom-wardrobe](findings/master-bedroom-wardrobe.md) 取代咗最初估錯 Component#180 嘅判斷（保留喺同一頁嘅 "Journey" section 做反思）。

## Updating

每 update 一個 fact，bump frontmatter 嘅 `updated` 同視乎需要 `confidence`，並喺 page 底加 changelog entry：

```markdown
## Changelog
- 2026-04-29 — Initial creation; confidence 0.7 from BBox alone
- 2026-04-29 — Bumped confidence to 0.95 after `SUDimension` entity confirmed 2875mm
```

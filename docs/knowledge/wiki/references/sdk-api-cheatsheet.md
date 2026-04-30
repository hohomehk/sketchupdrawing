---
id: sdk-api-cheatsheet
type: reference
market: na
tone: cantonese
confidence: 0.9
sources:
  - ref: SDK_WIN_x64_2026-1-103.zip headers (win/headers/SketchUpAPI/)
    date: 2026-04-29
  - ref: 2026-04-29 build session
    date: 2026-04-29
created: 2026-04-29
updated: 2026-04-29
next_review: 2026-10-29
tags: [sdk, api, cheatsheet]
---

# SDK API Cheatsheet

我哋實際用過嘅 SU* function。Header 全部喺 `win/headers/SketchUpAPI/`。

## Lifecycle

```cpp
SUInitialize();                                // mandatory before any SU* call
SUModelRef m = SU_INVALID;
SUModelLoadStatus status;
SUResult r = SUModelCreateFromFileWithStatus(&m, "path.skp", &status);
// ... use ...
SUModelRelease(&m);
SUTerminate();
```

`status == SUModelLoadStatus_Success_MoreRecent` 時表示 model 比 SDK 新；data 可能讀唔晒。我哋用 SDK 2026 / model 2021 → status 永遠 = Success (0)。

## Strings

```cpp
SUStringRef s = SU_INVALID;
SUStringCreate(&s);
SUSomethingGetName(thing, &s);
size_t len = 0;
SUStringGetUTF8Length(s, &len);
std::string out(len, '\0');
SUStringGetUTF8(s, len + 1, &out[0], &len);
SUStringRelease(&s);
```

UTF-8 in／UTF-8 out。**唔需要任何 encoding conversion** for CJK，只要 console／pipe 識讀 UTF-8。

## Result codes

| Value | Enum | 我哋觸發過 |
|---|---|---|
| 0 | `SU_ERROR_NONE` | success |
| 7 | `SU_ERROR_SERIALIZATION` | 中文 path 載入 fail；改 ASCII path |
| 1 | `SU_ERROR_NULL_POINTER_INPUT` | 漏咗 `SUInstancePathRef*`（`SUDimensionLinearGetStartPoint` 個 path 參數**唔可以 NULL**） |

## Iteration patterns

```cpp
size_t n = 0;
SUEntitiesGetNumInstances(ents, &n);
std::vector<SUComponentInstanceRef> insts(n);
SUEntitiesGetInstances(ents, n, insts.data(), &n);
for (auto i : insts) { ... }
```

每個 GetNumXxx／GetXxx 都係呢個模式。Available counts:

```
SUEntitiesGetNumFaces / Curves / ArcCurves / Edges / GuidePoints / GuideLines /
                       Polyline3ds / Groups / Images / Instances / SectionPlanes /
                       Texts / Dimensions
```

## Core traversal

```
SUModel
├── SUModelGetEntities    → SUEntitiesRef root
├── SUModelGetLayers
├── SUModelGetScenes
└── SUModelGetComponentDefinitions

SUEntities (root or sub)
├── instances → SUComponentInstance → SUComponentDefinition → its own SUEntities
├── groups    → SUGroup             → its own SUEntities
├── faces, edges, dimensions, texts  ← leaf data
```

## Transforms

`SUTransformation.values[16]` 係 **column-major 4×4**：
- `values[0..3]`   = 第一 column (X axis basis)
- `values[4..7]`   = 第二 column (Y axis basis)
- `values[8..11]`  = 第三 column (Z axis basis)
- `values[12..15]` = 第四 column (translation + 1)

Apply to point:
```cpp
SUPoint3D q;
q.x = t.values[0]*p.x + t.values[4]*p.y + t.values[8]*p.z  + t.values[12];
q.y = t.values[1]*p.x + t.values[5]*p.y + t.values[9]*p.z  + t.values[13];
q.z = t.values[2]*p.x + t.values[6]*p.y + t.values[10]*p.z + t.values[14];
```

## Units conversion

SKP internal unit 永遠係 inches。轉 mm：
```cpp
constexpr double IN_TO_MM = 25.4;
double mm = inches * IN_TO_MM;
```

## SUInstancePathRef trap ⚠

Dimension／Text 嘅 GetStartPoint／GetEndPoint／GetPoint 個 `SUInstancePathRef* path` 參數**唔可以 NULL**（即使你唔關心個 path）：

```cpp
SUInstancePathRef path = SU_INVALID;
SUInstancePathCreate(&path);
SUDimensionLinearGetStartPoint(dl, &point, &path);
SUInstancePathRelease(&path);
```

否則會 `SU_ERROR_NULL_POINTER_OUTPUT`，length 計唔到。

## Polymorphism casts

```cpp
SUEntityRef            e  = SUComponentInstanceToEntity(inst);
SUDrawingElementRef    de = SUComponentInstanceToDrawingElement(inst);
SUDrawingElementRef    de = SUGroupToDrawingElement(grp);
SUDimensionLinearRef   dl = SUDimensionLinearFromDimension(dim);
SUEntityRef            de = SUComponentDefinitionToEntity(cd);
```

唔係 implicit cast；要顯式 call `XXXToYYY` / `XXXFromYYY`.

## ID 用嚟去重

```cpp
int32_t id = 0;
SUEntityGetID(SUSomethingToEntity(thing), &id);
```

`SUEntityGetID` 喺 `SketchUpAPI/model/entity.h`（**注意要 include**，唔係喺 common.h）。

`SUEntityGetPersistentID(thing, &int64_pid)` 比較穩定但只 subset 嘅 entity type 支援；entity ID 全部支援。

## BBox

```cpp
SUBoundingBox3D bb;
SUEntitiesGetBoundingBox(ents, &bb);
// bb.min_point, bb.max_point are SUPoint3D in inches
double w = (bb.max_point.x - bb.min_point.x) * 25.4;  // mm
```

⚠️ **Bbox 包邊緣突出**（圓邊／門板／hardware overhang）。User 標嘅 `SUDimension` 通常係 carcass 真實開料尺寸，bbox 會大幾 mm 至幾十 mm。Reconcile 詳見 [master-bedroom-wardrobe](../findings/master-bedroom-wardrobe.md)。

## Scene / Camera

```cpp
SUSceneRef scene = ...;
SUCameraRef cam;
SUSceneGetCamera(scene, &cam);
SUPoint3D eye, target;
SUVector3D up;
SUCameraGetOrientation(cam, &eye, &target, &up);
```

⚠️ **Camera target 唔保證指住 scene 命名嘅 cabinet**。User 可能 orbit／zoom 後個 target 飄去其他位（例：master bedroom scene 嘅 target Z = -19444mm，即地下 19m）。**唔好用 camera target 做 cabinet identification**。

## Hide flags（per scene）

我哋試過用以下方法 isolate 衣櫃 entity，但 `寶翠園5.skp` 冇用：
- `SUSceneGetHiddenEntities` — 0 entities hidden
- `SUSceneGetDrawingElementHidden(scene, de, &h)` — 全部 false

呢個 model 嘅 scene 純粹 camera framing，唔靠 visibility flag isolate。其他 model 可能會用，要 case-by-case 測。

## 我哋未碰嘅 API（潛在用途）

- `SUMaterialGetXxx` — material／texture 抽取
- `SUFaceGetMaterial` — 板材對應 material
- `SUInstancePathCreateFromXxx` — 建立 path object 用 entity hierarchy
- `SUOptionsManagerGet*` — model 嘅 unit／display options
- `SUModelGetClassifications` — IFC／BIM 分類

## Changelog
- 2026-04-29 — Initial; covers what we used in 寶翠園5 parsing

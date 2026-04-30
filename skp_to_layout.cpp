// skp_to_layout.cpp — generate a multi-page .layout document from a .skp,
// one page per Scene. Pure SDK serialization — no rendering, no GL needed.
//
// Output is a normal LayOut file editable in LayOut app. Saving doesn't
// rasterize the model viewports; SketchUp scene references are stored
// as metadata and re-rendered when the .layout doc is opened.
//
// Usage: wine skp_to_layout.exe <model.skp> <out.layout> [version=Current]
//   version: integer enum, e.g. 22 for LayOut 2022, 23 for 2023 (Current).

#include <LayOutAPI/common.h>
#include <LayOutAPI/initialize.h>
#include <LayOutAPI/model/document.h>
#include <LayOutAPI/model/page.h>
#include <LayOutAPI/model/layer.h>
#include <LayOutAPI/model/sketchupmodel.h>
#include <SketchUpAPI/unicodestring.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static std::string SU_S(SUStringRef s) {
    size_t l = 0; SUStringGetUTF8Length(s, &l);
    std::string r(l, '\0');
    if (l) SUStringGetUTF8(s, l + 1, &r[0], &l);
    return r;
}

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s <model.skp> <out.layout> [version_int]\n", argv[0]);
        return 2;
    }
    const char* skp_path = argv[1];
    const char* out_path = argv[2];
    LODocumentVersion ver = LODocumentVersion_Current;
    if (argc >= 4) ver = (LODocumentVersion)std::atoi(argv[3]);

    LOInitialize();

    // Probe SKP to enumerate scenes
    LOSketchUpModelRef probe = SU_INVALID;
    LOAxisAlignedRect2D b = { {.25, 1.}, {10.5, 7.5} };
    SUResult r = LOSketchUpModelCreate(&probe, skp_path, &b);
    if (r != SU_ERROR_NONE) {
        std::fprintf(stderr, "Cannot open SKP: code=%d\n", (int)r);
        return 1;
    }
    size_t scene_count = 0;
    LOSketchUpModelGetNumberOfAvailableScenes(probe, &scene_count);
    std::vector<SUStringRef> scenes(scene_count);
    for (size_t i = 0; i < scene_count; ++i) {
        SUSetInvalid(scenes[i]); SUStringCreate(&scenes[i]);
    }
    LOSketchUpModelGetAvailableScenes(probe, scene_count, scenes.data(), &scene_count);
    std::printf("Found %zu scenes (incl. default)\n", scene_count);

    // Build multi-page document
    LODocumentRef doc = SU_INVALID;
    if (LODocumentCreateEmpty(&doc) != SU_ERROR_NONE) {
        std::fprintf(stderr, "LODocumentCreateEmpty failed\n"); return 1;
    }
    LOLayerRef layer = SU_INVALID;
    LODocumentAddLayer(doc, false /* shared */, &layer);
    LOLayerSetName(layer, "Models");

    for (size_t i = 1; i < scene_count; ++i) {
        LOPageRef page = SU_INVALID;
        if (i == 1) {
            LODocumentGetPageAtIndex(doc, 0, &page);
        } else {
            LODocumentAddPage(doc, &page);
        }
        std::string nm = SU_S(scenes[i]);
        LOPageSetName(page, nm.c_str());

        LOSketchUpModelRef m = SU_INVALID;
        LOAxisAlignedRect2D bounds = { {.25, 1.}, {10.5, 7.5} };
        if (LOSketchUpModelCreate(&m, skp_path, &bounds) != SU_ERROR_NONE) {
            std::fprintf(stderr, "scene %zu: SKP load failed\n", i);
            continue;
        }
        LOSketchUpModelSetCurrentScene(m, i);
        LOEntityRef ent = LOSketchUpModelToEntity(m);
        LODocumentAddEntity(doc, ent, layer, page);
        std::printf("  page %zu: %s\n", i, nm.c_str());
    }

    // Save to .layout file — pure serialization, no rendering
    std::printf("\nSaving as LayOut version %d ...\n", (int)ver);
    r = LODocumentSaveToFile(doc, out_path, ver);
    if (r == SU_ERROR_NONE) {
        std::printf("OK: %s\n", out_path);
    } else {
        std::fprintf(stderr, "Save failed: code=%d\n", (int)r);
    }

    for (size_t i = 0; i < scene_count; ++i) SUStringRelease(&scenes[i]);
    LODocumentRelease(&doc);
    LOTerminate();
    return r == SU_ERROR_NONE ? 0 : 1;
}

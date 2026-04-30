// skp_to_png.cpp — render every Scene in a .skp as a PNG via LayOut SDK.
// Pipeline:
//   1. Use LOSketchUpModelCreate to load each SKP scene as a LayOut viewport
//   2. Build a LayOut document with one page per scene
//   3. LODocumentExportToImageSet → PNGs at configurable DPI
//
// Usage: wine skp_to_png.exe <model.skp> <out_dir> [<dpi=200>]

#include <LayOutAPI/common.h>
#include <LayOutAPI/initialize.h>
#include <LayOutAPI/model/document.h>
#include <LayOutAPI/model/documentexportoptions.h>
#include <LayOutAPI/model/dictionary.h>
#include <LayOutAPI/model/typed_value.h>
#include <LayOutAPI/model/imagerep.h>
#include <LayOutAPI/model/layer.h>
#include <LayOutAPI/model/page.h>
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
        std::fprintf(stderr, "usage: %s <model.skp> <out_pdf_template> [scene_index]\n", argv[0]);
        std::fprintf(stderr, "  out_pdf_template: substitutes %%d with scene index\n");
        std::fprintf(stderr, "    e.g. \"Z:/work/out/scene_%%02d.pdf\"\n");
        std::fprintf(stderr, "  scene_index: 0-based; if given, render only that scene\n");
        return 2;
    }
    const char* skp_path = argv[1];
    const char* out_template = argv[2];
    int only_scene = (argc >= 4) ? std::atoi(argv[3]) : -1;

    LOInitialize();

    // ---- Load .skp once, just to enumerate scene names ----
    LOSketchUpModelRef probe_model = SU_INVALID;
    LOAxisAlignedRect2D probe_bounds = { {.25, 1.}, {10.5, 7.5} };
    SUResult r = LOSketchUpModelCreate(&probe_model, skp_path, &probe_bounds);
    if (r != SU_ERROR_NONE) {
        std::fprintf(stderr, "LOSketchUpModelCreate failed: %d\n", (int)r);
        return 1;
    }
    size_t scene_count = 0;
    LOSketchUpModelGetNumberOfAvailableScenes(probe_model, &scene_count);
    std::vector<SUStringRef> scene_names(scene_count);
    for (size_t i = 0; i < scene_count; ++i) {
        SUSetInvalid(scene_names[i]);
        SUStringCreate(&scene_names[i]);
    }
    LOSketchUpModelGetAvailableScenes(probe_model, scene_count, scene_names.data(), &scene_count);
    std::printf("scene_count = %zu\n", scene_count);

    // ---- Build LayOut document from template ----
    LODocumentRef doc = SU_INVALID;
    r = LODocumentCreateEmpty(&doc);  // empty doc, no template RTF text fields
    if (r != SU_ERROR_NONE) {
        std::fprintf(stderr, "LODocumentCreateEmpty failed: %d\n", (int)r);
        return 1;
    }

    LOLayerRef layer = SU_INVALID;
    LODocumentAddLayer(doc, false /* shared */, &layer);
    LOLayerSetName(layer, "Models");

    LODocumentRelease(&doc);  // discard exploration doc; we build per-scene below

    // ---- Per-scene render: build a single-page document, export, release ----
    size_t start_idx = (only_scene >= 0) ? (size_t)only_scene : 1;
    size_t end_idx   = (only_scene >= 0) ? (size_t)only_scene + 1 : scene_count;

    int ok = 0, fail = 0;
    for (size_t i = start_idx; i < end_idx; ++i) {
        LODocumentRef d = SU_INVALID;
        if (LODocumentCreateEmpty(&d) != SU_ERROR_NONE) { fail++; continue; }
        LOLayerRef layer = SU_INVALID;
        LODocumentAddLayer(d, false, &layer);
        LOLayerSetName(layer, "Models");

        LOPageRef page = SU_INVALID;
        LODocumentGetPageAtIndex(d, 0, &page);
        std::string nm = SU_S(scene_names[i]);
        LOPageSetName(page, nm.c_str());

        LOSketchUpModelRef m = SU_INVALID;
        LOAxisAlignedRect2D bounds = { {.25, 1.}, {10.5, 7.5} };
        if (LOSketchUpModelCreate(&m, skp_path, &bounds) != SU_ERROR_NONE) {
            LODocumentRelease(&d); fail++; continue;
        }
        LOSketchUpModelSetCurrentScene(m, i);
        LOEntityRef ent = LOSketchUpModelToEntity(m);
        LODocumentAddEntity(d, ent, layer, page);

        char outpath[1024];
        std::snprintf(outpath, sizeof(outpath), out_template, (int)i);

        LODictionaryRef opts = SU_INVALID; LODictionaryCreate(&opts);
        SUResult er = LODocumentExportToPDF(d, outpath, opts);
        LODictionaryRelease(&opts);
        LODocumentRelease(&d);
        if (er == SU_ERROR_NONE) {
            std::printf("[%2zu/%2zu] %s -> %s\n", i, scene_count - 1, nm.c_str(), outpath);
            std::fflush(stdout);
            ok++;
        } else {
            std::fprintf(stderr, "[%2zu] export failed (err=%d): %s\n", i, (int)er, nm.c_str());
            fail++;
        }
    }
    std::printf("\nDone: %d ok, %d fail\n", ok, fail);
    r = (fail == 0) ? SU_ERROR_NONE : SU_ERROR_GENERIC;
    for (size_t i = 0; i < scene_count; ++i)
        SUStringRelease(&scene_names[i]);
    LODocumentRelease(&doc);
    LOTerminate();
    return r == SU_ERROR_NONE ? 0 : 1;
}

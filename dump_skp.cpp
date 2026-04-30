// dump_skp.cpp — list all ComponentDefinitions, Layers, Scenes, and dump
// faces+vertices for definitions whose name matches a substring (default 衣櫃).
//
// Usage (under wine64):
//   wine64 dump_skp.exe <model.skp> [name_substring_utf8]
//
// Output: tab-separated to stdout. UTF-8 throughout.

#include <SketchUpAPI/initialize.h>
#include <SketchUpAPI/unicodestring.h>
#include <SketchUpAPI/transformation.h>
#include <SketchUpAPI/model/model.h>
#include <SketchUpAPI/model/entities.h>
#include <SketchUpAPI/model/component_definition.h>
#include <SketchUpAPI/model/component_instance.h>
#include <SketchUpAPI/model/group.h>
#include <SketchUpAPI/model/scene.h>
#include <SketchUpAPI/model/layer.h>
#include <SketchUpAPI/model/drawing_element.h>
#include <SketchUpAPI/model/entity.h>
#include <SketchUpAPI/model/face.h>
#include <SketchUpAPI/model/edge.h>
#include <SketchUpAPI/model/vertex.h>
#include <SketchUpAPI/model/loop.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// SKP internal length unit is inches. Convert to mm.
static const double IN_TO_MM = 25.4;

static std::string SUString_To_UTF8(SUStringRef s) {
    size_t len = 0;
    SUStringGetUTF8Length(s, &len);
    std::string out(len, '\0');
    if (len) SUStringGetUTF8(s, len + 1, &out[0], &len);
    return out;
}

static std::string GetName_Component(SUComponentDefinitionRef cd) {
    SUStringRef s = SU_INVALID; SUStringCreate(&s);
    SUComponentDefinitionGetName(cd, &s);
    std::string r = SUString_To_UTF8(s);
    SUStringRelease(&s);
    return r;
}
static std::string GetDescription_Component(SUComponentDefinitionRef cd) {
    SUStringRef s = SU_INVALID; SUStringCreate(&s);
    SUComponentDefinitionGetDescription(cd, &s);
    std::string r = SUString_To_UTF8(s);
    SUStringRelease(&s);
    return r;
}
static std::string GetName_Instance(SUComponentInstanceRef ci) {
    SUStringRef s = SU_INVALID; SUStringCreate(&s);
    SUComponentInstanceGetName(ci, &s);
    std::string r = SUString_To_UTF8(s);
    SUStringRelease(&s);
    return r;
}
static std::string GetName_Layer(SULayerRef l) {
    SUStringRef s = SU_INVALID; SUStringCreate(&s);
    SULayerGetName(l, &s);
    std::string r = SUString_To_UTF8(s);
    SUStringRelease(&s);
    return r;
}
static std::string GetName_Scene(SUSceneRef sc) {
    SUStringRef s = SU_INVALID; SUStringCreate(&s);
    SUSceneGetName(sc, &s);
    std::string r = SUString_To_UTF8(s);
    SUStringRelease(&s);
    return r;
}

static void PrintBBox_mm(SUBoundingBox3D bb) {
    double xs = (bb.max_point.x - bb.min_point.x) * IN_TO_MM;
    double ys = (bb.max_point.y - bb.min_point.y) * IN_TO_MM;
    double zs = (bb.max_point.z - bb.min_point.z) * IN_TO_MM;
    std::printf("size_mm=(%.1f x %.1f x %.1f)", xs, ys, zs);
}

static int CountFacesRecursive(SUEntitiesRef ents) {
    size_t n = 0;
    SUEntitiesGetNumFaces(ents, &n);
    int total = (int)n;
    size_t ng = 0;
    SUEntitiesGetNumGroups(ents, &ng);
    if (ng) {
        std::vector<SUGroupRef> groups(ng);
        SUEntitiesGetGroups(ents, ng, groups.data(), &ng);
        for (auto g : groups) {
            SUEntitiesRef ge = SU_INVALID;
            SUGroupGetEntities(g, &ge);
            total += CountFacesRecursive(ge);
        }
    }
    size_t ni = 0;
    SUEntitiesGetNumInstances(ents, &ni);
    if (ni) {
        std::vector<SUComponentInstanceRef> insts(ni);
        SUEntitiesGetInstances(ents, ni, insts.data(), &ni);
        for (auto ci : insts) {
            SUComponentDefinitionRef cd = SU_INVALID;
            SUComponentInstanceGetDefinition(ci, &cd);
            SUEntitiesRef ce = SU_INVALID;
            SUComponentDefinitionGetEntities(cd, &ce);
            total += CountFacesRecursive(ce);
        }
    }
    return total;
}

static void DumpFaces(SUEntitiesRef ents, const std::string& prefix, int depth) {
    if (depth > 6) return;
    size_t nFaces = 0;
    SUEntitiesGetNumFaces(ents, &nFaces);
    if (nFaces) {
        std::vector<SUFaceRef> faces(nFaces);
        SUEntitiesGetFaces(ents, nFaces, faces.data(), &nFaces);
        for (size_t i = 0; i < nFaces; ++i) {
            SUFaceRef f = faces[i];
            double area = 0;
            SUFaceGetArea(f, &area);
            // Outer loop vertices
            SULoopRef outer = SU_INVALID;
            SUFaceGetOuterLoop(f, &outer);
            size_t nv = 0;
            SULoopGetNumVertices(outer, &nv);
            std::vector<SUVertexRef> verts(nv);
            SULoopGetVertices(outer, nv, verts.data(), &nv);
            std::printf("%sFace#%zu  area_mm2=%.1f  verts=%zu  pts=[",
                        prefix.c_str(), i, area * IN_TO_MM * IN_TO_MM, nv);
            for (size_t j = 0; j < nv && j < 12; ++j) {
                SUPoint3D p;
                SUVertexGetPosition(verts[j], &p);
                std::printf("(%.0f,%.0f,%.0f)%s",
                            p.x * IN_TO_MM, p.y * IN_TO_MM, p.z * IN_TO_MM,
                            (j + 1 < nv && j < 11) ? "," : "");
            }
            if (nv > 12) std::printf(",...");
            std::printf("]\n");
        }
    }
    // Recurse into groups and instances inside this entities container
    size_t ng = 0;
    SUEntitiesGetNumGroups(ents, &ng);
    if (ng) {
        std::vector<SUGroupRef> groups(ng);
        SUEntitiesGetGroups(ents, ng, groups.data(), &ng);
        for (size_t i = 0; i < ng; ++i) {
            SUEntitiesRef ge = SU_INVALID;
            SUGroupGetEntities(groups[i], &ge);
            char buf[64]; std::snprintf(buf, sizeof(buf), "  group#%zu/", i);
            DumpFaces(ge, prefix + buf, depth + 1);
        }
    }
    size_t ni = 0;
    SUEntitiesGetNumInstances(ents, &ni);
    if (ni) {
        std::vector<SUComponentInstanceRef> insts(ni);
        SUEntitiesGetInstances(ents, ni, insts.data(), &ni);
        for (size_t i = 0; i < ni; ++i) {
            SUComponentDefinitionRef cd = SU_INVALID;
            SUComponentInstanceGetDefinition(insts[i], &cd);
            std::string name = GetName_Component(cd);
            char buf[256]; std::snprintf(buf, sizeof(buf), "  inst#%zu(%s)/", i, name.c_str());
            SUEntitiesRef ce = SU_INVALID;
            SUComponentDefinitionGetEntities(cd, &ce);
            DumpFaces(ce, prefix + buf, depth + 1);
        }
    }
}

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <model.skp> [name_substring]\n", argv[0]);
        return 2;
    }
    const char* path = argv[1];
    const char* needle = (argc >= 3) ? argv[2] : "衣櫃";

    SUInitialize();

    SUModelRef model = SU_INVALID;
    SUModelLoadStatus status;
    SUResult r = SUModelCreateFromFileWithStatus(&model, path, &status);
    if (r != SU_ERROR_NONE) {
        std::fprintf(stderr, "SUModelCreateFromFileWithStatus failed: %d\n", (int)r);
        SUTerminate();
        return 1;
    }
    if (status == SUModelLoadStatus_Success_MoreRecent) {
        std::fprintf(stderr, "(model is newer than SDK; some data may be missing)\n");
    }

    // ---- Header ----
    SUStringRef name = SU_INVALID; SUStringCreate(&name);
    SUModelGetName(model, &name);
    std::printf("== MODEL ==\nname=%s\n", SUString_To_UTF8(name).c_str());
    SUStringRelease(&name);

    // ---- Layers ----
    size_t numLayers = 0;
    SUModelGetNumLayers(model, &numLayers);
    std::printf("\n== LAYERS (%zu) ==\n", numLayers);
    if (numLayers) {
        std::vector<SULayerRef> layers(numLayers);
        SUModelGetLayers(model, numLayers, layers.data(), &numLayers);
        for (size_t i = 0; i < numLayers; ++i) {
            std::printf("  L%-3zu  %s\n", i, GetName_Layer(layers[i]).c_str());
        }
    }

    // ---- Scenes ----
    size_t numScenes = 0;
    SUModelGetNumScenes(model, &numScenes);
    std::printf("\n== SCENES (%zu) ==\n", numScenes);
    if (numScenes) {
        std::vector<SUSceneRef> scenes(numScenes);
        SUModelGetScenes(model, numScenes, scenes.data(), &numScenes);
        for (size_t i = 0; i < numScenes; ++i) {
            std::printf("  S%-3zu  %s\n", i, GetName_Scene(scenes[i]).c_str());
        }
    }

    // ---- ComponentDefinitions ----
    size_t numDefs = 0;
    SUModelGetNumComponentDefinitions(model, &numDefs);
    std::printf("\n== COMPONENT DEFINITIONS (%zu) ==\n", numDefs);
    std::vector<SUComponentDefinitionRef> defs(numDefs);
    if (numDefs) SUModelGetComponentDefinitions(model, numDefs, defs.data(), &numDefs);
    for (size_t i = 0; i < numDefs; ++i) {
        SUComponentDefinitionRef cd = defs[i];
        std::string nm = GetName_Component(cd);
        size_t nInst = 0; SUComponentDefinitionGetNumInstances(cd, &nInst);
        size_t nUsed = 0; SUComponentDefinitionGetNumUsedInstances(cd, &nUsed);
        SUEntitiesRef ce = SU_INVALID;
        SUComponentDefinitionGetEntities(cd, &ce);
        SUBoundingBox3D bb; SUEntitiesGetBoundingBox(ce, &bb);
        int nf = CountFacesRecursive(ce);
        std::printf("  D%-4zu name=%-40s inst=%2zu(used=%2zu) faces_total=%d  ",
                    i, nm.c_str(), nInst, nUsed, nf);
        PrintBBox_mm(bb);
        std::printf("\n");
    }

    // ---- Top-level entities (groups + instances) ----
    SUEntitiesRef root = SU_INVALID;
    SUModelGetEntities(model, &root);
    size_t nRootGroups = 0;  SUEntitiesGetNumGroups(root, &nRootGroups);
    size_t nRootInsts  = 0;  SUEntitiesGetNumInstances(root, &nRootInsts);
    std::printf("\n== TOP-LEVEL ENTITIES ==\n");
    std::printf("groups_at_root=%zu instances_at_root=%zu\n", nRootGroups, nRootInsts);
    if (nRootGroups) {
        std::vector<SUGroupRef> gs(nRootGroups);
        SUEntitiesGetGroups(root, nRootGroups, gs.data(), &nRootGroups);
        for (size_t i = 0; i < nRootGroups; ++i) {
            SUStringRef gn = SU_INVALID; SUStringCreate(&gn);
            SUGroupGetName(gs[i], &gn);
            SUEntitiesRef ge = SU_INVALID;
            SUGroupGetEntities(gs[i], &ge);
            SUBoundingBox3D bb; SUEntitiesGetBoundingBox(ge, &bb);
            std::printf("  G%-3zu  %-40s ", i, SUString_To_UTF8(gn).c_str());
            PrintBBox_mm(bb);
            std::printf("\n");
            SUStringRelease(&gn);
        }
    }
    if (nRootInsts) {
        std::vector<SUComponentInstanceRef> is(nRootInsts);
        SUEntitiesGetInstances(root, nRootInsts, is.data(), &nRootInsts);
        for (size_t i = 0; i < nRootInsts; ++i) {
            SUComponentDefinitionRef cd = SU_INVALID;
            SUComponentInstanceGetDefinition(is[i], &cd);
            std::string defNm = GetName_Component(cd);
            std::string instNm = GetName_Instance(is[i]);
            SUTransformation t;
            SUComponentInstanceGetTransform(is[i], &t);
            // Translation (last column in column-major 4x4)
            double tx = t.values[12] * IN_TO_MM;
            double ty = t.values[13] * IN_TO_MM;
            double tz = t.values[14] * IN_TO_MM;
            std::printf("  I%-3zu  inst=%-30s def=%-30s pos_mm=(%.0f,%.0f,%.0f)\n",
                        i, instNm.c_str(), defNm.c_str(), tx, ty, tz);
        }
    }

    // ---- Detailed dump of definitions matching needle ----
    std::printf("\n== DETAILED DUMP for definitions containing %s ==\n", needle);
    for (size_t i = 0; i < numDefs; ++i) {
        SUComponentDefinitionRef cd = defs[i];
        std::string nm = GetName_Component(cd);
        if (nm.find(needle) == std::string::npos) continue;
        std::printf("\n--- %s ---\n", nm.c_str());
        std::string desc = GetDescription_Component(cd);
        if (!desc.empty()) std::printf("desc=%s\n", desc.c_str());
        SUEntitiesRef ce = SU_INVALID;
        SUComponentDefinitionGetEntities(cd, &ce);
        SUBoundingBox3D bb; SUEntitiesGetBoundingBox(ce, &bb);
        std::printf("bbox_mm: min=(%.1f,%.1f,%.1f) max=(%.1f,%.1f,%.1f)\n",
                    bb.min_point.x*IN_TO_MM, bb.min_point.y*IN_TO_MM, bb.min_point.z*IN_TO_MM,
                    bb.max_point.x*IN_TO_MM, bb.max_point.y*IN_TO_MM, bb.max_point.z*IN_TO_MM);
        DumpFaces(ce, "    ", 0);
    }

    SUModelRelease(&model);
    SUTerminate();
    return 0;
}

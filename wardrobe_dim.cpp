// wardrobe_dim.cpp — find dimensions of a scene by EXCLUDING entities the
// scene has explicitly hidden. The user's workflow: each cabinet has its
// own scene that hides everything else and shows just that cabinet.
//
// Usage: echo "<scene_name_utf8>" | wine wardrobe_dim.exe <model.skp>
//        or echo "#N" | wine wardrobe_dim.exe <model.skp>   (index form)

#include <SketchUpAPI/initialize.h>
#include <SketchUpAPI/unicodestring.h>
#include <SketchUpAPI/transformation.h>
#include <SketchUpAPI/model/model.h>
#include <SketchUpAPI/model/entities.h>
#include <SketchUpAPI/model/entity.h>
#include <SketchUpAPI/model/scene.h>
#include <SketchUpAPI/model/component_definition.h>
#include <SketchUpAPI/model/component_instance.h>
#include <SketchUpAPI/model/group.h>
#include <SketchUpAPI/model/drawing_element.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <set>

static const double IN_TO_MM = 25.4;

static std::string SU_S(SUStringRef s) {
    size_t len = 0; SUStringGetUTF8Length(s, &len);
    std::string r(len, '\0');
    if (len) SUStringGetUTF8(s, len + 1, &r[0], &len);
    return r;
}

static SUPoint3D Tx_Pt(const SUTransformation& t, SUPoint3D p) {
    SUPoint3D q;
    q.x = t.values[0]*p.x + t.values[4]*p.y + t.values[8]*p.z  + t.values[12];
    q.y = t.values[1]*p.x + t.values[5]*p.y + t.values[9]*p.z  + t.values[13];
    q.z = t.values[2]*p.x + t.values[6]*p.y + t.values[10]*p.z + t.values[14];
    return q;
}

struct BBox {
    double mn[3] = { 1e18, 1e18, 1e18 };
    double mx[3] = { -1e18, -1e18, -1e18 };
    bool valid() const { return mn[0] <= mx[0]; }
    void add(SUPoint3D p) {
        double v[3] = { p.x, p.y, p.z };
        for (int i = 0; i < 3; ++i) {
            if (v[i] < mn[i]) mn[i] = v[i];
            if (v[i] > mx[i]) mx[i] = v[i];
        }
    }
    void merge(const BBox& o) {
        if (!o.valid()) return;
        for (int i = 0; i < 3; ++i) {
            if (o.mn[i] < mn[i]) mn[i] = o.mn[i];
            if (o.mx[i] > mx[i]) mx[i] = o.mx[i];
        }
    }
};

static BBox TransformedBBox(const SUBoundingBox3D& local, const SUTransformation& t) {
    BBox out;
    for (int xi = 0; xi < 2; ++xi)
    for (int yi = 0; yi < 2; ++yi)
    for (int zi = 0; zi < 2; ++zi) {
        SUPoint3D p;
        p.x = (xi ? local.max_point.x : local.min_point.x);
        p.y = (yi ? local.max_point.y : local.min_point.y);
        p.z = (zi ? local.max_point.z : local.min_point.z);
        out.add(Tx_Pt(t, p));
    }
    return out;
}

static int32_t EntityID(SUEntityRef e) {
    int32_t id = 0;
    SUEntityGetID(e, &id);
    return id;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <model.skp>\n  scene name from stdin\n", argv[0]);
        return 2;
    }
    char buf[256] = {0};
    if (!std::fgets(buf, sizeof(buf), stdin)) { std::fprintf(stderr, "no scene\n"); return 2; }
    size_t bn = std::strlen(buf);
    while (bn && (buf[bn-1] == '\n' || buf[bn-1] == '\r')) buf[--bn] = 0;
    const char* sceneName = buf;

    SUInitialize();
    SUModelRef model = SU_INVALID;
    SUModelLoadStatus st;
    if (SUModelCreateFromFileWithStatus(&model, argv[1], &st) != SU_ERROR_NONE) {
        std::fprintf(stderr, "load failed\n"); return 1;
    }

    // ---- find scene ----
    size_t numScenes = 0; SUModelGetNumScenes(model, &numScenes);
    std::vector<SUSceneRef> scenes(numScenes);
    SUModelGetScenes(model, numScenes, scenes.data(), &numScenes);

    SUSceneRef target_scene = SU_INVALID;
    std::string matched;
    if (sceneName[0] == '#') {
        size_t idx = (size_t)std::atoi(sceneName + 1);
        if (idx < numScenes) {
            target_scene = scenes[idx];
            SUStringRef sn = SU_INVALID; SUStringCreate(&sn);
            SUSceneGetName(target_scene, &sn);
            matched = SU_S(sn);
            SUStringRelease(&sn);
        }
    } else {
        for (size_t i = 0; i < numScenes; ++i) {
            SUStringRef sn = SU_INVALID; SUStringCreate(&sn);
            SUSceneGetName(scenes[i], &sn);
            std::string nm = SU_S(sn);
            SUStringRelease(&sn);
            if (nm.find(sceneName) != std::string::npos) {
                target_scene = scenes[i]; matched = nm; break;
            }
        }
    }
    if (SUIsInvalid(target_scene)) {
        std::fprintf(stderr, "scene not found: %s\n", sceneName); return 1;
    }
    std::printf("Matched scene: \"%s\"\n", matched.c_str());

    // ---- get hidden entities for this scene ----
    bool useHidden = false;
    SUSceneGetUseHidden(target_scene, &useHidden);
    bool useHiddenGeo = false;
    SUSceneGetUseHiddenGeometry(target_scene, &useHiddenGeo);
    bool useHiddenObj = false;
    SUSceneGetUseHiddenObjects(target_scene, &useHiddenObj);
    std::printf("UseHidden=%d UseHiddenGeometry=%d UseHiddenObjects=%d\n",
                useHidden, useHiddenGeo, useHiddenObj);

    size_t numHidden = 0;
    SUSceneGetNumHiddenEntities(target_scene, &numHidden);
    std::printf("Scene hides %zu entities\n", numHidden);
    std::set<int32_t> hiddenIds;
    if (numHidden) {
        std::vector<SUEntityRef> hidden(numHidden);
        SUSceneGetHiddenEntities(target_scene, numHidden, hidden.data(), &numHidden);
        for (auto h : hidden) hiddenIds.insert(EntityID(h));
    }

    // ---- iterate root entities, skip hidden ----
    SUEntitiesRef root = SU_INVALID;
    SUModelGetEntities(model, &root);

    BBox combined;
    int kept = 0, skipped = 0;
    std::printf("\n%-7s %-25s %-30s %s\n", "kind", "def_or_grp", "pos_mm", "world_bbox_mm");

    // instances
    size_t nI = 0; SUEntitiesGetNumInstances(root, &nI);
    if (nI) {
        std::vector<SUComponentInstanceRef> insts(nI);
        SUEntitiesGetInstances(root, nI, insts.data(), &nI);
        for (size_t i = 0; i < nI; ++i) {
            SUEntityRef en = SUComponentInstanceToEntity(insts[i]);
            int32_t id = EntityID(en);
            bool isHidden = hiddenIds.count(id) > 0;
            // Per-scene per-entity hidden override
            if (!isHidden) {
                SUDrawingElementRef de = SUComponentInstanceToDrawingElement(insts[i]);
                bool h = false;
                if (SUSceneGetDrawingElementHidden(target_scene, de, &h) == SU_ERROR_NONE) {
                    if (h) isHidden = true;
                }
            }

            SUTransformation t; SUComponentInstanceGetTransform(insts[i], &t);
            SUPoint3D p = { t.values[12], t.values[13], t.values[14] };

            SUComponentDefinitionRef cd = SU_INVALID;
            SUComponentInstanceGetDefinition(insts[i], &cd);
            SUStringRef cn = SU_INVALID; SUStringCreate(&cn);
            SUComponentDefinitionGetName(cd, &cn);
            std::string defName = SU_S(cn);
            SUStringRelease(&cn);

            SUEntitiesRef ce = SU_INVALID;
            SUComponentDefinitionGetEntities(cd, &ce);
            SUBoundingBox3D lb; SUEntitiesGetBoundingBox(ce, &lb);
            BBox wb = TransformedBBox(lb, t);

            if (isHidden) { skipped++; continue; }
            combined.merge(wb);
            kept++;
            if (kept <= 80) {
                std::printf("inst    %-25s (%6.0f,%6.0f,%6.0f)  (%6.0f..%6.0f, %6.0f..%6.0f, %5.0f..%5.0f)\n",
                            defName.c_str(),
                            p.x*IN_TO_MM, p.y*IN_TO_MM, p.z*IN_TO_MM,
                            wb.mn[0]*IN_TO_MM, wb.mx[0]*IN_TO_MM,
                            wb.mn[1]*IN_TO_MM, wb.mx[1]*IN_TO_MM,
                            wb.mn[2]*IN_TO_MM, wb.mx[2]*IN_TO_MM);
            }
        }
    }
    // groups
    size_t nG = 0; SUEntitiesGetNumGroups(root, &nG);
    if (nG) {
        std::vector<SUGroupRef> grps(nG);
        SUEntitiesGetGroups(root, nG, grps.data(), &nG);
        for (size_t i = 0; i < nG; ++i) {
            SUEntityRef en = SUGroupToEntity(grps[i]);
            int32_t id = EntityID(en);
            bool isHidden = hiddenIds.count(id) > 0;
            if (!isHidden) {
                SUDrawingElementRef de = SUGroupToDrawingElement(grps[i]);
                bool h = false;
                if (SUSceneGetDrawingElementHidden(target_scene, de, &h) == SU_ERROR_NONE) {
                    if (h) isHidden = true;
                }
            }

            SUTransformation t; SUGroupGetTransform(grps[i], &t);
            SUPoint3D p = { t.values[12], t.values[13], t.values[14] };
            SUEntitiesRef ge = SU_INVALID;
            SUGroupGetEntities(grps[i], &ge);
            SUBoundingBox3D lb; SUEntitiesGetBoundingBox(ge, &lb);
            BBox wb = TransformedBBox(lb, t);

            if (isHidden) { skipped++; continue; }
            combined.merge(wb);
            kept++;
            std::printf("group   %-25s (%6.0f,%6.0f,%6.0f)  (%6.0f..%6.0f, %6.0f..%6.0f, %5.0f..%5.0f)\n",
                        "(group)",
                        p.x*IN_TO_MM, p.y*IN_TO_MM, p.z*IN_TO_MM,
                        wb.mn[0]*IN_TO_MM, wb.mx[0]*IN_TO_MM,
                        wb.mn[1]*IN_TO_MM, wb.mx[1]*IN_TO_MM,
                        wb.mn[2]*IN_TO_MM, wb.mx[2]*IN_TO_MM);
        }
    }

    std::printf("\n==== RESULT ====\n");
    std::printf("Kept %d, hidden-skipped %d (of %zu instances + %zu groups)\n",
                kept, skipped, nI, nG);
    if (combined.valid()) {
        double L = (combined.mx[0] - combined.mn[0]) * IN_TO_MM;
        double W = (combined.mx[1] - combined.mn[1]) * IN_TO_MM;
        double H = (combined.mx[2] - combined.mn[2]) * IN_TO_MM;
        std::printf("Combined visible bbox (mm):\n");
        std::printf("  X: %.0f .. %.0f   length=%.0f\n",
                    combined.mn[0]*IN_TO_MM, combined.mx[0]*IN_TO_MM, L);
        std::printf("  Y: %.0f .. %.0f   width =%.0f\n",
                    combined.mn[1]*IN_TO_MM, combined.mx[1]*IN_TO_MM, W);
        std::printf("  Z: %.0f .. %.0f   height=%.0f\n",
                    combined.mn[2]*IN_TO_MM, combined.mx[2]*IN_TO_MM, H);
        std::printf("\n  L x W x H  =  %.0f x %.0f x %.0f mm\n", L, W, H);
    }

    SUModelRelease(&model);
    SUTerminate();
    return 0;
}

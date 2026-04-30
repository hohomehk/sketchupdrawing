// dump_dims.cpp — list all linear Dimensions in the model with their
// labeled text, computed length (from start->end), and 3D location.
// Recurse into ComponentDefinitions so we catch annotations attached
// to anything (the user labels heights inside a wardrobe component).
//
// Usage: wine dump_dims.exe <model.skp>

#include <SketchUpAPI/initialize.h>
#include <SketchUpAPI/unicodestring.h>
#include <SketchUpAPI/transformation.h>
#include <SketchUpAPI/geometry.h>
#include <SketchUpAPI/model/model.h>
#include <SketchUpAPI/model/entities.h>
#include <SketchUpAPI/model/dimension.h>
#include <SketchUpAPI/model/dimension_linear.h>
#include <SketchUpAPI/model/component_definition.h>
#include <SketchUpAPI/model/component_instance.h>
#include <SketchUpAPI/model/group.h>
#include <SketchUpAPI/model/entity.h>
#include <SketchUpAPI/model/instancepath.h>

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

static SUTransformation Identity() {
    SUTransformation t{};
    for (int i = 0; i < 4; ++i) t.values[i*4 + i] = 1.0;
    return t;
}

static SUTransformation Mul(const SUTransformation& a, const SUTransformation& b) {
    SUTransformation r{};
    for (int row = 0; row < 4; ++row)
        for (int col = 0; col < 4; ++col) {
            double v = 0;
            for (int k = 0; k < 4; ++k)
                v += a.values[k*4 + row] * b.values[col*4 + k];
            r.values[col*4 + row] = v;
        }
    return r;
}

static SUPoint3D Tx_Pt(const SUTransformation& t, SUPoint3D p) {
    SUPoint3D q;
    q.x = t.values[0]*p.x + t.values[4]*p.y + t.values[8]*p.z  + t.values[12];
    q.y = t.values[1]*p.x + t.values[5]*p.y + t.values[9]*p.z  + t.values[13];
    q.z = t.values[2]*p.x + t.values[6]*p.y + t.values[10]*p.z + t.values[14];
    return q;
}

struct Hit {
    std::string label;
    double length_mm;
    SUPoint3D start_w, end_w;
    std::string context;
};

static void Walk(SUEntitiesRef ents, const SUTransformation& parentTx,
                 const std::string& ctx, std::set<int32_t>& visited,
                 std::vector<Hit>& hits, int depth) {
    if (depth > 6) return;

    size_t nDim = 0;
    SUEntitiesGetNumDimensions(ents, &nDim);
    if (nDim) {
        std::vector<SUDimensionRef> dims(nDim);
        SUEntitiesGetDimensions(ents, nDim, dims.data(), &nDim);
        for (auto d : dims) {
            SUDimensionType t;
            if (SUDimensionGetType(d, &t) != SU_ERROR_NONE) continue;
            if (t != SUDimensionType_Linear) continue;
            SUDimensionLinearRef dl = SUDimensionLinearFromDimension(d);
            SUPoint3D s, e;
            SUInstancePathRef path1 = SU_INVALID, path2 = SU_INVALID;
            SUInstancePathCreate(&path1); SUInstancePathCreate(&path2);
            SUResult rs = SUDimensionLinearGetStartPoint(dl, &s, &path1);
            SUResult re = SUDimensionLinearGetEndPoint(dl, &e, &path2);
            SUInstancePathRelease(&path1); SUInstancePathRelease(&path2);
            if (rs != SU_ERROR_NONE || re != SU_ERROR_NONE) continue;
            SUPoint3D ws = Tx_Pt(parentTx, s);
            SUPoint3D we = Tx_Pt(parentTx, e);
            double dx = (we.x - ws.x), dy = (we.y - ws.y), dz = (we.z - ws.z);
            double L = std::sqrt(dx*dx + dy*dy + dz*dz) * IN_TO_MM;

            SUStringRef txt = SU_INVALID; SUStringCreate(&txt);
            SUDimensionGetText(d, &txt);
            std::string label = SU_S(txt); SUStringRelease(&txt);

            Hit h;
            h.label = label;
            h.length_mm = L;
            h.start_w = ws; h.end_w = we;
            h.context = ctx;
            hits.push_back(h);
        }
    }

    // Recurse groups
    size_t nG = 0; SUEntitiesGetNumGroups(ents, &nG);
    if (nG) {
        std::vector<SUGroupRef> gs(nG);
        SUEntitiesGetGroups(ents, nG, gs.data(), &nG);
        for (size_t i = 0; i < nG; ++i) {
            SUTransformation t; SUGroupGetTransform(gs[i], &t);
            SUEntitiesRef ge = SU_INVALID;
            SUGroupGetEntities(gs[i], &ge);
            char b[64]; std::snprintf(b, sizeof(b), "/grp[%zu]", i);
            Walk(ge, Mul(parentTx, t), ctx + b, visited, hits, depth + 1);
        }
    }
    // Recurse instances (avoid revisiting the same definition)
    size_t nI = 0; SUEntitiesGetNumInstances(ents, &nI);
    if (nI) {
        std::vector<SUComponentInstanceRef> insts(nI);
        SUEntitiesGetInstances(ents, nI, insts.data(), &nI);
        for (size_t i = 0; i < nI; ++i) {
            SUComponentDefinitionRef cd = SU_INVALID;
            SUComponentInstanceGetDefinition(insts[i], &cd);
            SUStringRef nm = SU_INVALID; SUStringCreate(&nm);
            SUComponentDefinitionGetName(cd, &nm);
            std::string defNm = SU_S(nm); SUStringRelease(&nm);

            int32_t did = 0;
            SUEntityGetID(SUComponentDefinitionToEntity(cd), &did);
            if (visited.count(did)) continue;
            visited.insert(did);

            SUTransformation t; SUComponentInstanceGetTransform(insts[i], &t);
            SUEntitiesRef ce = SU_INVALID;
            SUComponentDefinitionGetEntities(cd, &ce);
            std::string nctx = ctx + "/" + defNm;
            Walk(ce, Mul(parentTx, t), nctx, visited, hits, depth + 1);
        }
    }
}

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <model.skp>\n", argv[0]);
        return 2;
    }
    SUInitialize();
    SUModelRef model = SU_INVALID;
    SUModelLoadStatus st;
    if (SUModelCreateFromFileWithStatus(&model, argv[1], &st) != SU_ERROR_NONE) {
        std::fprintf(stderr, "load failed\n"); return 1;
    }

    SUEntitiesRef root = SU_INVALID;
    SUModelGetEntities(model, &root);
    std::vector<Hit> hits;
    std::set<int32_t> visited;
    SUTransformation I = Identity();
    Walk(root, I, "root", visited, hits, 0);

    std::printf("Total linear dimension entities: %zu\n\n", hits.size());
    std::printf("%-8s  %-30s %-12s  %s\n", "len(mm)", "label", "z_mid", "context");
    for (const auto& h : hits) {
        double zmid = (h.start_w.z + h.end_w.z) * 0.5 * IN_TO_MM;
        std::printf("%8.0f  %-30s %12.0f  %s\n",
                    h.length_mm, h.label.c_str(), zmid, h.context.c_str());
    }

    SUModelRelease(&model);
    SUTerminate();
    return 0;
}

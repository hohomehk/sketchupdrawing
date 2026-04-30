// dump_text.cpp — list every SUText annotation with its 3D anchor point
// and string. Recurses through groups and ComponentDefinitions.
//
// Usage: wine dump_text.exe <model.skp>

#include <SketchUpAPI/initialize.h>
#include <SketchUpAPI/unicodestring.h>
#include <SketchUpAPI/transformation.h>
#include <SketchUpAPI/geometry.h>
#include <SketchUpAPI/model/model.h>
#include <SketchUpAPI/model/entities.h>
#include <SketchUpAPI/model/text.h>
#include <SketchUpAPI/model/entity.h>
#include <SketchUpAPI/model/component_definition.h>
#include <SketchUpAPI/model/component_instance.h>
#include <SketchUpAPI/model/group.h>
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

static void Walk(SUEntitiesRef ents, const SUTransformation& parentTx,
                 const std::string& ctx, std::set<int32_t>& visited, int depth) {
    if (depth > 6) return;

    size_t nT = 0; SUEntitiesGetNumTexts(ents, &nT);
    if (nT) {
        std::vector<SUTextRef> ts(nT);
        SUEntitiesGetTexts(ents, nT, ts.data(), &nT);
        for (size_t i = 0; i < nT; ++i) {
            SUStringRef s = SU_INVALID; SUStringCreate(&s);
            SUTextGetString(ts[i], &s);
            std::string txt = SU_S(s); SUStringRelease(&s);

            SUPoint3D p3 = {0,0,0};
            SUInstancePathRef path = SU_INVALID;
            SUInstancePathCreate(&path);
            SUTextGetPoint(ts[i], &p3, &path);
            SUInstancePathRelease(&path);
            SUPoint3D wp = Tx_Pt(parentTx, p3);
            // Newlines in label collapsed for one-line print
            for (char& c : txt) if (c == '\n' || c == '\r') c = ' ';
            std::printf("%-40s  @(%.0f,%.0f,%.0f)  %s\n",
                        txt.c_str(),
                        wp.x*IN_TO_MM, wp.y*IN_TO_MM, wp.z*IN_TO_MM,
                        ctx.c_str());
        }
    }

    size_t nG = 0; SUEntitiesGetNumGroups(ents, &nG);
    if (nG) {
        std::vector<SUGroupRef> gs(nG);
        SUEntitiesGetGroups(ents, nG, gs.data(), &nG);
        for (size_t i = 0; i < nG; ++i) {
            SUTransformation t; SUGroupGetTransform(gs[i], &t);
            SUEntitiesRef ge = SU_INVALID;
            SUGroupGetEntities(gs[i], &ge);
            char b[64]; std::snprintf(b, sizeof(b), "/grp[%zu]", i);
            Walk(ge, Mul(parentTx, t), ctx + b, visited, depth + 1);
        }
    }
    size_t nI = 0; SUEntitiesGetNumInstances(ents, &nI);
    if (nI) {
        std::vector<SUComponentInstanceRef> insts(nI);
        SUEntitiesGetInstances(ents, nI, insts.data(), &nI);
        for (size_t i = 0; i < nI; ++i) {
            SUComponentDefinitionRef cd = SU_INVALID;
            SUComponentInstanceGetDefinition(insts[i], &cd);
            int32_t did = 0;
            SUEntityGetID(SUComponentDefinitionToEntity(cd), &did);
            if (visited.count(did)) continue;
            visited.insert(did);

            SUStringRef nm = SU_INVALID; SUStringCreate(&nm);
            SUComponentDefinitionGetName(cd, &nm);
            std::string defNm = SU_S(nm); SUStringRelease(&nm);

            SUTransformation t; SUComponentInstanceGetTransform(insts[i], &t);
            SUEntitiesRef ce = SU_INVALID;
            SUComponentDefinitionGetEntities(cd, &ce);
            Walk(ce, Mul(parentTx, t), ctx + "/" + defNm, visited, depth + 1);
        }
    }
}

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: %s <model.skp>\n", argv[0]); return 2; }
    SUInitialize();
    SUModelRef model = SU_INVALID;
    SUModelLoadStatus st;
    if (SUModelCreateFromFileWithStatus(&model, argv[1], &st) != SU_ERROR_NONE) {
        std::fprintf(stderr, "load failed\n"); return 1;
    }
    SUEntitiesRef root = SU_INVALID;
    SUModelGetEntities(model, &root);
    std::set<int32_t> visited;
    SUTransformation I = Identity();
    Walk(root, I, "root", visited, 0);
    SUModelRelease(&model);
    SUTerminate();
    return 0;
}

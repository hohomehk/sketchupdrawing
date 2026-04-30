// tree_skp.cpp — print recursive entity tree of one ComponentDefinition
// (find by index or by name substring), with bbox per child.
//
// Usage: echo "<def_name_or_#N>" | wine tree_skp.exe <model.skp>

#include <SketchUpAPI/initialize.h>
#include <SketchUpAPI/unicodestring.h>
#include <SketchUpAPI/transformation.h>
#include <SketchUpAPI/model/model.h>
#include <SketchUpAPI/model/entities.h>
#include <SketchUpAPI/model/component_definition.h>
#include <SketchUpAPI/model/component_instance.h>
#include <SketchUpAPI/model/group.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

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

static void DumpTree(SUEntitiesRef ents, const SUTransformation& parentTx,
                     const std::string& indent, int depth) {
    if (depth > 8) return;
    size_t nF = 0; SUEntitiesGetNumFaces(ents, &nF);
    size_t nE = 0; SUEntitiesGetNumEdges(ents, false, &nE);
    SUBoundingBox3D lb; SUEntitiesGetBoundingBox(ents, &lb);
    double w = (lb.max_point.x - lb.min_point.x) * IN_TO_MM;
    double d = (lb.max_point.y - lb.min_point.y) * IN_TO_MM;
    double h = (lb.max_point.z - lb.min_point.z) * IN_TO_MM;
    std::printf("%sBBox local: %.0f x %.0f x %.0f mm  (faces=%zu edges=%zu)\n",
                indent.c_str(), w, d, h, nF, nE);

    size_t nG = 0; SUEntitiesGetNumGroups(ents, &nG);
    if (nG) {
        std::vector<SUGroupRef> gs(nG);
        SUEntitiesGetGroups(ents, nG, gs.data(), &nG);
        for (size_t i = 0; i < nG; ++i) {
            SUStringRef nm = SU_INVALID; SUStringCreate(&nm);
            SUGroupGetName(gs[i], &nm);
            std::string gn = SU_S(nm); SUStringRelease(&nm);
            SUTransformation t; SUGroupGetTransform(gs[i], &t);
            std::printf("%s+ Group[%zu] \"%s\"\n", indent.c_str(), i, gn.c_str());
            SUEntitiesRef ge = SU_INVALID;
            SUGroupGetEntities(gs[i], &ge);
            DumpTree(ge, Mul(parentTx, t), indent + "  ", depth + 1);
        }
    }
    size_t nI = 0; SUEntitiesGetNumInstances(ents, &nI);
    if (nI) {
        std::vector<SUComponentInstanceRef> is(nI);
        SUEntitiesGetInstances(ents, nI, is.data(), &nI);
        for (size_t i = 0; i < nI; ++i) {
            SUComponentDefinitionRef cd = SU_INVALID;
            SUComponentInstanceGetDefinition(is[i], &cd);
            SUStringRef nm = SU_INVALID; SUStringCreate(&nm);
            SUComponentDefinitionGetName(cd, &nm);
            std::string defNm = SU_S(nm); SUStringRelease(&nm);
            SUTransformation t; SUComponentInstanceGetTransform(is[i], &t);
            SUPoint3D pos = { t.values[12], t.values[13], t.values[14] };
            std::printf("%s+ Inst[%zu] def=%s @ (%.0f,%.0f,%.0f)\n",
                        indent.c_str(), i, defNm.c_str(),
                        pos.x*IN_TO_MM, pos.y*IN_TO_MM, pos.z*IN_TO_MM);
            // Don't recurse into shared components by default to keep output sane
            if (depth < 2) {
                SUEntitiesRef ce = SU_INVALID;
                SUComponentDefinitionGetEntities(cd, &ce);
                DumpTree(ce, Mul(parentTx, t), indent + "  ", depth + 1);
            }
        }
    }
}

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <model.skp>\n  def name from stdin (or '#N' or 'root')\n", argv[0]);
        return 2;
    }
    char buf[256] = {0};
    if (!std::fgets(buf, sizeof(buf), stdin)) return 2;
    size_t bn = std::strlen(buf);
    while (bn && (buf[bn-1]=='\n' || buf[bn-1]=='\r')) buf[--bn] = 0;

    SUInitialize();
    SUModelRef model = SU_INVALID;
    SUModelLoadStatus st;
    if (SUModelCreateFromFileWithStatus(&model, argv[1], &st) != SU_ERROR_NONE) {
        std::fprintf(stderr, "load failed\n"); return 1;
    }

    SUTransformation I{};
    for (int i = 0; i < 4; ++i) I.values[i*4 + i] = 1.0;

    if (std::strcmp(buf, "root") == 0) {
        SUEntitiesRef root = SU_INVALID;
        SUModelGetEntities(model, &root);
        std::printf("== ROOT ==\n");
        DumpTree(root, I, "", 0);
        SUModelRelease(&model);
        SUTerminate();
        return 0;
    }

    size_t nD = 0; SUModelGetNumComponentDefinitions(model, &nD);
    std::vector<SUComponentDefinitionRef> defs(nD);
    SUModelGetComponentDefinitions(model, nD, defs.data(), &nD);

    SUComponentDefinitionRef target = SU_INVALID;
    if (buf[0] == '#') {
        size_t idx = (size_t)std::atoi(buf + 1);
        if (idx < nD) target = defs[idx];
    } else {
        for (size_t i = 0; i < nD; ++i) {
            SUStringRef sn = SU_INVALID; SUStringCreate(&sn);
            SUComponentDefinitionGetName(defs[i], &sn);
            std::string nm = SU_S(sn); SUStringRelease(&sn);
            if (nm.find(buf) != std::string::npos) { target = defs[i]; break; }
        }
    }
    if (SUIsInvalid(target)) { std::fprintf(stderr, "def not found\n"); return 1; }

    SUStringRef tn = SU_INVALID; SUStringCreate(&tn);
    SUComponentDefinitionGetName(target, &tn);
    std::printf("== Definition \"%s\" ==\n", SU_S(tn).c_str());
    SUStringRelease(&tn);

    SUEntitiesRef ce = SU_INVALID;
    SUComponentDefinitionGetEntities(target, &ce);
    DumpTree(ce, I, "", 0);

    SUModelRelease(&model);
    SUTerminate();
    return 0;
}

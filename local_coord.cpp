// local_coord.cpp — given a world point and a target ComponentDefinition name,
// find that def's first root instance, compute the inverse of its 4x4 transform,
// and print the world point in the instance's local frame.
//
// Use case: 預埋制盒 anchor (world) → C#157 local frame to read 離櫃背距離.
//
// Usage:
//   wine local_coord.exe <model.skp> <def_name> <wx> <wy> <wz>   (mm)
//   def_name from argv (ASCII fine for "Component#157"); world coords in mm.

#include <SketchUpAPI/initialize.h>
#include <SketchUpAPI/unicodestring.h>
#include <SketchUpAPI/transformation.h>
#include <SketchUpAPI/model/model.h>
#include <SketchUpAPI/model/entities.h>
#include <SketchUpAPI/model/component_definition.h>
#include <SketchUpAPI/model/component_instance.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>

static const double IN_TO_MM = 25.4;

static std::string SU_S(SUStringRef s) {
    size_t l = 0; SUStringGetUTF8Length(s, &l);
    std::string r(l, '\0');
    if (l) SUStringGetUTF8(s, l + 1, &r[0], &l);
    return r;
}

// Print a 4x4 column-major matrix.
static void PrintMat(const SUTransformation& t, const char* name) {
    std::printf("%s = [\n", name);
    for (int r = 0; r < 4; ++r) {
        std::printf("  ");
        for (int c = 0; c < 4; ++c) std::printf("%12.6f ", t.values[c*4 + r]);
        std::printf("\n");
    }
    std::printf("]\n");
}

// Apply 4x4 (column-major) to point.
static void Apply(const SUTransformation& t, double x, double y, double z,
                  double& ox, double& oy, double& oz) {
    ox = t.values[0]*x + t.values[4]*y + t.values[8]*z  + t.values[12];
    oy = t.values[1]*x + t.values[5]*y + t.values[9]*z  + t.values[13];
    oz = t.values[2]*x + t.values[6]*y + t.values[10]*z + t.values[14];
}

// 4x4 inverse (general). Returns true on success.
static bool Inverse(const SUTransformation& m, SUTransformation& out) {
    // Use cofactor expansion
    const double* a = m.values;
    double inv[16];
    inv[0] =  a[5]*a[10]*a[15] - a[5]*a[11]*a[14] - a[9]*a[6]*a[15] + a[9]*a[7]*a[14] + a[13]*a[6]*a[11] - a[13]*a[7]*a[10];
    inv[4] = -a[4]*a[10]*a[15] + a[4]*a[11]*a[14] + a[8]*a[6]*a[15] - a[8]*a[7]*a[14] - a[12]*a[6]*a[11] + a[12]*a[7]*a[10];
    inv[8] =  a[4]*a[9]*a[15]  - a[4]*a[11]*a[13] - a[8]*a[5]*a[15] + a[8]*a[7]*a[13] + a[12]*a[5]*a[11] - a[12]*a[7]*a[9];
    inv[12]= -a[4]*a[9]*a[14]  + a[4]*a[10]*a[13] + a[8]*a[5]*a[14] - a[8]*a[6]*a[13] - a[12]*a[5]*a[10] + a[12]*a[6]*a[9];
    inv[1] = -a[1]*a[10]*a[15] + a[1]*a[11]*a[14] + a[9]*a[2]*a[15] - a[9]*a[3]*a[14] - a[13]*a[2]*a[11] + a[13]*a[3]*a[10];
    inv[5] =  a[0]*a[10]*a[15] - a[0]*a[11]*a[14] - a[8]*a[2]*a[15] + a[8]*a[3]*a[14] + a[12]*a[2]*a[11] - a[12]*a[3]*a[10];
    inv[9] = -a[0]*a[9]*a[15]  + a[0]*a[11]*a[13] + a[8]*a[1]*a[15] - a[8]*a[3]*a[13] - a[12]*a[1]*a[11] + a[12]*a[3]*a[9];
    inv[13]=  a[0]*a[9]*a[14]  - a[0]*a[10]*a[13] - a[8]*a[1]*a[14] + a[8]*a[2]*a[13] + a[12]*a[1]*a[10] - a[12]*a[2]*a[9];
    inv[2] =  a[1]*a[6]*a[15]  - a[1]*a[7]*a[14]  - a[5]*a[2]*a[15] + a[5]*a[3]*a[14] + a[13]*a[2]*a[7]  - a[13]*a[3]*a[6];
    inv[6] = -a[0]*a[6]*a[15]  + a[0]*a[7]*a[14]  + a[4]*a[2]*a[15] - a[4]*a[3]*a[14] - a[12]*a[2]*a[7]  + a[12]*a[3]*a[6];
    inv[10]=  a[0]*a[5]*a[15]  - a[0]*a[7]*a[13]  - a[4]*a[1]*a[15] + a[4]*a[3]*a[13] + a[12]*a[1]*a[7]  - a[12]*a[3]*a[5];
    inv[14]= -a[0]*a[5]*a[14]  + a[0]*a[6]*a[13]  + a[4]*a[1]*a[14] - a[4]*a[2]*a[13] - a[12]*a[1]*a[6]  + a[12]*a[2]*a[5];
    inv[3] = -a[1]*a[6]*a[11]  + a[1]*a[7]*a[10]  + a[5]*a[2]*a[11] - a[5]*a[3]*a[10] - a[9]*a[2]*a[7]   + a[9]*a[3]*a[6];
    inv[7] =  a[0]*a[6]*a[11]  - a[0]*a[7]*a[10]  - a[4]*a[2]*a[11] + a[4]*a[3]*a[10] + a[8]*a[2]*a[7]   - a[8]*a[3]*a[6];
    inv[11]= -a[0]*a[5]*a[11]  + a[0]*a[7]*a[9]   + a[4]*a[1]*a[11] - a[4]*a[3]*a[9]  - a[8]*a[1]*a[7]   + a[8]*a[3]*a[5];
    inv[15]=  a[0]*a[5]*a[10]  - a[0]*a[6]*a[9]   - a[4]*a[1]*a[10] + a[4]*a[2]*a[9]  + a[8]*a[1]*a[6]   - a[8]*a[2]*a[5];
    double det = a[0]*inv[0] + a[1]*inv[4] + a[2]*inv[8] + a[3]*inv[12];
    if (std::abs(det) < 1e-12) return false;
    double inv_det = 1.0 / det;
    for (int i = 0; i < 16; ++i) out.values[i] = inv[i] * inv_det;
    return true;
}

int main(int argc, char** argv) {
    if (argc < 6) {
        std::fprintf(stderr, "usage: %s <model.skp> <def_name> <wx_mm> <wy_mm> <wz_mm>\n", argv[0]);
        return 2;
    }
    const char* path = argv[1];
    const char* defName = argv[2];
    double wx = std::atof(argv[3]) / IN_TO_MM;   // mm -> in
    double wy = std::atof(argv[4]) / IN_TO_MM;
    double wz = std::atof(argv[5]) / IN_TO_MM;

    SUInitialize();
    SUModelRef m = SU_INVALID;
    SUModelLoadStatus st;
    if (SUModelCreateFromFileWithStatus(&m, path, &st) != SU_ERROR_NONE) {
        std::fprintf(stderr, "load failed\n"); return 1;
    }

    // Find first root instance whose definition name matches defName.
    SUEntitiesRef root = SU_INVALID;
    SUModelGetEntities(m, &root);
    size_t n = 0; SUEntitiesGetNumInstances(root, &n);
    std::vector<SUComponentInstanceRef> insts(n);
    SUEntitiesGetInstances(root, n, insts.data(), &n);

    SUComponentInstanceRef found = SU_INVALID;
    std::string foundName;
    for (auto i : insts) {
        SUComponentDefinitionRef cd = SU_INVALID;
        SUComponentInstanceGetDefinition(i, &cd);
        SUStringRef nm = SU_INVALID; SUStringCreate(&nm);
        SUComponentDefinitionGetName(cd, &nm);
        std::string s = SU_S(nm); SUStringRelease(&nm);
        if (s.find(defName) != std::string::npos) {
            found = i;
            foundName = s;
            break;
        }
    }
    if (SUIsInvalid(found)) {
        std::fprintf(stderr, "no root instance matches def name '%s'\n", defName);
        return 1;
    }
    std::printf("Matched root instance: def=\"%s\"\n\n", foundName.c_str());

    // Get its transform.
    SUTransformation t;
    SUComponentInstanceGetTransform(found, &t);
    PrintMat(t, "world<-local (instance transform)");

    // Print def's local bbox.
    SUComponentDefinitionRef cd = SU_INVALID;
    SUComponentInstanceGetDefinition(found, &cd);
    SUEntitiesRef ce = SU_INVALID;
    SUComponentDefinitionGetEntities(cd, &ce);
    SUBoundingBox3D lb; SUEntitiesGetBoundingBox(ce, &lb);
    std::printf("\nDef local bbox: X=[%.0f, %.0f], Y=[%.0f, %.0f], Z=[%.0f, %.0f] mm\n",
                lb.min_point.x*IN_TO_MM, lb.max_point.x*IN_TO_MM,
                lb.min_point.y*IN_TO_MM, lb.max_point.y*IN_TO_MM,
                lb.min_point.z*IN_TO_MM, lb.max_point.z*IN_TO_MM);

    // Inverse and apply.
    SUTransformation inv;
    if (!Inverse(t, inv)) {
        std::fprintf(stderr, "inverse failed\n"); return 1;
    }
    PrintMat(inv, "\nlocal<-world (inverse)");

    double lx, ly, lz;
    Apply(inv, wx, wy, wz, lx, ly, lz);
    std::printf("\n=== World point ===\n  (%.0f, %.0f, %.0f) mm\n",
                wx*IN_TO_MM, wy*IN_TO_MM, wz*IN_TO_MM);
    std::printf("=== Same point in instance LOCAL frame ===\n  (%.1f, %.1f, %.1f) mm\n",
                lx*IN_TO_MM, ly*IN_TO_MM, lz*IN_TO_MM);

    // Distance from each face of the local bbox.
    double bxmin = lb.min_point.x*IN_TO_MM, bxmax = lb.max_point.x*IN_TO_MM;
    double bymin = lb.min_point.y*IN_TO_MM, bymax = lb.max_point.y*IN_TO_MM;
    double bzmin = lb.min_point.z*IN_TO_MM, bzmax = lb.max_point.z*IN_TO_MM;
    std::printf("\n=== Distance to each local-bbox face (mm) ===\n");
    std::printf("  to X- face (local x=%.0f): %.1f\n", bxmin, lx*IN_TO_MM - bxmin);
    std::printf("  to X+ face (local x=%.0f): %.1f\n", bxmax, bxmax - lx*IN_TO_MM);
    std::printf("  to Y- face (local y=%.0f): %.1f\n", bymin, ly*IN_TO_MM - bymin);
    std::printf("  to Y+ face (local y=%.0f): %.1f\n", bymax, bymax - ly*IN_TO_MM);
    std::printf("  to Z- face (local z=%.0f): %.1f\n", bzmin, lz*IN_TO_MM - bzmin);
    std::printf("  to Z+ face (local z=%.0f): %.1f\n", bzmax, bzmax - lz*IN_TO_MM);

    SUModelRelease(&m);
    SUTerminate();
    return 0;
}

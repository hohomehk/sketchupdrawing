// skp_to_obj.cpp — export the entire SketchUp model as a Wavefront .obj
// (with .mtl materials), recursing through groups and component instances.
//
// Each face is triangulated via SUMeshHelper. Materials are exported as
// solid color (Kd) only; texture extraction omitted for v1 (textures are
// large and our viewer use case can do without).
//
// Usage: wine skp_to_obj.exe <model.skp> <out.obj>
//   Companion <out.mtl> auto-generated.

#include <SketchUpAPI/initialize.h>
#include <SketchUpAPI/unicodestring.h>
#include <SketchUpAPI/transformation.h>
#include <SketchUpAPI/color.h>
#include <SketchUpAPI/model/model.h>
#include <SketchUpAPI/model/entities.h>
#include <SketchUpAPI/model/face.h>
#include <SketchUpAPI/model/mesh_helper.h>
#include <SketchUpAPI/model/material.h>
#include <SketchUpAPI/model/component_definition.h>
#include <SketchUpAPI/model/component_instance.h>
#include <SketchUpAPI/model/group.h>
#include <SketchUpAPI/model/drawing_element.h>
#include <SketchUpAPI/model/entity.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <map>
#include <set>

static const double IN_TO_M = 0.0254;  // inches → meters (Blender prefers meters)

static std::string SU_S(SUStringRef s) {
    size_t l = 0; SUStringGetUTF8Length(s, &l);
    std::string r(l, '\0');
    if (l) SUStringGetUTF8(s, l + 1, &r[0], &l);
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

static void Apply(const SUTransformation& t, double x, double y, double z,
                  double& ox, double& oy, double& oz) {
    ox = t.values[0]*x + t.values[4]*y + t.values[8]*z  + t.values[12];
    oy = t.values[1]*x + t.values[5]*y + t.values[9]*z  + t.values[13];
    oz = t.values[2]*x + t.values[6]*y + t.values[10]*z + t.values[14];
}

struct ObjWriter {
    std::FILE* obj = nullptr;
    std::FILE* mtl = nullptr;
    std::string mtl_basename;
    size_t vert_offset = 0;        // current global vertex index (1-based for OBJ)
    std::map<std::string, std::string> materials;  // name -> mtl line
    std::string current_material;
};

static std::string SafeName(const std::string& in) {
    std::string out;
    for (char c : in) {
        if (std::isalnum((unsigned char)c) || c == '_' || c == '-') out += c;
        else out += '_';
    }
    if (out.empty()) out = "default";
    return out;
}

static std::string MaterialKey(SUMaterialRef m) {
    if (SUIsInvalid(m)) return "default";
    SUStringRef nm = SU_INVALID; SUStringCreate(&nm);
    SUMaterialGetName(m, &nm);
    std::string n = SU_S(nm); SUStringRelease(&nm);
    return SafeName(n);
}

static void RegisterMaterial(ObjWriter& w, SUMaterialRef m) {
    std::string key = MaterialKey(m);
    if (w.materials.count(key)) return;

    SUColor c = {180, 180, 180, 255};
    if (!SUIsInvalid(m)) {
        SUMaterialGetColor(m, &c);
    }
    char buf[256];
    std::snprintf(buf, sizeof(buf),
        "newmtl %s\nKa 0.2 0.2 0.2\nKd %.3f %.3f %.3f\nKs 0.0 0.0 0.0\nNs 10\nd %.3f\n\n",
        key.c_str(),
        c.red / 255.0, c.green / 255.0, c.blue / 255.0,
        c.alpha / 255.0);
    w.materials[key] = buf;
    std::fputs(buf, w.mtl);
}

static void WriteFaceMesh(ObjWriter& w, SUFaceRef face, const SUTransformation& tx) {
    SUMaterialRef mat = SU_INVALID;
    SUFaceGetFrontMaterial(face, &mat);

    std::string key = MaterialKey(mat);
    if (!w.materials.count(key)) RegisterMaterial(w, mat);
    if (key != w.current_material) {
        std::fprintf(w.obj, "usemtl %s\n", key.c_str());
        w.current_material = key;
    }

    SUMeshHelperRef mesh = SU_INVALID;
    if (SUMeshHelperCreate(&mesh, face) != SU_ERROR_NONE) return;

    size_t nv = 0, nt = 0;
    SUMeshHelperGetNumVertices(mesh, &nv);
    SUMeshHelperGetNumTriangles(mesh, &nt);
    if (nv == 0 || nt == 0) { SUMeshHelperRelease(&mesh); return; }

    std::vector<SUPoint3D> verts(nv);
    SUMeshHelperGetVertices(mesh, nv, verts.data(), &nv);

    // Write vertices (transformed to world, converted to meters)
    for (auto& p : verts) {
        double x, y, z;
        Apply(tx, p.x, p.y, p.z, x, y, z);
        std::fprintf(w.obj, "v %.4f %.4f %.4f\n", x * IN_TO_M, y * IN_TO_M, z * IN_TO_M);
    }

    // Triangle indices (use a separate variable; do NOT alias nv)
    std::vector<size_t> idx(nt * 3);
    size_t got_idx = 0;
    SUMeshHelperGetVertexIndices(mesh, nt * 3, idx.data(), &got_idx);

    for (size_t i = 0; i < nt; ++i) {
        size_t a = idx[i*3 + 0] + 1 + w.vert_offset;
        size_t b = idx[i*3 + 1] + 1 + w.vert_offset;
        size_t c = idx[i*3 + 2] + 1 + w.vert_offset;
        std::fprintf(w.obj, "f %zu %zu %zu\n", a, b, c);
    }
    w.vert_offset += nv;  // nv = vertex count (unchanged here)

    SUMeshHelperRelease(&mesh);
}

static void Walk(SUEntitiesRef ents, const SUTransformation& tx,
                 ObjWriter& w, int depth, int& face_count) {
    if (depth > 8) return;

    size_t nF = 0; SUEntitiesGetNumFaces(ents, &nF);
    if (nF) {
        std::vector<SUFaceRef> faces(nF);
        SUEntitiesGetFaces(ents, nF, faces.data(), &nF);
        for (auto f : faces) {
            // Skip hidden faces
            SUDrawingElementRef de = SUFaceToDrawingElement(f);
            bool h = false;
            SUDrawingElementGetHidden(de, &h);
            if (h) continue;
            WriteFaceMesh(w, f, tx);
            face_count++;
            if (face_count % 1000 == 0) {
                std::fprintf(stderr, "  ... %d faces written\n", face_count);
            }
        }
    }

    size_t nG = 0; SUEntitiesGetNumGroups(ents, &nG);
    if (nG) {
        std::vector<SUGroupRef> gs(nG);
        SUEntitiesGetGroups(ents, nG, gs.data(), &nG);
        for (auto g : gs) {
            SUDrawingElementRef de = SUGroupToDrawingElement(g);
            bool h = false; SUDrawingElementGetHidden(de, &h);
            if (h) continue;
            SUTransformation t; SUGroupGetTransform(g, &t);
            SUEntitiesRef ge = SU_INVALID; SUGroupGetEntities(g, &ge);
            Walk(ge, Mul(tx, t), w, depth + 1, face_count);
        }
    }

    size_t nI = 0; SUEntitiesGetNumInstances(ents, &nI);
    if (nI) {
        std::vector<SUComponentInstanceRef> insts(nI);
        SUEntitiesGetInstances(ents, nI, insts.data(), &nI);
        for (auto i : insts) {
            SUDrawingElementRef de = SUComponentInstanceToDrawingElement(i);
            bool h = false; SUDrawingElementGetHidden(de, &h);
            if (h) continue;
            SUComponentDefinitionRef cd = SU_INVALID;
            SUComponentInstanceGetDefinition(i, &cd);
            SUTransformation t; SUComponentInstanceGetTransform(i, &t);
            SUEntitiesRef ce = SU_INVALID; SUComponentDefinitionGetEntities(cd, &ce);
            Walk(ce, Mul(tx, t), w, depth + 1, face_count);
        }
    }
}

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s <model.skp> <out.obj>\n", argv[0]);
        return 2;
    }
    const char* skp = argv[1];
    const char* out_obj = argv[2];

    SUInitialize();
    SUModelRef m = SU_INVALID;
    SUModelLoadStatus st;
    if (SUModelCreateFromFileWithStatus(&m, skp, &st) != SU_ERROR_NONE) {
        std::fprintf(stderr, "load fail\n"); return 1;
    }

    // Derive .mtl path
    std::string obj_path(out_obj);
    std::string mtl_path = obj_path;
    size_t ext = mtl_path.find_last_of('.');
    if (ext != std::string::npos) mtl_path = mtl_path.substr(0, ext);
    mtl_path += ".mtl";
    std::string mtl_basename = mtl_path;
    size_t slash = mtl_basename.find_last_of("/\\");
    if (slash != std::string::npos) mtl_basename = mtl_basename.substr(slash + 1);

    ObjWriter w;
    w.obj = std::fopen(obj_path.c_str(), "wb");
    w.mtl = std::fopen(mtl_path.c_str(), "wb");
    if (!w.obj || !w.mtl) {
        std::fprintf(stderr, "open output failed\n"); return 1;
    }
    w.mtl_basename = mtl_basename;

    std::fprintf(w.obj, "# SKP -> OBJ via skp_to_obj\n");
    std::fprintf(w.obj, "mtllib %s\n", mtl_basename.c_str());

    // Default material
    RegisterMaterial(w, SU_INVALID);

    SUEntitiesRef root = SU_INVALID;
    SUModelGetEntities(m, &root);
    SUTransformation I = Identity();
    int face_count = 0;
    Walk(root, I, w, 0, face_count);

    std::fclose(w.obj);
    std::fclose(w.mtl);
    std::fprintf(stderr, "Done: %d faces, %zu vertices total, %zu materials\n",
                 face_count, w.vert_offset, w.materials.size());

    SUModelRelease(&m);
    SUTerminate();
    return 0;
}

#!/usr/bin/env python3
"""
Blender headless panorama renderer.

Run with: blender --background --python render_panoramas.py -- <obj_path> <out_dir>

Imports the OBJ, places equirectangular cameras at scene-defined positions,
renders 360° panoramas (Cycles, low samples for speed).

Edit VIEWPOINTS below for your specific model.
"""

import sys
import os
import bpy
import bmesh
from mathutils import Vector

# ---- argument parsing ----
argv = sys.argv
sep = argv.index("--") if "--" in argv else None
if sep is None or len(argv) - sep < 3:
    print("usage: blender -b -P render_panoramas.py -- <obj_path> <out_dir>")
    sys.exit(1)

OBJ_PATH = argv[sep + 1]
OUT_DIR  = argv[sep + 2]
os.makedirs(OUT_DIR, exist_ok=True)

# ---- viewpoints (mm coords from SDK; converted to meters) ----
# Each: (slug, pretty_name, [x_mm, y_mm, z_mm])
VIEWPOINTS = [
    ("master_bedroom",   "主人房",          [110000.0,  89000.0, 1500.0]),
    ("small_bedroom",    "細房",            [ 15700.0, -25500.0, 1500.0]),
    ("master_bathroom",  "主廁",           [185000.0, 149000.0, 1500.0]),
    ("living_dining",    "客飯廳",          [ 60000.0,  40000.0, 1500.0]),
]

# ---- render config ----
WIDTH      = 4096
HEIGHT     = 2048
SAMPLES    = 32        # cycles samples — keep low for demo speed
MAX_BOUNCES = 4

# ---- clean scene + import ----
bpy.ops.wm.read_factory_settings(use_empty=True)

print(f"Importing {OBJ_PATH} ...")
bpy.ops.wm.obj_import(filepath=OBJ_PATH)
print(f"  imported {len(bpy.data.objects)} objects, "
      f"{sum(len(o.data.vertices) for o in bpy.data.objects if o.type=='MESH')} verts")

# ---- world: simple grey sky + sun ----
world = bpy.data.worlds.new("BG")
bpy.context.scene.world = world
world.use_nodes = True
bg = world.node_tree.nodes.get("Background")
if bg:
    bg.inputs[0].default_value = (0.85, 0.85, 0.95, 1.0)
    bg.inputs[1].default_value = 1.5  # strength

# ---- light ----
light_data = bpy.data.lights.new(name="sun", type='SUN')
light_data.energy = 3.0
light_data.angle = 0.05
light_obj = bpy.data.objects.new(name="sun", object_data=light_data)
light_obj.location = (50, 50, 30)
light_obj.rotation_euler = (0.6, 0.0, 0.4)
bpy.context.collection.objects.link(light_obj)

# ---- render settings ----
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.render.resolution_x = WIDTH
scene.render.resolution_y = HEIGHT
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'JPEG'
scene.render.image_settings.quality = 85
scene.cycles.samples = SAMPLES
scene.cycles.max_bounces = MAX_BOUNCES
scene.cycles.use_denoising = True

# ---- camera (equirectangular panorama) ----
cam_data = bpy.data.cameras.new(name="pano_cam")
cam_data.type = 'PANO'
# Blender 4.x panorama type is set via cycles params
try:
    cam_data.panorama_type = 'EQUIRECTANGULAR'
except AttributeError:
    pass
cam_obj = bpy.data.objects.new("pano_cam", cam_data)
bpy.context.collection.objects.link(cam_obj)
scene.camera = cam_obj
# Set camera to upright (looking along +Y, Z up)
cam_obj.rotation_euler = (1.5708, 0.0, 0.0)  # 90° pitch up so equirectangular is horizon-aligned

# ---- render each viewpoint ----
for slug, name, pos_mm in VIEWPOINTS:
    pos_m = Vector((pos_mm[0]/1000.0, pos_mm[1]/1000.0, pos_mm[2]/1000.0))
    cam_obj.location = pos_m
    out_path = os.path.join(OUT_DIR, f"{slug}.jpg")
    scene.render.filepath = out_path
    print(f"Rendering [{slug}] {name} @ {tuple(round(v,1) for v in pos_m)} -> {out_path}")
    bpy.ops.render.render(write_still=True)
    print(f"  done")

print("\nAll done.")

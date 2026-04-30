#!/usr/bin/env python3
"""
Blender headless renderer: cabinets + auto-generated rooms.

usage: blender -b -P render_with_rooms.py -- <cabinets.obj> <rooms.obj> <rooms.json> <out_dir>
"""

import sys, os, json, bpy
from mathutils import Vector

argv = sys.argv
sep = argv.index("--") if "--" in argv else None
if sep is None or len(argv) - sep < 5:
    print("usage: blender -b -P render_with_rooms.py -- <cab.obj> <rooms.obj> <rooms.json> <out_dir>")
    sys.exit(1)

CAB_OBJ   = argv[sep+1]
ROOMS_OBJ = argv[sep+2]
ROOMS_JSON = argv[sep+3]
OUT_DIR   = argv[sep+4]
os.makedirs(OUT_DIR, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)

print(f"Importing cabinets {CAB_OBJ}")
bpy.ops.wm.obj_import(filepath=CAB_OBJ, forward_axis="Y", up_axis="Z")
print(f"Importing rooms {ROOMS_OBJ}")
bpy.ops.wm.obj_import(filepath=ROOMS_OBJ, forward_axis="Y", up_axis="Z")
print(f"Total verts: {sum(len(o.data.vertices) for o in bpy.data.objects if o.type=='MESH')}")

# World background
world = bpy.data.worlds.new("BG"); bpy.context.scene.world = world
world.use_nodes = True
bg = world.node_tree.nodes["Background"]
bg.inputs[0].default_value = (0.95, 0.95, 0.98, 1.0)
bg.inputs[1].default_value = 1.5

# Add a sun for outside-window light effect (gentle from outside)
sun_data = bpy.data.lights.new(name="sun", type="SUN")
sun_data.energy = 2.5
sun = bpy.data.objects.new("sun", sun_data)
sun.rotation_euler = (0.7, 0.0, 0.4)
bpy.context.collection.objects.link(sun)

scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.render.resolution_x = 4096
scene.render.resolution_y = 2048
scene.cycles.samples = 64
scene.cycles.use_denoising = False
scene.render.image_settings.file_format = "JPEG"
scene.render.image_settings.quality = 88

# Camera (panoramic, equirectangular)
cam_data = bpy.data.cameras.new("c")
cam_data.type = "PANO"
try: cam_data.panorama_type = "EQUIRECTANGULAR"
except AttributeError: pass
cam = bpy.data.objects.new("c", cam_data)
cam.rotation_euler = (1.5708, 0.0, 0.0)
bpy.context.collection.objects.link(cam)
scene.camera = cam

# Per-room interior light helper
def add_interior_light(pos_m, energy):
    ld = bpy.data.lights.new(name="ipt", type="POINT")
    ld.energy = energy
    ld.shadow_soft_size = 0.5
    o = bpy.data.objects.new("ipt", ld)
    o.location = pos_m
    bpy.context.collection.objects.link(o)
    return o

# Read rooms json
with open(ROOMS_JSON) as f:
    rooms = json.load(f)

# Render each room
for r in rooms:
    rid = r["id"]
    cx, cy, cz = r["camera_mm"]
    # Scale to meters
    cam_pos = (cx/1000.0, cy/1000.0, cz/1000.0)

    # Place a couple of point lights inside the room (centroid + corners)
    bb = r["bbox_mm"]
    ceil_z_m = bb[5] / 1000.0 - 0.3
    light_objs = [
        add_interior_light(cam_pos, 80),
        add_interior_light((cam_pos[0], cam_pos[1], ceil_z_m), 200),
    ]

    cam.location = cam_pos
    out_path = os.path.join(OUT_DIR, f"{rid}.jpg")
    scene.render.filepath = out_path
    print(f"Rendering {rid} @ {cam_pos}")
    bpy.ops.render.render(write_still=True)

    # Remove this room's lights so next render isn't double-lit
    for o in light_objs:
        bpy.data.objects.remove(o, do_unlink=True)

print("All rooms rendered.")

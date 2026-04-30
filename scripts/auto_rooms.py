#!/usr/bin/env python3
"""
Cluster root entities by spatial proximity, generate one "room" per cluster
(walls + floor + ceiling) as OBJ geometry, write rooms.obj + rooms.json.

Input: dump_full.txt (output of dump_skp.exe)
Output: rooms.obj  + rooms.json (cluster bbox + suggested camera positions)

Run: python3 scripts/auto_rooms.py out/dump_full.txt out/rooms
"""
import sys, os, re, json, math
from collections import defaultdict

if len(sys.argv) < 3:
    print("usage: auto_rooms.py <dump_full.txt> <out_basename>")
    sys.exit(1)

dump_path = sys.argv[1]
out_base  = sys.argv[2]
os.makedirs(os.path.dirname(out_base) or ".", exist_ok=True)

# Parse "I0  inst=  def=Component#203  pos_mm=(-58331,-80904,0)" lines
# AND "G0  ...  size_mm=(...)"  + we'll keep instance-level pts only
points = []   # list of (x_mm, y_mm, z_mm, def_name)
inst_re = re.compile(r"^\s*I\d+\s+inst=\S*\s+def=(\S+)\s+pos_mm=\(\s*([-\d.]+),\s*([-\d.]+),\s*([-\d.]+)\)")

with open(dump_path) as f:
    for line in f:
        m = inst_re.match(line)
        if not m: continue
        defn, x, y, z = m.group(1), float(m.group(2)), float(m.group(3)), float(m.group(4))
        # Skip instances at very far positions or oddly low z (those are often plan refs)
        points.append((x, y, z, defn))

print(f"Loaded {len(points)} root instance positions")

# Simple grid-based clustering: bucket by 5m × 5m, then merge buckets within 8m
GRID = 5000.0   # mm
buckets = defaultdict(list)
for p in points:
    bx, by = int(p[0] // GRID), int(p[1] // GRID)
    buckets[(bx, by)].append(p)

# Connected-components on grid: 8-neighborhood
visited = set()
clusters = []
for key in list(buckets.keys()):
    if key in visited: continue
    stack = [key]; visited.add(key)
    pts = []
    while stack:
        k = stack.pop()
        pts.extend(buckets.get(k, []))
        bx, by = k
        for dx in (-1,0,1):
            for dy in (-1,0,1):
                nk = (bx+dx, by+dy)
                if nk in buckets and nk not in visited:
                    visited.add(nk); stack.append(nk)
    if pts: clusters.append(pts)

# For each cluster, compute bbox + suggested camera centroid
MARGIN = 1500.0   # mm padding around cluster bbox to make room "walkable"
CEIL_Z = 2875.0   # standard HK ceiling height for our model
clusters_info = []
for i, pts in enumerate(clusters):
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]; zs = [p[2] for p in pts]
    xmin, xmax = min(xs), max(xs)
    ymin, ymax = min(ys), max(ys)
    zmin, zmax = min(zs), max(zs)
    rxmin = xmin - MARGIN; rxmax = xmax + MARGIN
    rymin = ymin - MARGIN; rymax = ymax + MARGIN
    rzmin = 0.0; rzmax = CEIL_Z

    # Suggested camera at room center, eye height
    cx = (rxmin + rxmax) * 0.5
    cy = (rymin + rymax) * 0.5
    cz = 1500.0   # 1.5m eye level

    clusters_info.append({
        "id": f"room_{i:02d}",
        "n_instances": len(pts),
        "bbox_mm":   [rxmin, rymin, rzmin, rxmax, rymax, rzmax],
        "cabinet_bbox_mm": [xmin, ymin, zmin, xmax, ymax, zmax],
        "camera_mm": [cx, cy, cz],
        "size_mm":   [rxmax - rxmin, rymax - rymin, rzmax - rzmin],
        "instances": [{"def": p[3], "pos_mm": [p[0], p[1], p[2]]} for p in pts],
    })

# Sort by instance count (largest cluster first)
clusters_info.sort(key=lambda c: -c["n_instances"])

# Keep clusters where size_mm > 1m × 1m (ignore tiny ones)
clusters_info = [
    c for c in clusters_info
    if c["size_mm"][0] > 2000 and c["size_mm"][1] > 2000
]
# Always include 主人房衣櫃 cluster if found (~110, 89 m)
def is_master_bedroom(c):
    cx, cy, _ = c["camera_mm"]
    return abs(cx/1000 - 110) < 3 and abs(cy/1000 - 89) < 3
mb_clusters = [c for c in clusters_info if is_master_bedroom(c)]
top = clusters_info[:12]
for mb in mb_clusters:
    if mb not in top: top.append(mb)
clusters_info = top

# Friendly label override for known clusters (matches user's scene names where we can guess)
LABELS = {
    (round(110.0), round(89.0)): "主人房衣櫃 (Component#157+#99)",
    (round(58.9),  round(38.1)): "細房衣櫃 area",
    (round(15.7), round(-26.2)): "細房 (上下床) area",
    (round(83.1),  round(61.3)): "中間 area",
    (round(154.3), round(117.8)): "右上 area",
    (round(187.8), round(150.0)): "主廁 area",
    (round(213.7), round(175.6)): "右上遠 area",
}
for c in clusters_info:
    cx, cy, _ = c["camera_mm"]
    key = (round(cx/1000.0), round(cy/1000.0))
    if key in LABELS:
        c["label"] = LABELS[key]
    else:
        c["label"] = c["id"]

# ---- write rooms.obj (one box per cluster) ----
def emit_room_box(out, vert_offset, bb, mat_name):
    """Write 4 walls + floor + ceiling as 6 quads. bb = [xmin,ymin,zmin,xmax,ymax,zmax] in mm.
    Walls face inward. Returns new vert_offset."""
    xmin, ymin, zmin, xmax, ymax, zmax = bb
    # Convert to meters (matches our skp_to_obj output unit)
    M = 0.001
    pts = [
        (xmin*M, ymin*M, zmin*M),  # 1: bottom-front-left
        (xmax*M, ymin*M, zmin*M),  # 2: bottom-front-right
        (xmax*M, ymax*M, zmin*M),  # 3: bottom-back-right
        (xmin*M, ymax*M, zmin*M),  # 4: bottom-back-left
        (xmin*M, ymin*M, zmax*M),  # 5: top-front-left
        (xmax*M, ymin*M, zmax*M),  # 6: top-front-right
        (xmax*M, ymax*M, zmax*M),  # 7: top-back-right
        (xmin*M, ymax*M, zmax*M),  # 8: top-back-left
    ]
    for x, y, z in pts:
        out.write(f"v {x:.4f} {y:.4f} {z:.4f}\n")

    o = vert_offset
    # Each face: ccw winding when viewed from INSIDE the room
    # Floor (looking up from below room is ccw, so inside-up needs reversed)
    out.write(f"usemtl {mat_name}_floor\n")
    out.write(f"f {o+1} {o+4} {o+3} {o+2}\n")  # floor (looking down)
    out.write(f"usemtl {mat_name}_ceiling\n")
    out.write(f"f {o+5} {o+6} {o+7} {o+8}\n")  # ceiling
    out.write(f"usemtl {mat_name}_wall\n")
    out.write(f"f {o+1} {o+2} {o+6} {o+5}\n")  # front wall (Y=ymin)
    out.write(f"f {o+2} {o+3} {o+7} {o+6}\n")  # right wall (X=xmax)
    out.write(f"f {o+3} {o+4} {o+8} {o+7}\n")  # back wall (Y=ymax)
    out.write(f"f {o+4} {o+1} {o+5} {o+8}\n")  # left wall (X=xmin)
    return vert_offset + 8

obj_path = out_base + ".obj"
mtl_path = out_base + ".mtl"
mtl_basename = os.path.basename(mtl_path)

with open(obj_path, "w") as obj, open(mtl_path, "w") as mtl:
    obj.write("# Auto-generated rooms\n")
    obj.write(f"mtllib {mtl_basename}\n")
    # Materials
    mtl.write("newmtl room_wall\nKa 0.4 0.4 0.4\nKd 0.92 0.92 0.88\nKs 0.0 0.0 0.0\nNs 5\nd 1.0\n\n")
    mtl.write("newmtl room_floor\nKa 0.3 0.25 0.2\nKd 0.62 0.55 0.45\nKs 0.0 0.0 0.0\nNs 5\nd 1.0\n\n")
    mtl.write("newmtl room_ceiling\nKa 0.4 0.4 0.4\nKd 0.96 0.96 0.96\nKs 0.0 0.0 0.0\nNs 5\nd 1.0\n\n")

    voff = 0
    for c in clusters_info:
        obj.write(f"\no {c['id']}\n")
        voff = emit_room_box(obj, voff, c["bbox_mm"], "room")

# Write json
with open(out_base + ".json", "w") as f:
    json.dump(clusters_info, f, ensure_ascii=False, indent=2)

print(f"\nGenerated {len(clusters_info)} rooms:")
for c in clusters_info:
    sx = c["size_mm"][0] / 1000.0
    sy = c["size_mm"][1] / 1000.0
    cx, cy, cz = c["camera_mm"]
    print(f"  {c['id']}: {c['n_instances']:>3} instances, {sx:.1f}m × {sy:.1f}m, "
          f"camera @ ({cx/1000:.1f}, {cy/1000:.1f}, {cz/1000:.1f}) m")

print(f"\nWritten:\n  {obj_path}\n  {mtl_path}\n  {out_base}.json")

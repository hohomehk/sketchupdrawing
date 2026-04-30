#!/usr/bin/env python3
"""
360 Render Pipeline — job runner.

Watches /home/timothy/mydocs/360_inbox/ for new job folders dropped by the
SketchUp Ruby plugin (su_360_export.rb). For each job:
  1. skp_to_obj.exe (SDK + Wine in Docker)
  2. Build a single-room walls box from manifest bbox
  3. Blender Cycles 4K equirectangular panorama from manifest camera position
  4. (optional) GPT-Image-2 enhance
  5. Publish a Pannellum viewer to out/jobs/<job_id>/
  6. Update inbox/<job_id>/status.json with the URL

A new job is "ready" once a folder contains both manifest.json AND model.skp.
After processing, status.json is written into the inbox job folder so the
SketchUp side can read the URL when Dropbox syncs back.
"""

import os, sys, time, json, subprocess, shutil, traceback
from pathlib import Path
from datetime import datetime

ROOT = Path("/home/timothy/sketchupdrawing")
INBOX = Path("/home/timothy/mydocs/360_inbox")
OUTBOX = Path("/home/timothy/mydocs/360_outbox")
JOBS_OUT = ROOT / "out" / "jobs"
WEB_PORT = 8765   # localhost serve

INBOX.mkdir(parents=True, exist_ok=True)
OUTBOX.mkdir(parents=True, exist_ok=True)
JOBS_OUT.mkdir(parents=True, exist_ok=True)

# ---- helpers ----
def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)

def write_status(job_dir: Path, status: dict):
    out = job_dir / "status.json"
    out.write_text(json.dumps(status, ensure_ascii=False, indent=2))

def run_docker(cmd_args, timeout=600):
    """Run a docker command synchronously, return stdout."""
    full = ["docker", "run", "--rm",
            "-v", f"{ROOT}:/work",
            "-v", f"{INBOX}:/inbox:ro",
            "skpbuild", "bash", "-c"] + [" ".join(cmd_args)]
    return subprocess.run(full, capture_output=True, text=True, timeout=timeout)

# ---- pipeline steps ----
def host_to_container(host_path: Path) -> str:
    """Translate /home/timothy/sketchupdrawing/... → /work/... for Docker volume."""
    p = str(host_path.absolute())
    if p.startswith(str(ROOT)):
        return "/work" + p[len(str(ROOT)):]
    raise ValueError(f"path {p} not under {ROOT}")

def run_skp_to_obj(skp_in: Path, obj_out: Path):
    """Convert SKP to OBJ using our Wine-based SDK exporter."""
    log(f"  [step 1/5] SKP → OBJ: {skp_in.name}")
    obj_out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(skp_in, "/tmp/job_model.skp")
    obj_in_container = host_to_container(obj_out)
    cmd = (
        f"export WINEPREFIX=/wineprefix WINEDEBUG=-all && "
        f"wine wineboot --init >/dev/null 2>&1 && "
        f"cd /work/win/binaries/sketchup/x64 && "
        f"wine ./skp_to_obj.exe Z:/tmp/job_model.skp Z:{obj_in_container}"
    )
    full = ["docker", "run", "--rm",
            "-v", f"{ROOT}:/work",
            "-v", f"/tmp/job_model.skp:/tmp/job_model.skp:ro",
            "skpbuild", "bash", "-c", cmd]
    r = subprocess.run(full, capture_output=True, text=True, timeout=300)
    if r.returncode != 0 or not obj_out.exists():
        raise RuntimeError(f"skp_to_obj failed: {r.stderr[-300:]}")
    log(f"          → {obj_out.name} ({obj_out.stat().st_size//1024} KB)")

def build_room_obj(manifest: dict, rooms_obj: Path):
    """Generate single-room walls/floor/ceiling from manifest bbox."""
    log(f"  [step 2/5] generating room walls")
    bb_min = manifest["room"]["bbox_min_mm"]
    bb_max = manifest["room"]["bbox_max_mm"]
    pad    = manifest["room"].get("padding_mm", 1500)
    # Pad and force ceiling height 2875
    xmin = bb_min[0] - pad; xmax = bb_max[0] + pad
    ymin = bb_min[1] - pad; ymax = bb_max[1] + pad
    zmin = 0.0;            zmax = 2875.0
    M = 0.001  # mm → m
    pts = [
        (xmin*M, ymin*M, zmin*M),
        (xmax*M, ymin*M, zmin*M),
        (xmax*M, ymax*M, zmin*M),
        (xmin*M, ymax*M, zmin*M),
        (xmin*M, ymin*M, zmax*M),
        (xmax*M, ymin*M, zmax*M),
        (xmax*M, ymax*M, zmax*M),
        (xmin*M, ymax*M, zmax*M),
    ]
    rooms_obj.parent.mkdir(parents=True, exist_ok=True)
    mtl = rooms_obj.with_suffix(".mtl")
    with open(rooms_obj, "w") as o, open(mtl, "w") as m:
        o.write(f"mtllib {mtl.name}\n")
        for x, y, z in pts:
            o.write(f"v {x:.4f} {y:.4f} {z:.4f}\n")
        o.write("usemtl room_floor\n")
        o.write("f 1 4 3 2\n")
        o.write("usemtl room_ceiling\n")
        o.write("f 5 6 7 8\n")
        o.write("usemtl room_wall\n")
        o.write("f 1 2 6 5\n")  # front
        o.write("f 2 3 7 6\n")  # right
        o.write("f 3 4 8 7\n")  # back
        o.write("f 4 1 5 8\n")  # left
        m.write("newmtl room_wall\nKd 0.92 0.92 0.88\nNs 5\nd 1.0\n\n")
        m.write("newmtl room_floor\nKd 0.62 0.55 0.45\nNs 5\nd 1.0\n\n")
        m.write("newmtl room_ceiling\nKd 0.96 0.96 0.96\nNs 5\nd 1.0\n\n")
    log(f"          room: ({xmin/1000:.1f},{ymin/1000:.1f}) → ({xmax/1000:.1f},{ymax/1000:.1f}) m")

def render_scene_view(cab_obj: Path, rooms_obj: Path, manifest: dict,
                      out_jpg: Path, quality: int):
    """Render flat perspective from the manifest's scene camera (eye + target + FOV).
    Output is 3:2 ratio (1536×1024) to match GPT-Image-2's supported aspect ratio.
    """
    log(f"  [step 3/5] Cycles perspective render (quality={quality})")
    samples = {1: 32, 2: 80, 3: 200}.get(quality, 80)
    # 3:2 to match Poe GPT-Image-2 native ratio
    res_w, res_h = (1536, 1024)

    cam = manifest["camera"]
    eye_m = [v / 1000.0 for v in cam["eye_mm"]]
    tgt_m = [v / 1000.0 for v in cam["target_mm"]]
    up_v  = cam.get("up", [0, 0, 1])
    fov_deg = cam.get("fov_deg") or 60.0  # fallback
    is_persp = cam.get("perspective", True)

    bb_min = manifest["room"]["bbox_min_mm"]
    bb_max = manifest["room"]["bbox_max_mm"]
    cx_mm = (bb_min[0] + bb_max[0]) * 0.5
    cy_mm = (bb_min[1] + bb_max[1]) * 0.5

    pyfile = "/tmp/render_scene.py"
    cab_in = host_to_container(cab_obj)
    rooms_in = host_to_container(rooms_obj)
    out_in = host_to_container(out_jpg)
    import math
    fov_rad = math.radians(fov_deg)

    Path(pyfile).write_text(f"""
import sys, os, math, bpy
from mathutils import Vector
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.obj_import(filepath="{cab_in}", forward_axis="Y", up_axis="Z")
bpy.ops.wm.obj_import(filepath="{rooms_in}", forward_axis="Y", up_axis="Z")

# World background — soft blue-white
w = bpy.data.worlds.new("BG"); bpy.context.scene.world = w
w.use_nodes = True
b = w.node_tree.nodes["Background"]
b.inputs[0].default_value = (0.95, 0.95, 0.98, 1.0)
b.inputs[1].default_value = 1.5

# Sun light (soft outdoor) + interior fill
sun = bpy.data.lights.new("sun", "SUN"); sun.energy = 2.5
so = bpy.data.objects.new("sun", sun); so.rotation_euler = (0.7, 0.0, 0.4)
bpy.context.collection.objects.link(so)
for pos, e in [(({cx_mm/1000:.3f},{cy_mm/1000:.3f}, 2.55), 250)]:
    ld = bpy.data.lights.new("pt","POINT"); ld.energy = e; ld.shadow_soft_size = 0.5
    o = bpy.data.objects.new("pt", ld); o.location = pos
    bpy.context.collection.objects.link(o)

s = bpy.context.scene
s.render.engine = "CYCLES"; s.cycles.device = "CPU"
s.render.resolution_x = {res_w}; s.render.resolution_y = {res_h}
s.cycles.samples = {samples}; s.cycles.use_denoising = False
s.render.image_settings.file_format = "JPEG"; s.render.image_settings.quality = 90

# Perspective camera at scene's eye, looking at target
cd = bpy.data.cameras.new("c")
cd.type = "PERSP"
cd.angle = {fov_rad}    # FOV in radians (Blender uses horizontal-by-default depends on sensor)
c = bpy.data.objects.new("c", cd)
c.location = ({eye_m[0]:.3f}, {eye_m[1]:.3f}, {eye_m[2]:.3f})
look_at = Vector(({tgt_m[0]:.3f}, {tgt_m[1]:.3f}, {tgt_m[2]:.3f}))
direction = look_at - Vector(c.location)
c.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
bpy.context.collection.objects.link(c); s.camera = c

s.render.filepath = "{out_in}"
print(f"camera at {{c.location}}, looking at {{look_at}}, fov_deg={fov_deg:.1f}")
bpy.ops.render.render(write_still=True)
""")
    cmd = f"timeout 600 blender --background --python /tmp/render_scene.py 2>&1 | tail -5"
    full = ["docker", "run", "--rm",
            "-v", f"{ROOT}:/work",
            "-v", f"{pyfile}:{pyfile}:ro",
            "skpbuild", "bash", "-c", cmd]
    r = subprocess.run(full, capture_output=True, text=True, timeout=700)
    if not out_jpg.exists() or out_jpg.stat().st_size < 10000:
        raise RuntimeError(f"Blender render failed: {r.stderr[-300:]}")
    log(f"          → {out_jpg.name} ({out_jpg.stat().st_size//1024} KB)")

def ai_enhance_via_poe(in_jpg: Path, out_jpg: Path, project_name: str, scene_name: str):
    """Send Blender render to Poe GPT-Image-2 for photorealistic enhance.

    Requires POE_API_KEY env var (Poe API key from poe.com/api_key).
    Falls back to copying the source if API key absent.
    """
    log(f"  [step 4/5] AI enhance via Poe GPT-Image-2")
    api_key = os.environ.get("POE_API_KEY", "").strip()
    if not api_key:
        log("          POE_API_KEY not set — skipping enhance, copying raw render")
        shutil.copy(in_jpg, out_jpg)
        return False

    import base64, requests
    img_b64 = base64.b64encode(in_jpg.read_bytes()).decode()
    prompt = (
        f"Transform this 3D architectural rendering into a photorealistic interior "
        f"photograph for a Hong Kong residential project ({project_name} / {scene_name}). "
        f"CRITICAL: Preserve the exact cabinet shape, position, dimensions, shelving "
        f"layout, and overall geometry — do NOT change the structure. "
        f"Add: realistic light oak wood grain texture on cabinets, soft warm white walls "
        f"with subtle texture, light wooden floor with natural grain, soft even ambient "
        f"lighting (no harsh shadows), modern clean minimal Hong Kong residential style. "
        f"Do NOT add any furniture, decor, plants, or human figures. Aspect ratio 3:2."
    )
    # Poe API: openai-compatible endpoint at api.poe.com
    url = "https://api.poe.com/v1/chat/completions"
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    payload = {
        "model": "GPT-Image-2",
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{img_b64}"}}
        ]}],
        "stream": False
    }
    try:
        r = requests.post(url, headers=headers, json=payload, timeout=120)
        r.raise_for_status()
        data = r.json()
        # Poe returns the image as a URL/markdown in the assistant message
        content = data["choices"][0]["message"]["content"]
        # Parse markdown ![...](url)
        import re
        m = re.search(r"\((https?://[^\s)]+)\)", content)
        if not m:
            raise RuntimeError(f"No image URL in response: {content[:200]}")
        img_url = m.group(1)
        img_data = requests.get(img_url, timeout=60).content
        out_jpg.write_bytes(img_data)
        log(f"          → enhanced {out_jpg.name} ({len(img_data)//1024} KB)")
        return True
    except Exception as e:
        log(f"          enhance failed: {e}; copying raw render")
        shutil.copy(in_jpg, out_jpg)
        return False

def build_viewer(job_id: str, project_name: str, scene_name: str,
                 raw_jpg: Path, enhanced_jpg: Path, manifest: dict, viewer_dir: Path):
    """Generate a side-by-side viewer of raw Cycles render + AI-enhanced result."""
    log(f"  [step 5/5] viewer page")
    viewer_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy(raw_jpg, viewer_dir / "raw.jpg")
    shutil.copy(enhanced_jpg, viewer_dir / "enhanced.jpg")
    bb_min = manifest["room"]["bbox_min_mm"]
    bb_max = manifest["room"]["bbox_max_mm"]
    sx = (bb_max[0] - bb_min[0]) / 1000.0
    sy = (bb_max[1] - bb_min[1]) / 1000.0
    html = f"""<!doctype html>
<html lang="zh-Hant"><head>
<meta charset="utf-8">
<title>{project_name}</title>
<style>
html,body{{margin:0;padding:0;background:#0d0d0d;color:#eee;font-family:-apple-system,"Helvetica Neue","PingFang HK","Microsoft JhengHei",sans-serif;min-height:100vh;}}
header{{padding:16px 24px;border-bottom:1px solid #222;}}
header h1{{margin:0 0 4px 0;font-size:18px;}}
header small{{opacity:.65;font-size:12px;}}
.tabs{{padding:14px 24px 0 24px;display:flex;gap:6px;}}
.tabs button{{background:#1a1a1a;border:1px solid #2a2a2a;color:#bbb;padding:8px 16px;border-radius:6px;cursor:pointer;font-size:13px;}}
.tabs button.active{{background:rgba(40,120,180,.3);border-color:#5cf;color:#fff;}}
.viewport{{padding:14px 24px 24px 24px;}}
.viewport img{{max-width:100%;display:block;border-radius:6px;box-shadow:0 4px 24px rgba(0,0,0,.4);}}
#both{{display:none;grid-template-columns:1fr 1fr;gap:14px;}}
#both.show{{display:grid;}}
#both .col label{{display:block;text-align:center;padding:6px 0;font-size:12px;opacity:.6;}}
</style></head>
<body>
<header>
  <h1>{project_name}</h1>
  <small>Scene: {scene_name} · Room ≈ {sx:.1f} × {sy:.1f} m · Job: {job_id}</small>
</header>
<div class="tabs">
  <button data-mode="enhanced" class="active">AI 效果</button>
  <button data-mode="raw">原 render</button>
  <button data-mode="both">並排對比</button>
</div>
<div class="viewport">
  <img id="single" src="enhanced.jpg" alt="render">
  <div id="both">
    <div class="col"><img src="raw.jpg" alt="raw"><label>原 Cycles render</label></div>
    <div class="col"><img src="enhanced.jpg" alt="enhanced"><label>AI 效果（GPT-Image-2）</label></div>
  </div>
</div>
<script>
const single = document.getElementById('single');
const both = document.getElementById('both');
document.querySelectorAll('.tabs button').forEach(b => b.addEventListener('click', () => {{
  document.querySelectorAll('.tabs button').forEach(x => x.classList.remove('active'));
  b.classList.add('active');
  const m = b.dataset.mode;
  if (m === 'both') {{ single.style.display='none'; both.classList.add('show'); }}
  else {{ single.style.display=''; both.classList.remove('show'); single.src = (m==='raw'?'raw.jpg':'enhanced.jpg'); }}
}}));
</script>
</body></html>"""
    (viewer_dir / "index.html").write_text(html)
    log(f"          published: {viewer_dir}/index.html")

# ---- main loop ----
def process_job(job_dir: Path):
    job_id = job_dir.name
    log(f"=== JOB: {job_id} ===")
    write_status(job_dir, {"status": "processing", "started_at": datetime.now().isoformat()})

    try:
        manifest = json.loads((job_dir / "manifest.json").read_text())
        skp_path = job_dir / "model.skp"
        if not skp_path.exists():
            raise RuntimeError("model.skp not in job folder")

        project = manifest.get("project_name", job_id)
        scene = manifest.get("scene_name", "")
        quality = manifest.get("options", {}).get("quality", 2)
        do_ai = manifest.get("options", {}).get("ai_enhance", False)

        work = JOBS_OUT / job_id
        work.mkdir(parents=True, exist_ok=True)

        run_skp_to_obj(skp_path, work / "cabinets.obj")
        build_room_obj(manifest, work / "room.obj")
        render_scene_view(work / "cabinets.obj", work / "room.obj", manifest,
                          work / "raw.jpg", quality)

        enhanced = work / "enhanced.jpg"
        if do_ai:
            ai_enhance_via_poe(work / "raw.jpg", enhanced, project, scene)
        else:
            shutil.copy(work / "raw.jpg", enhanced)

        viewer_dir = ROOT / "out" / "web" / "jobs" / job_id
        build_viewer(job_id, project, scene, work / "raw.jpg", enhanced, manifest, viewer_dir)

        url = f"http://127.0.0.1:{WEB_PORT}/jobs/{job_id}/"
        write_status(job_dir, {
            "status": "ready",
            "finished_at": datetime.now().isoformat(),
            "viewer_url": url,
            "project": project,
            "scene": scene,
        })
        log(f"=== READY: {url} ===\n")
    except Exception as e:
        log(f"!!! FAILED: {e}\n{traceback.format_exc()}")
        write_status(job_dir, {
            "status": "failed",
            "finished_at": datetime.now().isoformat(),
            "error": str(e),
            "trace": traceback.format_exc(),
        })

def main():
    log(f"360 job runner started — watching {INBOX}")
    seen = set()
    # Pick up any pre-existing folders that have manifest+skp but no status.json
    while True:
        try:
            for d in sorted(INBOX.iterdir()):
                if not d.is_dir(): continue
                if d.name in seen: continue
                if not (d / "manifest.json").exists(): continue
                if not (d / "model.skp").exists(): continue
                if (d / "status.json").exists(): continue   # already processed
                seen.add(d.name)
                process_job(d)
        except Exception as e:
            log(f"main loop error: {e}")
        time.sleep(5)

if __name__ == "__main__":
    main()

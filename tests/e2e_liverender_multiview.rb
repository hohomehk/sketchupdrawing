# Multi-view + texture-swatch E2E for Live Render. Sends:
#   Image 1: Hidden Line view (PNG)
#   Image 2: Shaded view (PNG)
#   Image 3: A texture swatch (PNG)
# All to Gemini via the same code path Live Render uses, including the
# new build_multi_view_preamble(view_count, prompt, material_table) flow.
# Verifies a real PNG comes back without errors.
#
# Run via Docker (same image as test suite):
#   docker run --rm -v "$PWD:/work" -w /work ruby:3.2-slim \
#     ruby tests/e2e_liverender_multiview.rb

$LOAD_PATH.unshift File.expand_path(__dir__)
require "sketchup_stub"
load File.expand_path("../releases/su_gpt_render.rb", __dir__)

view1 = File.expand_path("e2e-frame.png", __dir__)
abort "missing #{view1}" unless File.exist?(view1)

# We use the same fixture for all 3 inputs — the goal here is to verify the
# wire format / preamble / response parsing for multi-image input, not to
# get a perfect render.
inputs = [view1, view1, view1]

prompt = "Render this scene in clean photographic style, soft daylight, neutral colours."

# Build a fake material table that the preamble would normally generate.
material_table = <<~TBL.strip
  | HEX | Material name | Hint | Texture ref |
  |---|---|---|---|
  | `#8B4513` | Walnut Veneer | tex: oak.jpg | Image 3 |
  | `#FFFFFF` | Off-White Plaster | solid | — |
TBL

puts "PLUGIN_VERSION:    #{SuGptRender::PLUGIN_VERSION}"
puts "AIG token:         #{SuGptRender::GEMINI_AIG_TOKEN[0,12]}…"
puts "API key const:     #{SuGptRender.const_defined?(:GEMINI_API_KEY, false) ? 'EXISTS — leak!' : 'absent ✓'}"
puts "inputs:            #{inputs.length} (2 views + 1 texture swatch)"
puts

start = Time.now
render_path, tokens = SuGptRender.call_gemini_image(
  inputs, prompt,
  model: "gemini-2.5-flash-image",
  input_mime: "image/png",
  view_count: 2,                    # views are images 1-2; rest are textures
  material_table: material_table,
)
elapsed = (Time.now - start).round(1)

abort "no render path returned" unless render_path
abort "render file missing: #{render_path}" unless File.exist?(render_path)
size = File.size(render_path)
abort "render file too small (#{size}B) — likely a placeholder, not a real PNG" if size < 50_000

# Sanity: PNG signature
sig = File.binread(render_path, 8)
abort "not a PNG (header bytes: #{sig.bytes.inspect})" unless sig.start_with?("\x89PNG\r\n\x1a\n".b)

puts "--- E2E multi-view result ---"
puts "elapsed:         #{elapsed}s"
puts "tokens (image):  #{tokens}"
puts "render file:     #{render_path} (#{size} bytes)"
puts "PNG signature:   ✓ valid"

# Copy out for the user to view if running on host with /tmp shared.
require "fileutils"
FileUtils.cp(render_path, "/tmp/e2e-multiview-rendered.png") rescue nil
puts "copied to:       /tmp/e2e-multiview-rendered.png"

puts
puts "✅ multi-view E2E PASS"

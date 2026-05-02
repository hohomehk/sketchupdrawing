# End-to-end: load the built plugin (releases/su_gpt_render.rb) + call
# call_gemini_image with a real test frame, write the rendered PNG to /tmp,
# print byte size + token count. No stubs — hits CF AI Gateway → real Gemini
# 2.5 Flash Image. Used as the manual release-time smoke test (alongside
# tests/e2e_livestream.rb for the SSE streaming path).
#
# Run via Docker (so it's reproducible, same Ruby as the unit tests):
#   docker run --rm -v "$PWD:/work" -w /work ruby:3.2-slim ruby tests/e2e_liverender.rb
#
# Cost: ~$0.0005 per run. Latency: ~10s. Output: 1024² PNG ~2-3MB at /tmp/e2e-rendered.png.

$LOAD_PATH.unshift File.expand_path(__dir__)
require "sketchup_stub"
load File.expand_path("../releases/su_gpt_render.rb", __dir__)

img = File.expand_path("e2e-frame.png", __dir__)
puts "input image:    #{img} (#{File.size(img)} bytes)"
puts "PLUGIN_VERSION: #{SuGptRender::PLUGIN_VERSION}"
puts "URL base:       #{SuGptRender::GEMINI_AIG_URL}"
puts "AIG token:      #{SuGptRender::GEMINI_AIG_TOKEN[0,12]}…"
puts "API key const:  #{SuGptRender.const_defined?(:GEMINI_API_KEY, false) ? 'EXISTS — should not!' : 'absent ✓'}"
puts "Image models:   #{SuGptRender::GEMINI_IMAGE_MODELS.inspect}"
puts

prompt = "Render this SketchUp scene as a photorealistic interior design rendering, " \
         "soft natural light, professional 3d visualization. Preserve geometry exactly."

started = Time.now
out_path = nil
tokens = nil
begin
  out_path, tokens = SuGptRender.call_gemini_image(
    img, prompt,
    model: "gemini-2.5-flash-image",
    input_mime: "image/png"
  )
rescue => e
  puts "ERROR: #{e.class}: #{e.message}"
  exit 1
end
elapsed = (Time.now - started).round(2)

# Move/copy the result to /tmp/e2e-rendered.png for easy inspection.
target = "/tmp/e2e-rendered.png"
require "fileutils"
FileUtils.cp(out_path, target)

puts "--- E2E Live Render result ---"
puts "elapsed:        #{elapsed}s"
puts "tokens (image): #{tokens}"
puts "estimated cost: $#{format('%.6f', tokens.to_i * 0.40e-6)}"
puts "output written: #{out_path} (#{File.size(out_path)} bytes)"
puts "copied to:      #{target}"

# End-to-end: load injected plugin + invoke stream_gemini with a real image,
# print every token as the wire delivers it. No stubs.
#
# Run via Docker (so it's reproducible, same Ruby as test suite):
#   docker run --rm -v "$PWD:/work" -w /work ruby:3.2-slim ruby tests/e2e_livestream.rb

$LOAD_PATH.unshift File.expand_path(__dir__)
require "sketchup_stub"
load File.expand_path("../releases/su_gpt_render.rb", __dir__)

img = File.expand_path("e2e-frame.png", __dir__)
puts "wrote #{img}: #{File.size(img)} bytes"
puts "PLUGIN_VERSION: #{SuGptRender::PLUGIN_VERSION}"
puts "URL base:       #{SuGptRender::GEMINI_AIG_URL}"
puts "AIG token:      #{SuGptRender::GEMINI_AIG_TOKEN[0,12]}…"
puts "API key const:  #{SuGptRender.const_defined?(:GEMINI_API_KEY, false) ? 'EXISTS — should not!' : 'absent ✓'}"
puts

prompt = "用一句中文形容呢張圖。"
deltas = []
done = false
begin
  SuGptRender.stream_gemini(img, prompt, model: "gemini-2.5-flash", mime_type: "image/png") do |kind, payload|
    case kind
    when :token
      deltas << payload
      print payload
      $stdout.flush
    when :done
      done = true
    end
  end
rescue => e
  puts; puts "ERROR: #{e.class}: #{e.message}"
end
puts
puts "--- E2E result ---"
puts "tokens received: #{deltas.length}"
puts "done flag:       #{done}"
puts "full text:       #{deltas.join.inspect[0,500]}"

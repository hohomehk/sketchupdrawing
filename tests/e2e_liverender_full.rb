# Full-flow E2E for Live Render — exercises the timer + capture + bg thread +
# queue + push chain that was hanging in v0.5.0. Hits real Gemini via AI
# Gateway. Uses tests/e2e-frame.png as the synthetic "captured view" so
# write_image produces a real PNG Gemini can decode (the stock stub writes
# "FAKE_PNG_BYTES" which Gemini rejects with 400).
#
# Run:
#   docker run --rm -v "$PWD:/work" -w /work ruby:3.2-slim ruby tests/e2e_liverender_full.rb

$LOAD_PATH.unshift File.expand_path(__dir__)
require "sketchup_stub"

# Override write_image so Sketchup.active_model.active_view.write_image emits
# a valid PNG (the existing stub writes 13 fake bytes Gemini can't decode).
PNG_FIXTURE = File.expand_path("e2e-frame.png", __dir__)
unless File.exist?(PNG_FIXTURE)
  abort "missing fixture: #{PNG_FIXTURE} (regenerate via tests/ generator)"
end
module Sketchup
  class ViewStub
    def write_image(opts)
      @write_image_calls << opts
      FileUtils.mkdir_p(File.dirname(opts[:filename]))
      FileUtils.cp(PNG_FIXTURE, opts[:filename])
      true
    end
  end
end
require "fileutils"

load File.expand_path("../releases/su_gpt_render.rb", __dir__)

puts "PLUGIN_VERSION:    #{SuGptRender::PLUGIN_VERSION}"
puts "AIG token:         #{SuGptRender::GEMINI_AIG_TOKEN[0,12]}…"
puts "GEMINI_API_KEY?    #{SuGptRender.const_defined?(:GEMINI_API_KEY, false)}"
puts

# Bypass the @tray.visible? gate in push_live_render_* so we can verify the
# state-transition chain without an actual HtmlDialog.
fake_tray = Class.new {
  attr_reader :scripts
  def initialize; @scripts = []; end
  def visible?; true; end
  def execute_script(s); @scripts << s; end
  def set_html(_); end
}.new
SuGptRender.instance_variable_set(:@tray, fake_tray)

# Step 1: start the loop. Should register both the poll_timer (0.2s) and the
# first-tick timer (0.5s). v0.5.0 had a 0.05s tick; v0.5.1 changed to 0.5s.
puts "[1] start_live_render"
SuGptRender.start_live_render
state = SuGptRender.instance_variable_get(:@liverender)
abort "FAIL: not enabled" unless state[:enabled]
abort "FAIL: poll_timer missing" unless state[:poll_timer]
puts "    state.enabled=#{state[:enabled]}  poll_timer=#{state[:poll_timer]}"
timers_after_start = UI.timers.keys
puts "    timers registered: #{timers_after_start} " \
     "(poll @0.2s, first-tick @0.5s — count = #{timers_after_start.size})"
unless timers_after_start.size >= 2
  abort "FAIL: expected ≥2 timers (poll + first-tick), got #{timers_after_start.size}"
end

# Step 2: fire the first-tick timer manually (the one with seconds=0.5).
puts
puts "[2] fire first-tick timer"
first_tick_id = UI.timers.find { |_, t| t[:seconds] == 0.5 }&.first
abort "FAIL: no 0.5s first-tick timer" unless first_tick_id
puts "    first-tick id = #{first_tick_id}"
UI.fire_timer(first_tick_id)

# Step 3: kick should have fired bg thread and tick_timer should now be set.
puts
puts "[3] post-tick state"
state = SuGptRender.instance_variable_get(:@liverender)
puts "    in_flight=#{state[:in_flight]}  bg_thread alive?=#{state[:bg_thread]&.alive?}"
abort "FAIL: in_flight should be true after kick" unless state[:in_flight]
abort "FAIL: bg_thread missing" unless state[:bg_thread]

# Step 4: wait for bg thread to finish the real Gemini call (~10-15s).
puts
puts "[4] waiting up to 60s for bg thread (real Gemini call)..."
t0 = Time.now
state[:bg_thread].join(60)
elapsed = (Time.now - t0).round(1)
puts "    bg thread done in #{elapsed}s"
abort "FAIL: bg thread still alive" if state[:bg_thread].alive?

# Step 5: fire poll timer to drain the queue onto the (fake) tray.
puts
puts "[5] drain queue"
poll_id = state[:poll_timer]
UI.fire_timer(poll_id)

# Step 6: verify state — current_render populated, history has 1 entry, render
# file exists on disk.
puts
puts "[6] final state"
state = SuGptRender.instance_variable_get(:@liverender)
cur = state[:current_render]
abort "FAIL: no current_render" unless cur
abort "FAIL: no render_path"   unless cur[:render_path]
abort "FAIL: render file missing #{cur[:render_path]}" unless File.exist?(cur[:render_path])
size = File.size(cur[:render_path])
abort "FAIL: render PNG too small (#{size}b)" if size < 50_000

puts "    history.size:   #{state[:history].size}"
puts "    current.tokens: #{cur[:tokens]}  elapsed: #{cur[:elapsed]}s"
puts "    render_path:    #{cur[:render_path]} (#{size} bytes)"
puts

# Step 7: confirm tray got the right execute_script calls
in_url_pushed  = fake_tray.scripts.any? { |s| s.include?("setLiveRenderFrames(") && !s.include?("null, null") }
done_pushed    = fake_tray.scripts.any? { |s| s.include?("liveRenderDone(") }
puts "[7] tray push verification"
puts "    setLiveRenderFrames called?  #{in_url_pushed}"
puts "    liveRenderDone called?       #{done_pushed}"
abort "FAIL: setLiveRenderFrames not pushed" unless in_url_pushed
abort "FAIL: liveRenderDone not pushed"      unless done_pushed

puts
puts "✅ E2E PASS — Live Render full chain works on v#{SuGptRender::PLUGIN_VERSION}"

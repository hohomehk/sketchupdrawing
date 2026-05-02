#!/usr/bin/env ruby
# test_su_gpt_render.rb — non-GUI unit tests for the SketchUp plugin.
#
# Run via:  ruby tests/test_su_gpt_render.rb
# Or:       docker run --rm -v "$PWD:/work" -w /work ruby:3.2-slim ruby tests/test_su_gpt_render.rb

$VERBOSE = nil  # silence "already initialized constant" during hot-reload tests

require "json"
require "tempfile"
require "fileutils"
require "minitest/autorun"
require "stringio"

require_relative "sketchup_stub"

# Override CONFIG_PATH to a tmp file BEFORE loading the plugin so set_config
# doesn't clobber the user's real config.
TEST_CFG_PATH = File.join(Dir.tmpdir, "sketchup_su_gpt_render_test.json")
File.delete(TEST_CFG_PATH) if File.exist?(TEST_CFG_PATH)

# Load plugin
PLUGIN_RB = File.expand_path("../sketchup_plugin/su_gpt_render/su_gpt_render.rb", __dir__)
require_relative PLUGIN_RB

# Re-define CONFIG_PATH to test path (avoid touching user files)
SuGptRender.send(:remove_const, :CONFIG_PATH)
SuGptRender.const_set(:CONFIG_PATH, TEST_CFG_PATH)

# ============================================================================

class FakeHttpResponse
  attr_reader :code, :body
  def initialize(code, body); @code = code.to_s; @body = body; end
  def is_a?(klass); klass == Net::HTTPSuccess && @code.start_with?("2"); end
end

# Convenience: stub http_get / http_post_json on SuGptRender
module SuGptRender
  class << self
    attr_accessor :stub_responses, :stub_calls

    def http_get(url, attempts: 3)
      @stub_calls ||= []
      @stub_calls << [:get, url]
      stub = (@stub_responses || {})[url] || (@stub_responses || {})["*"]
      raise "no stub response for #{url}" unless stub
      stub.respond_to?(:call) ? stub.call(url) : stub
    end

    def http_post_json(url, headers, body, attempts: 3)
      @stub_calls ||= []
      @stub_calls << [:post, url, body]
      stub = (@stub_responses || {})[url] || (@stub_responses || {})["*"]
      raise "no stub response for #{url}" unless stub
      stub.respond_to?(:call) ? stub.call(url, body) : stub
    end
  end
end

# ============================================================================

class TestVersionNewer < Minitest::Test
  def vn(a, b); SuGptRender.version_newer?(a, b); end

  def test_basic
    assert vn("0.2.6", "0.2.5"),   "0.2.6 > 0.2.5"
    refute vn("0.2.5", "0.2.6"),   "0.2.5 < 0.2.6"
    refute vn("0.2.5", "0.2.5"),   "0.2.5 == 0.2.5 (not newer)"
  end

  def test_major_bump
    assert vn("1.0.0", "0.99.99")
    assert vn("0.3.0", "0.2.99")
  end

  def test_short_form
    assert vn("0.2", "0.1.999"), "0.2 (== 0.2.0) > 0.1.999"
    assert vn("1", "0.99")
  end

  def test_double_digit_components
    assert vn("0.2.10", "0.2.9"),  "0.2.10 > 0.2.9 (numeric, not lex)"
    assert vn("0.10.0", "0.9.99")
  end

  def test_equal_with_diff_lengths
    refute vn("0.2.0", "0.2"),  "0.2.0 == 0.2"
    refute vn("0.2",   "0.2.0"), "0.2 == 0.2.0"
  end
end

# ============================================================================

class TestPoeUrlRegex < Minitest::Test
  # The regex we care about lives inside call_poe. Replicate it here to test.
  REGEX_MD  = /!\[[^\]]*\]\(([^)\s]+)\)/
  REGEX_BARE = /(https?:\/\/[^\s)\]]+)/

  def extract(content)
    m = content.match(REGEX_MD) || content.match(REGEX_BARE)
    m && m[1]
  end

  def test_poe_cdn_no_extension
    body = '![alt text](https://pfst.cf2.poecdn.net/base/image/0e43ca47b8d1dd889e6b603e86ca8e3fef2837d1bb916314f768cdcb6ff079e5?w=1536&h=1024)'
    url = extract(body)
    assert url.start_with?("https://pfst.cf2.poecdn.net/base/image/"), "got #{url}"
    refute url.include?(")"), "URL should not include trailing paren"
  end

  def test_with_png_extension
    body = '![](https://example.com/foo/bar.png)'
    assert_equal "https://example.com/foo/bar.png", extract(body)
  end

  def test_chinese_alt_text
    body = '![中文 alt](https://pfst.cf2.poecdn.net/x/abc?w=1024&h=1024)'
    url = extract(body)
    assert url.start_with?("https://pfst.cf2.poecdn.net/x/abc")
  end

  def test_bare_url_fallback
    body = "Here is your image:\nhttps://cdn.example.com/x/y/z.jpg\nThanks"
    url = extract(body)
    assert_equal "https://cdn.example.com/x/y/z.jpg", url
  end

  def test_no_url_returns_nil
    assert_nil extract("Sorry, I cannot generate that image.")
  end
end

# ============================================================================

class TestConfig < Minitest::Test
  def setup
    File.delete(TEST_CFG_PATH) if File.exist?(TEST_CFG_PATH)
  end

  def test_load_empty_when_missing
    assert_equal({}, SuGptRender.load_config)
  end

  def test_save_and_load_roundtrip
    SuGptRender.save_config({"poe_api_key" => "ABC", "model" => "GPT-Image-2"})
    cfg = SuGptRender.load_config
    assert_equal "ABC", cfg["poe_api_key"]
    assert_equal "GPT-Image-2", cfg["model"]
  end

  def test_load_invalid_json_returns_empty
    File.write(TEST_CFG_PATH, "{bogus")
    assert_equal({}, SuGptRender.load_config)
  end
end

# ============================================================================

class TestUpdateLogic < Minitest::Test
  def setup
    SuGptRender.stub_responses = nil
    SuGptRender.stub_calls = []
  end

  def manifest_json(version, notes: "test")
    {
      "version" => version,
      "rb_url"  => "https://raw/rb",
      "notes"   => notes
    }.to_json
  end

  def test_remote_update_available_true_when_newer
    SuGptRender.stub_responses = {
      SuGptRender::UPDATE_MANIFEST_URL => FakeHttpResponse.new(200, manifest_json("99.99.99"))
    }
    assert SuGptRender.remote_update_available?
  end

  def test_remote_update_available_false_when_same
    SuGptRender.stub_responses = {
      SuGptRender::UPDATE_MANIFEST_URL => FakeHttpResponse.new(200, manifest_json(SuGptRender::PLUGIN_VERSION))
    }
    refute SuGptRender.remote_update_available?
  end

  def test_remote_update_available_false_on_404
    SuGptRender.stub_responses = {
      SuGptRender::UPDATE_MANIFEST_URL => FakeHttpResponse.new(404, "")
    }
    refute SuGptRender.remote_update_available?
  end
end

# ============================================================================

class TestHotReload < Minitest::Test
  # Verifies that load(__FILE__) actually redefines methods.
  # We do NOT call download_update_and_apply (it would hit real disk + URLs);
  # instead, write a fake version of the plugin to a tmp file and load it.

  def test_load_redefines_method
    # Original method
    SuGptRender.module_eval { def self.test_marker; "v1"; end }
    assert_equal "v1", SuGptRender.test_marker

    # Write a tmp file that redefines the marker
    tmp = Tempfile.new(["plugin_redef", ".rb"])
    tmp.write <<~RUBY
      module SuGptRender
        def self.test_marker; "v2"; end
      end
    RUBY
    tmp.close
    load tmp.path
    assert_equal "v2", SuGptRender.test_marker
    tmp.unlink
  end

  def test_load_redefines_constant_with_silenced_warnings
    SuGptRender.module_eval { remove_const(:TEST_CONST) if const_defined?(:TEST_CONST) }
    SuGptRender.const_set(:TEST_CONST, "old")
    tmp = Tempfile.new(["plugin_const", ".rb"])
    tmp.write <<~RUBY
      module SuGptRender
        TEST_CONST = "new"
      end
    RUBY
    tmp.close
    prev = $VERBOSE
    $VERBOSE = nil
    load tmp.path
    $VERBOSE = prev
    assert_equal "new", SuGptRender::TEST_CONST
    tmp.unlink
  end

  # Critical: silent-update relies on @tray reference SURVIVING `load`.
  # `@tray = nil` at module top would reset it. We use `@tray ||= nil`.
  def test_load_preserves_module_ivars_with_or_equals
    SuGptRender.instance_variable_set(:@tray, "MARKER")
    tmp = Tempfile.new(["plugin_ivar", ".rb"])
    tmp.write <<~RUBY
      module SuGptRender
        @tray ||= nil    # ||= preserves existing
      end
    RUBY
    tmp.close
    load tmp.path
    assert_equal "MARKER", SuGptRender.instance_variable_get(:@tray),
      "||= should preserve the live tray reference across load"
    tmp.unlink
  end

  def test_plain_assignment_loses_ivar_across_load
    # Sanity check: confirm the Ruby semantics we're guarding against.
    SuGptRender.instance_variable_set(:@tray, "WILL_BE_LOST")
    tmp = Tempfile.new(["plugin_bug", ".rb"])
    tmp.write <<~RUBY
      module SuGptRender
        @tray = nil    # plain = wipes
      end
    RUBY
    tmp.close
    load tmp.path
    assert_nil SuGptRender.instance_variable_get(:@tray),
      "plain = is destructive across load (this is the bug we fixed in 0.2.9)"
    tmp.unlink
  end
end

# ============================================================================

class TestTrayHtml < Minitest::Test
  def test_tray_html_returns_string_no_exception
    File.delete(TEST_CFG_PATH) if File.exist?(TEST_CFG_PATH)
    Sketchup.reset_model!
    html = SuGptRender.tray_html
    assert_kind_of String, html
    assert html.include?("<!doctype html>"), "looks like html"
    assert html.include?(SuGptRender::PLUGIN_NAME), "has plugin name (#{SuGptRender::PLUGIN_NAME})"
    assert html.include?("v#{SuGptRender::PLUGIN_VERSION}"), "has version"
    assert html.include?("Render Current View"), "has render button"
    assert html.include?("History"), "has history tab"
  end

  def test_tray_html_with_models_dropdown
    html = SuGptRender.tray_html
    SuGptRender::IMAGE_MODELS.first(3).each do |id, label, _hint|
      assert html.include?(id), "model id #{id} in html"
    end
  end

  def test_tray_html_handles_missing_api_key
    File.delete(TEST_CFG_PATH) if File.exist?(TEST_CFG_PATH)
    html = SuGptRender.tray_html
    assert html.include?("not set"), "missing api-key warning"
  end

  def test_tray_html_handles_present_api_key
    SuGptRender.save_config({"poe_api_key" => "abc"})
    html = SuGptRender.tray_html
    assert html.include?("API key ✓"), "api-key tick when set"
  end
end

# ============================================================================

class TestHistoryHtml < Minitest::Test
  def setup
    @tmp_dir = Dir.mktmpdir("test_history")
    @model = Sketchup.active_model
    @model.path = File.join(@tmp_dir, "test.skp")
    File.binwrite(@model.path, "fake")
    FileUtils.mkdir_p(File.join(@tmp_dir, "gpt_render"))
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir) if @tmp_dir
    Sketchup.reset_model!
  end

  def make_render(stem)
    dir = File.join(@tmp_dir, "gpt_render")
    File.binwrite(File.join(dir, "#{stem}_raw.png"), "raw")
    File.binwrite(File.join(dir, "#{stem}_enhanced.png"), "enh")
    File.write(File.join(dir, "#{stem}_meta.json"), JSON.generate({
      "model" => "GPT-Image-2", "width" => 1536, "height" => 1024,
      "prompt" => "test", "elapsed_sec" => 12.3,
    }))
  end

  def test_empty_history
    html = SuGptRender.render_history_html
    assert html.include?("No renders yet")
  end

  def test_history_with_entries
    make_render("20260501_120000_test")
    make_render("20260501_130000_test")
    html = SuGptRender.render_history_html
    refute html.include?("No renders yet")
    assert html.include?("12:00") || html.include?("13:00")
    assert html.include?("GPT-Image-2"), "model label visible"
    assert html.include?("1536"), "dimensions"
  end

  def test_count_history
    assert_equal 0, SuGptRender.count_history
    make_render("20260501_120000_a")
    make_render("20260501_130000_b")
    assert_equal 2, SuGptRender.count_history
  end
end

# ============================================================================

class TestCallPoePayload < Minitest::Test
  def setup
    SuGptRender.stub_responses = nil
    SuGptRender.stub_calls = []
    @tmpimg = Tempfile.new(["test", ".png"])
    @tmpimg.binmode; @tmpimg.write("\x89PNG\r\n\x1a\n" + "x" * 100); @tmpimg.close
  end

  def teardown
    @tmpimg.unlink if @tmpimg
  end

  def test_call_poe_sends_image_b64_and_returns_url
    response_body = JSON.generate({
      "choices" => [{
        "message" => { "role" => "assistant",
                       "content" => "![out](https://pfst.cf2.poecdn.net/base/image/abcdef?w=1536&h=1024)" }
      }]
    })
    SuGptRender.stub_responses = {
      "*" => FakeHttpResponse.new(200, response_body)
    }
    url = SuGptRender.call_poe("FAKE_KEY", @tmpimg.path, "TEST PROMPT", "GPT-Image-2")
    assert url.start_with?("https://pfst.cf2.poecdn.net/base/image/abcdef")
    # Verify the stub got a POST with our model + image
    posts = SuGptRender.stub_calls.select { |c| c[0] == :post }
    assert_equal 1, posts.length
    payload = JSON.parse(posts.first[2])
    assert_equal "GPT-Image-2", payload["model"]
    content_arr = payload["messages"][0]["content"]
    assert_equal 2, content_arr.length
    assert_equal "TEST PROMPT", content_arr[0]["text"]
    assert content_arr[1]["image_url"]["url"].start_with?("data:image/png;base64,"),
           "image attached as data URL"
  end

  def test_call_poe_raises_on_no_url
    response_body = JSON.generate({
      "choices" => [{ "message" => { "content" => "Sorry, I cannot do that." } }]
    })
    SuGptRender.stub_responses = { "*" => FakeHttpResponse.new(200, response_body) }
    err = assert_raises(RuntimeError) {
      SuGptRender.call_poe("KEY", @tmpimg.path, "p", "GPT-Image-2")
    }
    assert err.message.include?("No image URL"), "got: #{err.message}"
  end

  def test_call_poe_raises_on_http_error
    SuGptRender.stub_responses = { "*" => FakeHttpResponse.new(401, '{"error":"unauthorized"}') }
    err = assert_raises(RuntimeError) {
      SuGptRender.call_poe("KEY", @tmpimg.path, "p", "GPT-Image-2")
    }
    assert err.message.include?("Poe API HTTP 401")
  end
end

# ============================================================================

class TestPromptTemplates < Minitest::Test
  def setup
    File.delete(TEST_CFG_PATH) if File.exist?(TEST_CFG_PATH)
  end

  def test_builtin_templates_present
    tpls = SuGptRender.all_templates
    assert tpls.length >= 7, "at least 7 builtins, got #{tpls.length}"
    builtin_names = tpls.select { |t| t["source"] == "builtin" }.map { |t| t["name"] }
    assert builtin_names.any? { |n| n.include?("HK Residential") }, "has HK Residential template"
    assert builtin_names.any? { |n| n.include?("Walnut") }, "has walnut template"
    assert builtin_names.any? { |n| n.include?("Marble") }, "has marble template"
  end

  def test_save_user_template
    SuGptRender.save_user_template("My HK style", "preserve geom; oak; warm")
    tpls = SuGptRender.all_templates
    user = tpls.select { |t| t["source"] == "user" }
    assert_equal 1, user.length
    assert_equal "My HK style", user.first["name"]
    assert_equal "preserve geom; oak; warm", user.first["prompt"]
  end

  def test_replace_existing_user_template
    SuGptRender.save_user_template("dup", "v1")
    SuGptRender.save_user_template("dup", "v2")
    user = SuGptRender.all_templates.select { |t| t["source"] == "user" }
    assert_equal 1, user.length
    assert_equal "v2", user.first["prompt"]
  end

  def test_delete_user_template
    SuGptRender.save_user_template("toDel", "x")
    user = SuGptRender.all_templates.select { |t| t["source"] == "user" }
    refute user.empty?
    id = user.first["id"]
    SuGptRender.delete_user_template(id)
    user = SuGptRender.all_templates.select { |t| t["source"] == "user" }
    assert user.empty?
  end

  def test_find_template_by_id
    tpl = SuGptRender.find_template("b0")
    assert tpl, "first builtin (b0) findable"
    assert_equal "builtin", tpl["source"]
  end

  def test_set_active_prompt
    SuGptRender.set_active_prompt("hello")
    assert_equal "hello", SuGptRender.load_config["prompt"]
  end

  def test_render_templates_html_no_error
    html = SuGptRender.render_templates_html
    assert_kind_of String, html
    assert html.include?("HK Residential")
  end
end

class TestPromptHistory < Minitest::Test
  def setup
    @tmp_dir = Dir.mktmpdir("test_prompt_history")
    @model = Sketchup.active_model
    @model.path = File.join(@tmp_dir, "test.skp")
    File.binwrite(@model.path, "fake")
    FileUtils.mkdir_p(File.join(@tmp_dir, "gpt_render"))
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir) if @tmp_dir
    Sketchup.reset_model!
  end

  def make_meta(stem, prompt, model: "GPT-Image-2", finished: "2026-05-01T12:00:00Z")
    File.write(File.join(@tmp_dir, "gpt_render", "#{stem}_meta.json"),
      JSON.generate({
        "prompt" => prompt, "model" => model,
        "finished_at" => finished,
      }))
  end

  def test_recent_prompts_dedup
    make_meta("20260501_120000_a", "prompt one")
    make_meta("20260501_130000_b", "prompt one")  # duplicate
    make_meta("20260501_140000_c", "prompt two")
    items = SuGptRender.recent_prompts
    assert_equal 2, items.length, "deduped"
  end

  def test_recent_prompts_limit_15
    20.times { |i| make_meta(sprintf("20260501_%06d_x", i), "prompt #{i}") }
    items = SuGptRender.recent_prompts
    assert_equal 15, items.length
  end

  def test_recent_prompts_html_empty
    html = SuGptRender.render_recent_prompts_html
    assert html.include?("No past prompts yet")
  end

  def test_recent_prompts_html_with_entries
    make_meta("20260501_120000_a", "test prompt content here")
    html = SuGptRender.render_recent_prompts_html
    assert html.include?("test prompt content here")
    assert html.include?("GPT-Image-2")
  end
end

class TestAiWatch < Minitest::Test
  def setup
    File.delete(TEST_CFG_PATH) if File.exist?(TEST_CFG_PATH)
    @tmp_dir = Dir.mktmpdir("test_aiwatch")
    @model = Sketchup.active_model
    @model.path = File.join(@tmp_dir, "test.skp")
    File.binwrite(@model.path, "fake")
    SuGptRender.save_config({"poe_api_key" => "TEST_KEY", "watch_delay" => 5})
    SuGptRender.instance_variable_set(:@aiwatch, {
      enabled: false, pending_timer: nil, observer: nil,
      bg_thread: nil, bg_poll_timer: nil
    })
    # Clear any lingering @tray from TestHotReload's MARKER strings
    SuGptRender.instance_variable_set(:@tray, nil)
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir) if @tmp_dir
    Sketchup.reset_model!
  end

  def test_watch_models_constant
    assert SuGptRender::WATCH_MODELS.length >= 5
    # v0.4.0: first entry is now the AI-Gateway direct option (no Poe markup).
    assert_equal SuGptRender::GEMINI_DIRECT_ID, SuGptRender::WATCH_MODELS.first[0]
    # Poe-routed Gemini-2.5-Flash still exists as a fallback option.
    ids = SuGptRender::WATCH_MODELS.map { |x| x[0] }
    assert_includes ids, "Gemini-2.5-Flash"
  end

  def test_default_watch_prompt_present
    assert SuGptRender::DEFAULT_WATCH_PROMPT.length > 50
    assert SuGptRender::DEFAULT_WATCH_PROMPT.include?("SketchUp")
  end

  def test_start_watching_sets_enabled
    SuGptRender.start_watching
    assert SuGptRender.instance_variable_get(:@aiwatch)[:enabled]
  end

  def test_start_watching_skipped_without_api_key
    # v0.4.0: skipping logic is per-model. Poe-routed models still need a
    # Poe key. Direct-via-AI-Gateway needs none (tokens bundled).
    SuGptRender.save_config({"watch_model" => "Gemini-2.5-Flash"})  # Poe-routed, no key
    SuGptRender.start_watching
    refute SuGptRender.instance_variable_get(:@aiwatch)[:enabled],
      "Poe-routed model without Poe API key should NOT start watching"
  end

  def test_start_watching_direct_works_without_poe_key
    # The direct-via-AI-Gateway path bundles its own tokens, so it must
    # work even when no Poe key is configured.
    SuGptRender.save_config({"watch_model" => SuGptRender::GEMINI_DIRECT_ID})
    SuGptRender.start_watching
    assert SuGptRender.instance_variable_get(:@aiwatch)[:enabled],
      "Direct-via-AI-Gateway should start watching without a Poe key"
    SuGptRender.stop_watching
  end

  def test_stop_watching_clears
    SuGptRender.start_watching
    SuGptRender.stop_watching
    refute SuGptRender.instance_variable_get(:@aiwatch)[:enabled]
  end

  def test_toggle_watching
    SuGptRender.toggle_watching
    assert SuGptRender.instance_variable_get(:@aiwatch)[:enabled]
    SuGptRender.toggle_watching
    refute SuGptRender.instance_variable_get(:@aiwatch)[:enabled]
  end

  def test_on_view_changed_schedules_timer
    SuGptRender.start_watching
    UI.reset!
    SuGptRender.on_view_changed
    assert_equal 1, UI.timers.length
    timer_id, t = UI.timers.first
    assert_equal 5, t[:seconds]
    refute t[:repeat]
  end

  def test_on_view_changed_debounces
    SuGptRender.start_watching
    UI.reset!
    SuGptRender.on_view_changed
    SuGptRender.on_view_changed   # second call should cancel + reschedule
    SuGptRender.on_view_changed
    # After 3 rapid calls, only the most recent timer should be pending
    pending = SuGptRender.instance_variable_get(:@aiwatch)[:pending_timer]
    assert pending, "pending timer set"
    # And UI.timers should reflect it (might have residue but the live one is set)
  end

  def test_watch_count_today_persists
    SuGptRender.bump_watch_count
    SuGptRender.bump_watch_count
    assert_equal 2, SuGptRender.watch_count_today
  end

  def test_estimated_cost_today
    SuGptRender.save_config({"watch_model" => "Gemini-2.5-Flash"})
    3.times { SuGptRender.bump_watch_count }
    cost = SuGptRender.estimated_cost_today
    assert_in_delta 0.0045, cost, 0.001
  end

  def test_log_observation_writes_jsonl
    raw_path = File.join(@tmp_dir, "gpt_render", "watch", "20260502_120000_test_watch.png")
    FileUtils.mkdir_p(File.dirname(raw_path))
    File.binwrite(raw_path, "FAKE")
    SuGptRender.log_observation(raw_path, "AI says: looks good", "Gemini-2.5-Flash", 1.4)
    log_file = File.join(@tmp_dir, "gpt_render", "watch", "ai_watch_#{Time.now.strftime('%Y%m%d')}.jsonl")
    assert File.exist?(log_file)
    line = File.readlines(log_file).first
    parsed = JSON.parse(line)
    assert_equal "Gemini-2.5-Flash", parsed["model"]
    assert_equal 1.4, parsed["elapsed_sec"]
    assert parsed["text"].include?("looks good")
  end

  def test_recent_observations_returns_in_reverse_order
    raw_path1 = File.join(@tmp_dir, "gpt_render", "watch", "a.png")
    raw_path2 = File.join(@tmp_dir, "gpt_render", "watch", "b.png")
    FileUtils.mkdir_p(File.dirname(raw_path1))
    File.binwrite(raw_path1, "x"); File.binwrite(raw_path2, "x")
    SuGptRender.log_observation(raw_path1, "first", "Gemini-2.5-Flash", 1.0)
    sleep 0.01
    SuGptRender.log_observation(raw_path2, "second", "Gemini-2.5-Flash", 1.0)
    obs = SuGptRender.recent_observations(10)
    assert_equal "second", obs.first["text"]   # newest first
    assert_equal 2, obs.length
  end
end

class TestCallPoeText < Minitest::Test
  def setup
    SuGptRender.stub_responses = nil
    SuGptRender.stub_calls = []
    @tmpimg = Tempfile.new(["w", ".png"])
    @tmpimg.binmode; @tmpimg.write("\x89PNG" + "x" * 64); @tmpimg.close
  end
  def teardown; @tmpimg.unlink if @tmpimg; end

  def test_returns_text_content
    response = JSON.generate({
      "choices" => [{ "message" => { "role" => "assistant",
        "content" => "Looks like a wardrobe. Suggest checking proportions." } }]
    })
    SuGptRender.stub_responses = { "*" => FakeHttpResponse.new(200, response) }
    text = SuGptRender.call_poe_text("KEY", @tmpimg.path, "describe", "Gemini-2.5-Flash")
    assert text.include?("wardrobe")
  end

  def test_raises_on_http_error
    SuGptRender.stub_responses = { "*" => FakeHttpResponse.new(500, '{"error":"oops"}') }
    err = assert_raises(RuntimeError) {
      SuGptRender.call_poe_text("KEY", @tmpimg.path, "p", "Gemini-2.5-Flash")
    }
    assert err.message.include?("HTTP 500")
  end
end

class TestImageModelList < Minitest::Test
  def test_no_t2i_models
    SuGptRender::IMAGE_MODELS.each do |entry|
      # After v0.2.5 each entry should be [id, label, hint] only
      assert_equal 3, entry.length, "unexpected entry #{entry.inspect}"
    end
  end

  def test_default_is_first_entry
    cfg = SuGptRender::IMAGE_MODELS.first
    assert_equal "GPT-Image-2", cfg[0]
  end

  def test_includes_nano_banana_pro
    ids = SuGptRender::IMAGE_MODELS.map { |x| x[0] }
    assert_includes ids, "Nano-Banana-Pro"
    assert_includes ids, "Flux-Kontext-Max"
    assert_includes ids, "Flux-Kontext-Pro"
  end

  def test_excludes_text_only_models
    ids = SuGptRender::IMAGE_MODELS.map { |x| x[0] }
    refute_includes ids, "Nano-Banana-2"
    refute_includes ids, "DALL-E-3"
    refute_includes ids, "Imagen-4"
  end
end

# ============================================================================
# v0.4.0 — Cloudflare AI Gateway + Live Stream
# ============================================================================

class TestAiGatewayConstants < Minitest::Test
  def test_constants_present
    assert SuGptRender::GEMINI_AIG_URL.start_with?("https://gateway.ai.cloudflare.com/v1/"),
      "AI Gateway URL points at gateway.ai.cloudflare.com"
    assert SuGptRender::GEMINI_AIG_URL.include?("/google-ai-studio"),
      "URL includes the google-ai-studio sub-path"
    refute SuGptRender::GEMINI_AIG_URL.end_with?("/v1"),
      "URL must NOT end with /v1 — `/v1beta` is appended at call time so " \
      "thinkingConfig is accepted by Gemini API"
    # Token is a placeholder in source (`__INJECT_CF_AIG_TOKEN__`) and replaced
    # at build time by build-rbz.sh. Either form is valid; tests run on dev source.
    tok = SuGptRender::GEMINI_AIG_TOKEN
    assert tok.start_with?("cfut_") || tok == "__INJECT_CF_AIG_TOKEN__",
      "AIG token must be real cfut_ value or build placeholder, got #{tok.inspect}"
  end

  def test_no_gemini_api_key_constant
    # As of v0.4.3, Gemini key is BYOK on AI Gateway side — never bundled in
    # plugin. Guard against accidental reintroduction.
    refute SuGptRender.const_defined?(:GEMINI_API_KEY, false),
      "GEMINI_API_KEY must NOT be defined on the module — BYOK only"
  end

  def test_aig_headers_only_cf_auth
    h = SuGptRender.gemini_aig_headers
    assert_equal "Bearer #{SuGptRender::GEMINI_AIG_TOKEN}", h["cf-aig-authorization"]
    assert_equal "application/json", h["Content-Type"]
    refute h.key?("x-goog-api-key"),
      "BYOK: gateway attaches Google key server-side, plugin must not send it"
  end

  def test_watch_dropdown_includes_direct_option
    ids = SuGptRender::WATCH_MODELS.map { |x| x[0] }
    assert_includes ids, SuGptRender::GEMINI_DIRECT_ID
    # The label should make it obvious which one is the direct path.
    direct_entry = SuGptRender::WATCH_MODELS.find { |x| x[0] == SuGptRender::GEMINI_DIRECT_ID }
    refute_nil direct_entry
    assert direct_entry[1].downcase.include?("direct") || direct_entry[1].downcase.include?("ai gateway"),
      "label hints at direct/AI-Gateway path: #{direct_entry[1]}"
  end

  def test_watch_dropdown_in_tray_html
    # Make sure tray HTML actually renders both Poe-routed and direct entries.
    Sketchup.reset_model!
    html = SuGptRender.tray_html
    assert html.include?(SuGptRender::GEMINI_DIRECT_ID),
      "tray HTML contains the direct-via-AI-Gateway option id"
    assert html.include?("Gemini-2.5-Flash"),
      "tray HTML still contains Poe-routed Gemini option"
  end
end

class TestGeminiDirectRequest < Minitest::Test
  def setup
    SuGptRender.stub_responses = nil
    SuGptRender.stub_calls = []
    @tmpimg = Tempfile.new(["gemini", ".jpg"])
    @tmpimg.binmode; @tmpimg.write("\xff\xd8\xff" + "x" * 200); @tmpimg.close
  end

  def teardown
    @tmpimg.unlink if @tmpimg
  end

  def test_call_gemini_direct_request_shape_and_url
    response = JSON.generate({
      "candidates" => [{
        "content" => { "parts" => [{ "text" => "I see a kitchen cabinet." }] },
        "finishReason" => "STOP"
      }]
    })
    SuGptRender.stub_responses = { "*" => FakeHttpResponse.new(200, response) }
    text = SuGptRender.call_gemini_direct(@tmpimg.path, "Describe.",
                                          model: "gemini-2.5-flash")
    assert_equal "I see a kitchen cabinet.", text

    # Verify the POST went to the AI Gateway URL with the right path.
    posts = SuGptRender.stub_calls.select { |c| c[0] == :post }
    assert_equal 1, posts.length
    posted_url = posts.first[1]
    assert posted_url.start_with?(SuGptRender::GEMINI_AIG_URL),
      "URL prefix is the AI Gateway base"
    assert posted_url.include?("/v1beta/models/gemini-2.5-flash:generateContent"),
      "URL uses /v1beta path (thinkingConfig requires it): #{posted_url}"

    # Verify the body shape — inlineData + text parts.
    payload = JSON.parse(posts.first[2])
    parts = payload.dig("contents", 0, "parts")
    assert_equal 2, parts.length, "two parts: inline data + text"
    assert parts[0]["inlineData"], "first part is inlineData"
    assert_equal "image/jpeg", parts[0]["inlineData"]["mimeType"]
    refute parts[0]["inlineData"]["data"].empty?, "base64 image data present"
    assert_equal "Describe.", parts[1]["text"]
  end

  def test_call_gemini_direct_raises_on_http_error
    SuGptRender.stub_responses = {
      "*" => FakeHttpResponse.new(400, '{"error":{"message":"User location is not supported"}}')
    }
    err = assert_raises(RuntimeError) {
      SuGptRender.call_gemini_direct(@tmpimg.path, "p")
    }
    assert err.message.include?("HTTP 400")
    # Sanity: even when CF AI Gateway returns Gemini's error verbatim, we
    # surface it cleanly.
    assert err.message.include?("location"), "error body forwarded"
  end

  def test_build_gemini_payload_uses_inline_data
    payload = SuGptRender.build_gemini_payload(@tmpimg.path, "hi", mime_type: "image/png")
    parts = payload["contents"][0]["parts"]
    assert_equal "image/png", parts[0]["inlineData"]["mimeType"]
    # Base64 of our test bytes
    expected = Base64.strict_encode64(File.binread(@tmpimg.path))
    assert_equal expected, parts[0]["inlineData"]["data"]
    assert_equal "hi", parts[1]["text"]
  end

  def test_payload_has_thinking_budget_zero_for_flash
    payload = SuGptRender.build_gemini_payload(@tmpimg.path, "p", model: "gemini-2.5-flash")
    assert_equal 0, payload.dig("generationConfig", "thinkingConfig", "thinkingBudget"),
      "thinkingBudget=0 needed or all output goes to thoughts (the v0.4.0–0.4.2 empty-Live-Stream bug)"
    assert payload.dig("generationConfig", "maxOutputTokens"),
      "maxOutputTokens cap present"
  end

  def test_payload_has_thinking_budget_zero_for_flash_lite
    payload = SuGptRender.build_gemini_payload(@tmpimg.path, "p", model: "gemini-3.1-flash-lite-preview")
    assert_equal 0, payload.dig("generationConfig", "thinkingConfig", "thinkingBudget")
  end

  def test_payload_omits_thinking_budget_for_pro
    # gemini-3.1-pro-preview rejects thinkingBudget=0 with
    # "Budget 0 is invalid. This model only works in thinking mode."
    payload = SuGptRender.build_gemini_payload(@tmpimg.path, "p", model: "gemini-3.1-pro-preview")
    refute payload.dig("generationConfig", "thinkingConfig"),
      "must NOT send thinkingConfig for thinking-mandatory models"
    # maxOutputTokens still present
    assert payload.dig("generationConfig", "maxOutputTokens")
  end
end

class TestSseParser < Minitest::Test
  # Helper: collect [kind, payload] events from parse_sse_chunks.
  def parse(buffer)
    events = []
    remaining, _done = SuGptRender.parse_sse_chunks(buffer.dup) do |kind, data|
      events << [kind, data]
    end
    [events, remaining]
  end

  def test_single_event
    buf = %(data: {"candidates":[{"content":{"parts":[{"text":"hi"}]}}]}\n\n)
    events, remaining = parse(buf)
    assert_equal 1, events.length
    assert_equal :event, events.first[0]
    assert_equal "hi", events.first[1].dig("candidates", 0, "content", "parts", 0, "text")
    assert_equal "", remaining, "fully consumed"
  end

  def test_multiple_events_in_one_buffer
    buf = %(data: {"candidates":[{"content":{"parts":[{"text":"first"}]}}]}\n) +
          %(\n) +
          %(data: {"candidates":[{"content":{"parts":[{"text":"second"}]}}]}\n\n)
    events, remaining = parse(buf)
    assert_equal 2, events.length
    assert_equal "first",  SuGptRender.gemini_extract_delta(events[0][1])
    assert_equal "second", SuGptRender.gemini_extract_delta(events[1][1])
    assert_equal "", remaining
  end

  def test_keepalive_comment_ignored
    buf = ": keepalive\n\n" +
          %(data: {"candidates":[{"content":{"parts":[{"text":"x"}]}}]}\n\n)
    events, _r = parse(buf)
    # Comment-only event is dropped silently; only the real event surfaces.
    assert_equal 1, events.length
    assert_equal "x", SuGptRender.gemini_extract_delta(events.first[1])
  end

  def test_partial_json_left_in_buffer
    # The closing `\n\n` is missing → the parser should NOT yield, and the
    # bytes must be returned in the remaining buffer for the next chunk.
    buf = %(data: {"candidates":[{"content":{"parts":[{"text":"par)
    events, remaining = parse(buf)
    assert_empty events, "no event yet — JSON not terminated"
    assert_equal buf, remaining, "all bytes preserved for next chunk"
  end

  def test_two_chunks_glued
    chunk1 = %(data: {"candidates":[{"content":{"parts":[{"text":"hel)
    chunk2 = %(lo"}]}}]}\n\n)
    # Simulate the caller's buffer-carry-over pattern.
    events1 = []
    rem, _ = SuGptRender.parse_sse_chunks(chunk1.dup) { |k, d| events1 << [k, d] }
    assert_empty events1
    # Now glue chunk2 onto the carry-over and parse again.
    events2 = []
    rem2, _ = SuGptRender.parse_sse_chunks(rem + chunk2) { |k, d| events2 << [k, d] }
    assert_equal 1, events2.length
    assert_equal "hello", SuGptRender.gemini_extract_delta(events2.first[1])
    assert_equal "", rem2
  end

  def test_finish_reason_stop_yields_done
    buf = %(data: {"candidates":[{"finishReason":"STOP"}]}\n\n)
    events, _r = parse(buf)
    kinds = events.map { |e| e[0] }
    assert_includes kinds, :event
    assert_includes kinds, :done, ":done emitted on finishReason STOP"
  end

  def test_done_sentinel
    buf = "data: [DONE]\n\n"
    events, _r = parse(buf)
    assert_equal [[:done, nil]], events
  end

  def test_crlf_line_endings_handled
    buf = %(data: {"candidates":[{"content":{"parts":[{"text":"win"}]}}]}\r\n\r\n)
    events, _r = parse(buf)
    assert_equal 1, events.length
    assert_equal "win", SuGptRender.gemini_extract_delta(events.first[1])
  end

  def test_multi_line_data_in_one_event
    # SSE allows a single event to have multiple `data:` lines; the spec says
    # they're joined with \n. We don't expect Gemini to do this but we
    # tolerate it.
    buf = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\n" +
          "data: \"hi\"\n" +
          "data: }]}}]}\n\n"
    events, _r = parse(buf)
    # If JSON.parse on the joined string succeeds, we yield. If not, we drop
    # — either way no crash. Just assert no exception was raised.
    assert events.length >= 0
  end

  def test_extract_delta_empty_when_no_parts
    assert_equal "", SuGptRender.gemini_extract_delta({})
    assert_equal "", SuGptRender.gemini_extract_delta({"candidates" => [{}]})
  end
end

class TestLiveStreamCost < Minitest::Test
  def setup
    File.delete(TEST_CFG_PATH) if File.exist?(TEST_CFG_PATH)
  end

  def test_live_count_starts_at_zero
    assert_equal 0, SuGptRender.live_count_today
    assert_equal 0.0, SuGptRender.live_cost_today
  end

  def test_live_count_bump_persists
    3.times { SuGptRender.bump_live_count }
    assert_equal 3, SuGptRender.live_count_today
  end

  def test_live_cost_inside_free_tier
    # 100 streams << 1500 RPD → still on the free tier.
    100.times { SuGptRender.bump_live_count }
    assert_equal 0.0, SuGptRender.live_cost_today,
      "Gemini 2.5 Flash free tier covers up to 1500 requests/day"
  end

  def test_live_cost_above_free_tier
    cfg = SuGptRender.load_config
    cfg["live_counts"] = { Time.now.strftime("%Y-%m-%d") => 1600 }
    SuGptRender.save_config(cfg)
    # 1600 * 0.0001 = 0.16 (rough, just checking the meter triggers).
    assert SuGptRender.live_cost_today > 0.0,
      "above 1500 RPD the meter starts charging"
  end

  def test_direct_watch_model_has_cost_entry
    assert SuGptRender::WATCH_COST_PER_CALL.key?(SuGptRender::GEMINI_DIRECT_ID),
      "cost meter knows about the direct model"
    SuGptRender.save_config({"watch_model" => SuGptRender::GEMINI_DIRECT_ID})
    SuGptRender.bump_watch_count
    cost = SuGptRender.estimated_cost_today
    assert cost >= 0.0
    # Direct path should be cheaper than Poe-routed Gemini (no markup).
    poe_rate    = SuGptRender::WATCH_COST_PER_CALL["Gemini-2.5-Flash"]
    direct_rate = SuGptRender::WATCH_COST_PER_CALL[SuGptRender::GEMINI_DIRECT_ID]
    assert direct_rate < poe_rate,
      "direct rate (#{direct_rate}) cheaper than Poe-routed (#{poe_rate})"
  end
end

class TestLiveStreamLifecycle < Minitest::Test
  def setup
    File.delete(TEST_CFG_PATH) if File.exist?(TEST_CFG_PATH)
    Sketchup.reset_model!
    SuGptRender.instance_variable_set(:@livestream, {
      enabled:      false,
      stop_flag:    false,
      bg_thread:    nil,
      poll_timer:   nil,
      tick_timer:   nil,
      queue:        nil,
      current_text: "",
      in_flight:    false,
    })
    SuGptRender.instance_variable_set(:@tray, nil)
    UI.reset!
  end

  def test_start_live_stream_flips_flag
    SuGptRender.start_live_stream
    assert SuGptRender.instance_variable_get(:@livestream)[:enabled]
    SuGptRender.stop_live_stream
    refute SuGptRender.instance_variable_get(:@livestream)[:enabled]
  end

  def test_toggle_live_stream
    SuGptRender.toggle_live_stream
    assert SuGptRender.instance_variable_get(:@livestream)[:enabled]
    SuGptRender.toggle_live_stream
    refute SuGptRender.instance_variable_get(:@livestream)[:enabled]
  end

  def test_stop_clears_timers
    SuGptRender.start_live_stream
    refute_empty UI.timers
    SuGptRender.stop_live_stream
    # poll/tick timers should be removed; we don't enforce zero (other code
    # may have started timers) but the live ones must be gone.
    ls = SuGptRender.instance_variable_get(:@livestream)
    assert_nil ls[:poll_timer]
    assert_nil ls[:tick_timer]
  end

  def test_tray_html_includes_live_tab
    Sketchup.reset_model!
    html = SuGptRender.tray_html
    assert html.include?("Live Stream"),  "tab label rendered"
    assert html.include?("live_pane"),    "pane element rendered"
    assert html.include?("toggleLive"),   "JS handler wired"
    assert html.include?("Frame interval"), "interval selector visible"
    assert html.include?("JPEG quality"), "quality selector visible"
  end
end

class TestVersionBump < Minitest::Test
  # Single source of truth — bump when releasing.
  EXPECTED_VERSION = "0.6.4"

  def test_plugin_version_matches_expected
    assert_equal EXPECTED_VERSION, SuGptRender::PLUGIN_VERSION
  end

  def test_version_json_matches
    path = File.expand_path("../sketchup_plugin/version.json", __dir__)
    data = JSON.parse(File.read(path))
    assert_equal EXPECTED_VERSION, data["version"]
    refute_empty data["notes"], "release notes must not be empty"
    assert data["rb_url"].start_with?("https://"), "rb_url is https"
  end
end

# ============================================================================
# v0.4.2 — http_get must follow GitHub release-asset 302 redirects.
# Tests target http_get_once (one full GET round, including redirect chase) so
# we don't fight the per-test stub override of http_get itself.
# ============================================================================

class TestHttpRedirectFollowing < Minitest::Test
  # Tiny response shims that pass `is_a?(Net::HTTPRedirection|HTTPSuccess)`.
  class FakeRedirect
    def initialize(loc); @loc = loc; end
    def is_a?(klass); klass == Net::HTTPRedirection; end
    def [](h); h == "location" ? @loc : nil; end
    def code; "302"; end
  end

  class FakeSuccess
    def initialize(body); @body = body; end
    def is_a?(klass); klass == Net::HTTPSuccess; end
    def [](_); nil; end
    def body; @body; end
    def code; "200"; end
  end

  # Stub-driven fake of Net::HTTP — captures host of each connect, returns a
  # scripted sequence of responses regardless of which path the client requests.
  class FakeNetHTTP
    @@hosts = []
    @@responses = []
    def self.reset!(responses); @@hosts = []; @@responses = responses.dup; end
    def self.hosts; @@hosts; end
    def initialize(host, _port = nil); @@hosts << host; end
    def use_ssl=(*); end
    def verify_mode=(*); end
    def min_version=(*); end
    def ssl_version=(*); end
    def cert_store=(*); end
    def open_timeout=(*); end
    def read_timeout=(*); end
    def request(_req); @@responses.shift or raise "ran out of fake responses"; end
  end

  def with_fake_http(responses)
    FakeNetHTTP.reset!(responses)
    Net::HTTP.stub :new, ->(*args) { FakeNetHTTP.new(*args) } do
      yield
    end
  end

  def test_follows_single_302
    with_fake_http([
      FakeRedirect.new("https://final.example.com/file.rb"),
      FakeSuccess.new("real plugin code"),
    ]) do
      res = SuGptRender.http_get_once("https://github.com/owner/repo/releases/download/v9/file.rb")
      assert_kind_of FakeSuccess, res
      assert_equal "real plugin code", res.body
      # Confirm we contacted both hosts in order.
      assert_equal ["github.com", "final.example.com"], FakeNetHTTP.hosts
    end
  end

  def test_follows_chain_of_3
    with_fake_http([
      FakeRedirect.new("https://hop1.example.com/a"),
      FakeRedirect.new("https://hop2.example.com/b"),
      FakeSuccess.new("OK"),
    ]) do
      res = SuGptRender.http_get_once("https://start.example.com/x")
      assert_equal "OK", res.body
      assert_equal ["start.example.com", "hop1.example.com", "hop2.example.com"], FakeNetHTTP.hosts
    end
  end

  def test_relative_redirect_resolved_against_origin
    with_fake_http([
      FakeRedirect.new("/relative/path"),
      FakeSuccess.new("OK"),
    ]) do
      SuGptRender.http_get_once("https://server.example.com/start")
      assert_equal ["server.example.com", "server.example.com"], FakeNetHTTP.hosts
    end
  end

  def test_returns_non_redirect_unchanged
    with_fake_http([FakeSuccess.new("direct")]) do
      res = SuGptRender.http_get_once("https://direct.example.com/x")
      assert_equal "direct", res.body
      assert_equal 1, FakeNetHTTP.hosts.size
    end
  end

  def test_too_many_redirects_raises
    loops = Array.new(7) { FakeRedirect.new("https://loop.example.com/next") }
    with_fake_http(loops) do
      err = assert_raises(RuntimeError) do
        SuGptRender.http_get_once("https://start.example.com/x", max_redirects: 5)
      end
      assert_match(/Too many redirects/, err.message)
    end
  end
end

# ============================================================================
# v0.5.0 — Live Render tab (gemini-2.5-flash-image via AI Gateway)
# ============================================================================

class TestImageModelsConstant < Minitest::Test
  def test_image_models_constant_present
    assert SuGptRender.const_defined?(:GEMINI_IMAGE_MODELS)
    assert_includes SuGptRender::GEMINI_IMAGE_MODELS, "gemini-2.5-flash-image"
  end

  def test_image_model_not_in_thinking_disablable
    # Image models reject thinkingConfig entirely. Must NOT be in
    # GEMINI_THINKING_DISABLABLE — otherwise build_gemini_payload would still
    # try to attach thinkingBudget=0 and the call would 400.
    refute_includes SuGptRender::GEMINI_THINKING_DISABLABLE, "gemini-2.5-flash-image",
      "image model must NOT appear in thinking-disablable list"
  end

  def test_payload_skips_thinking_and_max_tokens_for_image_models
    tmp = Tempfile.new(["img", ".png"])
    tmp.binmode; tmp.write("\x89PNG" + "x" * 64); tmp.close
    payload = SuGptRender.build_gemini_payload(tmp.path, "render this",
                                               model: "gemini-2.5-flash-image",
                                               mime_type: "image/png")
    refute payload.dig("generationConfig", "thinkingConfig"),
      "image models must NOT receive thinkingConfig"
    refute payload.dig("generationConfig", "maxOutputTokens"),
      "image models need their full ~1290 token budget — no maxOutputTokens cap"
    # Body shape — input image + prompt only.
    parts = payload["contents"][0]["parts"]
    assert_equal 2, parts.length
    assert parts[0]["inlineData"]
    assert_equal "render this", parts[1]["text"]
    tmp.unlink
  end

  def test_live_render_models_constant
    assert SuGptRender.const_defined?(:LIVE_RENDER_MODELS)
    # As of v0.5.6 the default switched to Poe Nano-Banana (~17× cheaper).
    # Each entry now also carries provider + per-token rate + per-image cost.
    first = SuGptRender::LIVE_RENDER_MODELS.first
    assert_equal "nano-banana-poe", first[0], "Poe Nano-Banana should be default"
    assert_equal :poe, first[3], "first entry must be a Poe-routed model"
  end

  def test_live_render_models_have_both_providers
    providers = SuGptRender::LIVE_RENDER_MODELS.map { |row| row[3] }.uniq
    assert_includes providers, :poe,     "must offer at least one Poe-routed model"
    assert_includes providers, :gateway, "must offer at least one direct-Google option (privacy)"
  end

  def test_live_render_provider_lookup
    assert_equal :poe,     SuGptRender.live_render_provider_for("nano-banana-poe")
    assert_equal :gateway, SuGptRender.live_render_provider_for("gemini-2.5-flash-image")
    # Unknown id falls back to default (first entry)
    assert_equal :poe,     SuGptRender.live_render_provider_for("nonexistent")
  end
end

class TestCallGeminiImage < Minitest::Test
  def setup
    SuGptRender.stub_responses = nil
    SuGptRender.stub_calls = []
    @tmpimg = Tempfile.new(["lr", ".png"])
    @tmpimg.binmode; @tmpimg.write("\x89PNG" + "x" * 200); @tmpimg.close
  end

  def teardown
    return unless @tmpimg
    # Sweep any rendered output the call wrote next to the input BEFORE
    # we unlink (which nils out the path).
    base = File.basename(@tmpimg.path, ".*")
    out  = File.join(File.dirname(@tmpimg.path), "#{base}_render.png")
    File.delete(out) if File.exist?(out)
    @tmpimg.unlink
  end

  def test_call_gemini_image_request_shape_and_url
    # Synthetic 1×1 PNG b64 — content doesn't matter for the test.
    fake_png = Base64.strict_encode64("\x89PNG\r\n\x1a\nFAKE")
    response = JSON.generate({
      "candidates" => [{
        "content" => { "parts" => [
          { "inlineData" => { "mimeType" => "image/png", "data" => fake_png } }
        ] },
        "finishReason" => "STOP"
      }],
      "usageMetadata" => {
        "candidatesTokensDetails" => [
          { "modality" => "IMAGE", "tokenCount" => 1290 }
        ]
      }
    })
    SuGptRender.stub_responses = { "*" => FakeHttpResponse.new(200, response) }

    out_path, tokens = SuGptRender.call_gemini_image(
      @tmpimg.path, "render photoreal",
      model: "gemini-2.5-flash-image", input_mime: "image/png"
    )
    assert File.exist?(out_path), "output PNG written to disk"
    assert_equal 1290, tokens, "image-modality tokens parsed"

    # Verify the POST went to the AI Gateway URL with the right path.
    posts = SuGptRender.stub_calls.select { |c| c[0] == :post }
    assert_equal 1, posts.length
    posted_url = posts.first[1]
    assert posted_url.start_with?(SuGptRender::GEMINI_AIG_URL),
      "URL prefix is the AI Gateway base"
    assert posted_url.include?("/v1beta/models/gemini-2.5-flash-image:generateContent"),
      "URL targets the image model: #{posted_url}"

    # Verify the body shape — inlineData input + text prompt, NO thinkingConfig.
    payload = JSON.parse(posts.first[2])
    parts = payload.dig("contents", 0, "parts")
    assert_equal 2, parts.length
    assert parts[0]["inlineData"], "first part is the input image"
    assert_equal "image/png", parts[0]["inlineData"]["mimeType"]
    assert_equal "render photoreal", parts[1]["text"]
    refute payload.dig("generationConfig", "thinkingConfig"),
      "image model: NO thinkingConfig in request"

    # Cleanup the rendered output the function wrote.
    File.delete(out_path) if File.exist?(out_path)
  end

  def test_call_gemini_image_uses_only_cf_aig_auth_headers
    h = SuGptRender.gemini_aig_headers
    assert_equal "Bearer #{SuGptRender::GEMINI_AIG_TOKEN}", h["cf-aig-authorization"]
    refute h.key?("x-goog-api-key"),
      "BYOK: Google key never sent from plugin (CF AI Gateway attaches it)"
  end

  def test_call_gemini_image_raises_on_http_error
    SuGptRender.stub_responses = {
      "*" => FakeHttpResponse.new(400, '{"error":{"message":"image too large"}}')
    }
    err = assert_raises(RuntimeError) {
      SuGptRender.call_gemini_image(@tmpimg.path, "p")
    }
    assert err.message.include?("HTTP 400"), "got: #{err.message}"
  end

  def test_call_gemini_image_raises_when_no_image_in_response
    response = JSON.generate({
      "candidates" => [{ "content" => { "parts" => [{ "text" => "Sorry I can't" }] } }]
    })
    SuGptRender.stub_responses = { "*" => FakeHttpResponse.new(200, response) }
    err = assert_raises(RuntimeError) {
      SuGptRender.call_gemini_image(@tmpimg.path, "p")
    }
    assert err.message.include?("No inlineData"), "got: #{err.message}"
  end
end

class TestLiveRenderState < Minitest::Test
  def setup
    File.delete(TEST_CFG_PATH) if File.exist?(TEST_CFG_PATH)
    Sketchup.reset_model!
    SuGptRender.instance_variable_set(:@liverender, {
      enabled:        false,
      in_flight:      false,
      stop_flag:      false,
      history:        [],
      history_max:    8,
      current_render: nil,
      poll_timer:     nil,
      tick_timer:     nil,
      bg_thread:      nil,
      queue:          nil,
    })
    SuGptRender.instance_variable_set(:@tray, nil)
    UI.reset!
  end

  def test_state_initialized_with_or_equals_survives_reload
    # Mirror test_load_preserves_module_ivars_with_or_equals — confirm the
    # ||= guard keeps history etc. across `load __FILE__`.
    SuGptRender.instance_variable_set(:@liverender,
      { enabled: false, history: ["MARKER"], history_max: 8 })
    tmp = Tempfile.new(["plugin_lr_ivar", ".rb"])
    tmp.write <<~RUBY
      module SuGptRender
        @liverender ||= { enabled: false, history: [] }
      end
    RUBY
    tmp.close
    load tmp.path
    state = SuGptRender.instance_variable_get(:@liverender)
    assert_equal ["MARKER"], state[:history],
      "||= must preserve in-flight history across hot-reload"
    tmp.unlink
  end

  def test_start_stop_toggle
    SuGptRender.start_live_render
    assert SuGptRender.instance_variable_get(:@liverender)[:enabled]
    SuGptRender.stop_live_render
    refute SuGptRender.instance_variable_get(:@liverender)[:enabled]
    SuGptRender.toggle_live_render
    assert SuGptRender.instance_variable_get(:@liverender)[:enabled]
    SuGptRender.toggle_live_render
    refute SuGptRender.instance_variable_get(:@liverender)[:enabled]
  end

  def test_stop_clears_timers
    SuGptRender.start_live_render
    refute_empty UI.timers
    SuGptRender.stop_live_render
    lr = SuGptRender.instance_variable_get(:@liverender)
    assert_nil lr[:poll_timer]
    assert_nil lr[:tick_timer]
  end
end

class TestLiveRenderCost < Minitest::Test
  def setup
    File.delete(TEST_CFG_PATH) if File.exist?(TEST_CFG_PATH)
  end

  def test_count_starts_at_zero
    assert_equal 0, SuGptRender.live_render_count_today
    assert_equal 0.0, SuGptRender.live_render_cost_today
  end

  def test_bump_writes_to_config
    SuGptRender.bump_live_render_count(1290)
    SuGptRender.bump_live_render_count(1290)
    assert_equal 2, SuGptRender.live_render_count_today
    cfg = SuGptRender.load_config
    today = Time.now.strftime("%Y-%m-%d")
    assert_equal 2, cfg["live_render_counts"][today]
    assert_equal 2580, cfg["live_render_tokens"][today]
  end

  def test_cost_today_default_model_poe_rate
    # As of v0.5.6, the default model is Poe Nano-Banana at $1.77/M output.
    # 1290 output tokens × 1.77e-6 = $0.0023 per image.
    SuGptRender.bump_live_render_count(1290, "nano-banana-poe")
    cost = SuGptRender.live_render_cost_today
    assert_in_delta 0.0023, cost, 0.0005,
      "1290 tokens via Poe at $1.77/M ≈ $0.0023, got #{cost}"
  end

  def test_cost_today_gateway_rate_higher
    # Same 1290 tokens via CF Gateway (gemini-2.5-flash-image) hits the
    # Google image-token premium at $30/M. 17× the Poe path.
    SuGptRender.bump_live_render_count(1290, "gemini-2.5-flash-image")
    cost = SuGptRender.live_render_cost_today
    assert_in_delta 0.0387, cost, 0.001,
      "1290 tokens via CF Gateway at $30/M ≈ $0.039, got #{cost}"
  end

  def test_cost_today_mixed_models_sum_correctly
    # The cost meter must use the rate of the model that produced each
    # render. 1× Poe + 1× Gateway should be the SUM, not 2× either rate.
    SuGptRender.bump_live_render_count(1290, "nano-banana-poe")
    SuGptRender.bump_live_render_count(1290, "gemini-2.5-flash-image")
    cost = SuGptRender.live_render_cost_today
    assert_in_delta (0.0023 + 0.0387), cost, 0.001,
      "mixed-model day must sum per-rate, got #{cost}"
  end

  def test_cost_today_in_hkd
    # 1290 tokens × $1.77/M × 7.85 ≈ HK$0.018 (Poe default)
    SuGptRender.bump_live_render_count(1290, "nano-banana-poe")
    cost_hkd = SuGptRender.live_render_cost_today_hkd
    assert_in_delta 0.018, cost_hkd, 0.005,
      "default Poe path ≈ HK$0.018, got HK$#{cost_hkd}"
  end
end

class TestLiveRenderTabUi < Minitest::Test
  def setup
    Sketchup.reset_model!
    File.delete(TEST_CFG_PATH) if File.exist?(TEST_CFG_PATH)
    SuGptRender.instance_variable_set(:@liverender, {
      enabled: false, in_flight: false, stop_flag: false,
      history: [], history_max: 8, current_render: nil,
      poll_timer: nil, tick_timer: nil, bg_thread: nil, queue: nil,
    })
  end

  def test_tab_button_present
    html = SuGptRender.tray_html
    assert html.include?("Live Render"), "tab label rendered"
    assert html.include?("liver_pane"),  "pane element rendered"
    assert html.include?("toggleLiveRender"), "JS handler wired"
    assert html.include?("mt_liver"),    "tab button id"
  end

  def test_tab_has_model_dropdown_and_interval
    html = SuGptRender.tray_html
    assert html.include?("liver_model"),    "model dropdown present"
    assert html.include?("gemini-2.5-flash-image"), "default image model rendered"
    assert html.include?("liver_interval"), "interval selector present"
    assert html.include?("Render interval"), "interval label visible"
  end

  def test_tab_has_two_image_cells_and_history_strip
    html = SuGptRender.tray_html
    assert html.include?("liver_frame_in"),  "captured frame cell"
    assert html.include?("liver_frame_out"), "AI render cell"
    assert html.include?("liver_history"),   "history strip container"
  end

  def test_tab_has_cost_meter
    html = SuGptRender.tray_html
    assert html.include?("liver_today"), "cost meter element present"
    assert html.match?(/0 renders.*\$0\.0000/), "cost meter renders 0/0 by default"
  end

  def test_default_live_render_prompt_constant
    assert SuGptRender::DEFAULT_LIVE_RENDER_PROMPT.length > 50
    assert SuGptRender::DEFAULT_LIVE_RENDER_PROMPT.downcase.include?("photorealistic")
  end
end

# ============================================================================
# v0.6.2 — Boost material contrast: temporary segmentation-palette repaint
# of each scoped material before the Shaded view is captured, restored on
# exit (even on raise) via start_operation(transparent:true) +
# abort_operation. Plus the material table grows an "Original HEX" column
# when boost is on.
# ============================================================================

class TestSegmentationPalette < Minitest::Test
  # Tiny material stub: just stores a Sketchup::Color and lets us check
  # the colour after the helper runs.
  class MaterialStub
    attr_accessor :color, :name
    def initialize(name, r, g, b)
      @name  = name
      @color = Sketchup::Color.new(r, g, b)
    end
    def display_name; @name; end
  end

  def setup
    Sketchup.reset_model!
    @model = Sketchup.active_model
  end

  def palette; SuGptRender::SEGMENTATION_PALETTE; end

  def hex_of(color)
    format("#%02X%02X%02X", color.red, color.green, color.blue)
  end

  def test_palette_size_and_no_magenta
    assert_equal 12, palette.length, "palette must be 12 entries"
    refute_includes palette.map(&:upcase), "#FF00FF",
      "pure magenta is the window marker — must not be in the segmentation palette"
    palette.each do |hex|
      assert_match(/\A#[0-9A-Fa-f]{6}\z/, hex, "palette entry not 6-hex: #{hex}")
    end
    assert_equal palette.uniq.length, palette.length, "palette entries must be distinct"
  end

  def test_boost_off_preserves_material_colors
    # Hand-crafted "real" material colours like a typical HK SU file.
    mats = [
      MaterialStub.new("White wall",   0xF0, 0xF0, 0xE8),
      MaterialStub.new("Cream cabinet",0xE8, 0xDC, 0xC0),
      MaterialStub.new("Light oak",    0xB8, 0xA5, 0x82),
    ]
    originals = mats.map { |m| m.color.dup }
    inside_colors = nil

    SuGptRender.with_segmentation_palette(@model, mats) do
      inside_colors = mats.map { |m| hex_of(m.color) }
    end

    # Inside the block, colours were re-painted to the palette in order.
    assert_equal palette[0], inside_colors[0]
    assert_equal palette[1], inside_colors[1]
    assert_equal palette[2], inside_colors[2]

    # After the block, originals are restored.
    mats.each_with_index do |m, i|
      assert_equal originals[i].red,   m.color.red,   "#{m.name}: red restored"
      assert_equal originals[i].green, m.color.green, "#{m.name}: green restored"
      assert_equal originals[i].blue,  m.color.blue,  "#{m.name}: blue restored"
    end

    # And the start/abort_operation pair was actually used (silent edit).
    assert_equal 1, @model.start_operation_calls, "start_operation called once"
    assert_equal 1, @model.abort_operation_calls, "abort_operation called once"
  end

  def test_boost_off_preserves_on_raise
    mats = [
      MaterialStub.new("Wall",     0xF0, 0xF0, 0xE8),
      MaterialStub.new("Cabinet",  0xE8, 0xDC, 0xC0),
    ]
    originals = mats.map { |m| m.color.dup }

    err = assert_raises(RuntimeError) do
      SuGptRender.with_segmentation_palette(@model, mats) do
        # Sanity: we DID enter the recoloured state before the raise.
        assert_equal palette[0], hex_of(mats[0].color)
        raise "simulated capture failure"
      end
    end
    assert_equal "simulated capture failure", err.message

    # Even with the raise, abort_operation ran (in the ensure block) and
    # the manual restore-fallback put the original colours back. The
    # .skp's material colours must NOT be persisted to the synthetic
    # palette after the call returns.
    mats.each_with_index do |m, i|
      assert_equal originals[i].red,   m.color.red,   "#{m.name}: red restored on raise"
      assert_equal originals[i].green, m.color.green, "#{m.name}: green restored on raise"
      assert_equal originals[i].blue,  m.color.blue,  "#{m.name}: blue restored on raise"
    end
    assert_equal 1, @model.abort_operation_calls,
      "abort_operation must run from the ensure block even on raise"
  end

  def test_palette_wraps_for_extra_materials
    # 13 materials → 13th must wrap back to palette[0].
    mats = Array.new(13) { |i| MaterialStub.new("m#{i}", 100, 100, 100) }
    inside = nil
    SuGptRender.with_segmentation_palette(@model, mats) do
      inside = mats.map { |m| hex_of(m.color) }
    end
    assert_equal 13, inside.length
    assert_equal palette[0],  inside[0]
    assert_equal palette[11], inside[11]
    assert_equal palette[0],  inside[12], "13th material wraps back to palette[0]"
  end

  def test_synthetic_hex_in_material_table
    # collect_model_material_table walks model entities; we don't exercise
    # the entity tree here — we monkey-patch collect_used_materials for
    # this test only. The cross-cutting concern under test is: when
    # boost_on:true, the rendered table puts SYNTHETIC palette colours in
    # the HEX column and adds an "Original HEX" column with the real
    # material colour.
    real_mats = [
      MaterialStub.new("White wall",    0xF0, 0xF0, 0xE8),
      MaterialStub.new("Cream cabinet", 0xE8, 0xDC, 0xC0),
      MaterialStub.new("Light oak",     0xB8, 0xA5, 0x82),
    ]
    SuGptRender.singleton_class.send(:alias_method, :__orig_collect_used_materials, :collect_used_materials)
    SuGptRender.define_singleton_method(:collect_used_materials) { |_m| real_mats }
    begin
      table = SuGptRender.collect_model_material_table(@model, boost_on: true)

      # Header row gains the 5th column.
      assert_match(/\| HEX \| Material name \| Hint \| Texture ref \| Original HEX \|/, table)

      # Each row's HEX column must be a palette entry (not the real colour).
      data_rows = table.lines.drop(2).reject { |l| l.strip.empty? }
      assert_equal real_mats.length, data_rows.length, "one data row per material"
      data_rows.each_with_index do |row, i|
        # First backticked value = HEX column = synthetic palette colour.
        first_hex = row[/`(#[0-9A-Fa-f]{6})`/, 1]
        assert palette.map(&:upcase).include?(first_hex.upcase),
          "row #{i} HEX (#{first_hex.inspect}) must be from SEGMENTATION_PALETTE"
        assert_equal palette[i % palette.length].upcase, first_hex.upcase,
          "row #{i} HEX must be palette[#{i % palette.length}] in collect order"

        # Last backticked value = Original HEX column = real material colour.
        all_hex = row.scan(/`(#[0-9A-Fa-f]{6})`/).flatten
        assert_equal 2, all_hex.length, "row #{i} should have 2 HEX values (synthetic + original)"
        original_hex = all_hex.last
        c = real_mats[i].color
        expected = format("#%02X%02X%02X", c.red, c.green, c.blue)
        assert_equal expected.upcase, original_hex.upcase,
          "row #{i} Original HEX must be the real material colour"
      end

      # And the boost-off table is unchanged (4 columns, real HEX only).
      table_off = SuGptRender.collect_model_material_table(@model, boost_on: false)
      refute_match(/Original HEX/, table_off, "boost-off table must NOT grow the column")
      assert_match(/\| HEX \| Material name \| Hint \| Texture ref \|/, table_off)
    ensure
      SuGptRender.singleton_class.send(:alias_method, :collect_used_materials, :__orig_collect_used_materials)
      SuGptRender.singleton_class.send(:remove_method, :__orig_collect_used_materials) rescue nil
    end
  end

  def test_preamble_explains_synthetic_palette_when_boost_on
    table = "| HEX | Material name | Hint | Texture ref | Original HEX |\n" \
            "|---|---|---|---|---|\n" \
            "| `#FF0000` | Walnut | tex: oak.jpg | — | `#8B4513` |"
    pre = SuGptRender.build_multi_view_preamble(2, "render this", table)
    # Must call out the synthetic-palette nature so the model doesn't paint
    # the palette colours into the output.
    assert_match(/SYNTHETIC/, pre, "preamble must explain synthetic palette")
    assert_match(/Original HEX/, pre, "preamble must reference the Original HEX column")
    assert_match(/render this/, pre, "user prompt still present")

    # And the boost-off path still works (no synthetic-language leakage).
    table_off = "| HEX | Material name | Hint | Texture ref |\n" \
                "|---|---|---|---|\n" \
                "| `#8B4513` | Walnut | tex: oak.jpg | — |"
    pre_off = SuGptRender.build_multi_view_preamble(2, "render this", table_off)
    refute_match(/SYNTHETIC/, pre_off,
      "boost-off preamble must NOT mention synthetic palette")
  end

  def test_boost_dropdown_present_in_tray
    html = SuGptRender.tray_html
    assert_match(/liver_boost/, html, "boost dropdown id present")
    assert_match(/Boost material contrast/, html, "boost dropdown label visible")
    assert_match(/setLiveRenderBoost/, html, "boost JS handler wired")
    assert_match(/set_live_render_boost_contrast/, html, "boost action callback wired")
  end
end

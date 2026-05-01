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
end

# ============================================================================

class TestTrayHtml < Minitest::Test
  def test_tray_html_returns_string_no_exception
    File.delete(TEST_CFG_PATH) if File.exist?(TEST_CFG_PATH)
    Sketchup.reset_model!
    html = SuGptRender.tray_html
    assert_kind_of String, html
    assert html.include?("<!doctype html>"), "looks like html"
    assert html.include?("GPT Render"),       "has plugin name"
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

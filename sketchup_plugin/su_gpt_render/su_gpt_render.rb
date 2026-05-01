# su_gpt_render.rb — SketchUp 插件：current view → Poe GPT-Image-2 → enhanced image
# v0.2 — V-Ray style tray + async (non-blocking) + auto-update check

require 'sketchup.rb'
require 'fileutils'
require 'json'
require 'net/http'
require 'uri'
require 'base64'
require 'cgi'
require 'openssl'
require 'time'
require 'thread'   # Queue used by Live Stream main↔bg thread handoff

module SuGptRender
  PLUGIN_NAME    = "GPT Render"
  PLUGIN_VERSION = "0.4.2"
  POE_ENDPOINT   = "https://api.poe.com/v1/chat/completions"
  CONFIG_PATH    = File.expand_path("~/.sketchup_su_gpt_render.json")

  # ---- Gemini via Cloudflare AI Gateway -------------------------------------
  # Direct google-ai-studio call from HK fails with 400 "User location not
  # supported" (Gemini geo-blocks HK IPs). A vanilla CF Worker proxy ALSO
  # fails because CF colo selection follows client IP (HK→HKG colo→HK egress).
  # Cloudflare AI Gateway is the working path: it runs on CF managed infra
  # and egresses through non-HK IPs. Empirically verified from HK with HTTP
  # 200, 1.3-1.6s latency, and SSE streaming works.
  #
  # Two secrets below are placeholders in source — replaced at .rbz build time
  # by sketchup_plugin/build-rbz.sh from $CF_AIG_TOKEN / $GEMINI_API_KEY env.
  # Source on GitHub stays clean; secrets only land in shipped .rbz / release
  # asset .rb (which are also the URL the auto-update flow fetches).
  # Bundled in-plugin is internal-deploy-only; accepted leak risk per the firm.
  GEMINI_AIG_URL   = "https://gateway.ai.cloudflare.com/v1/945eb571b27f72d3ad419c2468313f6f/hohome-gemini/google-ai-studio/v1"
  GEMINI_AIG_TOKEN = "__INJECT_CF_AIG_TOKEN__"
  GEMINI_API_KEY   = "__INJECT_GEMINI_API_KEY__"

  # Sentinel id used in WATCH_MODELS dropdown to mean "go through AI Gateway
  # directly to Gemini 2.5 Flash, bypass Poe". Cheaper since no Poe markup.
  GEMINI_DIRECT_ID = "gemini-2.5-flash-direct"

  # Vision models for AI Watch (text+image → text). First entry = default.
  # The "*-direct" id is the sentinel for AI-Gateway-routed Gemini (see
  # GEMINI_DIRECT_ID); all other ids are Poe model ids.
  WATCH_MODELS = [
    [GEMINI_DIRECT_ID,       "Gemini 2.5 Flash (direct via AI Gateway)", "Google · 直連 · 最平"],
    ["Gemini-2.5-Flash",     "Gemini 2.5 Flash",   "Google · 平 + 快 · 推薦"],
    ["Seed-2.0-Mini",        "Seed 2.0 Mini",      "ByteDance · 最便宜"],
    ["Seed-2.0-Pro",         "Seed 2.0 Pro",       "ByteDance · flagship"],
    ["Gemini-3.1-Pro",       "Gemini 3.1 Pro",     "Google · 最強 reasoning · 較貴"],
    ["GPT-5.2",              "GPT-5.2",            "OpenAI 旗艦"],
    ["GPT-4o",               "GPT-4o",             "OpenAI"],
    ["Claude-Sonnet-4.5",    "Claude Sonnet 4.5",  "Anthropic"],
    ["Claude-Opus-4.7",      "Claude Opus 4.7",    "Anthropic flagship"],
    ["Qwen3-VL-235B-A22B-T", "Qwen 3-VL",          "阿里 · GUI-aware"],
  ]

  DEFAULT_WATCH_PROMPT = <<~P.strip
    你係一個 senior interior designer，依家睇住有人喺 SketchUp 入面畫嘢。
    用 2-3 句**繁體中文**簡單講：
    1. 你見到佢喺度畫緊乜（櫃／房／傢俬／layout）
    2. 有冇結構問題（unclosed face、奇怪比例、漏咗組件）
    3. 一個實用 suggestion

    保持簡短，香港裝修術語為佳。
  P

  # Poe image models — image-editing only (accepts text+image → image).
  # Each: [poe_id, label, hint]. First entry is the default.
  IMAGE_MODELS = [
    ["GPT-Image-2",        "GPT-Image-2",         "OpenAI · 最強 prompt adherence"],
    ["Nano-Banana-Pro",    "Nano-Banana Pro",     "Google · Gemini 3 Pro Image · ⭐ 最新"],
    ["Nano-Banana",        "Nano-Banana",         "Google · Gemini 2.5 Flash · 多語言文字"],
    ["Flux-Kontext-Max",   "FLUX Kontext Max",    "BFL · 編輯最強旗艦"],
    ["Flux-Kontext-Pro",   "FLUX Kontext Pro",    "BFL · 專為 edit · 保結構好"],
    ["FLUX-2-Max",         "FLUX 2 Max",          "BFL · 多參考圖旗艦"],
    ["FLUX-2-Pro",         "FLUX 2 Pro",          "BFL · 多參考圖"],
    ["FLUX-2-Flex",        "FLUX 2 Flex",         "BFL · 大尺寸"],
    ["FLUX-2-Dev",         "FLUX 2 Dev",          "BFL · open-weight"],
    ["FLUX-Krea",          "FLUX Krea",           "BFL · Aesthetic tuned"],
    ["GPT-Image-1.5",      "GPT-Image-1.5",       "OpenAI · ChatGPT default"],
    ["GPT-Image-1",        "GPT-Image-1",         "OpenAI · 經濟"],
    ["GPT-Image-1-Mini",   "GPT-Image-1 Mini",    "OpenAI · 最平 · 快"],
    ["seededit-3.0",       "Seededit 3.0",        "Bytedance · edit"],
    ["ideogram",           "Ideogram",            "IdeogramAI"],
    ["ideogram-v2",        "Ideogram v2",         "IdeogramAI v2"],
    ["qwen-edit",          "Qwen Edit",           "Alibaba edit"],
    ["sketch-to-image",    "Sketch-to-Image",     "Convert sketch → photo"],
  ]

  # Set this to a JSON URL to enable auto-update. The JSON should have:
  #   { "version": "0.3.0", "rb_url": "https://.../su_gpt_render.rb", "notes": "..." }
  # Leave nil to disable auto-update entirely.
  UPDATE_MANIFEST_URL = "https://raw.githubusercontent.com/hohomehk/sketchupdrawing/main/sketchup_plugin/version.json"

  DEFAULT_PROMPT = <<~PROMPT.strip
    Transform this 3D architectural rendering into a photorealistic interior photograph
    for a Hong Kong residential project.

    CRITICAL: Preserve the exact cabinet shape, position, dimensions, shelving layout,
    and overall geometry — do NOT change the structure or proportions.

    Add: realistic light oak wood grain texture on cabinets, soft warm white walls
    with subtle texture, light wooden floor with natural grain, soft even ambient lighting
    (no harsh shadows), modern clean minimal Hong Kong residential style.
    Do NOT add furniture, decor, plants, or human figures.

    Output aspect ratio 3:2, high quality.
  PROMPT

  # Built-in prompt templates. User can also save their own (stored in config).
  BUILTIN_TEMPLATES = [
    {
      "name" => "HK Residential — Light Oak (default)",
      "prompt" => DEFAULT_PROMPT,
    },
    {
      "name" => "Walnut Luxury — Hotel Suite",
      "prompt" => <<~P.strip,
        Transform this 3D architectural rendering into a photorealistic interior photograph
        of a luxury 5-star hotel suite.

        CRITICAL: Preserve the exact cabinet shape, position, dimensions, shelving layout,
        and overall geometry — do NOT change the structure or proportions.

        Add: rich dark walnut wood grain texture with visible figure, beige/champagne textured walls,
        dark hardwood herringbone floor, warm golden hour lighting from soft directional source,
        cinematic ambient occlusion, slight film grain. Modern luxury minimalist aesthetic.
        Do NOT add furniture, decor, plants, or human figures.

        Output aspect ratio 3:2, high quality.
      P
    },
    {
      "name" => "Marble Bathroom — Soft White",
      "prompt" => <<~P.strip,
        Transform this 3D architectural rendering into a photorealistic interior photograph
        of a clean modern bathroom.

        CRITICAL: Preserve all cabinet/vanity shapes, dimensions, layout — do NOT change the structure.

        Add: white Carrara marble with grey veining for vanity tops and walls, brushed nickel fixtures,
        soft white wall paint, light grey large-format porcelain floor, gentle daylight from window,
        subtle reflective surfaces, fresh and bright atmosphere. Modern hotel bathroom style.
        Do NOT add furniture, decor, plants, or human figures.

        Output aspect ratio 3:2, high quality.
      P
    },
    {
      "name" => "Nordic Minimal — Cool Grey",
      "prompt" => <<~P.strip,
        Transform this 3D architectural rendering into a photorealistic Scandinavian-style interior.

        CRITICAL: Preserve the exact cabinet shape, dimensions, layout — do NOT change the structure.

        Add: light Nordic ash wood with subtle grain on cabinets, cool light grey walls,
        light grey concrete-look floor, diffuse cool natural daylight, soft shadow falloff,
        clean minimal Scandinavian aesthetic. Hygge atmosphere with calm restrained palette.
        Do NOT add furniture, decor, plants, or human figures.

        Output aspect ratio 3:2, high quality.
      P
    },
    {
      "name" => "Cabinet Shop — Technical Accurate",
      "prompt" => <<~P.strip,
        Render this 3D model as a technical product photograph for a cabinet shop drawing.

        CRITICAL: Preserve EVERY cabinet shape, dimension, shelving line, panel proportion,
        and detail line EXACTLY. Do NOT add or remove any structural element. Do NOT smooth
        away technical detail. The output must be dimensionally accurate.

        Style: studio softbox lighting, even illumination, neutral white background,
        light maple wood texture, clean factory-photo aesthetic. No environment or context.
        Do NOT add walls, floor, ceiling, or any room context — just the cabinet on a soft white sweep.

        Output aspect ratio 3:2, high quality.
      P
    },
    {
      "name" => "Showroom — Retail Display",
      "prompt" => <<~P.strip,
        Transform this 3D rendering into a photoreal retail showroom display photograph.

        CRITICAL: Preserve cabinet structure, shelving, dimensions exactly.

        Add: polished concrete floor with subtle reflection, dark grey gallery walls,
        directional spotlights highlighting the cabinet, dramatic but clean lighting,
        product-photography aesthetic, professional editorial finish.
        Do NOT add furniture, decor, plants, or human figures.

        Output aspect ratio 3:2, high quality.
      P
    },
    {
      "name" => "Office — Modern Workspace",
      "prompt" => <<~P.strip,
        Transform this 3D rendering into a photorealistic modern office interior photograph.

        CRITICAL: Preserve all cabinet/storage geometry exactly.

        Add: light walnut veneer cabinetry, smooth white acoustic ceiling, light grey carpet
        tiles, subtle daylight from large windows, minimal blue accent on signage details,
        clean corporate aesthetic. Architectural photography style.
        Do NOT add desks, chairs, computers, plants, or human figures.

        Output aspect ratio 3:2, high quality.
      P
    },
  ]

  # ------ config -------------------------------------------------------------
  def self.load_config
    return {} unless File.exist?(CONFIG_PATH)
    JSON.parse(File.read(CONFIG_PATH)) rescue {}
  end

  def self.save_config(cfg)
    File.write(CONFIG_PATH, JSON.pretty_generate(cfg))
  end

  def self.get_api_key
    cfg = load_config
    key = cfg["poe_api_key"]
    if key.nil? || key.strip.empty?
      input = UI.inputbox(
        ["Poe API Key (poe.com/api_key)"],
        [""],
        "#{PLUGIN_NAME} — first-time setup"
      )
      return nil unless input
      key = input.first.to_s.strip
      return nil if key.empty?
      cfg["poe_api_key"] = key
      save_config(cfg)
    end
    key
  end

  # ------ render current view to PNG ----------------------------------------
  def self.export_view(width, height)
    model = Sketchup.active_model
    view = model.active_view

    base = model.path.empty? ? "Untitled" : File.basename(model.path, ".skp")
    base = base.gsub(/[^\w一-鿿\-]/, "_")
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    out_dir = if model.path.empty?
                File.expand_path("~/Desktop/gpt_render")
              else
                File.join(File.dirname(model.path), "gpt_render")
              end
    FileUtils.mkdir_p(out_dir)

    raw_path = File.join(out_dir, "#{timestamp}_#{base}_raw.png")
    options = {
      filename:    raw_path,
      width:       width,
      height:      height,
      antialias:   true,
      transparent: false,
    }
    success = view.write_image(options)
    raise "Failed to write_image" unless success
    raw_path
  end

  # ------ HTTPS plumbing -----------------------------------------------------
  # Configures Net::HTTP for SketchUp's bundled Ruby/OpenSSL which ships with
  # quirky defaults. Forces TLS 1.2+, picks a sensible CA bundle, and lets the
  # user opt out of cert verification as a last resort (config: verify_ssl=false).
  def self.configure_http(http, scheme)
    http.read_timeout = 180
    http.open_timeout = 30
    if scheme == "https"
      http.use_ssl = true
      begin
        # Force a modern TLS — SU's old OpenSSL otherwise tries SSL3/TLS1.0
        # which Cloudflare (Poe's CDN) drops mid-handshake.
        http.min_version = OpenSSL::SSL::TLS1_2_VERSION if defined?(OpenSSL::SSL::TLS1_2_VERSION)
      rescue NoMethodError, NameError
        # very old OpenSSL — fall back to ssl_version
        http.ssl_version = :TLSv1_2 rescue nil
      end
      cfg = load_config
      if cfg["verify_ssl"] == false
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      else
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        # If user supplied a CA bundle path, use it
        if cfg["ca_file"] && File.exist?(cfg["ca_file"])
          http.ca_file = cfg["ca_file"]
        elsif ENV["SSL_CERT_FILE"] && File.exist?(ENV["SSL_CERT_FILE"])
          http.ca_file = ENV["SSL_CERT_FILE"]
        end
      end
    end
    http
  end

  # POST with retry on transient SSL / connection errors.
  def self.http_post_json(url, headers, body, attempts: 3)
    uri = URI.parse(url)
    last_err = nil
    attempts.times do |i|
      http = Net::HTTP.new(uri.host, uri.port)
      configure_http(http, uri.scheme)
      req = Net::HTTP::Post.new(uri.request_uri)
      headers.each { |k, v| req[k] = v }
      req.body = body
      begin
        return http.request(req)
      rescue OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::EPIPE, Net::OpenTimeout, Net::ReadTimeout, EOFError => e
        last_err = e
        sleep(1.5 + i * 2.5) unless i == attempts - 1
      end
    end
    raise "HTTPS failed after #{attempts} attempts: #{last_err.class}: #{last_err.message}\n\nIf this persists, try Set SSL Verify (off) in the menu."
  end

  def self.http_get(url, attempts: 3, max_redirects: 5)
    last_err = nil
    attempts.times do |i|
      begin
        return http_get_once(url, max_redirects: max_redirects)
      rescue OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::EPIPE, Net::OpenTimeout, Net::ReadTimeout, EOFError => e
        last_err = e
        sleep(1.0 + i * 2.0) unless i == attempts - 1
      end
    end
    raise "HTTPS GET failed: #{last_err.class}: #{last_err.message}"
  end

  # GitHub release-asset URLs 302 → release-assets.githubusercontent.com CDN.
  # Without redirect-following, auto-update silently fails — version.json's
  # rb_url stopped pointing at raw main as of v0.4.1.
  def self.http_get_once(url, max_redirects: 5)
    max_redirects.times do |hop|
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      configure_http(http, uri.scheme)
      res = http.request(Net::HTTP::Get.new(uri.request_uri))
      return res unless res.is_a?(Net::HTTPRedirection)
      next_url = res["location"].to_s
      return res if next_url.empty?
      # Resolve relative redirects against the original URL.
      url = URI.join(uri.to_s, next_url).to_s
    end
    raise "Too many redirects (>#{max_redirects})"
  end

  # ------ Poe API call -------------------------------------------------------
  def self.call_poe(api_key, image_path, prompt, model = "GPT-Image-2")
    img_b64 = Base64.strict_encode64(File.binread(image_path))
    payload = {
      "model"    => model,
      "messages" => [{
        "role" => "user",
        "content" => [
          { "type" => "text", "text" => prompt },
          { "type" => "image_url",
            "image_url" => { "url" => "data:image/png;base64,#{img_b64}" } }
        ]
      }],
      "stream"   => false
    }
    res = http_post_json(POE_ENDPOINT,
      { "Authorization" => "Bearer #{api_key}", "Content-Type" => "application/json" },
      JSON.generate(payload))
    unless res.is_a?(Net::HTTPSuccess)
      raise "Poe API HTTP #{res.code}: #{res.body[0,500]}"
    end
    content = JSON.parse(res.body).dig("choices", 0, "message", "content").to_s
    m = content.match(/!\[[^\]]*\]\(([^)\s]+)\)/) ||
        content.match(/(https?:\/\/[^\s)\]]+)/)
    raise "No image URL in response: #{content[0,300]}" unless m
    m[1]
  end

  def self.download(url, out_path)
    res = http_get(url)
    raise "Download HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
    File.binwrite(out_path, res.body)
    out_path
  end

  # Vision (text+image → text) — used by AI Watch. Returns the model's text answer.
  def self.call_poe_text(api_key, image_path, prompt, model)
    img_b64 = Base64.strict_encode64(File.binread(image_path))
    payload = {
      "model" => model,
      "messages" => [{
        "role" => "user",
        "content" => [
          { "type" => "text", "text" => prompt },
          { "type" => "image_url",
            "image_url" => { "url" => "data:image/png;base64,#{img_b64}" } }
        ]
      }],
      "stream" => false
    }
    res = http_post_json(POE_ENDPOINT,
      { "Authorization" => "Bearer #{api_key}", "Content-Type" => "application/json" },
      JSON.generate(payload))
    raise "Poe API HTTP #{res.code}: #{res.body[0,300]}" unless res.is_a?(Net::HTTPSuccess)
    JSON.parse(res.body).dig("choices", 0, "message", "content").to_s
  end

  # ---- Gemini direct (via Cloudflare AI Gateway) ----------------------------

  # Build the request shape Gemini expects: an inlineData image part plus a
  # text part. Used for both non-streaming (AI Watch direct) and streaming
  # (Live Stream tab) requests so the body shape stays identical.
  def self.build_gemini_payload(image_path, prompt, mime_type: "image/jpeg")
    img_b64 = Base64.strict_encode64(File.binread(image_path))
    {
      "contents" => [{
        "parts" => [
          { "inlineData" => { "mimeType" => mime_type, "data" => img_b64 } },
          { "text" => prompt },
        ]
      }]
    }
  end

  # Both auth headers AI Gateway requires. Centralized so tests can verify
  # the request shape and so the streaming + non-streaming paths can't drift.
  def self.gemini_aig_headers
    {
      "cf-aig-authorization" => "Bearer #{GEMINI_AIG_TOKEN}",
      "x-goog-api-key"       => GEMINI_API_KEY,
      "Content-Type"         => "application/json",
    }
  end

  # Non-streaming Gemini call — used by AI Watch when user picks the direct
  # model. Returns the joined text from candidates[0].content.parts[*].text.
  def self.call_gemini_direct(image_path, prompt, model: "gemini-2.5-flash", mime_type: "image/jpeg")
    url = "#{GEMINI_AIG_URL}/models/#{model}:generateContent"
    payload = build_gemini_payload(image_path, prompt, mime_type: mime_type)
    res = http_post_json(url, gemini_aig_headers, JSON.generate(payload))
    unless res.is_a?(Net::HTTPSuccess)
      raise "Gemini AI Gateway HTTP #{res.code}: #{res.body[0,300]}"
    end
    data = JSON.parse(res.body) rescue {}
    parts = data.dig("candidates", 0, "content", "parts") || []
    parts.map { |p| p["text"].to_s }.join.strip
  end

  # Pure-Ruby SSE chunk parser. Feeds incoming HTTP body bytes (which may
  # arrive as partial frames, or multiple frames glued together) and yields
  # one parsed JSON event at a time + a :done sentinel when the stream ends.
  #
  # Returns a `[remaining_buffer, finished?]` tuple so the caller can keep
  # carrying over bytes that didn't form a complete `\n\n`-terminated event.
  #
  # Handles:
  #  - Multiple `data: ...` lines per event (Gemini streams one event per
  #    chunk in practice but we tolerate both).
  #  - `: keepalive` comments (lines starting with `:`).
  #  - Partial JSON across chunks (only emit on complete `\n\n`).
  #  - finishReason "STOP" → mark stream finished, yield :done.
  def self.parse_sse_chunks(buffer)
    finished = false
    # Normalize CRLF → LF so the \n\n splitter works on either platform.
    buffer = buffer.gsub("\r\n", "\n")
    while (idx = buffer.index("\n\n"))
      raw_event = buffer[0...idx]
      buffer    = buffer[(idx + 2)..-1] || ""
      data_lines = []
      raw_event.split("\n").each do |line|
        # SSE comment / keepalive — ignore.
        next if line.empty? || line.start_with?(":")
        if line.start_with?("data:")
          data_lines << line.sub(/\Adata:\s?/, "")
        end
        # Other fields (event:, id:, retry:) — Gemini doesn't use them so
        # we ignore. If they ever appear we just skip silently.
      end
      next if data_lines.empty?
      payload = data_lines.join("\n")
      # Some servers send a literal "[DONE]" sentinel. Gemini doesn't, but
      # it's cheap insurance in case AI Gateway ever wraps it.
      if payload.strip == "[DONE]"
        finished = true
        yield :done, nil
        next
      end
      data = JSON.parse(payload) rescue nil
      next unless data
      yield :event, data
      # Stop sentinel from Gemini.
      if (data.dig("candidates", 0, "finishReason") || "").to_s == "STOP"
        finished = true
        yield :done, data
      end
    end
    [buffer, finished]
  end

  # Walk the candidates list and pull out any text deltas. Gemini streams
  # incremental tokens as candidates[0].content.parts[*].text — the parts
  # array typically contains one text part with the latest delta.
  def self.gemini_extract_delta(event_data)
    parts = event_data.dig("candidates", 0, "content", "parts") || []
    parts.map { |p| p["text"].to_s }.join
  end

  # Streaming Gemini call. Spawns Net::HTTP request + read_body block, calls
  # `on_token` (main thread isn't safe from a Thread, so the caller must
  # marshal back via UI.start_timer or a Queue if needed). For our use we
  # call this from a background Thread and the on_token closure pushes to a
  # Queue that the main UI timer drains.
  def self.stream_gemini(image_path, prompt, model: "gemini-2.5-flash",
                        mime_type: "image/jpeg", &on_token)
    url = "#{GEMINI_AIG_URL}/models/#{model}:streamGenerateContent?alt=sse"
    payload = JSON.generate(build_gemini_payload(image_path, prompt, mime_type: mime_type))
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    configure_http(http, uri.scheme)
    req = Net::HTTP::Post.new(uri.request_uri)
    gemini_aig_headers.each { |k, v| req[k] = v }
    req.body = payload

    buffer    = +""
    finished  = false
    full_text = +""
    err_body  = nil
    http.request(req) do |res|
      if !res.is_a?(Net::HTTPSuccess)
        err_body = +""
        res.read_body { |chunk| err_body << chunk }
        next
      end
      res.read_body do |chunk|
        buffer << chunk
        buffer, done_flag = parse_sse_chunks(buffer) do |kind, data|
          if kind == :event
            delta = gemini_extract_delta(data)
            unless delta.empty?
              full_text << delta
              on_token.call(:token, delta) if on_token
            end
          elsif kind == :done
            on_token.call(:done, full_text) if on_token
          end
        end
        finished ||= done_flag
      end
    end
    if err_body
      raise "Gemini stream HTTP error: #{err_body[0,300]}"
    end
    # If the server closed without an explicit STOP we still report done so
    # the UI can flip out of "streaming" state.
    on_token.call(:done, full_text) if on_token && !finished
    full_text
  end

  # ----- AI Watch ------------------------------------------------------------
  class WatchObserver < Sketchup::ViewObserver
    def onViewChanged(view)
      SuGptRender.on_view_changed
    rescue => e
      puts "[GPT Render] onViewChanged err: #{e.message}"
    end
  end

  def self.start_watching
    cfg = load_config
    # Direct-via-AI-Gateway path needs no Poe key (the CF + Gemini tokens
    # are bundled). Only the Poe-routed models require poe_api_key.
    model = cfg["watch_model"] || WATCH_MODELS.first[0]
    if model != GEMINI_DIRECT_ID && cfg["poe_api_key"].to_s.empty?
      return
    end
    return if @aiwatch[:enabled]
    @aiwatch[:enabled] = true
    @aiwatch[:observer] ||= WatchObserver.new
    model = Sketchup.active_model
    if model
      view = model.active_view
      view.add_observer(@aiwatch[:observer]) rescue nil
    end
    push_watch_state(true)
    push_status("AI Watch: ON", "ok")
    puts "[GPT Render] AI Watch started"
  end

  def self.stop_watching
    return unless @aiwatch[:enabled]
    @aiwatch[:enabled] = false
    if @aiwatch[:pending_timer]
      UI.stop_timer(@aiwatch[:pending_timer])
      @aiwatch[:pending_timer] = nil
    end
    model = Sketchup.active_model
    if model && @aiwatch[:observer]
      model.active_view.remove_observer(@aiwatch[:observer]) rescue nil
    end
    push_watch_state(false)
    push_status("AI Watch: OFF", "ok")
    puts "[GPT Render] AI Watch stopped"
  end

  def self.toggle_watching
    @aiwatch[:enabled] ? stop_watching : start_watching
  end

  def self.on_view_changed
    return unless @aiwatch[:enabled]
    cfg = load_config
    delay = (cfg["watch_delay"] || 15).to_i.clamp(2, 600)
    if @aiwatch[:pending_timer]
      UI.stop_timer(@aiwatch[:pending_timer])
    end
    @aiwatch[:pending_timer] = UI.start_timer(delay, false) do
      @aiwatch[:pending_timer] = nil
      capture_and_analyze
    end
  end

  def self.analyze_now
    cfg = load_config
    model = cfg["watch_model"] || WATCH_MODELS.first[0]
    if model != GEMINI_DIRECT_ID && cfg["poe_api_key"].to_s.empty?
      return
    end
    if @aiwatch[:pending_timer]
      UI.stop_timer(@aiwatch[:pending_timer])
      @aiwatch[:pending_timer] = nil
    end
    capture_and_analyze
  end

  def self.capture_and_analyze
    return if @aiwatch[:bg_thread] && @aiwatch[:bg_thread].alive?
    cfg = load_config
    model = cfg["watch_model"] || WATCH_MODELS.first[0]
    prompt = cfg["watch_prompt"] || DEFAULT_WATCH_PROMPT
    use_direct = (model == GEMINI_DIRECT_ID)

    # Direct-via-AI-Gateway needs no Poe key. Poe path still does.
    api_key = cfg["poe_api_key"].to_s
    if !use_direct && api_key.empty?
      push_watch_status("Set Poe API key first", "err")
      return
    end

    # Smaller resolution for cheap polling
    raw_path = nil
    begin
      raw_path = export_view_for_watch(800, 600)
    rescue => e
      push_watch_status("Capture failed: #{e.message}", "err")
      return
    end

    push_watch_status("Analyzing (#{model})...", "busy")
    started = Time.now

    @aiwatch[:bg_thread] = Thread.new do
      begin
        text = if use_direct
                 # Convert PNG → JPEG-on-disk would need ChunkyPNG / RMagick;
                 # SU's stdlib can't transcode in-process. We just send the
                 # PNG bytes with image/png mime — Gemini accepts both.
                 call_gemini_direct(raw_path, prompt,
                                    model: "gemini-2.5-flash",
                                    mime_type: "image/png")
               else
                 call_poe_text(api_key, raw_path, prompt, model)
               end
        Thread.current[:result] = { ok: true, text: text, raw: raw_path,
                                    model: model, started: started }
      rescue => e
        Thread.current[:result] = { ok: false, error: e.message, raw: raw_path }
      end
    end

    @aiwatch[:bg_poll_timer] = UI.start_timer(0.5, true) do
      if @aiwatch[:bg_thread] && !@aiwatch[:bg_thread].alive?
        UI.stop_timer(@aiwatch[:bg_poll_timer]) if @aiwatch[:bg_poll_timer]
        @aiwatch[:bg_poll_timer] = nil
        result = @aiwatch[:bg_thread][:result]
        @aiwatch[:bg_thread] = nil
        if result[:ok]
          elapsed = (Time.now - result[:started]).round(1)
          log_observation(result[:raw], result[:text], result[:model], elapsed)
          push_watch_observation(result[:raw], result[:text], result[:model], elapsed)
          push_watch_status("Watching (last: #{elapsed}s)", "ok")
        else
          push_watch_status("Watch failed: #{result[:error][0,80]}", "err")
        end
      end
    end
  end

  def self.export_view_for_watch(width, height)
    model = Sketchup.active_model
    raise "No model" unless model
    base = model.path.empty? ? "Untitled" : File.basename(model.path, ".skp")
    base = base.gsub(/[^\w一-鿿\-]/, "_")
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    out_dir = if model.path.empty?
                File.expand_path("~/Desktop/gpt_render/watch")
              else
                File.join(File.dirname(model.path), "gpt_render", "watch")
              end
    FileUtils.mkdir_p(out_dir)
    out_path = File.join(out_dir, "#{timestamp}_#{base}_watch.png")
    success = model.active_view.write_image(filename: out_path, width: width,
                                            height: height, antialias: false,
                                            transparent: false)
    raise "write_image failed" unless success
    out_path
  end

  def self.log_observation(raw_path, text, model, elapsed)
    dir = File.dirname(raw_path)
    log_path = File.join(dir, "ai_watch_#{Time.now.strftime('%Y%m%d')}.jsonl")
    entry = {
      "ts" => Time.now.iso8601,
      "model" => model,
      "elapsed_sec" => elapsed,
      "image" => File.basename(raw_path),
      "text" => text,
    }
    File.open(log_path, "a") { |f| f.puts JSON.generate(entry) }
    # Bump today's count for cost meter
    bump_watch_count
  end

  def self.bump_watch_count
    cfg = load_config
    cfg["watch_counts"] ||= {}
    today = Time.now.strftime("%Y-%m-%d")
    cfg["watch_counts"][today] = (cfg["watch_counts"][today] || 0) + 1
    save_config(cfg)
  end

  def self.watch_count_today
    cfg = load_config
    today = Time.now.strftime("%Y-%m-%d")
    (cfg["watch_counts"] || {})[today] || 0
  end

  # Rough cost estimate per call by model. Real billing varies; this is just for
  # the display on the tray (so user can see if cost is exploding).
  WATCH_COST_PER_CALL = {
    # Direct-via-AI-Gateway path. Gemini 2.5 Flash free tier is $0/$0 up to
    # 1500 requests/day, then $0.10 per 1M input tokens / $0.40 per 1M output.
    # A typical 800x600 JPEG inline image is ~258 tokens (image) + ~80 tokens
    # (prompt) input, ~120 tokens output → ≈ ($0.10·338 + $0.40·120)/1e6 ≈
    # $0.000082. Round up to 0.0001 to keep the daily-meter honest above
    # 1500 RPD without scaring the user inside it.
    GEMINI_DIRECT_ID        => 0.0001,
    "Gemini-2.5-Flash"      => 0.0015,
    "Seed-2.0-Mini"         => 0.0008,
    "Seed-2.0-Pro"          => 0.0040,
    "Gemini-3.1-Pro"        => 0.0150,
    "GPT-5.2"               => 0.0150,
    "GPT-4o"                => 0.0080,
    "Claude-Sonnet-4.5"     => 0.0080,
    "Claude-Opus-4.7"       => 0.0250,
    "Qwen3-VL-235B-A22B-T"  => 0.0036,
  }.freeze

  def self.estimated_cost_today
    n = watch_count_today
    cfg = load_config
    rate = WATCH_COST_PER_CALL[cfg["watch_model"] || WATCH_MODELS.first[0]] || 0.005
    (n * rate).round(4)
  end

  # Recent watch observations from today's JSONL log
  def self.recent_observations(limit = 30)
    dir = history_dir
    return [] unless dir
    log_path = File.join(dir, "watch", "ai_watch_#{Time.now.strftime('%Y%m%d')}.jsonl")
    return [] unless File.exist?(log_path)
    lines = File.readlines(log_path).reverse
    lines.first(limit).map { |l| JSON.parse(l) rescue nil }.compact
  end

  # ----- Live Stream ---------------------------------------------------------

  # Capture the current view as a JPEG with quality knob. Returns the path.
  # SU's view.write_image accepts :jpeg_quality 0.0..1.0 when filename ends
  # with .jpg. Smaller quality → smaller payload → faster SSE first-token.
  def self.export_view_for_stream(width, height, quality_pct)
    model = Sketchup.active_model
    raise "No model" unless model
    base = model.path.empty? ? "Untitled" : File.basename(model.path, ".skp")
    base = base.gsub(/[^\w一-鿿\-]/, "_")
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%L")
    out_dir = if model.path.empty?
                File.expand_path("~/Desktop/gpt_render/stream")
              else
                File.join(File.dirname(model.path), "gpt_render", "stream")
              end
    FileUtils.mkdir_p(out_dir)
    out_path = File.join(out_dir, "#{timestamp}_#{base}_stream.jpg")
    quality_f = (quality_pct.to_f / 100.0).clamp(0.05, 1.0)
    success = model.active_view.write_image(filename: out_path, width: width,
                                            height: height, antialias: false,
                                            transparent: false,
                                            jpeg_quality: quality_f)
    raise "write_image failed" unless success
    out_path
  end

  def self.start_live_stream
    return if @livestream[:enabled]
    @livestream[:enabled]      = true
    @livestream[:stop_flag]    = false
    @livestream[:queue]        = Queue.new
    @livestream[:current_text] = +""
    @livestream[:in_flight]    = false
    cfg = load_config
    interval = (cfg["live_interval"] || 2).to_i.clamp(1, 30)

    push_live_state(true)
    push_live_status("Live stream: ON (#{interval}s)", "ok")

    # Drain queue from main thread (Net::HTTP read_body is on bg thread).
    @livestream[:poll_timer] = UI.start_timer(0.1, true) { drain_live_queue }

    # Capture-and-stream tick. We don't fire a new request while one is
    # in_flight — that would tear the stream and confuse the user.
    @livestream[:tick_timer] = UI.start_timer(0.05, true) do
      if !@livestream[:in_flight] && @livestream[:enabled]
        kick_live_frame
        # Re-arm with the configured interval after each kick.
        UI.stop_timer(@livestream[:tick_timer]) if @livestream[:tick_timer]
        @livestream[:tick_timer] = UI.start_timer(interval, true) do
          kick_live_frame if !@livestream[:in_flight] && @livestream[:enabled]
        end
      end
    end
    puts "[GPT Render] Live stream started"
  end

  def self.stop_live_stream
    return unless @livestream[:enabled]
    @livestream[:enabled]   = false
    @livestream[:stop_flag] = true
    if @livestream[:tick_timer]
      UI.stop_timer(@livestream[:tick_timer]); @livestream[:tick_timer] = nil
    end
    if @livestream[:poll_timer]
      UI.stop_timer(@livestream[:poll_timer]); @livestream[:poll_timer] = nil
    end
    # Don't .join the thread — the read_body block may be mid-chunk and we
    # don't want to block the main UI. Setting stop_flag lets it exit on
    # its next chunk; the GIL will clean up after that.
    @livestream[:bg_thread] = nil
    @livestream[:queue]     = nil
    @livestream[:in_flight] = false
    push_live_state(false)
    push_live_status("Live stream: OFF", "ok")
    puts "[GPT Render] Live stream stopped"
  end

  def self.toggle_live_stream
    @livestream[:enabled] ? stop_live_stream : start_live_stream
  end

  def self.kick_live_frame
    return unless @livestream[:enabled]
    return if @livestream[:in_flight]
    cfg = load_config
    prompt  = cfg["live_prompt"] || cfg["watch_prompt"] || DEFAULT_WATCH_PROMPT
    quality = (cfg["live_quality"] || 60).to_i
    width   = (cfg["live_width"]   || 800).to_i
    height  = (cfg["live_height"]  || 600).to_i

    raw_path = nil
    begin
      raw_path = export_view_for_stream(width, height, quality)
    rescue => e
      push_live_status("Capture failed: #{e.message}", "err")
      return
    end
    push_live_frame(raw_path)
    @livestream[:in_flight] = true
    @livestream[:current_text] = +""
    push_live_status("Streaming…", "busy")

    @livestream[:bg_thread] = Thread.new do
      q = @livestream[:queue]
      begin
        stream_gemini(raw_path, prompt,
                      model: "gemini-2.5-flash",
                      mime_type: "image/jpeg") do |kind, payload|
          # Bail out cooperatively if user hit Stop mid-stream.
          break if @livestream[:stop_flag]
          q << [kind, payload] if q
        end
      rescue => e
        q << [:err, e.message] if q
      ensure
        q << [:flight_done, nil] if q
      end
    end
  end

  # Drain queue. Runs on main UI thread via UI.start_timer.
  def self.drain_live_queue
    q = @livestream[:queue]
    return unless q
    until q.empty?
      kind, payload = q.pop(true) rescue break
      case kind
      when :token
        @livestream[:current_text] << payload.to_s
        push_live_token(payload.to_s, @livestream[:current_text])
      when :done
        push_live_done(@livestream[:current_text])
        log_live_observation(@livestream[:current_text])
        bump_live_count
      when :err
        push_live_status("Stream error: #{payload.to_s[0,120]}", "err")
      when :flight_done
        @livestream[:in_flight] = false
      end
    end
  end

  # Persist a streamed observation alongside the watch JSONL but in its
  # own log so the meters don't double-count.
  def self.log_live_observation(text)
    dir = history_dir
    return unless dir
    out_dir = File.join(dir, "stream")
    FileUtils.mkdir_p(out_dir)
    log_path = File.join(out_dir, "live_stream_#{Time.now.strftime('%Y%m%d')}.jsonl")
    File.open(log_path, "a") { |f|
      f.puts JSON.generate({
        "ts"    => Time.now.iso8601,
        "model" => "gemini-2.5-flash",
        "text"  => text,
      })
    }
  end

  def self.bump_live_count
    cfg = load_config
    cfg["live_counts"] ||= {}
    today = Time.now.strftime("%Y-%m-%d")
    cfg["live_counts"][today] = (cfg["live_counts"][today] || 0) + 1
    save_config(cfg)
  end

  def self.live_count_today
    cfg = load_config
    today = Time.now.strftime("%Y-%m-%d")
    (cfg["live_counts"] || {})[today] || 0
  end

  # Cost estimate for live stream. gemini-2.5-flash free tier is $0/$0 input
  # and output up to 1500 RPD; beyond that, $0.10/M input, $0.40/M output.
  # Per call: ~338 input tokens + ~120 output ≈ $0.000082 → 0.0001 rounded.
  def self.live_cost_today
    n = live_count_today
    rate = n > 1500 ? 0.0001 : 0.0
    (n * rate).round(4)
  end

  # ------ tray dialog --------------------------------------------------------
  # Use ||= so that `load __FILE__` (hot-reload) preserves these references.
  # If we used = the load would reset @tray to nil and we'd lose the live dialog.
  @tray                  ||= nil
  @bg_thread             ||= nil
  @bg_timer              ||= nil
  @initial_update_timer  ||= nil
  @recurring_update_timer ||= nil
  @update_thread         ||= nil
  @update_poll_timer     ||= nil
  # AI Watch state
  @aiwatch               ||= {
    enabled:        false,
    pending_timer:  nil,
    observer:       nil,
    bg_thread:      nil,
    bg_poll_timer:  nil,
  }
  # Live Stream state — separate tab, no debounce, SSE token-by-token output
  # via Cloudflare AI Gateway → Gemini streamGenerateContent.
  #   :enabled       — true while streaming
  #   :stop_flag     — Mutex-protected boolean the bg thread polls every chunk
  #   :bg_thread     — the streaming Thread (one in flight at a time)
  #   :poll_timer    — UI timer that drains :queue onto the tray
  #   :tick_timer    — recurring frame trigger between calls
  #   :queue         — Thread::Queue of [:token|:done|:err, payload]
  #   :tokens_today  — counters for cost meter (input/output tokens approx)
  @livestream            ||= {
    enabled:       false,
    stop_flag:     false,
    bg_thread:     nil,
    poll_timer:    nil,
    tick_timer:    nil,
    queue:         nil,
    current_text:  "",
    in_flight:     false,
  }

  def self.tray_html
    cfg = load_config
    prompt_chars = (cfg["prompt"] || DEFAULT_PROMPT).length
    has_key = !(cfg["poe_api_key"].to_s.strip.empty?)
    width = cfg["width"] || 1536
    height = cfg["height"] || 1024
    selected_model = cfg["model"] || IMAGE_MODELS.first[0]
    history_html = render_history_html
    history_count = count_history

    # AI Watch state for HTML
    aiw_enabled = @aiwatch && @aiwatch[:enabled] ? true : false
    aiw_model = cfg["watch_model"] || WATCH_MODELS.first[0]
    aiw_delay = cfg["watch_delay"] || 15
    aiw_today = watch_count_today
    aiw_cost = estimated_cost_today
    aiw_feed_html = render_watch_feed_html
    aiw_model_options = WATCH_MODELS.map { |id, label, hint|
      sel = (id == aiw_model) ? " selected" : ""
      "<option value=\"#{id}\"#{sel}>#{CGI.escapeHTML(label)} — #{CGI.escapeHTML(hint)}</option>"
    }.join("\n")

    # Live Stream state for HTML
    live_enabled  = @livestream && @livestream[:enabled] ? true : false
    live_interval = (cfg["live_interval"] || 2).to_i
    live_quality  = (cfg["live_quality"]  || 60).to_i
    live_today    = live_count_today
    live_cost     = live_cost_today

    model_options_html = IMAGE_MODELS.map { |id, label, hint|
      sel = (id == selected_model) ? " selected" : ""
      "<option value=\"#{id}\"#{sel} title=\"#{CGI.escapeHTML(hint)}\">#{CGI.escapeHTML(label)} — #{CGI.escapeHTML(hint)}</option>"
    }.join("\n")

    <<~HTML
      <!doctype html><html><head><meta charset="utf-8">
      <style>
        * { box-sizing: border-box; }
        body { margin:0; padding:12px; font-family:-apple-system,"Helvetica Neue","PingFang HK","Microsoft JhengHei",sans-serif; font-size:13px; background:#1d1d1d; color:#ddd; }
        .head { display:flex; align-items:center; justify-content:space-between; margin-bottom:10px; }
        .head h1 { margin:0; font-size:14px; font-weight:600; }
        .head .ver { font-size:11px; opacity:.5; }
        .row { margin-bottom:10px; }
        button { background:#2a2a2a; color:#eee; border:1px solid #3a3a3a; padding:8px 14px; border-radius:5px; cursor:pointer; font-size:13px; }
        button:hover { background:#353535; border-color:#555; }
        button.primary { background:#2c80c0; border-color:#2c80c0; color:#fff; font-weight:600; padding:10px 18px; }
        button.primary:hover { background:#3590d0; }
        button.primary:disabled { opacity:.5; cursor:not-allowed; }
        button.small { font-size:11px; padding:5px 9px; }
        .grid { display:grid; grid-template-columns: 1fr 1fr; gap:6px; }
        input[type=number] { background:#2a2a2a; color:#eee; border:1px solid #3a3a3a; padding:5px 8px; border-radius:4px; width:100%; font-size:13px; }
        label { display:flex; flex-direction:column; gap:3px; font-size:11px; opacity:.7; }
        #status { padding:8px 10px; background:#222; border-radius:4px; border-left:3px solid #555; font-size:12px; min-height:18px; margin-bottom:10px; }
        #status.busy { border-color:#f80; color:#fc6; }
        #status.ok { border-color:#5c5; color:#cfc; }
        #status.err { border-color:#c44; color:#fcc; }
        .preview { background:#0a0a0a; border:1px solid #2a2a2a; border-radius:4px; padding:6px; margin-bottom:10px; min-height:120px; position:relative; }
        .preview img { width:100%; display:block; border-radius:3px; cursor:zoom-in; transition:opacity .12s; }
        .preview img:hover { opacity:.85; }
        .preview img:after { content:"🔍 click to open full size"; position:absolute; }
        .preview .hint { position:absolute; bottom:10px; right:10px; background:rgba(0,0,0,.7); color:#fff; font-size:10px; padding:3px 7px; border-radius:3px; pointer-events:none; opacity:0; transition:opacity .15s; }
        .preview:hover .hint { opacity:1; }
        .preview .empty { padding:20px; text-align:center; opacity:.4; font-size:11px; }
        select { background:#2a2a2a; color:#eee; border:1px solid #3a3a3a; padding:5px 8px; border-radius:4px; width:100%; font-size:13px; }
        /* sub-tabs (Enhanced/Raw) */
        .tabs { display:flex; gap:4px; margin-bottom:6px; }
        .tabs button { padding:5px 10px; font-size:11px; background:#222; }
        .tabs button.active { background:#2c80c0; }
        /* main top-level tabs (Render/History) */
        .maintabs { display:flex; gap:0; margin:0 -12px 12px -12px; padding:0 12px; border-bottom:1px solid #2a2a2a; }
        .maintabs button { background:transparent; border:none; border-bottom:2px solid transparent; padding:9px 14px; color:#888; font-size:13px; font-weight:500; border-radius:0; cursor:pointer; }
        .maintabs button.active { color:#fff; border-bottom-color:#2c80c0; }
        .maintabs button:hover:not(.active) { color:#bbb; }
        .maintabs button .badge { display:inline-block; background:#3a3a3a; color:#bbb; font-size:10px; padding:1px 6px; border-radius:8px; margin-left:6px; }
        .maintabs button.active .badge { background:#2c80c0; color:#fff; }
        .pane { display:none; }
        .pane.active { display:block; }
        /* History pane bigger thumbs */
        #history_pane .history { max-height:none; }
        #history_pane .history img { width:96px; height:64px; }
        #history_pane .history .item { padding:8px 0; }
        #history_pane .history .meta .ts { font-size:13px; }
        #history_pane .history .meta .sub { font-size:11px; }
        #history_pane .empty-history { padding:40px 20px; text-align:center; opacity:.5; }
        #history_pane .empty-history .icon { font-size:32px; margin-bottom:10px; }
        /* Prompts tab */
        #prompts_pane .empty-history { padding:24px 20px; text-align:center; opacity:.5; }
        #prompts_pane .empty-history .icon { font-size:24px; margin-bottom:8px; }
        .tpl-item { display:flex; gap:8px; padding:8px; align-items:flex-start; border:1px solid #2a2a2a; border-radius:5px; margin-bottom:6px; background:#222; }
        .tpl-item:hover { border-color:#3a3a3a; }
        .tpl-item .tpl-meta { flex:1; min-width:0; }
        .tpl-item .tpl-name { font-size:12px; font-weight:600; color:#ddd; margin-bottom:3px; }
        .tpl-item .tpl-preview { font-size:11px; opacity:.55; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
        .tpl-item button.small { padding:4px 8px; font-size:11px; flex-shrink:0; }
        .tpl-item button.danger { background:#3a1a1a; border-color:#5a2a2a; color:#fcc; }
        .tpl-item .tag { display:inline-block; font-size:9px; padding:1px 5px; border-radius:3px; margin-right:5px; vertical-align:middle; text-transform:uppercase; letter-spacing:.5px; }
        .tpl-item .tag.builtin { background:#264; color:#cfb; }
        .tpl-item .tag.user { background:#246; color:#cdf; }
        .tpl-item .tag.tweak { background:#642; color:#fcb; }
        .tpl-item .dim { opacity:.55; font-size:10px; font-weight:400; margin-right:4px; }
        /* AI Watch */
        .aiw-status { padding:6px 12px; border-radius:14px; font-size:12px; display:inline-block; margin-bottom:10px; font-weight:600; }
        .aiw-status.on  { background:#1c4; color:#fff; box-shadow:0 0 12px rgba(28,200,80,.5); animation:pulse 2s infinite; }
        .aiw-status.off { background:#444; color:#bbb; }
        @keyframes pulse { 0%,100% { box-shadow:0 0 8px rgba(28,200,80,.4); } 50% { box-shadow:0 0 18px rgba(28,200,80,.8); } }
        .aiw-feed { max-height:none; }
        .aiw-feed .empty-history { padding:24px 20px; text-align:center; opacity:.5; }
        .aiw-item { display:flex; gap:10px; padding:10px; margin-bottom:8px; background:#222; border-radius:6px; border-left:3px solid #2c80c0; }
        .aiw-item img { width:96px; height:64px; object-fit:cover; border-radius:3px; cursor:pointer; flex-shrink:0; }
        .aiw-item .aiw-meta { flex:1; min-width:0; }
        .aiw-item .aiw-when { font-size:11px; opacity:.7; margin-bottom:4px; }
        .aiw-item .aiw-when .model { color:#7cf; margin-left:6px; }
        .aiw-item .aiw-text { font-size:12.5px; line-height:1.45; color:#eee; }
        .small-btns { display:flex; gap:6px; flex-wrap:wrap; margin-bottom:10px; }
        .info-grid { display:grid; grid-template-columns: auto 1fr; gap:4px 12px; padding:8px 10px; background:#222; border-radius:4px; font-size:11px; margin-bottom:10px; }
        .info-grid div:nth-child(odd) { opacity:.6; }
        h3 { margin:14px 0 6px 0; font-size:11px; opacity:.6; text-transform:uppercase; letter-spacing:.5px; }
        .history { max-height:280px; overflow-y:auto; }
        .history .item { display:flex; gap:8px; padding:5px 0; align-items:center; border-bottom:1px solid #222; }
        .history .item:hover { background:#252525; }
        .history img { width:54px; height:36px; object-fit:cover; border-radius:3px; cursor:pointer; flex-shrink:0; }
        .history .meta { flex:1; cursor:pointer; min-width:0; }
        .history .meta .ts { font-size:11px; opacity:.85; }
        .history .meta .sub { font-size:10px; opacity:.55; margin-top:2px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
        .history .meta .dim { margin-left:8px; opacity:.5; }
        .history button.small { padding:3px 6px; font-size:11px; opacity:.6; flex-shrink:0; }
        .history button.small:hover { opacity:1; }
        #upd { padding:8px; background:#3a2c1a; border-radius:4px; font-size:11px; margin-bottom:10px; display:none; }
        #upd.show { display:block; }
      </style>
      </head><body>
        <div class="head">
          <h1>GPT Render</h1>
          <span class="ver">v#{PLUGIN_VERSION}</span>
        </div>

        <div id="upd"></div>

        <div class="maintabs">
          <button id="mt_render"  class="active" onclick="switchMainTab('render')">Render</button>
          <button id="mt_prompts" onclick="switchMainTab('prompts')">Prompts</button>
          <button id="mt_history" onclick="switchMainTab('history')">History <span class="badge" id="hist_count">#{history_count}</span></button>
          <button id="mt_aiwatch" onclick="switchMainTab('aiwatch')">AI Watch <span class="badge" id="aiw_dot">#{aiw_enabled ? '●' : ''}</span></button>
          <button id="mt_live"    onclick="switchMainTab('live')">Live Stream <span class="badge" id="live_dot">#{live_enabled ? '●' : ''}</span></button>
        </div>

        <!-- ========== Render tab ========== -->
        <div id="render_pane" class="pane active">
          <div id="status">Ready · API key #{has_key ? "✓" : "<span style='color:#fa6'>not set</span>"}</div>

          <div class="row">
            <label style="font-size:11px;opacity:.7;display:block;margin-bottom:3px">Model</label>
            <select id="model" onchange="onModelChange()">
              #{model_options_html}
            </select>
          </div>

          <div class="row">
            <button id="renderBtn" class="primary" style="width:100%" onclick="doRender()">Render Current View</button>
          </div>

          <div class="grid row">
            <label>Width <input id="w" type="number" value="#{width}"></label>
            <label>Height <input id="h" type="number" value="#{height}"></label>
          </div>

          <div class="info-grid">
            <div>Prompt</div><div>#{prompt_chars} chars saved</div>
            <div>Output</div><div><code>&lt;model&gt;/gpt_render/</code></div>
          </div>

          <div class="small-btns">
            <button class="small" onclick="cmd('edit_prompt')">Edit Prompt</button>
            <button class="small" onclick="cmd('set_key')">API Key</button>
            <button class="small" onclick="cmd('check_update')">Check Update</button>
            <button class="small" onclick="cmd('open_folder')">Open Folder</button>
          </div>

          <h3>Latest result</h3>
          <div class="tabs">
            <button id="tab_enh" class="active" onclick="switchTab('enh')">Enhanced</button>
            <button id="tab_raw" onclick="switchTab('raw')">Raw render</button>
          </div>
          <div class="preview">
            <div id="preview_empty" class="empty">Render 完會喺度顯示</div>
            <img id="preview_img" style="display:none" onclick="openCurrentImage()">
            <div class="hint">🔍 click to open full size</div>
          </div>
          <div class="small-btns" id="refine_row" style="display:none">
            <button class="small" onclick="refineCurrent()" title="用呢張結果做 input 再 render，加 tweak 指示">↻ Refine this</button>
            <button class="small" onclick="openCurrentImage()">Open full size</button>
          </div>
        </div>

        <!-- ========== Prompts tab ========== -->
        <div id="prompts_pane" class="pane">
          <div class="small-btns">
            <button class="small" onclick="cmd('edit_prompt')">Edit Active Prompt</button>
          </div>
          <h3 style="margin-top:8px">Templates</h3>
          <div id="templates_list">#{render_templates_html}</div>
          <h3>Recent prompts (from your past renders)</h3>
          <div id="recent_prompts">#{render_recent_prompts_html}</div>
        </div>

        <!-- ========== AI Watch tab ========== -->
        <div id="aiwatch_pane" class="pane">
          <div id="aiw_status" class="aiw-status #{aiw_enabled ? 'on' : 'off'}">
            #{aiw_enabled ? '● Watching' : '○ Off'}
          </div>
          <div class="row">
            <button id="aiw_btn" class="primary" style="width:100%" onclick="toggleWatch()">
              #{aiw_enabled ? '■ Stop Watching' : '▶ Start Watching'}
            </button>
          </div>

          <div class="grid row">
            <label>Trigger after view settles
              <select id="aiw_delay" onchange="setWatchDelay()">
                <option value="5"  #{aiw_delay == 5  ? 'selected' : ''}>5s</option>
                <option value="15" #{aiw_delay == 15 ? 'selected' : ''}>15s</option>
                <option value="30" #{aiw_delay == 30 ? 'selected' : ''}>30s</option>
                <option value="60" #{aiw_delay == 60 ? 'selected' : ''}>1 min</option>
                <option value="180" #{aiw_delay == 180 ? 'selected' : ''}>3 min</option>
              </select>
            </label>
            <label>Vision model
              <select id="aiw_model" onchange="setWatchModel()">#{aiw_model_options}</select>
            </label>
          </div>

          <div class="small-btns">
            <button class="small" onclick="cmd('analyze_now')">▷ Analyze now</button>
            <button class="small" onclick="cmd('edit_watch_prompt')">Watch Prompt</button>
            <button class="small" onclick="cmd('open_watch_log')">Open log</button>
          </div>

          <div class="info-grid">
            <div>Today</div><div id="aiw_today">#{aiw_today} analyses · ~$#{format('%.2f', aiw_cost)}</div>
            <div>Output dir</div><div><code>&lt;model&gt;/gpt_render/watch/</code></div>
          </div>

          <h3>Live feed</h3>
          <div class="aiw-feed" id="aiw_feed">#{aiw_feed_html}</div>
        </div>

        <!-- ========== Live Stream tab ========== -->
        <div id="live_pane" class="pane">
          <div id="live_status_pill" class="aiw-status #{live_enabled ? 'on' : 'off'}">
            #{live_enabled ? '● Streaming' : '○ Off'}
          </div>
          <div class="row">
            <button id="live_btn" class="primary" style="width:100%" onclick="toggleLive()">
              #{live_enabled ? '■ Stop Live' : '▶ Start Live'}
            </button>
          </div>

          <div class="grid row">
            <label>Frame interval
              <select id="live_interval" onchange="setLiveInterval()">
                <option value="1" #{live_interval == 1 ? 'selected' : ''}>1s</option>
                <option value="2" #{live_interval == 2 ? 'selected' : ''}>2s</option>
                <option value="3" #{live_interval == 3 ? 'selected' : ''}>3s</option>
              </select>
            </label>
            <label>JPEG quality
              <select id="live_quality" onchange="setLiveQuality()">
                <option value="40" #{live_quality == 40 ? 'selected' : ''}>40% (smallest)</option>
                <option value="60" #{live_quality == 60 ? 'selected' : ''}>60% (default)</option>
                <option value="80" #{live_quality == 80 ? 'selected' : ''}>80%</option>
                <option value="95" #{live_quality == 95 ? 'selected' : ''}>95%</option>
              </select>
            </label>
          </div>

          <div class="small-btns">
            <button class="small" onclick="cmd('edit_live_prompt')">Live Prompt</button>
            <button class="small" onclick="cmd('open_live_log')">Open log</button>
          </div>

          <div class="info-grid">
            <div>Today</div><div id="live_today">#{live_today} streams · ~$#{format('%.4f', live_cost)}</div>
            <div>Endpoint</div><div><code>gemini-2.5-flash · streamGenerateContent (SSE)</code></div>
          </div>

          <h3>Current frame</h3>
          <div class="preview" style="min-height:90px">
            <div id="live_frame_empty" class="empty">Click Start Live → frame appears here</div>
            <img id="live_frame" style="display:none">
          </div>

          <h3>Streamed output</h3>
          <div id="live_output" style="background:#0a0a0a;border:1px solid #2a2a2a;border-radius:4px;padding:10px;min-height:80px;font-size:12.5px;line-height:1.5;white-space:pre-wrap;color:#cfc;"></div>
        </div>

        <!-- ========== History tab ========== -->
        <div id="history_pane" class="pane">
          <div class="small-btns">
            <button class="small" onclick="cmd('open_folder')">Open Folder</button>
            <button class="small" onclick="cmd('refresh_history')">Refresh</button>
          </div>
          <div class="history" id="history">#{history_html}</div>
        </div>

        <script>
        let lastRaw = null, lastEnh = null, currentTab = 'enh', lastRawPath = null, lastEnhPath = null;
        function setStatus(msg, cls) {
          const s = document.getElementById('status');
          s.textContent = msg;
          s.className = cls || '';
        }
        function setPreview(rawUrl, enhUrl, rawPath, enhPath) {
          if (rawUrl !== undefined) lastRaw = rawUrl;
          if (enhUrl !== undefined) lastEnh = enhUrl;
          if (rawPath !== undefined) lastRawPath = rawPath;
          if (enhPath !== undefined) lastEnhPath = enhPath;
          renderPreview();
        }
        function renderPreview() {
          const img = document.getElementById('preview_img');
          const empty = document.getElementById('preview_empty');
          const refineRow = document.getElementById('refine_row');
          const url = currentTab === 'enh' ? lastEnh : lastRaw;
          if (url) {
            img.src = url + '?_=' + Date.now();
            img.style.display = 'block';
            empty.style.display = 'none';
            refineRow.style.display = lastEnhPath ? 'flex' : 'none';
          } else {
            img.style.display = 'none';
            empty.style.display = 'block';
            refineRow.style.display = 'none';
          }
        }
        function refineCurrent() {
          const path = currentTab === 'enh' ? lastEnhPath : lastRawPath;
          if (path) sketchup.refine(path);
        }
        function refineHistory(path) {
          if (path) sketchup.refine(path);
        }
        function switchTab(t) {
          currentTab = t;
          document.getElementById('tab_enh').classList.toggle('active', t==='enh');
          document.getElementById('tab_raw').classList.toggle('active', t==='raw');
          renderPreview();
        }
        function setBusy(b) {
          document.getElementById('renderBtn').disabled = b;
        }
        function showUpdate(version, notes) {
          const el = document.getElementById('upd');
          el.innerHTML = '⚠ New version ' + version + ' available. <a href="#" onclick="cmd(\\'download_update\\');return false;" style="color:#fa6">Update now</a><br><small>' + (notes||'') + '</small>';
          el.classList.add('show');
        }
        function setHistory(html, count) {
          document.getElementById('history').innerHTML = html;
          if (typeof count === 'number') {
            document.getElementById('hist_count').textContent = count;
          }
        }
        function switchMainTab(name) {
          ['render','prompts','history','aiwatch','live'].forEach(n => {
            const tabBtn = document.getElementById('mt_' + n);
            const pane = document.getElementById(n + '_pane');
            if (tabBtn) tabBtn.classList.toggle('active', name === n);
            if (pane) pane.classList.toggle('active', name === n);
          });
        }
        // Live Stream
        function toggleLive()       { sketchup.toggle_live(''); }
        function setLiveInterval()  { sketchup.set_live_interval(document.getElementById('live_interval').value); }
        function setLiveQuality()   { sketchup.set_live_quality(document.getElementById('live_quality').value); }
        function setLiveUI(enabled) {
          const btn  = document.getElementById('live_btn');
          const dot  = document.getElementById('live_dot');
          const pill = document.getElementById('live_status_pill');
          if (btn)  btn.textContent  = enabled ? '■ Stop Live' : '▶ Start Live';
          if (dot)  dot.textContent  = enabled ? '●' : '';
          if (pill) {
            pill.textContent = enabled ? '● Streaming' : '○ Off';
            pill.className   = 'aiw-status ' + (enabled ? 'on' : 'off');
          }
        }
        function setLiveFrame(url) {
          const img = document.getElementById('live_frame');
          const empty = document.getElementById('live_frame_empty');
          if (url) {
            img.src = url + '?_=' + Date.now();
            img.style.display = 'block';
            if (empty) empty.style.display = 'none';
            // New frame → start a fresh streamed-output buffer.
            const out = document.getElementById('live_output');
            if (out) out.textContent = '';
          }
        }
        function appendLiveToken(delta, fullText) {
          const out = document.getElementById('live_output');
          if (out) out.textContent = fullText;
        }
        function liveDone(fullText, todayCount, todayCost) {
          const out = document.getElementById('live_output');
          if (out) out.textContent = fullText;
          const t = document.getElementById('live_today');
          if (t) t.textContent = todayCount + ' streams · ~$' + todayCost;
        }
        function toggleWatch() { sketchup.toggle_watch(''); }
        function setWatchDelay() { sketchup.set_watch_delay(document.getElementById('aiw_delay').value); }
        function setWatchModel() { sketchup.set_watch_model(document.getElementById('aiw_model').value); }
        function setWatchUI(enabled, statusText, statusCls) {
          const btn = document.getElementById('aiw_btn');
          const dot = document.getElementById('aiw_dot');
          const stat = document.getElementById('aiw_status');
          if (btn) btn.textContent = enabled ? '■ Stop Watching' : '▶ Start Watching';
          if (dot) dot.textContent = enabled ? '●' : '';
          if (stat) {
            stat.textContent = enabled ? '● Watching' : '○ Off';
            stat.className = 'aiw-status ' + (enabled ? 'on' : 'off');
          }
          if (statusText) {
            const s = document.getElementById('status');
            if (s) { s.textContent = statusText; s.className = statusCls || ''; }
          }
        }
        function setWatchFeed(html, todayCount, todayCost) {
          const f = document.getElementById('aiw_feed');
          if (f) f.innerHTML = html;
          const t = document.getElementById('aiw_today');
          if (t) t.textContent = todayCount + ' analyses · ~$' + todayCost;
        }
        function useTpl(id) { sketchup.use_template(id); }
        function deleteTpl(id) {
          if (confirm('Delete this template?')) sketchup.delete_template(id);
        }
        function useRecent(i) { sketchup.use_recent_prompt(String(i)); }
        function saveRecentAsTpl(i) { sketchup.save_recent_as_template(String(i)); }
        function setPromptsHTML(tplHtml, recentHtml) {
          document.getElementById('templates_list').innerHTML = tplHtml;
          document.getElementById('recent_prompts').innerHTML = recentHtml;
        }
        function doRender() {
          const opts = {
            width: parseInt(document.getElementById('w').value),
            height: parseInt(document.getElementById('h').value),
            model: document.getElementById('model').value
          };
          sketchup.render(JSON.stringify(opts));
        }
        function onModelChange() {
          sketchup.set_model(document.getElementById('model').value);
        }
        function cmd(name) { sketchup[name](''); }
        function openCurrentImage() {
          const path = currentTab === 'enh' ? lastEnhPath : lastRawPath;
          if (path) sketchup.open_file(path);
        }
        function openImage(path) {
          if (path) sketchup.open_file(path);
        }
        function loadHistoryItem(rawUrl, enhUrl, rawPath, enhPath) {
          setPreview(rawUrl, enhUrl, rawPath, enhPath);
        }
        </script>
      </body></html>
    HTML
  end

  def self.history_dir
    model = Sketchup.active_model
    return nil if model.nil? || model.path.empty?
    File.join(File.dirname(model.path), "gpt_render")
  end

  # ----- HTML render helpers for the Prompts tab -----------------------------
  def self.render_templates_html
    items = all_templates
    items.map { |t|
      tag = t["source"] == "builtin" ? "<span class='tag builtin'>built-in</span>" : "<span class='tag user'>my</span>"
      preview = CGI.escapeHTML(t["prompt"][0,90]).gsub("\n", " ")
      del_btn = t["source"] == "user" ? "<button class='small danger' onclick=\"deleteTpl(#{t['id'].to_json})\" title='Delete'>×</button>" : ""
      <<~HTML
        <div class="tpl-item">
          <div class="tpl-meta">
            <div class="tpl-name">#{tag} #{CGI.escapeHTML(t['name'])}</div>
            <div class="tpl-preview">#{preview}…</div>
          </div>
          <button class='small' onclick="useTpl(#{t['id'].to_json})">Use</button>
          #{del_btn}
        </div>
      HTML
    }.join("\n")
  end

  def self.render_watch_feed_html
    items = recent_observations(30)
    return "<div class='empty-history'><div class='icon'>👁</div><div>No observations yet</div><div style='font-size:11px;margin-top:6px'>Start watching, the AI will comment as you work</div></div>" if items.empty?
    items.map { |o|
      img_path = File.join(history_dir || "", "watch", o["image"].to_s)
      img_url = File.exist?(img_path) ? "file://" + img_path.gsub("\\", "/") : ""
      ts = o["ts"].to_s
      time_label = ts.length >= 16 ? ts[11,8] : ts
      <<~HTML
        <div class='aiw-item'>
          <img src="#{img_url}" onclick="sketchup.open_file(#{img_path.to_json})">
          <div class='aiw-meta'>
            <div class='aiw-when'>#{time_label} <span class='model'>#{CGI.escapeHTML(o['model'].to_s)}</span> <span class='dim'>#{o['elapsed_sec']}s</span></div>
            <div class='aiw-text'>#{CGI.escapeHTML(o['text'].to_s).gsub("\n", '<br>')}</div>
          </div>
        </div>
      HTML
    }.join("\n")
  end

  def self.render_recent_prompts_html
    items = recent_prompts
    return "<div class='empty-history'><div class='icon'>💬</div><div>No past prompts yet</div><div style='font-size:11px;margin-top:6px'>Render once and your prompts will appear here</div></div>" if items.empty?
    items.each_with_index.map { |r, i|
      preview = CGI.escapeHTML(r["prompt"][0,140]).gsub("\n", " ")
      tweak = r["tweak"].to_s.empty? ? "" : "<span class='tag tweak'>refined</span>"
      ts = r["used_at"].to_s
      time_label = ts.length >= 16 ? ts[5,11].sub("T", " ") : ts
      <<~HTML
        <div class="tpl-item">
          <div class="tpl-meta">
            <div class="tpl-name">#{tweak} <span class='dim'>#{CGI.escapeHTML(r['model'].to_s)}</span> <span class='dim'>#{time_label}</span></div>
            <div class="tpl-preview">#{preview}…</div>
          </div>
          <button class='small' onclick="useRecent(#{i})">Use</button>
          <button class='small' onclick="saveRecentAsTpl(#{i})" title='Save as template'>+</button>
        </div>
      HTML
    }.join("\n")
  end

  # ----- prompt templates ----------------------------------------------------

  # Returns array of {name, prompt, source: "builtin"|"user", id, created_at?}
  def self.all_templates
    cfg = load_config
    user_tpl = (cfg["templates"] || []).map.with_index { |t, i|
      t.merge("source" => "user", "id" => "u#{i}")
    }
    builtin = BUILTIN_TEMPLATES.map.with_index { |t, i|
      t.merge("source" => "builtin", "id" => "b#{i}")
    }
    builtin + user_tpl
  end

  def self.find_template(id)
    all_templates.find { |t| t["id"].to_s == id.to_s }
  end

  def self.save_user_template(name, prompt)
    cfg = load_config
    cfg["templates"] ||= []
    # Replace if name exists, else append
    existing = cfg["templates"].find { |t| t["name"] == name }
    if existing
      existing["prompt"] = prompt
      existing["updated_at"] = Time.now.iso8601
    else
      cfg["templates"] << {
        "name" => name,
        "prompt" => prompt,
        "created_at" => Time.now.iso8601,
      }
    end
    save_config(cfg)
  end

  def self.delete_user_template(id)
    cfg = load_config
    return false unless cfg["templates"]
    idx = id.to_s.sub(/^u/, "").to_i
    return false if idx < 0 || idx >= cfg["templates"].length
    cfg["templates"].delete_at(idx)
    save_config(cfg)
    true
  end

  def self.set_active_prompt(prompt)
    cfg = load_config
    cfg["prompt"] = prompt
    save_config(cfg)
  end

  # ----- prompt history (derived from past _meta.json) -----------------------

  def self.recent_prompts
    dir = history_dir
    return [] unless dir && File.directory?(dir)
    seen = {}   # prompt → first occurrence info
    Dir.glob(File.join(dir, "*_meta.json")).sort.reverse.each do |meta|
      data = JSON.parse(File.read(meta)) rescue nil
      next unless data && data["prompt"]
      prompt = data["prompt"]
      next if seen[prompt]   # de-dup
      seen[prompt] = {
        "prompt" => prompt,
        "model"  => data["model"],
        "used_at" => data["finished_at"] || data["started_at"],
        "tweak"   => data["tweak"],
      }
    end
    seen.values.first(15)
  end

  def self.count_history
    dir = history_dir
    return 0 unless dir && File.directory?(dir)
    Dir.glob(File.join(dir, "*_raw.png")).length
  end

  def self.render_history_html
    model = Sketchup.active_model
    return "<div class='empty-history'><div class='icon'>📁</div><div>Save your model first</div><div style='font-size:11px;margin-top:6px'>(File → Save the .skp before rendering)</div></div>" if model.nil? || model.path.empty?
    dir = File.join(File.dirname(model.path), "gpt_render")
    return "<div class='empty-history'><div class='icon'>🎨</div><div>No renders yet</div><div style='font-size:11px;margin-top:6px'>Render a view first to start building history</div></div>" unless File.directory?(dir)

    pairs = {}
    Dir.glob(File.join(dir, "*_raw.png")).each do |raw|
      stem = File.basename(raw, "_raw.png")
      enh = File.join(dir, "#{stem}_enhanced.png")
      meta_path = File.join(dir, "#{stem}_meta.json")
      meta = nil
      if File.exist?(meta_path)
        meta = JSON.parse(File.read(meta_path)) rescue nil
      end
      pairs[stem] = { raw: raw, enh: File.exist?(enh) ? enh : nil, meta: meta }
    end

    items = pairs.keys.sort.reverse[0,50]
    return "<div class='empty-history'><div class='icon'>🎨</div><div>No renders yet</div></div>" if items.empty?

    items.map do |stem|
      p = pairs[stem]
      thumb = p[:enh] || p[:raw]
      raw_url = "file://" + (p[:raw] || "").gsub("\\", "/")
      enh_url = p[:enh] ? "file://" + p[:enh].gsub("\\", "/") : nil
      raw_path = p[:raw] || ""
      enh_path = p[:enh] || ""

      # Date / time formatting
      ts_raw = stem[0,15]   # YYYYMMDD_HHMMSS
      time_part = ts_raw.length >= 15 ? "#{ts_raw[9,2]}:#{ts_raw[11,2]}" : ""
      date_part = ts_raw.length >= 8  ? "#{ts_raw[4,2]}/#{ts_raw[6,2]}" : ""

      # Model + dim from sidecar
      model_label = "?"
      dim_label = ""
      elapsed_label = ""
      if p[:meta]
        m = IMAGE_MODELS.find { |x| x[0] == p[:meta]["model"] }
        model_label = m ? m[1] : p[:meta]["model"].to_s
        if p[:meta]["width"] && p[:meta]["height"]
          dim_label = "#{p[:meta]['width']}×#{p[:meta]['height']}"
        end
        elapsed_label = p[:meta]["elapsed_sec"] ? "#{p[:meta]['elapsed_sec'].round}s" : ""
      end

      url_args = "#{raw_url.to_json}, #{enh_url ? enh_url.to_json : 'null'}, #{raw_path.to_json}, #{enh_path.to_json}"
      open_path = enh_path.empty? ? raw_path : enh_path

      refine_target = enh_path.empty? ? raw_path : enh_path
      <<~HTML
        <div class='item'>
          <img src="file://#{thumb.gsub('\\','/')}" onclick="loadHistoryItem(#{url_args})" title="Click thumbnail to preview">
          <div class='meta' onclick="loadHistoryItem(#{url_args})">
            <div class='ts'>#{date_part} #{time_part}</div>
            <div class='sub'>#{CGI.escapeHTML(model_label)}<span class='dim'>#{dim_label}</span><span class='dim'>#{elapsed_label}</span></div>
          </div>
          <button class='small' onclick="refineHistory(#{refine_target.to_json})" title='Refine this'>↻</button>
          <button class='small' onclick="openImage(#{open_path.to_json})" title='Open full size'>↗</button>
        </div>
      HTML
    end.join("\n")
  end

  def self.show_tray
    if @tray && @tray.visible?
      @tray.bring_to_front
      return
    end
    @tray = UI::HtmlDialog.new(
      dialog_title:    PLUGIN_NAME,
      preferences_key: "su_gpt_render_tray_v2",
      scrollable:      true,
      resizable:       true,
      width:           400,
      height:          760,
      style:           UI::HtmlDialog::STYLE_UTILITY
    )
    @tray.set_html(tray_html)

    @tray.add_action_callback("render") do |_, opts_json|
      begin
        opts = JSON.parse(opts_json)
        do_render_async(opts["width"].to_i, opts["height"].to_i, opts["model"].to_s)
      rescue => e
        push_status("Failed: #{e.message}", "err")
      end
    end
    @tray.add_action_callback("set_model") do |_, model_id|
      cfg = load_config; cfg["model"] = model_id.to_s; save_config(cfg)
    end
    @tray.add_action_callback("open_file") do |_, path|
      if path && !path.to_s.empty? && File.exist?(path)
        UI.openURL("file://" + path.to_s.gsub("\\", "/"))
      end
    end
    @tray.add_action_callback("refine") do |_, image_path|
      open_refine_dialog(image_path.to_s)
    end
    @tray.add_action_callback("refresh_history") { |_, _| push_history }
    @tray.add_action_callback("use_template") do |_, id|
      tpl = find_template(id)
      if tpl
        set_active_prompt(tpl["prompt"])
        push_status("Loaded template: #{tpl['name']}", "ok")
        refresh_tray
      end
    end
    @tray.add_action_callback("delete_template") do |_, id|
      delete_user_template(id)
      push_prompts
      push_status("Template deleted.", "ok")
    end
    @tray.add_action_callback("use_recent_prompt") do |_, idx|
      r = recent_prompts[idx.to_i]
      if r
        set_active_prompt(r["prompt"])
        push_status("Loaded recent prompt", "ok")
        refresh_tray
      end
    end
    # AI Watch callbacks
    @tray.add_action_callback("toggle_watch")     { |_, _| toggle_watching }
    @tray.add_action_callback("analyze_now")      { |_, _| analyze_now }
    @tray.add_action_callback("set_watch_delay")  do |_, v|
      cfg = load_config; cfg["watch_delay"] = v.to_i; save_config(cfg)
    end
    @tray.add_action_callback("set_watch_model")  do |_, v|
      cfg = load_config; cfg["watch_model"] = v.to_s; save_config(cfg)
    end
    @tray.add_action_callback("edit_watch_prompt") { |_, _| edit_watch_prompt }
    @tray.add_action_callback("open_watch_log")   do |_, _|
      dir = history_dir
      if dir
        watch_dir = File.join(dir, "watch")
        FileUtils.mkdir_p(watch_dir)
        UI.openURL("file://" + watch_dir.gsub("\\", "/"))
      end
    end

    # Live Stream callbacks
    @tray.add_action_callback("toggle_live")        { |_, _| toggle_live_stream }
    @tray.add_action_callback("set_live_interval")  do |_, v|
      cfg = load_config; cfg["live_interval"] = v.to_i; save_config(cfg)
    end
    @tray.add_action_callback("set_live_quality")   do |_, v|
      cfg = load_config; cfg["live_quality"] = v.to_i; save_config(cfg)
    end
    @tray.add_action_callback("edit_live_prompt")   { |_, _| edit_live_prompt }
    @tray.add_action_callback("open_live_log")      do |_, _|
      dir = history_dir
      if dir
        stream_dir = File.join(dir, "stream")
        FileUtils.mkdir_p(stream_dir)
        UI.openURL("file://" + stream_dir.gsub("\\", "/"))
      end
    end

    @tray.add_action_callback("save_recent_as_template") do |_, idx|
      r = recent_prompts[idx.to_i]
      next unless r
      input = UI.inputbox(["Template name"],
        ["#{r['model']} #{r['used_at'].to_s[0,10]}"],
        "Save as template")
      next unless input
      name = input.first.to_s.strip
      next if name.empty?
      save_user_template(name, r["prompt"])
      push_prompts
      push_status("Saved template: #{name}", "ok")
    end
    @tray.add_action_callback("edit_prompt")     { |_, _| edit_prompt }
    @tray.add_action_callback("set_key")         { |_, _| set_api_key; refresh_tray }
    @tray.add_action_callback("check_update")    { |_, _| check_update(true) }
    @tray.add_action_callback("download_update") { |_, _| download_update }
    @tray.add_action_callback("open_folder")     { |_, _| open_output_folder }

    @tray.show

    # Background auto-update — schedule via UI.start_timer ON MAIN THREAD.
    # (Calling UI.start_timer FROM a background Thread is unreliable in SU;
    # the timer block never fires. So we keep all timer scheduling on main
    # thread, and only do the actual HTTP work inside a Thread we poll.)
    @initial_update_timer = UI.start_timer(2.0, false) { kick_auto_update }
    @recurring_update_timer ||= UI.start_timer(600, true) { kick_auto_update }
  end

  # Spawn a Ruby Thread to do the (slow) HTTP version check, then poll the
  # thread state from the main UI thread via UI.start_timer. When the thread
  # finishes with "newer version available", trigger download_update_and_apply
  # on the main thread (where it's safe to manipulate UI).
  def self.kick_auto_update
    return if @bg_thread && @bg_thread.alive?            # render in progress
    return if @update_thread && @update_thread.alive?    # already checking

    puts "[GPT Render] auto-update check..."
    @update_thread = Thread.new do
      Thread.current[:available] = remote_update_available? rescue false
    end
    @update_poll_timer = UI.start_timer(0.4, true) do
      if @update_thread.nil? || !@update_thread.alive?
        UI.stop_timer(@update_poll_timer) if @update_poll_timer
        @update_poll_timer = nil
        avail = (@update_thread && @update_thread[:available]) ? true : false
        @update_thread = nil
        if avail
          puts "[GPT Render] update available, applying..."
          download_update_and_apply(verbose: false)
        else
          puts "[GPT Render] up-to-date"
        end
      end
    end
  end

  # Lightweight check: returns true if remote manifest version > local.
  def self.remote_update_available?
    return false if UPDATE_MANIFEST_URL.nil? || UPDATE_MANIFEST_URL.empty?
    res = http_get(UPDATE_MANIFEST_URL, attempts: 1) rescue nil
    return false unless res.is_a?(Net::HTTPSuccess)
    data = JSON.parse(res.body) rescue nil
    return false unless data
    version_newer?(data["version"].to_s, PLUGIN_VERSION)
  end

  def self.refresh_tray
    return unless @tray && @tray.visible?
    @tray.set_html(tray_html)
  end

  def self.push_status(msg, cls = "")
    return unless @tray && @tray.visible?
    @tray.execute_script("setStatus(#{msg.to_json}, #{cls.to_json})")
  end

  def self.push_busy(b)
    return unless @tray && @tray.visible?
    @tray.execute_script("setBusy(#{b ? 'true' : 'false'})")
  end

  def self.push_preview(raw_path, enh_path)
    return unless @tray && @tray.visible?
    raw_url = raw_path ? "file://" + raw_path.gsub("\\", "/") : nil
    enh_url = enh_path ? "file://" + enh_path.gsub("\\", "/") : nil
    @tray.execute_script("setPreview(#{raw_url.to_json}, #{enh_url.to_json}, #{(raw_path||'').to_json}, #{(enh_path||'').to_json})")
  end

  def self.push_history
    return unless @tray && @tray.visible?
    html = render_history_html
    count = count_history
    @tray.execute_script("setHistory(#{html.to_json}, #{count})")
  end

  def self.push_prompts
    return unless @tray && @tray.visible?
    @tray.execute_script("setPromptsHTML(#{render_templates_html.to_json}, #{render_recent_prompts_html.to_json})")
  end

  def self.push_watch_state(enabled)
    return unless @tray && @tray.visible?
    @tray.execute_script("setWatchUI(#{enabled ? 'true' : 'false'})")
  end

  def self.push_watch_status(msg, cls = "")
    push_status(msg, cls)
  end

  def self.push_watch_observation(raw_path, text, model, elapsed)
    return unless @tray && @tray.visible?
    @tray.execute_script("setWatchFeed(#{render_watch_feed_html.to_json}, #{watch_count_today}, '#{format('%.2f', estimated_cost_today)}')")
  end

  # ---- Live Stream tray-push helpers ----------------------------------------
  def self.push_live_state(enabled)
    return unless @tray && @tray.visible?
    @tray.execute_script("setLiveUI(#{enabled ? 'true' : 'false'})")
  end

  def self.push_live_status(msg, cls = "")
    push_status(msg, cls)
  end

  def self.push_live_frame(raw_path)
    return unless @tray && @tray.visible?
    url = raw_path ? "file://" + raw_path.gsub("\\", "/") : ""
    @tray.execute_script("setLiveFrame(#{url.to_json})")
  end

  def self.push_live_token(delta, full_text)
    return unless @tray && @tray.visible?
    @tray.execute_script("appendLiveToken(#{delta.to_json}, #{full_text.to_json})")
  end

  def self.push_live_done(full_text)
    return unless @tray && @tray.visible?
    @tray.execute_script(
      "liveDone(#{full_text.to_json}, #{live_count_today}, '#{format('%.4f', live_cost_today)}')"
    )
  end

  # Edit the watch prompt in a multiline HtmlDialog (similar to render prompt)
  def self.edit_watch_prompt
    cfg = load_config
    current = cfg["watch_prompt"] || DEFAULT_WATCH_PROMPT
    dlg = UI::HtmlDialog.new(
      dialog_title:    "#{PLUGIN_NAME} — Edit Watch Prompt",
      preferences_key: "su_gpt_render_watch_prompt_dlg",
      scrollable:      true, resizable: true,
      width: 640, height: 540,
      style: UI::HtmlDialog::STYLE_DIALOG
    )
    cur_html = CGI.escapeHTML(current)
    default_html = CGI.escapeHTML(DEFAULT_WATCH_PROMPT).gsub("\n", '\\n').gsub("'", "\\\\'")
    html = <<~HTML
      <!doctype html><html><head><meta charset="utf-8">
      <style>
        body { font-family:-apple-system,"Helvetica Neue","PingFang HK","Microsoft JhengHei",sans-serif; margin:0; padding:14px; background:#f5f5f5; }
        h2 { margin:0 0 8px 0; font-size:14px; color:#333; }
        p.hint { margin:0 0 10px 0; font-size:12px; color:#666; line-height:1.4; }
        textarea { width:100%; min-height:340px; box-sizing:border-box; font-family:"SF Mono",Consolas,monospace; font-size:12.5px; padding:10px; border:1px solid #ccc; border-radius:4px; resize:vertical; }
        .row { margin-top:10px; display:flex; gap:8px; }
        button { padding:8px 14px; border:1px solid #aaa; border-radius:4px; background:#fff; cursor:pointer; font-size:13px; }
        button.primary { background:#2c80c0; color:#fff; border-color:#2c80c0; }
        button.danger { color:#a00; border-color:#caa; }
        .spacer { flex:1; }
      </style></head><body>
      <h2>AI Watch prompt</h2>
      <p class="hint">每次自動 capture 都會用呢個 prompt。可以叫 AI focus 喺 cabinet construction、material choice、proportions 等。</p>
      <textarea id="prompt">#{cur_html}</textarea>
      <div class="row">
        <button class="primary" onclick="window.location='skp:save@'+encodeURIComponent(document.getElementById('prompt').value)">Save</button>
        <button onclick="window.location='skp:cancel@'">Cancel</button>
        <div class="spacer"></div>
        <button class="danger" onclick="if(confirm('Reset?')){document.getElementById('prompt').value='#{default_html}';}">Reset</button>
      </div>
      </body></html>
    HTML
    dlg.set_html(html)
    dlg.add_action_callback("save") do |_, value|
      decoded = CGI.unescape(value.to_s)
      cfg2 = load_config; cfg2["watch_prompt"] = decoded; save_config(cfg2)
      dlg.close
      UI.messagebox("Watch prompt saved (#{decoded.length} chars).")
    end
    dlg.add_action_callback("cancel") { |_, _| dlg.close }
    dlg.show
  end

  # Live-stream prompt editor. Defaults to the watch prompt so the user can
  # share it across both flows; saving here is independent though.
  def self.edit_live_prompt
    cfg = load_config
    current = cfg["live_prompt"] || cfg["watch_prompt"] || DEFAULT_WATCH_PROMPT
    dlg = UI::HtmlDialog.new(
      dialog_title:    "#{PLUGIN_NAME} — Edit Live Prompt",
      preferences_key: "su_gpt_render_live_prompt_dlg",
      scrollable:      true, resizable: true,
      width: 640, height: 540,
      style: UI::HtmlDialog::STYLE_DIALOG
    )
    cur_html = CGI.escapeHTML(current)
    html = <<~HTML
      <!doctype html><html><head><meta charset="utf-8">
      <style>
        body { font-family:-apple-system,"Helvetica Neue","PingFang HK","Microsoft JhengHei",sans-serif; margin:0; padding:14px; background:#f5f5f5; }
        h2 { margin:0 0 8px 0; font-size:14px; color:#333; }
        p.hint { margin:0 0 10px 0; font-size:12px; color:#666; line-height:1.4; }
        textarea { width:100%; min-height:340px; box-sizing:border-box; font-family:"SF Mono",Consolas,monospace; font-size:12.5px; padding:10px; border:1px solid #ccc; border-radius:4px; resize:vertical; }
        .row { margin-top:10px; display:flex; gap:8px; }
        button { padding:8px 14px; border:1px solid #aaa; border-radius:4px; background:#fff; cursor:pointer; font-size:13px; }
        button.primary { background:#2c80c0; color:#fff; border-color:#2c80c0; }
      </style></head><body>
      <h2>Live-stream prompt</h2>
      <p class="hint">每次 frame 都會用呢個 prompt。建議要短 + 直接，因為 streaming 會 token-by-token 印出嚟。</p>
      <textarea id="prompt">#{cur_html}</textarea>
      <div class="row">
        <button class="primary" onclick="window.location='skp:save@'+encodeURIComponent(document.getElementById('prompt').value)">Save</button>
        <button onclick="window.location='skp:cancel@'">Cancel</button>
      </div>
      </body></html>
    HTML
    dlg.set_html(html)
    dlg.add_action_callback("save") do |_, value|
      decoded = CGI.unescape(value.to_s)
      cfg2 = load_config; cfg2["live_prompt"] = decoded; save_config(cfg2)
      dlg.close
      UI.messagebox("Live prompt saved (#{decoded.length} chars).")
    end
    dlg.add_action_callback("cancel") { |_, _| dlg.close }
    dlg.show
  end

  # ------ async render -------------------------------------------------------
  def self.do_render_async(width, height, model = nil)
    api_key = get_api_key
    return unless api_key

    if @bg_thread && @bg_thread.alive?
      UI.messagebox("Already rendering. Wait for the current job to finish.")
      return
    end

    cfg = load_config
    prompt = cfg["prompt"] || DEFAULT_PROMPT
    model = (model && !model.empty?) ? model : (cfg["model"] || IMAGE_MODELS.first[0])
    cfg["width"] = width; cfg["height"] = height; cfg["model"] = model; save_config(cfg)

    push_busy(true)
    push_status("Exporting view...", "busy")

    raw_path = nil
    begin
      raw_path = export_view(width, height)
      push_preview(raw_path, nil)
    rescue => e
      push_busy(false)
      push_status("Export failed: #{e.message}", "err")
      return
    end

    push_status("Calling Poe (#{model}) ~30-60s...", "busy")

    started_at = Time.now
    # Background HTTP — Net::HTTP releases GIL during I/O so this DOES run async.
    @bg_thread = Thread.new do
      begin
        url = call_poe(api_key, raw_path, prompt, model)
        out_path = raw_path.sub(/_raw\.png$/, "_enhanced.png")
        download(url, out_path)
        # Persist render metadata sidecar
        meta_path = raw_path.sub(/_raw\.png$/, "_meta.json")
        meta_data = {
          "raw"      => File.basename(raw_path),
          "enhanced" => File.basename(out_path),
          "model"    => model,
          "width"    => width,
          "height"   => height,
          "prompt"   => prompt,
          "started_at"  => started_at.iso8601,
          "finished_at" => Time.now.iso8601,
          "elapsed_sec" => (Time.now - started_at).round(1),
        }
        File.write(meta_path, JSON.pretty_generate(meta_data))
        Thread.current[:result] = { ok: true, raw: raw_path, enh: out_path }
      rescue => e
        Thread.current[:result] = { ok: false, raw: raw_path, error: e.message }
      end
    end

    # Poll thread on the SU main UI thread (we cannot touch UI from a Thread)
    @bg_timer = UI.start_timer(0.5, true) do
      if @bg_thread && !@bg_thread.alive?
        UI.stop_timer(@bg_timer)
        @bg_timer = nil
        result = @bg_thread[:result]
        @bg_thread = nil
        push_busy(false)
        if result[:ok]
          push_status("Done · #{File.basename(result[:enh])}", "ok")
          push_preview(result[:raw], result[:enh])
          push_history
        else
          push_status("Failed: #{result[:error]}", "err")
        end
      end
    end
  end

  # ------ refine flow --------------------------------------------------------
  def self.open_refine_dialog(image_path)
    unless File.exist?(image_path)
      UI.messagebox("Image not found:\n#{image_path}")
      return
    end
    cfg = load_config
    base_prompt = cfg["prompt"] || DEFAULT_PROMPT

    dlg = UI::HtmlDialog.new(
      dialog_title:    "#{PLUGIN_NAME} — Refine",
      preferences_key: "su_gpt_render_refine_dlg",
      scrollable:      true, resizable: true,
      width: 720, height: 640,
      style: UI::HtmlDialog::STYLE_DIALOG
    )

    img_url = "file://" + image_path.gsub("\\", "/")
    base_html = CGI.escapeHTML(base_prompt)

    html = <<~HTML
      <!doctype html><html><head><meta charset="utf-8">
      <style>
        body { font-family:-apple-system,"Helvetica Neue","PingFang HK","Microsoft JhengHei",sans-serif; margin:0; padding:14px; background:#f5f5f5; color:#222; }
        h2 { margin:0 0 8px 0; font-size:14px; }
        .twocol { display:grid; grid-template-columns: 1fr 1fr; gap:14px; }
        img { max-width:100%; max-height:280px; display:block; border-radius:4px; box-shadow:0 1px 6px rgba(0,0,0,.15); }
        textarea { width:100%; min-height:140px; box-sizing:border-box; font-family:"SF Mono",Consolas,monospace; font-size:12.5px; padding:10px; border:1px solid #ccc; border-radius:4px; resize:vertical; }
        label { font-size:11px; opacity:.7; display:block; margin-bottom:4px; }
        .row { margin-top:12px; display:flex; gap:8px; align-items:center; }
        button { padding:9px 16px; border:1px solid #aaa; border-radius:4px; background:#fff; cursor:pointer; font-size:13px; }
        button.primary { background:#2c80c0; color:#fff; border-color:#2c80c0; font-weight:600; }
        .spacer { flex:1; }
        details { margin-top:10px; }
        details summary { cursor:pointer; font-size:12px; color:#555; }
        details textarea { min-height:120px; margin-top:6px; }
      </style></head><body>
      <h2>Refine this render</h2>
      <p style="margin:0 0 12px 0;font-size:12px;opacity:.7">用左邊張圖做 input，加新指示再 render。新 prompt 會 prepend 到原 prompt 之前。</p>
      <div class="twocol">
        <div>
          <label>Input image (refine 用呢張)</label>
          <img src="#{img_url}">
        </div>
        <div>
          <label>Tweak instructions（中／英 OK）</label>
          <textarea id="tweak" placeholder="例：&#10;- darker walnut wood instead of light oak&#10;- warmer evening lighting&#10;- add visible window light from left&#10;- slightly more contrast"></textarea>
          <details>
            <summary>Show full base prompt (read-only)</summary>
            <textarea readonly>#{base_html}</textarea>
          </details>
        </div>
      </div>
      <div class="row">
        <button class="primary" onclick="window.location='skp:go@'+encodeURIComponent(document.getElementById('tweak').value)">↻ Refine</button>
        <button onclick="window.location='skp:cancel@'">Cancel</button>
        <div class="spacer"></div>
        <small style="opacity:.5">Output saved as new <code>_enhanced.png</code></small>
      </div>
      </body></html>
    HTML

    dlg.set_html(html)
    dlg.add_action_callback("go") do |_, tweak_enc|
      tweak = CGI.unescape(tweak_enc.to_s).strip
      dlg.close
      do_refine_async(image_path, tweak)
    end
    dlg.add_action_callback("cancel") { |_, _| dlg.close }
    dlg.show
  end

  def self.do_refine_async(image_path, tweak)
    api_key = get_api_key
    return unless api_key
    if @bg_thread && @bg_thread.alive?
      UI.messagebox("Already rendering. Wait for the current job to finish.")
      return
    end
    cfg = load_config
    base_prompt = cfg["prompt"] || DEFAULT_PROMPT
    model = cfg["model"] || IMAGE_MODELS.first[0]
    width  = cfg["width"]  || 1536
    height = cfg["height"] || 1024

    # Compose prompt: tweak first, then base. Tweak takes precedence.
    final_prompt = if tweak.empty?
                     base_prompt
                   else
                     "TWEAK INSTRUCTIONS (apply these changes):\n#{tweak}\n\nORIGINAL PROMPT:\n#{base_prompt}"
                   end

    # New filenames: <ts>_<base>_refine_raw.png + ..._refine_enhanced.png
    src_dir = File.dirname(image_path)
    src_stem = File.basename(image_path, ".png").sub(/_(raw|enhanced)$/, "")
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    raw_path = File.join(src_dir, "#{timestamp}_#{src_stem}_refine_raw.png")
    FileUtils.cp(image_path, raw_path)   # raw = the source image we're refining

    push_busy(true)
    push_status("Refining via Poe (#{model}) ~30-60s...", "busy")
    push_preview(raw_path, nil)

    started_at = Time.now
    @bg_thread = Thread.new do
      begin
        url = call_poe(api_key, raw_path, final_prompt, model)
        out_path = raw_path.sub(/_raw\.png$/, "_enhanced.png")
        download(url, out_path)
        meta_path = raw_path.sub(/_raw\.png$/, "_meta.json")
        File.write(meta_path, JSON.pretty_generate({
          "raw" => File.basename(raw_path), "enhanced" => File.basename(out_path),
          "model" => model, "width" => width, "height" => height,
          "prompt" => final_prompt, "tweak" => tweak,
          "refined_from" => File.basename(image_path),
          "started_at" => started_at.iso8601, "finished_at" => Time.now.iso8601,
          "elapsed_sec" => (Time.now - started_at).round(1),
        }))
        Thread.current[:result] = { ok: true, raw: raw_path, enh: out_path }
      rescue => e
        Thread.current[:result] = { ok: false, raw: raw_path, error: e.message }
      end
    end
    @bg_timer = UI.start_timer(0.5, true) do
      if @bg_thread && !@bg_thread.alive?
        UI.stop_timer(@bg_timer); @bg_timer = nil
        result = @bg_thread[:result]; @bg_thread = nil
        push_busy(false)
        if result[:ok]
          push_status("Refined · #{File.basename(result[:enh])}", "ok")
          push_preview(result[:raw], result[:enh])
          push_history
        else
          push_status("Refine failed: #{result[:error]}", "err")
        end
      end
    end
  end

  # ------ prompt editor ------------------------------------------------------
  def self.edit_prompt
    cfg = load_config
    current = cfg["prompt"] || DEFAULT_PROMPT
    dlg = UI::HtmlDialog.new(
      dialog_title:    "#{PLUGIN_NAME} — Edit prompt",
      preferences_key: "su_gpt_render_prompt_dlg",
      scrollable:      true,
      resizable:       true,
      width:           640,
      height:          540,
      style:           UI::HtmlDialog::STYLE_DIALOG
    )
    cur_html = CGI.escapeHTML(current)
    default_html = CGI.escapeHTML(DEFAULT_PROMPT).gsub("\n", '\\n').gsub("'", "\\\\'")
    html = <<~HTML
      <!doctype html><html><head><meta charset="utf-8">
      <style>
        body { font-family:-apple-system,"Helvetica Neue","PingFang HK","Microsoft JhengHei",sans-serif; margin:0; padding:14px; background:#f5f5f5; }
        h2 { margin:0 0 8px 0; font-size:14px; color:#333; }
        p.hint { margin:0 0 10px 0; font-size:12px; color:#666; line-height:1.4; }
        textarea { width:100%; min-height:340px; box-sizing:border-box; font-family:"SF Mono",Consolas,monospace; font-size:12.5px; padding:10px; border:1px solid #ccc; border-radius:4px; resize:vertical; }
        .row { margin-top:10px; display:flex; gap:8px; }
        button { padding:8px 14px; border:1px solid #aaa; border-radius:4px; background:#fff; cursor:pointer; font-size:13px; }
        button.primary { background:#2c80c0; color:#fff; border-color:#2c80c0; }
        button.danger { color:#a00; border-color:#caa; }
        .spacer { flex:1; }
      </style></head><body>
      <h2>Prompt（GPT-Image-2 enhance 用）</h2>
      <p class="hint">改完撳「Save」即時生效。Tips：保留「preserve geometry」/「do NOT change structure」防 AI 改 dim。</p>
      <textarea id="prompt">#{cur_html}</textarea>
      <div class="row">
        <button class="primary" onclick="window.location='skp:save@'+encodeURIComponent(document.getElementById('prompt').value)">Save</button>
        <button onclick="window.location='skp:save_template@'+encodeURIComponent(document.getElementById('prompt').value)" title='Save current text as a named template'>Save as template…</button>
        <button onclick="window.location='skp:cancel@'">Cancel</button>
        <div class="spacer"></div>
        <button class="danger" onclick="if(confirm('Reset to default?')){document.getElementById('prompt').value='#{default_html}';}">Reset to default</button>
      </div>
      </body></html>
    HTML
    dlg.set_html(html)
    dlg.add_action_callback("save") do |_, value|
      decoded = CGI.unescape(value.to_s)
      cfg2 = load_config; cfg2["prompt"] = decoded; save_config(cfg2)
      dlg.close
      refresh_tray
      UI.messagebox("Prompt saved (#{decoded.length} chars).")
    end
    dlg.add_action_callback("save_template") do |_, value|
      decoded = CGI.unescape(value.to_s)
      input = UI.inputbox(["Template name"], ["My template"], "Save as template")
      next unless input
      name = input.first.to_s.strip
      next if name.empty?
      save_user_template(name, decoded)
      push_prompts
      UI.messagebox("Saved template: #{name}")
    end
    dlg.add_action_callback("cancel") { |_, _| dlg.close }
    dlg.show
  end

  # ------ api key ------------------------------------------------------------
  def self.set_api_key
    cfg = load_config
    cur = cfg["poe_api_key"] || ""
    masked = cur.empty? ? "(none)" : "#{cur[0,4]}...#{cur[-4..-1]}"
    inputs = UI.inputbox(
      ["Poe API Key (current: #{masked})"],
      [""],
      "#{PLUGIN_NAME} — Set API key"
    )
    return unless inputs
    new_key = inputs.first.to_s.strip
    return if new_key.empty?
    cfg["poe_api_key"] = new_key
    save_config(cfg)
    UI.messagebox("API key updated.")
  end

  def self.open_output_folder
    model = Sketchup.active_model
    dir = if model.nil? || model.path.empty?
            File.expand_path("~/Desktop/gpt_render")
          else
            File.join(File.dirname(model.path), "gpt_render")
          end
    FileUtils.mkdir_p(dir)
    UI.openURL("file://" + dir.gsub("\\", "/"))
  end

  # ------ auto-update --------------------------------------------------------
  def self.check_update(verbose)
    return if UPDATE_MANIFEST_URL.nil? || UPDATE_MANIFEST_URL.empty?
    begin
      res = http_get(UPDATE_MANIFEST_URL, attempts: 2)
      raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
      data = JSON.parse(res.body)
      remote_ver = data["version"].to_s
      if version_newer?(remote_ver, PLUGIN_VERSION)
        notes = data["notes"].to_s
        if @tray && @tray.visible?
          @tray.execute_script("showUpdate(#{remote_ver.to_json}, #{notes.to_json})")
        end
        if verbose
          UI.messagebox("New version #{remote_ver} available.\n#{notes}")
        end
      else
        UI.messagebox("Already up-to-date (v#{PLUGIN_VERSION}).") if verbose
      end
    rescue => e
      UI.messagebox("Update check failed: #{e.message}") if verbose
    end
  end

  def self.version_newer?(a, b)
    pa = a.split(".").map(&:to_i)
    pb = b.split(".").map(&:to_i)
    [pa.length, pb.length].max.times do |i|
      av = pa[i] || 0; bv = pb[i] || 0
      return true  if av > bv
      return false if av < bv
    end
    false
  end

  def self.download_update
    download_update_and_apply(verbose: true)
  end

  # Hot-reload: download new .rb, write to disk, then `load` it to redefine
  # methods/constants in the live Ruby session, then close+reopen the tray
  # so the HtmlDialog rebinds to the new HTML and callbacks. No SU restart.
  def self.download_update_and_apply(verbose: false)
    return false if UPDATE_MANIFEST_URL.nil? || UPDATE_MANIFEST_URL.empty?
    # Don't disrupt an in-flight render
    if @bg_thread && @bg_thread.alive?
      UI.messagebox("Render in progress — try update again after.") if verbose
      return false
    end
    begin
      res = http_get(UPDATE_MANIFEST_URL, attempts: 2)
      return false unless res.is_a?(Net::HTTPSuccess)
      data = JSON.parse(res.body)
      remote_ver = data["version"].to_s
      unless version_newer?(remote_ver, PLUGIN_VERSION)
        UI.messagebox("Already up-to-date (v#{PLUGIN_VERSION}).") if verbose
        return false
      end

      rb_url = data["rb_url"].to_s
      return false if rb_url.empty?
      res2 = http_get(rb_url)
      return false unless res2.is_a?(Net::HTTPSuccess)

      target = __FILE__
      File.binwrite(target, res2.body)

      # Save tray reference before load (load re-runs the module body and
      # would otherwise wipe @tray / @bg_thread). Even with ||= guard this
      # is a belt-and-braces measure for action_callbacks rebinding too.
      saved_tray = @tray

      # ---- HOT RELOAD ----
      # Re-execute the just-written file to pick up new method definitions.
      # `load` re-runs the top-level body; methods get redefined; constants
      # show "already initialized" warnings unless we silence them.
      prev_verbose = $VERBOSE
      $VERBOSE = nil
      begin
        load target
      ensure
        $VERBOSE = prev_verbose
      end

      # Restore the tray reference (||= already guards but keep explicit)
      @tray = saved_tray

      # Refresh the tray IN PLACE via set_html. The live HtmlDialog stays
      # open, action_callbacks already registered are late-bound to method
      # names so they auto-resolve to the new code. No flicker, no close.
      if @tray && @tray.visible?
        begin
          @tray.set_html(tray_html)
        rescue => e
          # If set_html-on-shown-dialog fails on this SU version, fall back
          # to close+reopen.
          @tray.close
          @tray = nil
          UI.start_timer(0.2, false) { show_tray rescue nil }
        end
      end

      msg = "⚡ Auto-updated to v#{remote_ver} (live, no restart)"
      push_status(msg, "ok")
      UI.messagebox("#{msg}\n\n#{data['notes']}") if verbose
      true
    rescue => e
      UI.messagebox("Auto-update failed: #{e.message}") if verbose
      false
    end
  end

  def self.toggle_ssl_verify
    cfg = load_config
    current = cfg["verify_ssl"] != false
    new_val = !current
    cfg["verify_ssl"] = new_val
    save_config(cfg)
    if new_val
      UI.messagebox("SSL verification: ON (secure, default)")
    else
      UI.messagebox("SSL verification: OFF\n\nWARNING: this disables certificate validation. Use only if normal mode hits SSL errors. Re-enable when possible.")
    end
  end

  def self.diagnose
    info = []
    info << "Plugin: v#{PLUGIN_VERSION}"
    info << "SketchUp: #{Sketchup.version}"
    info << "Ruby: #{RUBY_VERSION} (#{RUBY_PLATFORM})"
    info << "OpenSSL: #{OpenSSL::OPENSSL_VERSION rescue '?'}"
    info << "OpenSSL CA: #{OpenSSL::X509::DEFAULT_CERT_FILE rescue '?'}"
    cfg = load_config
    info << "verify_ssl: #{cfg['verify_ssl'] == false ? 'OFF' : 'ON (default)'}"
    info << ""
    info << "TLS test to api.poe.com..."
    begin
      res = http_get("https://api.poe.com/", attempts: 1)
      info << "  → HTTP #{res.code} ✓"
    rescue => e
      info << "  → FAILED: #{e.class}: #{e.message[0,200]}"
    end
    UI.messagebox(info.join("\n"))
  end

  # ------ menu ---------------------------------------------------------------
  unless file_loaded?(__FILE__)
    menu = UI.menu("Extensions").add_submenu(PLUGIN_NAME)
    menu.add_item("Show Tray") { SuGptRender.show_tray }
    menu.add_item("Edit Prompt...") { SuGptRender.edit_prompt }
    menu.add_separator
    menu.add_item("Set Poe API Key...") { SuGptRender.set_api_key }
    menu.add_item("Toggle SSL Verify (debug)") { SuGptRender.toggle_ssl_verify }
    menu.add_item("Diagnose Network") { SuGptRender.diagnose }
    menu.add_item("Check for Updates") { SuGptRender.check_update(true) }
    file_loaded(__FILE__)
  end
end

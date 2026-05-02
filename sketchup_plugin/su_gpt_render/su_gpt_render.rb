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
  PLUGIN_NAME    = "Hohome AI Render"
  PLUGIN_TAGLINE = "為你屋企添意思 · 訂造傢俬搵好傢俬"
  # ---- Brand identity (hohomehk.com) ----------------------------------------
  BRAND_TEAL_DEEP   = "#1a4548"     # primary surface
  BRAND_TEAL_DARKER = "#0f2f31"     # deeper surface (cards / inputs)
  BRAND_CREAM       = "#fdd79a"     # accent / highlights
  BRAND_CREAM_SOFT  = "#f6e7c1"     # softer accent on hover
  BRAND_TEXT        = "#f4ede0"     # primary text on dark
  BRAND_TEXT_DIM    = "#c9bfa8"     # secondary text
  # 300×281 hohomehk white-logo.png loaded from the plugin folder's sibling
  # PNG. .rbz packages it; the build script copies the source PNG in. We
  # base64 once at load and cache so the data: URI is reusable inside HTML.
  BRAND_LOGO_PATH = File.expand_path("brand_logo.png", __dir__)
  BRAND_LOGO_DATA_URI =
    if File.exist?(BRAND_LOGO_PATH)
      "data:image/png;base64,#{Base64.strict_encode64(File.binread(BRAND_LOGO_PATH))}"
    else
      nil
    end


  PLUGIN_VERSION = "0.6.4"
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
  # CF AI Gateway is configured with BYOK ("Bring Your Own Key") for Google AI
  # Studio: the Gemini API key is stored in the gateway's settings server-side
  # and the gateway auto-attaches it to upstream requests. The plugin therefore
  # only ships the cf-aig-authorization token; the Google key never appears in
  # the .rbz / release-asset .rb. This matters because release artifacts are
  # public — earlier versions bundled the Google key and Google's leaked-key
  # bot revoked it within ~hours, breaking the plugin in the field.
  #
  # The CF token below is a placeholder in source — replaced at .rbz build
  # time by sketchup_plugin/build-rbz.sh from $CF_AIG_TOKEN. Source on GitHub
  # stays clean; the secret only lands in the shipped .rbz / release asset.
  GEMINI_AIG_URL   = "https://gateway.ai.cloudflare.com/v1/945eb571b27f72d3ad419c2468313f6f/hohome-gemini/google-ai-studio"
  GEMINI_AIG_TOKEN = "__INJECT_CF_AIG_TOKEN__"

  # Sentinel id used in WATCH_MODELS dropdown to mean "go through AI Gateway
  # directly to Gemini, bypass Poe". Cheaper since no Poe markup.
  GEMINI_DIRECT_ID = "gemini-2.5-flash-direct"

  # Models that support disabling thinking (thinkingBudget=0). Other models
  # like gemini-3.1-pro-preview reject thinkingBudget=0 with
  # "Budget 0 is invalid. This model only works in thinking mode."
  GEMINI_THINKING_DISABLABLE = %w[
    gemini-2.5-flash
    gemini-3.1-flash-lite-preview
  ].freeze

  # Image-output Gemini models. These do NOT accept thinkingConfig at all,
  # and they need their full token budget (~1290 tokens for one 1024² PNG)
  # so we also skip the maxOutputTokens cap for them. Used by the Live
  # Render tab.
  GEMINI_IMAGE_MODELS = %w[
    gemini-2.5-flash-image
  ].freeze

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
  #
  # Hosted on a private ngrok tunnel (hohomehk-plugin.ngrok.app → local :8743)
  # so the served su_gpt_render.rb — which has the cf-aig-authorization token
  # baked in by build-rbz.sh — never lands on a public crawl path. We migrated
  # off raw.githubusercontent.com because Cloudflare's leaked-token scanner
  # auto-revoked every CF AIG token within minutes of a public release upload
  # (3 tokens burned before pivoting). The tunnel URL is fine to leak; the .rb
  # behind it has a real token but no automated scanner crawls ngrok endpoints.
  UPDATE_MANIFEST_URL = "https://hohomehk-plugin.ngrok.app/version.json"

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

  # Live Render path through Poe (the cheap one — Nano-Banana / Nano-Banana-Pro).
  # Maps the live-render id ("nano-banana-poe", "nano-banana-pro-poe") onto
  # the Poe bot name ("Nano-Banana", "Nano-Banana-Pro"), POSTs image + prompt,
  # parses the markdown image URL out of the response, downloads it next to
  # the input PNG. Returns [output_path, completion_tokens] so the cost meter
  # can use the per-model rate from LIVE_RENDER_MODELS.
  def self.call_poe_image_for_live_render(input_image_paths, prompt, live_render_id,
                                          material_table: nil, view_count: nil)
    paths = Array(input_image_paths)
    raise "no input images" if paths.empty?
    view_count ||= paths.length   # legacy single-batch callers
    cfg = load_config
    api_key = cfg["poe_api_key"].to_s
    raise "Poe API key missing — set it in tray Render tab" if api_key.empty?

    # Map live_render id → actual Poe bot name.
    poe_model = case live_render_id
                when "nano-banana-poe"     then "Nano-Banana"
                when "nano-banana-pro-poe" then "Nano-Banana-Pro"
                else live_render_id
                end

    final_prompt = build_multi_view_preamble(view_count, prompt, material_table)

    content_arr = [{ "type" => "text", "text" => final_prompt }]
    paths.each do |p|
      img_b64 = Base64.strict_encode64(File.binread(p))
      content_arr << {
        "type" => "image_url",
        "image_url" => { "url" => "data:image/png;base64,#{img_b64}" }
      }
    end

    payload = {
      "model"    => poe_model,
      "messages" => [{ "role" => "user", "content" => content_arr }],
      "stream"   => false,
    }
    res = http_post_json(POE_ENDPOINT,
      { "Authorization" => "Bearer #{api_key}", "Content-Type" => "application/json" },
      JSON.generate(payload))
    raise "Poe API HTTP #{res.code}: #{res.body[0,400]}" unless res.is_a?(Net::HTTPSuccess)
    j = JSON.parse(res.body) rescue {}
    content = j.dig("choices", 0, "message", "content").to_s
    url_match = content.match(/!\[[^\]]*\]\(([^)\s]+)\)/) ||
                content.match(/(https?:\/\/[^\s)\]]+)/)
    raise "Poe returned no image URL: #{content[0,300]}" unless url_match
    img_url = url_match[1]

    # Save next to first input.
    primary = paths.first
    in_dir = File.dirname(primary)
    base = File.basename(primary, ".*").sub(/_lr_(geom|raw|material|colour)$/, "_lr")
    out_path = File.join(in_dir, "#{base}_render.png")
    download(img_url, out_path)

    completion_tokens = (j.dig("usage", "completion_tokens") || 1290).to_i
    [out_path, completion_tokens]
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
  #
  # generationConfig:
  #   - thinkingBudget=0 for thinking-disablable models — without this, Gemini
  #     2.5+ silently spends all maxOutputTokens on internal "thoughts" and
  #     emits zero candidate text (root cause of the empty-Live-Stream bug).
  #   - maxOutputTokens=1024 caps the visible response. Live Stream feedback
  #     should be brief; the user can re-ask for more detail.
  def self.build_gemini_payload(image_path_or_paths, prompt,
                                model: "gemini-2.5-flash",
                                mime_type: "image/jpeg", max_output_tokens: 1024,
                                aspect_ratio: nil, material_table: nil,
                                view_count: nil)
    paths = Array(image_path_or_paths)
    raise "no input images" if paths.empty?
    parts = paths.map { |p|
      img_b64 = Base64.strict_encode64(File.binread(p))
      { "inlineData" => { "mimeType" => mime_type, "data" => img_b64 } }
    }
    # view_count distinguishes the SU view captures (first N images) from
    # texture-swatch reference images (last M). The preamble uses N to
    # describe "you are receiving N views of the SAME 3D scene" — without
    # the override it'd lie about the geom-vs-material setup.
    nv = view_count || paths.length
    final_prompt = build_multi_view_preamble(nv, prompt, material_table)
    parts << { "text" => final_prompt }
    body = { "contents" => [{ "parts" => parts }] }
    # Image-output models (gemini-2.5-flash-image et al.) do NOT accept
    # thinkingConfig and need their full token budget (~1290 tokens per
    # 1024² PNG). Skip both knobs entirely for them but DO accept
    # imageConfig.aspectRatio (verified: 16:9 → 1344×768, 9:16 → 768×1344,
    # 1:1 → 1024×1024 — all same cost, 1290 output tokens).
    if GEMINI_IMAGE_MODELS.include?(model)
      if aspect_ratio && aspect_ratio != "1:1"
        body["generationConfig"] = { "imageConfig" => { "aspectRatio" => aspect_ratio } }
      end
    else
      body["generationConfig"] = { "maxOutputTokens" => max_output_tokens }
      if GEMINI_THINKING_DISABLABLE.include?(model)
        body["generationConfig"]["thinkingConfig"] = { "thinkingBudget" => 0 }
      end
    end
    body
  end

  # Single auth header AI Gateway requires (BYOK mode — Google API key is
  # stored in the gateway settings server-side and auto-attached to upstream).
  # Centralized so tests can verify request shape and the streaming +
  # non-streaming paths can't drift.
  def self.gemini_aig_headers
    {
      "cf-aig-authorization" => "Bearer #{GEMINI_AIG_TOKEN}",
      "Content-Type"         => "application/json",
    }
  end

  # Non-streaming Gemini call — used by AI Watch when user picks the direct
  # model. Returns the joined text from candidates[0].content.parts[*].text.
  def self.call_gemini_direct(image_path, prompt, model: "gemini-2.5-flash", mime_type: "image/jpeg")
    url = "#{GEMINI_AIG_URL}/v1beta/models/#{model}:generateContent"
    payload = build_gemini_payload(image_path, prompt, model: model, mime_type: mime_type)
    res = http_post_json(url, gemini_aig_headers, JSON.generate(payload))
    unless res.is_a?(Net::HTTPSuccess)
      raise "Gemini AI Gateway HTTP #{res.code}: #{res.body[0,300]}"
    end
    data = JSON.parse(res.body) rescue {}
    parts = data.dig("candidates", 0, "content", "parts") || []
    parts.map { |p| p["text"].to_s }.join.strip
  end

  # Image-output Gemini call (gemini-2.5-flash-image et al.). Returns
  # `[output_path, candidate_image_tokens]`. The output PNG is written next
  # to `input_image_path` with a `_render.png` suffix (or to a temp dir if
  # the input is itself temp). Used by the Live Render tab.
  #
  # Body shape — same skeleton as build_gemini_payload but for image-out
  # the model rejects thinkingConfig and maxOutputTokens (we already skip
  # both via GEMINI_IMAGE_MODELS guard in build_gemini_payload).
  #
  # Response shape:
  #   candidates[0].content.parts[*].inlineData.data → base64 PNG output
  #   usageMetadata.candidatesTokensDetails[].tokenCount where modality=IMAGE
  def self.call_gemini_image(input_image_path_or_paths, prompt,
                             model: "gemini-2.5-flash-image",
                             input_mime: "image/png",
                             aspect_ratio: nil,
                             material_table: nil,
                             view_count: nil)
    paths = Array(input_image_path_or_paths)
    url = "#{GEMINI_AIG_URL}/v1beta/models/#{model}:generateContent"
    payload = build_gemini_payload(paths, prompt,
                                   model: model, mime_type: input_mime,
                                   aspect_ratio: aspect_ratio,
                                   material_table: material_table,
                                   view_count: view_count)
    res = http_post_json(url, gemini_aig_headers, JSON.generate(payload))
    unless res.is_a?(Net::HTTPSuccess)
      raise "Gemini Image AI Gateway HTTP #{res.code}: #{res.body[0,300]}"
    end
    data = JSON.parse(res.body) rescue {}
    parts = data.dig("candidates", 0, "content", "parts") || []
    img_part = parts.find { |p| p["inlineData"] && p["inlineData"]["data"] }
    raise "No inlineData image in Gemini response: #{res.body[0,300]}" unless img_part

    b64 = img_part["inlineData"]["data"].to_s
    out_bytes = Base64.decode64(b64)

    # Output goes next to the FIRST input. Strip any role-suffix from the
    # name so we don't end up with "..._lr_geom_render.png".
    primary = paths.first
    in_dir = File.dirname(primary)
    base = File.basename(primary, ".*").sub(/_lr_(geom|raw|material|colour)$/, "_lr")
    out_path = File.join(in_dir, "#{base}_render.png")
    File.binwrite(out_path, out_bytes)

    # Token accounting: pull the IMAGE-modality candidate token count for
    # the cost meter. Older Gemini responses include candidatesTokenCount
    # at usageMetadata top level; newer ones break it down by modality.
    tokens = 0
    usage = data["usageMetadata"] || {}
    if (details = usage["candidatesTokensDetails"])
      img_detail = details.find { |d| d["modality"].to_s.upcase == "IMAGE" }
      tokens = (img_detail && img_detail["tokenCount"]).to_i if img_detail
    end
    tokens = usage["candidatesTokenCount"].to_i if tokens.zero? && usage["candidatesTokenCount"]

    [out_path, tokens]
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
    url = "#{GEMINI_AIG_URL}/v1beta/models/#{model}:streamGenerateContent?alt=sse"
    payload = JSON.generate(build_gemini_payload(image_path, prompt, model: model, mime_type: mime_type))
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
    with_flat_lighting(model) do
      success = model.active_view.write_image(filename: out_path, width: width,
                                              height: height, antialias: false,
                                              transparent: false)
      raise "write_image failed" unless success
    end
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
    with_flat_lighting(model) do
      success = model.active_view.write_image(filename: out_path, width: width,
                                              height: height, antialias: false,
                                              transparent: false,
                                              jpeg_quality: quality_f)
      raise "write_image failed" unless success
    end
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
    # Wipe the output area on Start (and only on Start). Per-frame replies
    # accumulate as separate paragraphs so the user can scroll back.
    if @tray && @tray.visible?
      @tray.execute_script("_liveClear && _liveClear();")
    end
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

  # ----- Live Render ---------------------------------------------------------
  # Captures the current view → calls Gemini 2.5 Flash Image (via AI Gateway)
  # → writes the rendered PNG to disk → pushes input + output thumbnails to
  # the tray. Each call takes ~10s and costs ~$0.0005 (1290 image tokens at
  # $0.40/M output), so we keep a low cadence (5-30s) and never block the UI
  # thread — same Queue pattern as Live Stream.

  DEFAULT_LIVE_RENDER_PROMPT = <<~P.strip
    Render this SketchUp scene as a photorealistic interior design rendering,
    soft natural light, professional 3d visualization. Preserve the geometry
    and proportions exactly. Do not add furniture, plants, or human figures
    that aren't already present in the scene.
  P

  # Image-output models for Live Render. Each entry: [id, label, hint, provider, output_$/M_token, est_per_image_$].
  #
  # Two providers wired up:
  #   :poe      → POE_ENDPOINT, returns markdown image URL on Poe CDN
  #   :gateway  → CF AI Gateway, returns inline base64 PNG (gemini-*-image direct)
  #
  # Pricing observation (verified empirically against both APIs):
  # Poe charges per-token at unified text rate, NOT the Google image-token
  # premium ($30/M for 2.5-flash-image, $120/M for 3-pro-image). So Poe is
  # 7-17× cheaper for image-out models — Google may be subsidising Poe's
  # bulk traffic, or Poe may be subsidising it themselves; either way the
  # rate-card you're billed against is what we encode here.
  #
  # PRIVACY CAVEAT for Poe paths: rendered images live at pfst.cf2.poecdn.net
  # for ~hours-days; anyone with the URL can view. Use :gateway for client-
  # confidential designs.
  LIVE_RENDER_MODELS = [
    ["nano-banana-poe",         "Nano-Banana (Poe) · cheapest ⭐",
       "Google 2.5 Flash Image via Poe · ~$0.002/img (HK$0.018) · 13s · DEFAULT for mood-board",
       :poe, 1.77e-6, 0.0023],
    ["nano-banana-pro-poe",     "Nano-Banana Pro (Poe) · best quality",
       "Google 3 Pro Image via Poe · ~$0.018/img (HK$0.14) · 33s · slower but sharper",
       :poe, 12.12e-6, 0.0175],
    ["gemini-2.5-flash-image",  "Gemini 2.5 Flash Image (CF Gateway · private)",
       "Google direct via CF AI Gateway · ~$0.039/img (HK$0.31) · 12s · CONFIDENTIAL projects (no Poe CDN)",
       :gateway, 30.0e-6, 0.0387],
    ["gemini-3-pro-image-preview", "Gemini 3 Pro Image (CF Gateway · private)",
       "Google direct via CF AI Gateway · ~$0.134/img (HK$1.05) · 13s · CONFIDENTIAL + highest quality",
       :gateway, 120.0e-6, 0.1340],
  ].freeze

  # Per-model lookup. Build once.
  def self.live_render_model_meta(id)
    LIVE_RENDER_MODELS.find { |row| row[0] == id } || LIVE_RENDER_MODELS.first
  end

  def self.live_render_provider_for(id);     live_render_model_meta(id)[3]; end
  def self.live_render_rate_for(id);         live_render_model_meta(id)[4]; end
  def self.live_render_per_image_cost(id);   live_render_model_meta(id)[5]; end

  # Capture the current view as a PNG sized for image-input. We send PNG (not
  # JPEG) because gemini-2.5-flash-image happily accepts both and PNG keeps
  # SketchUp lines crisp (the ~3MB cost of an extra-quality input is fine
  # given the model latency dominates).
  def self.export_view_for_live_render(width, height, multi_view: false, boost_contrast: false)
    model = Sketchup.active_model
    raise "No model" unless model
    base = model.path.empty? ? "Untitled" : File.basename(model.path, ".skp")
    base = base.gsub(/[^\w一-鿿\-]/, "_")
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%L")
    out_dir = if model.path.empty?
                File.expand_path("~/Desktop/gpt_render/live_render")
              else
                File.join(File.dirname(model.path), "gpt_render", "live_render")
              end
    FileUtils.mkdir_p(out_dir)

    write_one = ->(suffix, style) {
      out = File.join(out_dir, "#{timestamp}_#{base}_lr_#{suffix}.png")
      do_write = lambda {
        ok = model.active_view.write_image(filename: out, width: width,
                                           height: height, antialias: true,
                                           transparent: false)
        raise "write_image #{suffix} failed" unless ok
      }
      # Magenta marker background ONLY for shaded captures (Image 2). Hidden
      # Line in SU paints faces with the default white face-front, so the
      # background only shows through window/door OPENINGS — that's where
      # we want magenta. But Hidden Line's edges-on-bg drawing means a
      # magenta bg paints the entire viewport magenta wherever there's
      # nothing to occlude (interior shots → all magenta). Skip the marker
      # for Hidden Line; clean default white bg is the right input for the
      # AI's geometry signal.
      with_face_style(model, style) do
        if style == "hidden_line"
          with_flat_lighting(model) do
            with_clean_edges(model, &do_write)
          end
        else
          with_marker_background(model) do
            with_flat_lighting(model, &do_write)
          end
        end
      end
      out
    }

    if multi_view
      # 2-pass capture for multi-image conditioning:
      #   geom  = Hidden Line — pure geometry constraint
      #   colour = Shaded (NO texture, just flat material colours) — clean
      #            HEX zones the model can cross-reference against the
      #            material-table HEX column. Texture detail comes from
      #            separately-uploaded texture swatches; bundling textures
      #            into View 2 confuses the diffusion model because the
      #            texture noise muddies the colour-to-material mapping.
      #
      # v0.6.2 — when boost_contrast is on, only Image 2 (Shaded) gets
      # the synthetic-palette treatment. Hidden Line shows pure edges, no
      # fills, so recolouring there would be wasted work and risk extra
      # undo-stack churn.
      geom_path = write_one.("geom", "hidden_line")
      colour_path =
        if boost_contrast
          mats = collect_used_materials(model)
          with_segmentation_palette(model, mats) do
            write_one.("colour", "shaded")
          end
        else
          write_one.("colour", "shaded")
        end
      [geom_path, colour_path]
    else
      # Single-view: keep the textured shaded for backward compat (shows
      # what a designer eyeballs). Boost contrast intentionally has no
      # effect here — single-view skips the material table cross-reference.
      [write_one.("raw", "shaded_with_texture")]
    end
  end

  # Temporarily set RenderMode (face style) for the active view, restore on
  # exit. Used to capture multiple views of the same scene in different
  # styles for multi-image conditioning. RenderMode integer values vary by
  # SU version, so the caller passes a name we map locally; unknown names
  # fall through to a no-op restore-only.
  RENDER_MODES = {
    "wireframe"          => 0,
    "hidden_line"        => 1,
    "shaded"             => 2,
    "shaded_with_texture"=> 3,
    "monochrome"         => 4,
    "xray"               => 5,
  }.freeze

  # Hidden-Line captures look "sketchy" by default — Profiles emphasises
  # silhouettes with thick lines, Depth Cue fades distant edges, Jitter +
  # Extension add hand-drawn artistic effects. ALL of those add noise to
  # what the AI sees. We force them off during capture and restore on exit.
  def self.with_clean_edges(model)
    ro = model.rendering_options rescue nil
    saved = {}
    keys = ["DrawProfilesOnly", "DrawProfile", "DrawProfiles", "EdgeProfileWidth",
            "DrawDepthQue", "JitterEdges", "ExtendEdges", "DrawHidden",
            "DisplayInstructions", "DisplaySketchAxes", "DisplaySectionCuts"]
    if ro
      keys.each { |k| saved[k] = ro[k] rescue nil }
      ro["DrawProfilesOnly"] = false rescue nil
      ro["DrawProfile"]      = false rescue nil
      ro["DrawProfiles"]     = false rescue nil
      ro["EdgeProfileWidth"] = 0     rescue nil   # 0 = no extra silhouette weight
      ro["DrawDepthQue"]     = false rescue nil   # no fade on far edges
      ro["JitterEdges"]      = false rescue nil   # no sketchy hand-drawn lines
      ro["ExtendEdges"]      = false rescue nil   # no extending past corners
      ro["DrawHidden"]       = false rescue nil   # no see-through ghost edges
    end
    begin
      yield
    ensure
      if ro
        saved.each { |k, v| ro[k] = v rescue nil unless v.nil? }
      end
    end
  end

  def self.with_face_style(model, style_name)
    ro = model.rendering_options rescue nil
    saved = (ro["RenderMode"] rescue nil)
    target = RENDER_MODES[style_name]
    if ro && target
      ro["RenderMode"] = target rescue nil
      model.active_view.refresh rescue nil
    end
    begin
      yield
    ensure
      if ro && !saved.nil?
        ro["RenderMode"] = saved rescue nil
        model.active_view.refresh rescue nil
      end
    end
  end

  # Pure magenta — a colour that effectively never appears in real interior
  # photos, so AI image models treat it as a marker rather than as material.
  # Used to paint the SU "world view" (sky/ground beyond walls) while the
  # capture runs, so window openings stand out as magenta instead of being
  # indistinguishable from white interior walls.
  WINDOW_MARKER_RGB = [255, 0, 255].freeze

  # v0.6.2 — Boost material contrast palette for the Shaded view.
  # Real HK residential SU files use very similar colours (white walls
  # #F0F0E8, cream cabinets #E8DCC0, light oak #B8A582) so Image 2's
  # flat-colour zones blend together and the AI can't reliably tell which
  # region is which material. When the user toggles "Boost material
  # contrast" ON, each scoped material is temporarily re-painted with a
  # synthetic high-contrast colour from this fixed palette so Image 2's
  # zones become unambiguous.
  #
  # Pure magenta #FF00FF is deliberately EXCLUDED — that's already reserved
  # as the window-opening marker (see WINDOW_MARKER_RGB). If a model has
  # more than 12 used materials, the palette wraps; the material table
  # still distinguishes them by name + Original HEX.
  SEGMENTATION_PALETTE = %w[
    #FF0000  #00FF00  #0000FF
    #FFFF00  #00FFFF  #FF8000
    #80FF00  #0080FF  #8000FF
    #FF0080  #00FF80  #804000
  ].freeze

  # Temporarily re-paint each material in `materials` with a colour from
  # SEGMENTATION_PALETTE, yield, then ALWAYS restore the originals — even
  # if the block raises. Uses model.start_operation(transparent: true)
  # + model.abort_operation so the recolour is a silent in-memory edit
  # that never appears in the user's undo history. CRITICAL: abort runs
  # in an ensure block so the .skp's material colours are never persisted
  # to the user's file, even on an exception during capture.
  #
  # Belt-and-braces: we also keep an explicit per-material colour snapshot
  # and re-apply it after abort if the colour didn't come back. Real SU's
  # abort_operation rolls back in-operation mutations, so the manual
  # restore is a no-op there; on platforms / stubs where abort doesn't
  # actually undo, the manual path catches it. Either way the .skp's
  # material colours are guaranteed to be unchanged after the call.
  #
  # Falls through (just yields) if the model has no start_operation —
  # keeps unit tests with minimal stubs working.
  def self.with_segmentation_palette(model, materials)
    return yield unless model && model.respond_to?(:start_operation)
    materials = (materials || []).compact
    saved = materials.map { |m| [m, (m.color rescue nil)] }
    began = false
    begin
      began = !!(model.start_operation("hohome_segmentation_capture", true, false, true) rescue nil)
      materials.each_with_index do |m, idx|
        hex = SEGMENTATION_PALETTE[idx % SEGMENTATION_PALETTE.length]
        r = hex[1, 2].to_i(16)
        g = hex[3, 2].to_i(16)
        b = hex[5, 2].to_i(16)
        if defined?(Sketchup::Color)
          (m.color = Sketchup::Color.new(r, g, b)) rescue nil
        else
          (m.color = [r, g, b]) rescue nil
        end
      end
      yield
    ensure
      # 1) Abort the silent operation — in real SU this rolls back the
      #    in-operation colour mutations with no undo-history entry.
      if began
        (model.abort_operation rescue nil)
      end
      # 2) Defensive per-material restore. Skipped when the colour is
      #    already back to its original (real SU's abort handled it),
      #    so we don't add redundant writes that could leak into undo.
      saved.each do |m, c|
        next if c.nil?
        cur = (m.color rescue nil)
        already_restored =
          cur && cur.respond_to?(:red) && c.respond_to?(:red) &&
          cur.red == c.red && cur.green == c.green && cur.blue == c.blue
        next if already_restored
        (m.color = c) rescue nil
      end
    end
  end

  # Walk the entity tree and collect the materials actually assigned to
  # something — front + back face materials + group/component
  # materials, recursing into definitions. We don't touch the model
  # (no `purge_unused`), so the user's clutter library stays as-is.
  # Shared preamble builder — both Poe and CF Gateway image paths use this
  # so the multi-view conditioning rules and material-table reference are
  # identical regardless of provider. Single-view falls through to the user
  # prompt unchanged.
  def self.build_multi_view_preamble(num_views, user_prompt, material_table = nil, boost_on: nil)
    return user_prompt if num_views < 2

    # If the caller didn't explicitly say, infer from the table header —
    # collect_model_material_table emits "Original HEX" only when
    # boost_on:true. This lets call_poe_image_for_live_render and
    # build_gemini_payload thread the flag through implicitly without
    # widening their signatures (kept narrow per v0.6.2 design rules).
    if boost_on.nil?
      boost_on = material_table.is_a?(String) && material_table.include?("Original HEX")
    end

    image2_caption =
      if boost_on
        # v0.6.2 — Image 2 uses synthetic palette colours, not real ones.
        <<~I2.chomp
          • Image 2 (SHADED — SYNTHETIC contrast palette, NOT the materials'
            actual colours): each material has been temporarily re-painted
            with a high-contrast palette colour so each region is
            unambiguous. The "HEX" column in the material table below is
            that synthetic palette colour — use it ONLY to map "this region
            in Image 2 = which row in the table". The "Original HEX"
            column is the REAL material colour you should render. Do NOT
            paint synthetic palette colours into the output. Geometry is
            locked by Image 1.
        I2
      else
        <<~I2.chomp
          • Image 2 (SHADED — flat colour zones, NO texture): tells you
            which region uses which material. Each visible solid colour
            matches the HEX column in the material table below; that is
            how you map "which region is which material". Geometry is
            locked by Image 1.
        I2
      end

    views_section = <<~V
      You are receiving #{num_views} views of the SAME 3D scene from the
      SAME camera. Treat each view as a different conditioning signal:

        • Image 1 (HIDDEN-LINE wireframe): EXACT geometry constraint. Every
          edge, corner, and panel division MUST appear in your output — do
          NOT smooth, round, merge, or invent geometry.
      #{image2_caption}
    V

    capture_section = <<~CAP
      IMPORTANT — capture convention:
        • Any pure MAGENTA (#FF00FF) regions in the views are NOT walls or
          surfaces. They are OPENINGS — windows, doors, or arches — where
          the scene sees through to the outside world. Replace each magenta
          region with a realistic outdoor view through a transparent glass
          pane appropriate to a Hong Kong residential setting (distant
          building façades, sky, soft daylight). NEVER render magenta as
          a colour itself.
    CAP

    table_section =
      if material_table && !material_table.empty?
        if boost_on
          <<~TBL
            ====== MATERIAL REFERENCE (from active SketchUp model) ======

            Image 2 uses a SYNTHETIC contrast palette (not the materials'
            actual colours) so each material's region is unambiguous. The
            "HEX" column below is the synthetic palette colour you'll see
            in Image 2; the "Original HEX" column is the real material
            colour you should render.

            #{material_table}

            For every visible coloured region in Image 2, match its
            synthetic HEX to a row above, then render that region in the
            named material's REAL appearance (use the Original HEX as the
            base colour, plus realistic texture / weave / grain / sheen).
            Do NOT paint synthetic palette colours into the output. Do NOT
            invent materials beyond this list.

            The "Texture ref" column may say "Image N" — those are TEXTURE
            SWATCHES uploaded as additional input images (after the view
            captures). Each swatch is the RAW source image from the .skp's
            texture slot — the user may have set an HSL / opacity override
            on the material so the actual in-scene appearance is "swatch
            image × HEX colour" with the material's alpha. The HEX in the
            row tells you the override / tint colour the user set:

              • If swatch dominant tone ≈ HEX → no meaningful tint, render
                the swatch's natural appearance.
              • If HEX is clearly different from the swatch's average tone
                (e.g. swatch is grey concrete, HEX is warm beige) → apply
                the HEX as a multiply-blend tint over the swatch's pattern.
              • If a row's hint says "translucent" → render with that
                translucency (frosted / tinted glass etc.).

            NEVER include the swatch itself as a scene element — it is
            reference only.
          TBL
        else
          <<~TBL
            ====== MATERIAL REFERENCE (from active SketchUp model) ======

            #{material_table}

            For every visible coloured region in the render, match it to a row
            above by HEX and render that region as the named material would
            look in a real photograph (real wood grain, real fabric weave,
            real metal sheen, real glass refraction). Do NOT invent materials
            beyond this list.

            The "Texture ref" column may say "Image N" — those are TEXTURE
            SWATCHES uploaded as additional input images (after the view
            captures). Each swatch is the RAW source image from the .skp's
            texture slot — the user may have set an HSL / opacity override
            on the material so the actual in-scene appearance is "swatch
            image × HEX colour" with the material's alpha. The HEX in the
            row tells you the override / tint colour the user set:

              • If swatch dominant tone ≈ HEX → no meaningful tint, render
                the swatch's natural appearance.
              • If HEX is clearly different from the swatch's average tone
                (e.g. swatch is grey concrete, HEX is warm beige) → apply
                the HEX as a multiply-blend tint over the swatch's pattern.
              • If a row's hint says "translucent" → render with that
                translucency (frosted / tinted glass etc.).

            NEVER include the swatch itself as a scene element — it is
            reference only.
          TBL
        end
      else
        ""
      end

    [views_section.chomp, "",
     capture_section.chomp, "",
     table_section.chomp, "",
     "====== USER INSTRUCTION ======",
     user_prompt
    ].reject(&:empty?).join("\n\n")
  end

  # Scope priority (a .skp may hold many rooms; only the active one matters):
  #   1. Active selection (if any)
  #   2. Currently-edited container (user double-clicked into a Group/Comp)
  #   3. Whole model (fallback)
  # Returns [enumerable_entities, scope_label_string].
  def self.live_render_material_scope(model)
    return [nil, "(none)"] unless model
    sel = (model.selection rescue nil)
    if sel && !sel.empty?
      return [sel.to_a, "selection (#{sel.size} entities)"]
    end
    active = (model.active_entities rescue nil)
    if active && active.respond_to?(:object_id) &&
       (model.entities rescue nil) &&
       active.object_id != model.entities.object_id
      label = "open container"
      ap = (model.active_path rescue nil)
      if ap && !ap.empty?
        last = ap.last
        nm = (last.respond_to?(:definition) ? last.definition.name : last.name) rescue nil
        label = "open container · #{nm}" if nm && !nm.empty?
      end
      return [active, label]
    end
    [model.entities, "whole model"]
  end

  # Extract texture images from the materials in the active scope so we
  # can attach them as Gemini reference inlineData. SU's Sketchup::Texture
  # has a #write(filepath) method (SU 2018+) that saves the texture to
  # disk in its original format. We dump up to MAX_TEXTURES into a temp
  # dir and return a list of {material:, path:, name:, hex:} so the
  # call site can both attach them as inline images and label them in
  # the material table.
  MAX_TEXTURES_PER_RENDER  = 8
  # Skip texture upload for any texture whose file is larger than this.
  # Token cost note: Gemini tiles each input image ~768×768 = ~258 tokens.
  # A 1024² PNG is fine (~258 tokens); a 4K texture image splits into many
  # tiles and inflates input cost. 500 KB ~ 1024² PNG ceiling.
  # NOTE: SU Ruby API has no native resize, so v0.6.1 just SKIPS oversized
  # textures (the material stays in the table by name+hex; the AI gets
  # less detail for that one but the cost stays bounded). v0.6.2 plans to
  # add an in-Ruby ImageRep bilinear-downscale for true downsize.
  MAX_TEXTURE_FILE_BYTES = 500 * 1024

  def self.extract_used_textures(model, out_dir, max_count: MAX_TEXTURES_PER_RENDER)
    materials = collect_used_materials(model)
    textures = []
    skipped_too_large = []
    materials.each do |m|
      break if textures.length >= max_count
      next unless m && m.respond_to?(:texture) && m.texture
      tex = m.texture
      next unless tex.respond_to?(:write)
      name = (m.respond_to?(:display_name) ? m.display_name : m.name).to_s
      next if name.empty?
      ext = ((tex.filename rescue "") || "").split(".").last.to_s.downcase
      ext = "png" unless %w[png jpg jpeg].include?(ext)
      safe_name = name.gsub(/[^\w一-鿿\-]/, "_")[0, 40]
      out = File.join(out_dir, "tex_#{textures.length + 1}_#{safe_name}.#{ext}")
      ok = (tex.write(out, false) rescue false)
      next unless ok && File.exist?(out) && File.size(out) > 0
      sz = File.size(out)
      if sz > MAX_TEXTURE_FILE_BYTES
        File.delete(out) rescue nil
        skipped_too_large << "#{name} (#{(sz / 1024.0).round} KB)"
        next
      end
      c = (m.color rescue nil)
      hex = c ? format("#%02X%02X%02X", c.red, c.green, c.blue) : "(none)"
      textures << { material: m, path: out, name: name, hex: hex,
                    mime: ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/png" }
    end
    if !skipped_too_large.empty?
      puts "[GPT Render Live] textures skipped (>#{MAX_TEXTURE_FILE_BYTES/1024} KB): #{skipped_too_large.join(', ')}"
    end
    textures
  end

  def self.collect_used_materials(model)
    return [] unless model && model.respond_to?(:entities)
    scope, label = live_render_material_scope(model)
    return [] unless scope
    puts "[GPT Render Live] material scope: #{label}"
    seen = {}   # object_id → material (dedup)
    visit = lambda do |entities|
      next unless entities
      entities.each do |e|
        next unless e
        mat = (e.material rescue nil)
        seen[mat.object_id] = mat if mat
        bm = (e.respond_to?(:back_material) ? (e.back_material rescue nil) : nil)
        seen[bm.object_id] = bm if bm
        defn = if e.is_a?(Sketchup::Group)
                 (e.respond_to?(:definition) ? (e.definition rescue nil) : (e.entities rescue nil))
               elsif e.is_a?(Sketchup::ComponentInstance)
                 (e.respond_to?(:definition) ? (e.definition rescue nil) : nil)
               end
        if defn
          inner = (defn.respond_to?(:entities) ? defn.entities : defn)
          visit.call(inner) if inner
        end
      end
    end
    visit.call(scope)
    seen.values
  end

  # Markdown table of in-use materials. With texture_meta: passes in the
  # extracted-texture list so the table can label each textured material
  # with its uploaded "Image #" — the model can then look up which inline
  # image is the texture swatch for that material.
  #
  # When boost_on: is true (v0.6.2 — Boost material contrast), the HEX
  # column shows the SYNTHETIC palette colour each material was repainted
  # to in Image 2 (the Shaded view), and a 5th "Original HEX" column is
  # added so Gemini still knows the real material colour to render. The
  # row order MUST match the order with_segmentation_palette assigned
  # palette colours (i.e. collect_used_materials order, palette wraps
  # past index 11), otherwise the synthetic-HEX in the table won't align
  # with what's visible in Image 2.
  def self.collect_model_material_table(model, texture_meta: [], view_count: 1, boost_on: false)
    materials = collect_used_materials(model)
    # Map material.object_id → image number (1-indexed, in the order they
    # appear in the request: views first, then textures).
    img_for = {}
    texture_meta.each_with_index do |tm, idx|
      img_for[tm[:material].object_id] = view_count + 1 + idx if tm[:material]
    end

    rows = []
    palette_idx = 0
    materials.each do |m|
      next unless m
      name = (m.respond_to?(:display_name) ? m.display_name : m.name).to_s
      next if name.empty?
      c = m.color rescue nil
      real_hex = c ? format("#%02X%02X%02X", c.red, c.green, c.blue) : "(none)"
      synthetic_hex =
        if boost_on
          SEGMENTATION_PALETTE[palette_idx % SEGMENTATION_PALETTE.length]
        else
          nil
        end
      palette_idx += 1
      tex = (m.respond_to?(:texture) && m.texture) ? m.texture : nil
      tex_hint =
        if tex
          fn = (tex.filename rescue "") || ""
          fn.empty? ? "textured" : "tex: #{File.basename(fn)}"
        else
          alpha = m.respond_to?(:alpha) ? (m.alpha rescue 1.0) : 1.0
          alpha && alpha < 0.95 ? "translucent" : "solid"
        end
      img_ref = img_for[m.object_id] ? "Image #{img_for[m.object_id]}" : "—"
      if boost_on
        rows << "| `#{synthetic_hex}` | #{name} | #{tex_hint} | #{img_ref} | `#{real_hex}` |"
      else
        rows << "| `#{real_hex}` | #{name} | #{tex_hint} | #{img_ref} |"
      end
    end
    return "" if rows.empty?
    rows = rows.first(30)
    if boost_on
      (
        ["| HEX | Material name | Hint | Texture ref | Original HEX |",
         "|---|---|---|---|---|"] + rows
      ).join("\n")
    else
      (
        ["| HEX | Material name | Hint | Texture ref |",
         "|---|---|---|---|"] + rows
      ).join("\n")
    end
  end

  def self.with_marker_background(model)
    ro = model.rendering_options rescue nil
    saved = {}
    keys = ["BackgroundColor", "SkyColor", "GroundColor", "DrawHorizon",
            "DrawGround", "DisplayHorizon", "DisplayGround", "DisplaySky",
            "BackgroundColorIsCustom"]
    if ro
      keys.each { |k| saved[k] = ro[k] rescue nil }
      magenta = (defined?(Sketchup::Color) ? Sketchup::Color.new(*WINDOW_MARKER_RGB) : WINDOW_MARKER_RGB) rescue nil
      if magenta
        ro["BackgroundColor"] = magenta rescue nil
        ro["SkyColor"]        = magenta rescue nil
        ro["GroundColor"]     = magenta rescue nil
      end
      ro["DrawHorizon"]    = false rescue nil
      ro["DrawGround"]     = false rescue nil
      ro["DisplayHorizon"] = false rescue nil
      ro["DisplayGround"]  = false rescue nil
      ro["DisplaySky"]     = false rescue nil
    end
    begin
      yield
    ensure
      if ro
        saved.each { |k, v| ro[k] = v rescue nil unless v.nil? }
      end
    end
  end

  # Temporarily flatten SU's lighting so a capture writes flat material colours
  # — no soft shading, no sun shadows, no ground shadows. Restored on exit
  # (including when the block raises). Yielded around any write_image that
  # gets fed to a vision model.
  def self.with_flat_lighting(model)
    si = model.shadow_info rescue nil
    ro = model.rendering_options rescue nil
    saved = {}
    keys_si = ["UseSunForShading", "DisplayShadows", "DisplayOnAllFaces",
               "DisplayOnGroundPlane"]
    keys_ro = ["DisplayInstructions", "ModelTransparency", "DisplaySectionPlanes"]
    if si
      keys_si.each { |k| saved[[:si, k]] = si[k] rescue nil }
    end
    if ro
      keys_ro.each { |k| saved[[:ro, k]] = ro[k] rescue nil }
    end
    begin
      if si
        # Both keys may not exist on older SU versions — `rescue nil` guards them.
        si["UseSunForShading"] = false rescue nil
        si["DisplayShadows"]   = false rescue nil
      end
      yield
    ensure
      saved.each do |(target, k), v|
        next if v.nil?
        case target
        when :si then si[k] = v rescue nil if si
        when :ro then ro[k] = v rescue nil if ro
        end
      end
    end
  end

  def self.start_live_render
    if @liverender[:enabled]
      puts "[GPT Render Live] start: already enabled — ignoring"
      return
    end
    @liverender[:enabled]    = true
    @liverender[:stop_flag]  = false
    @liverender[:queue]      = Queue.new
    @liverender[:in_flight]  = false
    cfg = load_config
    interval = (cfg["live_render_interval"] || 15).to_i.clamp(5, 600)

    push_live_render_state(true)
    push_live_render_status("Live Render: ON (#{interval}s) — first frame in ~1s", "ok")
    puts "[GPT Render Live] start: enabled=true interval=#{interval}s"

    # Drain queue from main thread.
    @liverender[:poll_timer] = UI.start_timer(0.2, true) { drain_live_render_queue }

    # Kick the first frame directly (no 0.05s indirection — was too short
    # under SU's timer scheduler). Then re-arm a recurring `interval` timer.
    UI.start_timer(0.5, false) do
      puts "[GPT Render Live] first-tick fired (enabled=#{@liverender[:enabled]} in_flight=#{@liverender[:in_flight]})"
      kick_live_render_frame if @liverender[:enabled] && !@liverender[:in_flight]
      @liverender[:tick_timer] = UI.start_timer(interval, true) do
        puts "[GPT Render Live] recurring-tick fired (enabled=#{@liverender[:enabled]} in_flight=#{@liverender[:in_flight]})"
        kick_live_render_frame if @liverender[:enabled] && !@liverender[:in_flight]
      end
    end
    puts "[GPT Render] Live Render started"
  end

  def self.stop_live_render
    return unless @liverender[:enabled]
    @liverender[:enabled]   = false
    @liverender[:stop_flag] = true
    if @liverender[:tick_timer]
      UI.stop_timer(@liverender[:tick_timer]); @liverender[:tick_timer] = nil
    end
    if @liverender[:poll_timer]
      UI.stop_timer(@liverender[:poll_timer]); @liverender[:poll_timer] = nil
    end
    @liverender[:bg_thread] = nil
    @liverender[:queue]     = nil
    @liverender[:in_flight] = false
    push_live_render_state(false)
    push_live_render_status("Live Render: OFF", "ok")
    puts "[GPT Render] Live Render stopped"
  end

  def self.toggle_live_render
    @liverender[:enabled] ? stop_live_render : start_live_render
  end

  def self.kick_live_render_frame
    unless @liverender[:enabled]
      puts "[GPT Render Live] kick: not enabled, skip"; return
    end
    if @liverender[:in_flight]
      puts "[GPT Render Live] kick: in_flight, skip"; return
    end
    cfg = load_config
    prompt = cfg["live_render_prompt"] || DEFAULT_LIVE_RENDER_PROMPT
    model  = cfg["live_render_model"]  || LIVE_RENDER_MODELS.first[0]
    width  = (cfg["live_render_width"]  || 1024).to_i
    height = (cfg["live_render_height"] || 1024).to_i
    aspect = cfg["live_render_aspect"] || "1:1"   # 1:1, 16:9, 9:16, 4:3, 3:4
    multi  = cfg["live_render_multi_view"] != false   # default ON in v0.5.7+
    upload_textures = cfg["live_render_upload_textures"] != false   # default ON
    # v0.6.2 — Boost material contrast for the Shaded view. Default OFF;
    # only meaningful when multi_view is on (single-view doesn't use the
    # material-table cross-reference).
    boost_contrast = (cfg["live_render_boost_contrast"] != false) && multi   # default ON in v0.6.4+
    puts "[GPT Render Live] kick: capturing #{width}x#{height} model=#{model} aspect=#{aspect} multi=#{multi} textures=#{upload_textures} boost=#{boost_contrast}"

    raw_paths = nil
    texture_meta = []
    begin
      raw_paths = export_view_for_live_render(width, height, multi_view: multi, boost_contrast: boost_contrast)
      puts "[GPT Render Live] capture OK: #{raw_paths.length} view(s) → #{raw_paths.map { |p| File.basename(p) }.join(', ')}"
      if upload_textures
        # Drop textures into a sibling subdir so cleanup is one rmtree.
        tex_dir = File.join(File.dirname(raw_paths.first), "textures")
        FileUtils.mkdir_p(tex_dir)
        texture_meta = extract_used_textures(Sketchup.active_model, tex_dir)
        puts "[GPT Render Live] textures attached: #{texture_meta.length}"
      end
    rescue => e
      puts "[GPT Render Live] capture FAIL: #{e.class}: #{e.message}"
      push_live_render_status("Capture failed: #{e.message}", "err")
      return
    end
    # Material table now references texture image numbers (views are 1..N,
    # textures are N+1..N+T, in the order they're added to the request).
    # When boost_contrast is on, the table's HEX column shows the synthetic
    # palette colour with a 5th "Original HEX" column for the real colour.
    mat_table = collect_model_material_table(Sketchup.active_model,
                                             texture_meta: texture_meta,
                                             view_count: raw_paths.length,
                                             boost_on: boost_contrast)
    texture_paths = texture_meta.map { |t| t[:path] }
    all_input_paths = raw_paths + texture_paths
    # In multi-view mode raw_paths is [geom, shaded]; in single-view it's [shaded].
    geom_path   = raw_paths.length >= 2 ? raw_paths.first : nil
    shaded_path = raw_paths.last
    raw_path    = shaded_path  # back-compat for downstream code that wants "the" capture
    push_live_render_frame(geom_path, shaded_path, nil)
    @liverender[:in_flight] = true
    push_live_render_status("Rendering (#{model}) ~10s…", "busy")
    puts "[GPT Render Live] kick: bg thread starting…"

    provider = live_render_provider_for(model)
    @liverender[:bg_thread] = Thread.new do
      q = @liverender[:queue]
      started = Time.now
      begin
        # Bail before we even hit the wire if user already pressed Stop.
        if @liverender[:stop_flag]
          q << [:flight_done, nil] if q
          next
        end
        render_path, tokens =
          if provider == :poe
            call_poe_image_for_live_render(all_input_paths, prompt, model,
                                            material_table: mat_table,
                                            view_count: raw_paths.length)
          else
            call_gemini_image(all_input_paths, prompt,
                              model: model,
                              input_mime: "image/png",
                              aspect_ratio: aspect,
                              material_table: mat_table,
                              view_count: raw_paths.length)
          end
        elapsed = (Time.now - started).round(1)
        puts "[GPT Render Live] render OK (#{provider}): #{render_path} (#{tokens} tokens, #{elapsed}s)"
        # Default: drop ALL raw SU views + extracted texture swatches we just
        # sent — only the AI render is interesting to keep. Texture swatches
        # always go (they're regenerated each tick from the .skp); raw views
        # respect live_render_keep_raw.
        texture_paths.each { |p| File.delete(p) rescue nil if p && File.exist?(p) }
        # Try to remove the texture subdir if empty (best-effort).
        if !texture_paths.empty?
          tex_dir = File.dirname(texture_paths.first)
          (Dir.rmdir(tex_dir) rescue nil)
        end
        keep_raw = (load_config["live_render_keep_raw"] == true) rescue false
        if !keep_raw
          raw_paths.each { |p| File.delete(p) rescue nil if p && File.exist?(p) }
          raw_path = nil  # so push_live_render_frame doesn't try to display deleted files
        end
        # Drop the result if user hit Stop while we were rendering — don't
        # push stale frames into a paused tab.
        if @liverender[:stop_flag]
          q << [:flight_done, nil] if q
          next
        end
        q << [:render, {
          raw_path:    raw_path,
          render_path: render_path,
          prompt:      prompt,
          model:       model,
          tokens:      tokens,
          elapsed:     elapsed,
          ts:          Time.now.iso8601,
        }] if q
      rescue => e
        puts "[GPT Render Live] render FAIL: #{e.class}: #{e.message[0,300]}"
        puts e.backtrace.first(3).join("\n  ")
        q << [:err, "#{e.class}: #{e.message}"] if q
      ensure
        q << [:flight_done, nil] if q
      end
    end
  end

  # Drain queue. Runs on main UI thread via UI.start_timer.
  def self.drain_live_render_queue
    q = @liverender[:queue]
    return unless q
    until q.empty?
      kind, payload = q.pop(true) rescue break
      case kind
      when :render
        record_live_render(payload)
        # The render-side push: only the rendered output is new at this
        # point — geom + shaded inputs were already pushed before the bg
        # call, so we pass nil for those to avoid re-fetching.
        push_live_render_frame(nil, nil, payload[:render_path])
        push_live_render_done(payload)
        push_live_render_status(
          "Rendered in #{payload[:elapsed]}s · #{payload[:tokens]} img tokens", "ok"
        )
      when :err
        push_live_render_status("Render error: #{payload.to_s[0,140]}", "err")
      when :flight_done
        @liverender[:in_flight] = false
      end
    end
  end

  # Persist a render to history (in-memory ring + JSONL on disk for audit).
  def self.record_live_render(entry)
    @liverender[:current_render] = entry
    @liverender[:history] ||= []
    @liverender[:history].unshift(entry)
    if @liverender[:history].length > (@liverender[:history_max] || 8)
      @liverender[:history] = @liverender[:history].first(@liverender[:history_max])
    end
    log_live_render(entry)
    bump_live_render_count(entry[:tokens] || 0, entry[:model])
  end

  def self.log_live_render(entry)
    dir = history_dir
    return unless dir
    out_dir = File.join(dir, "live_render")
    FileUtils.mkdir_p(out_dir)
    log_path = File.join(out_dir, "live_render_#{Time.now.strftime('%Y%m%d')}.jsonl")
    File.open(log_path, "a") { |f|
      f.puts JSON.generate({
        "ts"       => entry[:ts],
        "model"    => entry[:model],
        "tokens"   => entry[:tokens],
        "elapsed"  => entry[:elapsed],
        "raw"      => File.basename(entry[:raw_path].to_s),
        "render"   => File.basename(entry[:render_path].to_s),
        "prompt"   => entry[:prompt],
      })
    }
  end

  def self.bump_live_render_count(tokens = 0, model = nil)
    cfg = load_config
    today = Time.now.strftime("%Y-%m-%d")
    cfg["live_render_counts"] ||= {}
    cfg["live_render_counts"][today] = (cfg["live_render_counts"][today] || 0) + 1
    cfg["live_render_tokens"] ||= {}
    cfg["live_render_tokens"][today] = (cfg["live_render_tokens"][today] || 0) + tokens.to_i
    # USD running total — uses per-model rate so Poe vs Gateway costs sum correctly
    rate = live_render_rate_for(model || cfg["live_render_model"])
    cost_delta = (tokens.to_i * rate)
    cfg["live_render_cost_usd"] ||= {}
    cfg["live_render_cost_usd"][today] =
      ((cfg["live_render_cost_usd"][today] || 0.0) + cost_delta).round(6)
    save_config(cfg)
  end

  def self.live_render_count_today
    cfg = load_config
    today = Time.now.strftime("%Y-%m-%d")
    (cfg["live_render_counts"] || {})[today] || 0
  end

  def self.live_render_tokens_today
    cfg = load_config
    today = Time.now.strftime("%Y-%m-%d")
    (cfg["live_render_tokens"] || {})[today] || 0
  end

  # Daily cost — sum across whatever models the user invoked today (each
  # bump applies the model's own rate). For schemas migrated from earlier
  # versions that only have :live_render_tokens, fall back to assuming the
  # current default model's rate so old data still shows ~something useful.
  def self.live_render_cost_today
    cfg = load_config
    today = Time.now.strftime("%Y-%m-%d")
    if cfg["live_render_cost_usd"] && cfg["live_render_cost_usd"][today]
      return cfg["live_render_cost_usd"][today].to_f.round(4)
    end
    # Legacy fallback for pre-v0.5.6 data that only stored tokens
    tokens = live_render_tokens_today
    rate = live_render_rate_for(cfg["live_render_model"] || LIVE_RENDER_MODELS.first[0])
    (tokens * rate).round(4)
  end

  # Approximate USD→HKD. Pegged 7.75–7.85 since 1983; using 7.85 covers
  # the full peg band so we never under-show the local figure. We bake this
  # in (no FX API call) — the cost meter is informational, not invoiceable.
  USD_TO_HKD = 7.85

  # Cost in HKD for today's rendering (UI shows both USD and HKD).
  def self.live_render_cost_today_hkd
    (live_render_cost_today * USD_TO_HKD).round(3)
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
  @liverender_material_timer ||= nil
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
  # Live Render state — separate tab, ~10s per render, captures view → calls
  # gemini-2.5-flash-image → renders the result image side-by-side with the
  # input frame. Same Queue + bg_thread + poll_timer pattern as Live Stream
  # because each call blocks ~10s and we MUST not block the SU UI thread.
  #   :enabled        — true while the loop is running
  #   :stop_flag      — set true to abort an in-flight call cooperatively
  #   :in_flight      — true while a render call is mid-flight
  #   :history        — Array of {ts:, raw_path:, render_path:, prompt:, tokens:}
  #   :history_max    — keep last N (oldest evicted)
  #   :current_render — most recent {raw_path, render_path, tokens, ...}
  #   :poll_timer     — UI timer that drains :queue onto the tray
  #   :tick_timer     — recurring frame trigger between calls
  #   :queue          — Thread::Queue of [:render|:err|:flight_done, payload]
  @liverender            ||= {
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

    # Live Render state for HTML
    liver_enabled   = @liverender && @liverender[:enabled] ? true : false
    liver_interval  = (cfg["live_render_interval"]   || 15).to_i
    liver_resolution = (cfg["live_render_width"]      || 1024).to_i
    liver_aspect    = cfg["live_render_aspect"]      || "1:1"
    liver_keep_raw  = cfg["live_render_keep_raw"]    == true
    liver_multi     = cfg["live_render_multi_view"] != false   # default true
    liver_boost     = cfg["live_render_boost_contrast"] != false   # default ON in v0.6.4+
    liver_model     = cfg["live_render_model"]       || LIVE_RENDER_MODELS.first[0]
    liver_today     = live_render_count_today
    liver_cost      = live_render_cost_today
    liver_history_html = render_live_render_history_html
    liver_model_options = LIVE_RENDER_MODELS.map { |row|
      id, label, hint, _provider, _rate, per_img = row
      sel = (id == liver_model) ? " selected" : ""
      # Show "label — hint" — hint already includes price + use-case advice
      "<option value=\"#{id}\"#{sel} title=\"#{CGI.escapeHTML(hint)}\">" \
        "#{CGI.escapeHTML(label)} — #{CGI.escapeHTML(hint)}</option>"
    }.join("\n")
    liver_provider     = live_render_provider_for(liver_model)
    liver_per_image    = live_render_per_image_cost(liver_model)
    liver_per_image_hk = (liver_per_image * USD_TO_HKD).round(3)

    model_options_html = IMAGE_MODELS.map { |id, label, hint|
      sel = (id == selected_model) ? " selected" : ""
      "<option value=\"#{id}\"#{sel} title=\"#{CGI.escapeHTML(hint)}\">#{CGI.escapeHTML(label)} — #{CGI.escapeHTML(hint)}</option>"
    }.join("\n")

    <<~HTML
      <!doctype html><html><head><meta charset="utf-8">
      <style>
        * { box-sizing: border-box; }
        body { margin:0; padding:12px; font-family:-apple-system,"Helvetica Neue","PingFang HK","Microsoft JhengHei",sans-serif; font-size:13px; background:#{BRAND_TEAL_DEEP}; color:#{BRAND_TEXT}; }
        .brand { display:flex; align-items:center; gap:10px; padding:10px 4px 14px 4px; border-bottom:1px solid rgba(253,215,154,.15); margin-bottom:10px; }
        .brand img { width:36px; height:36px; flex-shrink:0; opacity:.95; }
        .brand .title { font-size:14px; font-weight:600; color:#{BRAND_CREAM}; letter-spacing:.3px; }
        .brand .tagline { font-size:10.5px; color:#{BRAND_TEXT_DIM}; margin-top:1px; letter-spacing:.4px; }
        .brand .ver { margin-left:auto; font-size:10px; color:#{BRAND_TEXT_DIM}; opacity:.7; }
        .head { display:none; }   /* legacy header replaced by .brand */
        .row { margin-bottom:10px; }
        button { background:#{BRAND_TEAL_DARKER}; color:#{BRAND_TEXT}; border:1px solid rgba(253,215,154,.18); padding:8px 14px; border-radius:5px; cursor:pointer; font-size:13px; transition:background .12s,border-color .12s; }
        button:hover { background:rgba(253,215,154,.08); border-color:rgba(253,215,154,.35); }
        button.primary { background:#{BRAND_CREAM}; border-color:#{BRAND_CREAM}; color:#{BRAND_TEAL_DEEP}; font-weight:600; padding:10px 18px; }
        button.primary:hover { background:#{BRAND_CREAM_SOFT}; }
        button.primary:disabled { opacity:.5; cursor:not-allowed; }
        button.small { font-size:11px; padding:5px 9px; }
        .grid { display:grid; grid-template-columns: 1fr 1fr; gap:6px; }
        input[type=number], input[type=text], select, textarea { background:#{BRAND_TEAL_DARKER}; color:#{BRAND_TEXT}; border:1px solid rgba(253,215,154,.18); padding:5px 8px; border-radius:4px; width:100%; font-size:13px; }
        select { cursor:pointer; }
        input:focus, select:focus, textarea:focus { outline:none; border-color:#{BRAND_CREAM}; }
        label { display:flex; flex-direction:column; gap:3px; font-size:11px; color:#{BRAND_TEXT_DIM}; }
        #status { padding:8px 10px; background:#{BRAND_TEAL_DARKER}; border-radius:4px; border-left:3px solid rgba(253,215,154,.4); font-size:12px; min-height:18px; margin-bottom:10px; color:#{BRAND_TEXT}; }
        #status.busy { border-color:#{BRAND_CREAM}; color:#{BRAND_CREAM}; }
        #status.ok { border-color:#7fb86b; color:#bcdda7; }
        #status.err { border-color:#d97064; color:#f5b6ad; }
        .preview { background:#0a0a0a; border:1px solid #2a2a2a; border-radius:4px; padding:6px; margin-bottom:10px; min-height:120px; position:relative; }
        .preview img { width:100%; display:block; border-radius:3px; cursor:zoom-in; transition:opacity .12s; }
        .preview img:hover { opacity:.85; }
        .preview img:after { content:"🔍 click to open full size"; position:absolute; }
        .preview .hint { position:absolute; bottom:10px; right:10px; background:rgba(0,0,0,.7); color:#fff; font-size:10px; padding:3px 7px; border-radius:3px; pointer-events:none; opacity:0; transition:opacity .15s; }
        .preview:hover .hint { opacity:1; }
        .preview .empty { padding:20px; text-align:center; opacity:.4; font-size:11px; }
        .liver-cell .cell-label { position:absolute; top:4px; left:6px; background:rgba(0,0,0,.6); color:#bbb; font-size:9.5px; padding:2px 6px; border-radius:2px; pointer-events:none; z-index:2; }
        .liver-cell { position:relative; }
        select { background:#2a2a2a; color:#eee; border:1px solid #3a3a3a; padding:5px 8px; border-radius:4px; width:100%; font-size:13px; }
        /* sub-tabs (Enhanced/Raw) */
        .tabs { display:flex; gap:4px; margin-bottom:6px; }
        .tabs button { padding:5px 10px; font-size:11px; background:#222; }
        .tabs button.active { background:#{BRAND_CREAM}; color:#{BRAND_TEAL_DEEP}; }
        /* main top-level tabs (Render/History) */
        .maintabs { display:flex; gap:0; margin:0 -12px 12px -12px; padding:0 12px; border-bottom:1px solid rgba(253,215,154,.15); flex-wrap:wrap; }
        .maintabs button { background:transparent; border:none; border-bottom:2px solid transparent; padding:9px 14px; color:#{BRAND_TEXT_DIM}; font-size:13px; font-weight:500; border-radius:0; cursor:pointer; }
        .maintabs button.active { color:#{BRAND_CREAM}; border-bottom-color:#{BRAND_CREAM}; }
        .maintabs button:hover:not(.active) { color:#{BRAND_TEXT}; }
        .maintabs button .badge { display:inline-block; background:rgba(253,215,154,.18); color:#{BRAND_TEXT_DIM}; font-size:10px; padding:1px 6px; border-radius:8px; margin-left:6px; }
        .maintabs button.active .badge { background:#{BRAND_CREAM}; color:#{BRAND_TEAL_DEEP}; }
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
        <div class="brand">
          #{BRAND_LOGO_DATA_URI ? %(<img src="#{BRAND_LOGO_DATA_URI}" alt="Hohome">) : ''}
          <div>
            <div class="title">#{PLUGIN_NAME}</div>
            <div class="tagline">#{PLUGIN_TAGLINE}</div>
          </div>
          <span class="ver">v#{PLUGIN_VERSION}</span>
        </div>

        <div id="upd"></div>

        <div class="maintabs">
          <button id="mt_render"  class="active" onclick="switchMainTab('render')">Render</button>
          <button id="mt_prompts" onclick="switchMainTab('prompts')">Prompts</button>
          <button id="mt_history" onclick="switchMainTab('history')">History <span class="badge" id="hist_count">#{history_count}</span></button>
          <button id="mt_aiwatch" onclick="switchMainTab('aiwatch')">AI Watch <span class="badge" id="aiw_dot">#{aiw_enabled ? '●' : ''}</span></button>
          <button id="mt_live"    onclick="switchMainTab('live')">Live Stream <span class="badge" id="live_dot">#{live_enabled ? '●' : ''}</span></button>
          <button id="mt_liver"   onclick="switchMainTab('liver')">🎨 Live Render <span class="badge" id="liver_dot">#{liver_enabled ? '●' : ''}</span></button>
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
          <div id="live_output" style="background:#0a0a0a;border:1px solid #2a2a2a;border-radius:4px;padding:10px;min-height:80px;max-height:280px;overflow-y:auto;font-size:12.5px;line-height:1.5;white-space:pre-wrap;color:#cfc;"></div>
        </div>

        <!-- ========== Live Render tab ========== -->
        <div id="liver_pane" class="pane">
          <div id="liver_status_pill" class="aiw-status #{liver_enabled ? 'on' : 'off'}">
            #{liver_enabled ? '● Rendering' : '○ Off'}
          </div>
          <div class="row">
            <button id="liver_btn" class="primary" style="width:100%" onclick="toggleLiveRender()">
              #{liver_enabled ? '■ Stop Live Render' : '▶ Start Live Render'}
            </button>
          </div>

          <div class="grid row">
            <label>Image model
              <select id="liver_model" onchange="setLiveRenderModel()">#{liver_model_options}</select>
            </label>
            <label>Render interval
              <select id="liver_interval" onchange="setLiveRenderInterval()">
                <option value="5"  #{liver_interval == 5  ? 'selected' : ''}>5s (overlaps)</option>
                <option value="10" #{liver_interval == 10 ? 'selected' : ''}>10s (overlaps)</option>
                <option value="15" #{liver_interval == 15 ? 'selected' : ''}>15s (recommended)</option>
                <option value="20" #{liver_interval == 20 ? 'selected' : ''}>20s</option>
                <option value="30" #{liver_interval == 30 ? 'selected' : ''}>30s</option>
              </select>
            </label>
          </div>

          <div class="grid row">
            <label>Capture resolution (input → Gemini)
              <select id="liver_resolution" onchange="setLiveRenderResolution()">
                <option value="512"  #{liver_resolution == 512  ? 'selected' : ''}>512×512   (~1× cost · least detail)</option>
                <option value="768"  #{liver_resolution == 768  ? 'selected' : ''}>768×768   (~1× cost)</option>
                <option value="1024" #{liver_resolution == 1024 ? 'selected' : ''}>1024×1024 (~1× cost · default ⭐)</option>
                <option value="1536" #{liver_resolution == 1536 ? 'selected' : ''}>1536×1536 (~2× cost · sharper detail)</option>
                <option value="2048" #{liver_resolution == 2048 ? 'selected' : ''}>2048×2048 (~4× cost · max detail)</option>
              </select>
            </label>
            <label>Output aspect (same cost)
              <select id="liver_aspect" onchange="setLiveRenderAspect()">
                <option value="1:1"  #{liver_aspect == "1:1"  ? 'selected' : ''}>1:1   (1024×1024 square)</option>
                <option value="16:9" #{liver_aspect == "16:9" ? 'selected' : ''}>16:9  (1344×768 widescreen)</option>
                <option value="9:16" #{liver_aspect == "9:16" ? 'selected' : ''}>9:16  (768×1344 portrait)</option>
                <option value="4:3"  #{liver_aspect == "4:3"  ? 'selected' : ''}>4:3   (1184×880 photo)</option>
                <option value="3:4"  #{liver_aspect == "3:4"  ? 'selected' : ''}>3:4   (880×1184 vertical)</option>
              </select>
            </label>
          </div>
          <div class="grid row">
            <label>Multi-view conditioning (reduces hallucination)
              <select id="liver_multi" onchange="setLiveRenderMulti()">
                <option value="1" #{liver_multi  ? 'selected' : ''}>2 views: Hidden-Line + Shaded ⭐ (recommended)</option>
                <option value="0" #{!liver_multi ? 'selected' : ''}>1 view: Shaded only (legacy / faster)</option>
              </select>
            </label>
            <label>Boost material contrast for Shaded view
              <select id="liver_boost" onchange="setLiveRenderBoost()">
                <option value="1" #{liver_boost  ? 'selected' : ''}>ON ⭐ (synthetic palette · cleaner segmentation · default)</option>
                <option value="0" #{!liver_boost ? 'selected' : ''}>OFF (use real material colours · for accurate before-after)</option>
              </select>
            </label>
          </div>
          <div class="grid row">
            <label>Keep raw captures
              <select id="liver_keep_raw" onchange="setLiveRenderKeepRaw()">
                <option value="0" #{!liver_keep_raw ? 'selected' : ''}>No (auto-delete after render)</option>
                <option value="1" #{liver_keep_raw ? 'selected' : ''}>Yes (keep both)</option>
              </select>
            </label>
          </div>

          <div class="small-btns">
            <button class="small" onclick="cmd('edit_live_render_prompt')">Render Prompt</button>
            <button class="small" onclick="cmd('load_remote_prompt')">📚 Preset library</button>
            <button class="small" onclick="cmd('open_live_render_folder')">Open folder</button>
          </div>

          <div class="info-grid">
            <div>Today</div><div id="liver_today">#{liver_today} renders · ~US$#{format('%.4f', liver_cost)} (HK$#{format('%.3f', liver_cost * USD_TO_HKD)})</div>
            <div>Per render</div><div>~US$#{format('%.4f', liver_per_image)} (HK$#{format('%.3f', liver_per_image_hk)}) at the selected model</div>
            <div>Provider</div><div><code>#{liver_provider == :poe ? 'Poe (cheap, public CDN)' : 'CF AI Gateway (private, direct Google)'}</code></div>
          </div>

          <h3 style="display:flex;align-items:center;justify-content:space-between;">
            <span>Materials Gemini will use</span>
            <button class="small" onclick="cmd('refresh_live_render_materials')" style="margin-left:8px;font-size:11px;">↻ Refresh</button>
          </h3>
          <div id="liver_materials" style="background:#0a0a0a;border:1px solid #2a2a2a;border-radius:4px;padding:8px;font-size:11.5px;line-height:1.5;color:#cfc;max-height:140px;overflow-y:auto;"></div>

          <h3>Captured views &nbsp;→&nbsp; AI Render</h3>
          <div id="liver_grid" style="display:grid;grid-template-columns:repeat(3, 1fr);gap:8px;">
            <div class="preview liver-cell" style="min-height:120px">
              <div class="cell-label">Hidden Line (geometry)</div>
              <div id="liver_frame_geom_empty" class="empty">— captured when multi-view ON —</div>
              <img id="liver_frame_geom" style="display:none" onclick="liverOpen('geom')">
            </div>
            <div class="preview liver-cell" style="min-height:120px">
              <div class="cell-label">Shaded (materials)</div>
              <div id="liver_frame_in_empty" class="empty">Captured SU view appears here</div>
              <img id="liver_frame_in" style="display:none" onclick="liverOpen('in')">
            </div>
            <div class="preview liver-cell" style="min-height:120px">
              <div class="cell-label">AI Render</div>
              <div id="liver_frame_out_empty" class="empty">AI render appears here ~10s after capture</div>
              <img id="liver_frame_out" style="display:none" onclick="liverOpen('out')">
            </div>
          </div>

          <h3>Recent renders</h3>
          <div id="liver_history" style="display:flex;gap:6px;overflow-x:auto;padding:4px 0 8px;min-height:90px;">#{liver_history_html}</div>
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
          ['render','prompts','history','aiwatch','live','liver'].forEach(n => {
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
        // The output area is an append-only log of model replies across frames
        // in the current Live Stream session. Each frame's reply lands in its
        // own paragraph prefixed with HH:MM:SS. The CURRENT (still-streaming)
        // reply lives in the last <p data-cur="1">…</p>; older replies stay put.
        // The Start button clears the whole log; new frames just push fresh.
        function _liveCurrentEl() {
          return document.querySelector('#live_output p[data-cur="1"]');
        }
        function _liveNewBlock() {
          const out = document.getElementById('live_output');
          if (!out) return null;
          const prev = _liveCurrentEl();
          if (prev) prev.removeAttribute('data-cur');     // freeze the previous reply
          const ts = new Date().toTimeString().slice(0, 8);
          const p = document.createElement('p');
          p.setAttribute('data-cur', '1');
          p.style.margin = '0 0 8px 0';
          p.innerHTML = '<span style="color:#888">[' + ts + ']</span> ';
          out.appendChild(p);
          out.scrollTop = out.scrollHeight;
          return p;
        }
        function _liveClear() {
          const out = document.getElementById('live_output');
          if (out) out.textContent = '';
        }
        function setLiveFrame(url) {
          const img = document.getElementById('live_frame');
          const empty = document.getElementById('live_frame_empty');
          if (url) {
            img.src = url + '?_=' + Date.now();
            img.style.display = 'block';
            if (empty) empty.style.display = 'none';
            // New frame → start a fresh paragraph for the next reply,
            // BUT keep prior replies visible so the user can re-read them.
            _liveNewBlock();
          }
        }
        function appendLiveToken(delta, fullText) {
          const cur = _liveCurrentEl() || _liveNewBlock();
          if (!cur) return;
          // Replace the text node after the timestamp span with fullText.
          while (cur.childNodes.length > 1) cur.removeChild(cur.lastChild);
          cur.appendChild(document.createTextNode(fullText));
          const out = document.getElementById('live_output');
          if (out) out.scrollTop = out.scrollHeight;
        }
        function liveDone(fullText, todayCount, todayCost) {
          appendLiveToken('', fullText);
          const t = document.getElementById('live_today');
          if (t) t.textContent = todayCount + ' streams · ~$' + todayCost;
        }
        // Live Render
        let liverGeomUrl = null, liverInUrl = null, liverOutUrl = null;
        function toggleLiveRender()       { sketchup.toggle_live_render(''); }
        function setLiveRenderInterval()  { sketchup.set_live_render_interval(document.getElementById('liver_interval').value); }
        function setLiveRenderModel()     { sketchup.set_live_render_model(document.getElementById('liver_model').value); }
        function setLiveRenderResolution(){ sketchup.set_live_render_resolution(document.getElementById('liver_resolution').value); }
        function setLiveRenderAspect()    { sketchup.set_live_render_aspect(document.getElementById('liver_aspect').value); }
        function setLiveRenderKeepRaw()   { sketchup.set_live_render_keep_raw(document.getElementById('liver_keep_raw').value); }
        function setLiveRenderMulti()     { sketchup.set_live_render_multi(document.getElementById('liver_multi').value); }
        function setLiveRenderBoost()     { sketchup.set_live_render_boost_contrast(document.getElementById('liver_boost').value); }
        function setLiveRenderUI(enabled) {
          const btn  = document.getElementById('liver_btn');
          const dot  = document.getElementById('liver_dot');
          const pill = document.getElementById('liver_status_pill');
          if (btn)  btn.textContent  = enabled ? '■ Stop Live Render' : '▶ Start Live Render';
          if (dot)  dot.textContent  = enabled ? '●' : '';
          if (pill) {
            pill.textContent = enabled ? '● Rendering' : '○ Off';
            pill.className   = 'aiw-status ' + (enabled ? 'on' : 'off');
          }
        }
        // setLiveRenderFrames(geomUrl, shadedUrl, renderUrl) — any can be null.
        // For 1-view captures, geomUrl is null.
        function setLiveRenderFrames(geomUrl, shadedUrl, renderUrl) {
          function show(idImg, idEmpty, url) {
            const i = document.getElementById(idImg);
            const e = document.getElementById(idEmpty);
            if (url) {
              if (i) { i.src = url + '?_=' + Date.now(); i.style.display = 'block'; }
              if (e) e.style.display = 'none';
            }
          }
          if (geomUrl)   { liverGeomUrl   = geomUrl;   show('liver_frame_geom','liver_frame_geom_empty', geomUrl); }
          if (shadedUrl) { liverInUrl     = shadedUrl; show('liver_frame_in',  'liver_frame_in_empty',   shadedUrl); }
          if (renderUrl) { liverOutUrl    = renderUrl; show('liver_frame_out', 'liver_frame_out_empty',  renderUrl); }
        }
        function liverOpen(side) {
          let url = null;
          if      (side === 'geom') url = liverGeomUrl;
          else if (side === 'in')   url = liverInUrl;
          else                      url = liverOutUrl;
          if (url) sketchup.open_url(url);
        }
        // Renders the markdown material table sent in the next render call.
        // payload: { rows: [[hex, name, hint], ...], scope_label: "..." }
        function renderLiveRenderMaterials(payload) {
          const el = document.getElementById('liver_materials');
          if (!el) return;
          if (!payload || !payload.rows || payload.rows.length === 0) {
            el.innerHTML = '<div style="opacity:.5">No materials in scope.</div>';
            return;
          }
          const swatch = (hex) => `<span style="display:inline-block;width:12px;height:12px;background:${hex};border:1px solid #444;vertical-align:middle;margin-right:6px;border-radius:2px;"></span>`;
          const rowsHtml = payload.rows.map(r =>
            `<div style="display:flex;align-items:center;gap:6px;font-family:monospace;">
              ${swatch(r[0])}<code>${r[0]}</code> · <span>${r[1]}</span><span style="opacity:.5;font-size:10px;margin-left:auto;">${r[2]||''}</span>
            </div>`).join('');
          const scope = payload.scope_label ? `<div style="opacity:.6;font-size:10px;margin-bottom:4px;">scope: ${payload.scope_label} · ${payload.rows.length} materials</div>` : '';
          el.innerHTML = scope + rowsHtml;
        }
        function setLiveRenderHistory(html) {
          const h = document.getElementById('liver_history');
          if (h) h.innerHTML = html;
        }
        function liveRenderDone(historyHtml, todayCount, todayCost) {
          setLiveRenderHistory(historyHtml);
          const t = document.getElementById('liver_today');
          // todayCost already includes the "US$x.xxx (HK$y.yyy)" formatting from Ruby
          if (t) t.textContent = todayCount + ' renders · ~' + todayCost;
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

    # Live Render callbacks
    @tray.add_action_callback("toggle_live_render")       { |_, _| toggle_live_render }
    @tray.add_action_callback("set_live_render_interval") do |_, v|
      cfg = load_config; cfg["live_render_interval"] = v.to_i; save_config(cfg)
    end
    @tray.add_action_callback("set_live_render_model")    do |_, v|
      cfg = load_config; cfg["live_render_model"] = v.to_s; save_config(cfg)
    end
    @tray.add_action_callback("set_live_render_resolution") do |_, v|
      r = v.to_i.clamp(256, 2048)
      cfg = load_config; cfg["live_render_width"] = r; cfg["live_render_height"] = r; save_config(cfg)
    end
    @tray.add_action_callback("set_live_render_aspect") do |_, v|
      allowed = %w[1:1 16:9 9:16 4:3 3:4]
      cfg = load_config
      cfg["live_render_aspect"] = allowed.include?(v.to_s) ? v.to_s : "1:1"
      save_config(cfg)
    end
    @tray.add_action_callback("set_live_render_keep_raw") do |_, v|
      cfg = load_config; cfg["live_render_keep_raw"] = (v.to_s == "1"); save_config(cfg)
    end
    @tray.add_action_callback("set_live_render_multi") do |_, v|
      cfg = load_config; cfg["live_render_multi_view"] = (v.to_s == "1"); save_config(cfg)
    end
    @tray.add_action_callback("set_live_render_boost_contrast") do |_, v|
      cfg = load_config; cfg["live_render_boost_contrast"] = (v.to_s == "1"); save_config(cfg)
    end
    @tray.add_action_callback("refresh_live_render_materials") do |_, _|
      push_live_render_materials
    end
    @tray.add_action_callback("edit_live_render_prompt")  { |_, _| edit_live_render_prompt }
    @tray.add_action_callback("load_remote_prompt")       { |_, _| load_remote_prompt_picker }
    @tray.add_action_callback("open_live_render_folder")  do |_, _|
      dir = history_dir
      if dir
        lr_dir = File.join(dir, "live_render")
        FileUtils.mkdir_p(lr_dir)
        UI.openURL("file://" + lr_dir.gsub("\\", "/"))
      end
    end
    @tray.add_action_callback("open_url") do |_, url|
      UI.openURL(url.to_s) unless url.to_s.empty?
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

    # Live Render material panel: prime once on tray-open, then poll every 5s
    # so user sees what materials Gemini will see when they switch component
    # / change selection / edit materials. Cheap (just a tree-walk + JSON
    # serialization, no HTTP). The timer survives load __FILE__ via @ivar.
    push_live_render_materials
    if @liverender_material_timer
      UI.stop_timer(@liverender_material_timer) rescue nil
    end
    @liverender_material_timer = UI.start_timer(5.0, true) {
      push_live_render_materials rescue nil
    }

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

  # ---- Live Render tray-push helpers ----------------------------------------
  def self.push_live_render_state(enabled)
    return unless @tray && @tray.visible?
    @tray.execute_script("setLiveRenderUI(#{enabled ? 'true' : 'false'})")
  end

  def self.push_live_render_status(msg, cls = "")
    push_status(msg, cls)
  end

  # Push captured views + render to the tray. Always 3 explicit args:
  #   geom_path    Hidden-Line capture (nil in single-view mode)
  #   shaded_path  Shaded-with-Texture capture
  #   render_path  AI render output (nil before bg thread completes)
  # Any of the three may be nil; the JS side only updates non-null cells.
  # The previous (raw, render) 2-arg form was dropped — it broke when the
  # 3-arg call passed nil as render_path because the optional-arg default
  # collapsed into the legacy branch and shuffled the cells out of order.
  def self.push_live_render_frame(geom_path, shaded_path, render_path)
    return unless @tray && @tray.visible?
    to_url = ->(p) { p ? "file://" + p.gsub("\\", "/") : nil }
    js = "setLiveRenderFrames(" \
         "#{(u = to_url.call(geom_path))   ? u.to_json : 'null'}, " \
         "#{(u = to_url.call(shaded_path)) ? u.to_json : 'null'}, " \
         "#{(u = to_url.call(render_path)) ? u.to_json : 'null'})"
    @tray.execute_script(js)
  end

  # Push the live material list to the tray panel. Used by:
  #   - 5s polling tick (so dragging selection / opening containers reflects)
  #   - Manual refresh button
  #   - On Live Render Start
  def self.push_live_render_materials
    return unless @tray && @tray.visible?
    model = (Sketchup.active_model rescue nil)
    return unless model
    _, label = live_render_material_scope(model)
    materials = collect_used_materials(model)
    rows = materials.first(30).map { |m|
      next nil unless m
      name = (m.respond_to?(:display_name) ? m.display_name : m.name).to_s
      next nil if name.empty?
      c = m.color rescue nil
      hex = c ? format("#%02X%02X%02X", c.red, c.green, c.blue) : "(none)"
      tex = (m.respond_to?(:texture) && m.texture) ? m.texture : nil
      hint =
        if tex
          fn = (tex.filename rescue "") || ""
          fn.empty? ? "textured" : "tex: #{File.basename(fn)}"
        else
          alpha = m.respond_to?(:alpha) ? (m.alpha rescue 1.0) : 1.0
          alpha < 0.95 ? "translucent" : "solid"
        end
      [hex, name, hint]
    }.compact
    payload = { rows: rows, scope_label: label }
    @tray.execute_script("renderLiveRenderMaterials(#{payload.to_json})")
  end

  def self.push_live_render_done(_entry)
    return unless @tray && @tray.visible?
    html = render_live_render_history_html
    @tray.execute_script(
      "liveRenderDone(#{html.to_json}, #{live_render_count_today}, 'US$#{format('%.4f', live_render_cost_today)} (HK$#{format('%.3f', live_render_cost_today_hkd)})')"
    )
  end

  # Render the horizontal-scroll history strip (last N renders, oldest →
  # newest left → right is reversed since we unshift onto the head).
  def self.render_live_render_history_html
    items = (@liverender && @liverender[:history]) || []
    items = items.select { |it| it.is_a?(Hash) }   # defensive: ignore stale ivar pollution
    return "<div style='opacity:.5;font-size:11px;padding:14px;'>No renders yet — Start Live Render and watch them stream in.</div>" if items.empty?
    items.map { |it|
      raw_url    = it[:raw_path]    ? "file://" + it[:raw_path].gsub("\\", "/")    : ""
      render_url = it[:render_path] ? "file://" + it[:render_path].gsub("\\", "/") : ""
      ts = it[:ts].to_s
      tlabel = ts.length >= 16 ? ts[11,8] : ts
      tokens = it[:tokens].to_i
      tooltip = "#{tlabel} · #{tokens} tokens · #{it[:elapsed]}s"
      <<~HTML
        <div style="flex:0 0 auto;display:flex;flex-direction:column;align-items:center;gap:4px;background:#222;padding:6px;border-radius:4px;">
          <img src="#{render_url}" style="width:96px;height:96px;object-fit:cover;border-radius:3px;cursor:pointer;" onclick="sketchup.open_url(#{render_url.to_json})" title="#{CGI.escapeHTML(tooltip)}">
          <div style="font-size:10px;opacity:.6;">#{tlabel}</div>
        </div>
      HTML
    }.join("\n")
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

  # Fetch the remote prompt library from the same ngrok-served path that
  # the auto-update flow uses (sibling to version.json). Lets a designer
  # pick from a curated set of presets ("Photoreal HK residential",
  # "Watercolour mood-board", "Minimal Japanese / Muji" etc.) without
  # having to copy-paste long prompts every time.
  REMOTE_PROMPT_URL =
    UPDATE_MANIFEST_URL.to_s.sub(%r{/version\.json$}, "/prompts.json").freeze

  def self.fetch_remote_prompts
    return [] if REMOTE_PROMPT_URL.empty?
    res = http_get(REMOTE_PROMPT_URL, attempts: 1) rescue nil
    return [] unless res.is_a?(Net::HTTPSuccess)
    data = JSON.parse(res.body) rescue {}
    Array(data["prompts"]).select { |p| p.is_a?(Hash) && p["body"] }
  end

  def self.load_remote_prompt_picker
    prompts = fetch_remote_prompts
    if prompts.empty?
      UI.messagebox("No remote prompts available.\n\n" \
                    "(Tried: #{REMOTE_PROMPT_URL})\n\n" \
                    "If you're the operator, edit the prompts.json on the\n" \
                    "local server and refresh.")
      return
    end
    labels = prompts.map.with_index(1) { |p, i|
      "#{i}. #{p['label'] || p['id']} — #{(p['description'] || '')[0,80]}"
    }
    msg = "Remote preset library\n\n" + labels.join("\n") +
          "\n\nEnter the number of the preset you want to load:"
    res = UI.inputbox(["Preset #"], ["1"], msg)
    return unless res
    idx = (res.is_a?(Array) ? res[0] : res).to_i - 1
    return unless idx >= 0 && idx < prompts.length
    chosen = prompts[idx]
    cfg = load_config
    cfg["live_render_prompt"] = chosen["body"].to_s
    save_config(cfg)
    push_status("Loaded preset: #{chosen['label'] || chosen['id']}", "ok")
  end

  # Live Render prompt editor. Defaults to DEFAULT_LIVE_RENDER_PROMPT — this
  # one drives the gemini-2.5-flash-image call so it should describe the
  # *visual* outcome (lighting, materials, mood), not the analytical commentary
  # that the Live Stream prompt asks for.
  def self.edit_live_render_prompt
    cfg = load_config
    current = cfg["live_render_prompt"] || DEFAULT_LIVE_RENDER_PROMPT
    dlg = UI::HtmlDialog.new(
      dialog_title:    "#{PLUGIN_NAME} — Edit Live Render Prompt",
      preferences_key: "su_gpt_render_live_render_prompt_dlg",
      scrollable:      true, resizable: true,
      width: 640, height: 540,
      style: UI::HtmlDialog::STYLE_DIALOG
    )
    cur_html = CGI.escapeHTML(current)
    default_html = CGI.escapeHTML(DEFAULT_LIVE_RENDER_PROMPT).gsub("\n", '\\n').gsub("'", "\\\\'")
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
      <h2>Live Render prompt</h2>
      <p class="hint">每次 frame 會用呢個 prompt 餵畀 gemini-2.5-flash-image。寫 visual outcome（lighting, material, mood）效果最好。</p>
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
      cfg2 = load_config; cfg2["live_render_prompt"] = decoded; save_config(cfg2)
      dlg.close
      UI.messagebox("Live Render prompt saved (#{decoded.length} chars).")
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

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

module SuGptRender
  PLUGIN_NAME    = "GPT Render"
  PLUGIN_VERSION = "0.2.4"
  POE_ENDPOINT   = "https://api.poe.com/v1/chat/completions"
  CONFIG_PATH    = File.expand_path("~/.sketchup_su_gpt_render.json")

  # Poe image models. Each: [poe_id, label, group, hint, t2i_only]
  # - "edit" group: accepts text+image → image (uses our SketchUp screenshot)
  # - "t2i"  group: text → image only (ignores input image, generates from prompt)
  # First entry is the default.
  IMAGE_MODELS = [
    # ----- Image editing (text+image → image) — recommended for SU plugin -----
    ["GPT-Image-2",        "GPT-Image-2",         "edit", "OpenAI · 最強 prompt adherence",         false],
    ["Nano-Banana-Pro",    "Nano-Banana Pro",     "edit", "Google · Gemini 3 Pro Image · ⭐ 最新 edit",  false],
    ["Nano-Banana",        "Nano-Banana",         "edit", "Google · Gemini 2.5 Flash · 多語言文字",     false],
    ["Flux-Kontext-Max",   "FLUX Kontext Max",    "edit", "BFL · 編輯最強旗艦",                          false],
    ["Flux-Kontext-Pro",   "FLUX Kontext Pro",    "edit", "BFL · 專為 edit · 保結構好",                  false],
    ["FLUX-2-Max",         "FLUX 2 Max",          "edit", "BFL · 多參考圖旗艦",                          false],
    ["FLUX-2-Pro",         "FLUX 2 Pro",          "edit", "BFL · 多參考圖",                              false],
    ["FLUX-2-Flex",        "FLUX 2 Flex",         "edit", "BFL · 大尺寸",                                false],
    ["FLUX-2-Dev",         "FLUX 2 Dev",          "edit", "BFL · open-weight",                           false],
    ["FLUX-Krea",          "FLUX Krea",           "edit", "BFL · Aesthetic tuned",                      false],
    ["GPT-Image-1.5",      "GPT-Image-1.5",       "edit", "OpenAI · ChatGPT default",                    false],
    ["GPT-Image-1",        "GPT-Image-1",         "edit", "OpenAI · 經濟",                                false],
    ["GPT-Image-1-Mini",   "GPT-Image-1 Mini",    "edit", "OpenAI · 最平 · 快",                          false],
    ["seededit-3.0",       "Seededit 3.0",        "edit", "Bytedance · edit",                            false],
    ["ideogram",           "Ideogram",            "edit", "IdeogramAI",                                  false],
    ["ideogram-v2",        "Ideogram v2",         "edit", "IdeogramAI v2",                               false],
    ["qwen-edit",          "Qwen Edit",           "edit", "Alibaba edit",                                false],
    ["sketch-to-image",    "Sketch-to-Image",     "edit", "Convert sketch → photo",                      false],

    # ----- Text-to-image only (input image is IGNORED) -----
    ["Nano-Banana-2",      "Nano-Banana 2",       "t2i",  "Google · 最新 T2I · 4K · 純 prompt 生成",      true],
    ["Imagen-4-Ultra",     "Imagen 4 Ultra",      "t2i",  "Google · 最強 T2I",                            true],
    ["Imagen-4",           "Imagen 4",            "t2i",  "Google T2I",                                   true],
    ["Imagen-4-Fast",      "Imagen 4 Fast",       "t2i",  "Google T2I 速版",                              true],
    ["FLUX-pro-1.1-ultra", "FLUX Pro 1.1 Ultra",  "t2i",  "BFL · 高解析 T2I",                              true],
    ["FLUX-pro-1.1",       "FLUX Pro 1.1",        "t2i",  "BFL T2I",                                      true],
    ["DALL-E-3",           "DALL-E 3",            "t2i",  "OpenAI 經典",                                  true],
    ["seedream-5.0-lite",  "Seedream 5.0 Lite",   "t2i",  "Bytedance T2I",                                true],
    ["recraft-v3",         "Recraft v3",          "t2i",  "Recraft 設計向",                               true],
    ["luma-photon",        "Luma Photon",         "t2i",  "Luma photoreal",                               true],
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

  def self.http_get(url, attempts: 3)
    uri = URI.parse(url)
    last_err = nil
    attempts.times do |i|
      http = Net::HTTP.new(uri.host, uri.port)
      configure_http(http, uri.scheme)
      begin
        return http.request(Net::HTTP::Get.new(uri.request_uri))
      rescue OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::EPIPE, Net::OpenTimeout, Net::ReadTimeout, EOFError => e
        last_err = e
        sleep(1.0 + i * 2.0) unless i == attempts - 1
      end
    end
    raise "HTTPS GET failed: #{last_err.class}: #{last_err.message}"
  end

  # ------ Poe API call -------------------------------------------------------
  def self.call_poe(api_key, image_path, prompt, model = "GPT-Image-2")
    meta = IMAGE_MODELS.find { |m| m[0] == model }
    t2i_only = meta ? meta[4] : false

    content = [{ "type" => "text", "text" => prompt }]
    unless t2i_only
      img_b64 = Base64.strict_encode64(File.binread(image_path))
      content << { "type" => "image_url",
                   "image_url" => { "url" => "data:image/png;base64,#{img_b64}" } }
    end
    payload = {
      "model"    => model,
      "messages" => [{ "role" => "user", "content" => content }],
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

  # ------ tray dialog --------------------------------------------------------
  @tray = nil
  @bg_thread = nil
  @bg_timer = nil

  def self.tray_html
    cfg = load_config
    prompt_chars = (cfg["prompt"] || DEFAULT_PROMPT).length
    has_key = !(cfg["poe_api_key"].to_s.strip.empty?)
    width = cfg["width"] || 1536
    height = cfg["height"] || 1024
    selected_model = cfg["model"] || IMAGE_MODELS.first[0]
    history_html = render_history_html

    edit_options = IMAGE_MODELS.select { |m| m[2] == "edit" }
    t2i_options  = IMAGE_MODELS.select { |m| m[2] == "t2i" }
    opt_html = lambda do |arr|
      arr.map { |id, label, _grp, hint, _t2i|
        sel = (id == selected_model) ? " selected" : ""
        "<option value=\"#{id}\"#{sel} title=\"#{CGI.escapeHTML(hint)}\">#{CGI.escapeHTML(label)} — #{CGI.escapeHTML(hint)}</option>"
      }.join("\n")
    end
    model_options_html =
      "<optgroup label=\"Image-edit (uses your SketchUp view)\">\n" +
      opt_html.call(edit_options) +
      "\n</optgroup>\n<optgroup label=\"Text-to-image only (ignores SketchUp view)\">\n" +
      opt_html.call(t2i_options) +
      "\n</optgroup>"

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
        .tabs { display:flex; gap:4px; margin-bottom:6px; }
        .tabs button { padding:5px 10px; font-size:11px; background:#222; }
        .tabs button.active { background:#2c80c0; }
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

        <h3>History</h3>
        <div class="history" id="history">#{history_html}</div>

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
        function setHistory(html) {
          document.getElementById('history').innerHTML = html;
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

  def self.render_history_html
    model = Sketchup.active_model
    return "<div class='empty' style='padding:8px;opacity:.5'>Save your model first</div>" if model.nil? || model.path.empty?
    dir = File.join(File.dirname(model.path), "gpt_render")
    return "<div class='empty' style='padding:8px;opacity:.5'>No renders yet</div>" unless File.directory?(dir)

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

    items = pairs.keys.sort.reverse[0,20]
    return "<div class='empty' style='padding:8px;opacity:.5'>No renders yet</div>" if items.empty?

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
    @tray.add_action_callback("edit_prompt")     { |_, _| edit_prompt }
    @tray.add_action_callback("set_key")         { |_, _| set_api_key; refresh_tray }
    @tray.add_action_callback("check_update")    { |_, _| check_update(true) }
    @tray.add_action_callback("download_update") { |_, _| download_update }
    @tray.add_action_callback("open_folder")     { |_, _| open_output_folder }

    @tray.show

    # Background update check
    Thread.new { sleep 2; check_update(false) rescue nil }
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
    @tray.execute_script("setHistory(#{html.to_json})")
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
    return if UPDATE_MANIFEST_URL.nil? || UPDATE_MANIFEST_URL.empty?
    begin
      res = http_get(UPDATE_MANIFEST_URL)
      raise "manifest HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
      data = JSON.parse(res.body)
      rb_url = data["rb_url"].to_s
      raise "no rb_url in manifest" if rb_url.empty?

      res2 = http_get(rb_url)
      raise "rb HTTP #{res2.code}" unless res2.is_a?(Net::HTTPSuccess)

      target = __FILE__
      File.binwrite(target, res2.body)
      UI.messagebox("Updated to v#{data['version']}.\n\nRestart SketchUp to take effect.\n\nFile updated: #{target}")
    rescue => e
      UI.messagebox("Update failed: #{e.message}")
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

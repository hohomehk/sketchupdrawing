# su_gpt_render.rb — SketchUp 插件：current view → Poe GPT-Image-2 → enhanced image
# v0.2 — V-Ray style tray + async (non-blocking) + auto-update check

require 'sketchup.rb'
require 'fileutils'
require 'json'
require 'net/http'
require 'uri'
require 'base64'
require 'cgi'

module SuGptRender
  PLUGIN_NAME    = "GPT Render"
  PLUGIN_VERSION = "0.2.0"
  POE_ENDPOINT   = "https://api.poe.com/v1/chat/completions"
  CONFIG_PATH    = File.expand_path("~/.sketchup_su_gpt_render.json")

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

  # ------ Poe API call (HTTP) ------------------------------------------------
  def self.call_poe(api_key, image_path, prompt)
    img_b64 = Base64.strict_encode64(File.binread(image_path))

    payload = {
      "model"    => "GPT-Image-2",
      "messages" => [{
        "role"    => "user",
        "content" => [
          { "type" => "text", "text" => prompt },
          { "type" => "image_url",
            "image_url" => { "url" => "data:image/png;base64,#{img_b64}" } }
        ]
      }],
      "stream"   => false
    }

    uri = URI.parse(POE_ENDPOINT)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 180
    http.open_timeout = 30

    req = Net::HTTP::Post.new(uri.path)
    req["Authorization"] = "Bearer #{api_key}"
    req["Content-Type"]  = "application/json"
    req.body = JSON.generate(payload)

    res = http.request(req)
    unless res.is_a?(Net::HTTPSuccess)
      raise "Poe API HTTP #{res.code}: #{res.body[0,500]}"
    end
    body = JSON.parse(res.body)
    content = body.dig("choices", 0, "message", "content").to_s
    m = content.match(/\(([^)]+\.(?:png|jpg|jpeg|webp))[^)]*\)/i) ||
        content.match(/(https?:\/\/\S+\.(?:png|jpg|jpeg|webp))/i)
    raise "No image URL in response: #{content[0,300]}" unless m
    m[1]
  end

  def self.download(url, out_path)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.read_timeout = 120

    req = Net::HTTP::Get.new(uri.request_uri)
    res = http.request(req)
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
    history_html = render_history_html

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
        .preview { background:#0a0a0a; border:1px solid #2a2a2a; border-radius:4px; padding:6px; margin-bottom:10px; min-height:120px; }
        .preview img { width:100%; display:block; border-radius:3px; }
        .preview .empty { padding:20px; text-align:center; opacity:.4; font-size:11px; }
        .tabs { display:flex; gap:4px; margin-bottom:6px; }
        .tabs button { padding:5px 10px; font-size:11px; background:#222; }
        .tabs button.active { background:#2c80c0; }
        .small-btns { display:flex; gap:6px; flex-wrap:wrap; margin-bottom:10px; }
        .info-grid { display:grid; grid-template-columns: auto 1fr; gap:4px 12px; padding:8px 10px; background:#222; border-radius:4px; font-size:11px; margin-bottom:10px; }
        .info-grid div:nth-child(odd) { opacity:.6; }
        h3 { margin:14px 0 6px 0; font-size:11px; opacity:.6; text-transform:uppercase; letter-spacing:.5px; }
        .history { max-height:240px; overflow-y:auto; }
        .history .item { display:flex; gap:8px; padding:4px 0; align-items:center; cursor:pointer; }
        .history .item:hover { background:#252525; }
        .history img { width:50px; height:34px; object-fit:cover; border-radius:3px; }
        .history .ts { font-size:11px; opacity:.6; flex:1; }
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
          <img id="preview_img" style="display:none">
        </div>

        <h3>History</h3>
        <div class="history" id="history">#{history_html}</div>

        <script>
        let lastRaw = null, lastEnh = null, currentTab = 'enh';
        function setStatus(msg, cls) {
          const s = document.getElementById('status');
          s.textContent = msg;
          s.className = cls || '';
        }
        function setPreview(rawUrl, enhUrl) {
          if (rawUrl) lastRaw = rawUrl;
          if (enhUrl) lastEnh = enhUrl;
          renderPreview();
        }
        function renderPreview() {
          const img = document.getElementById('preview_img');
          const empty = document.getElementById('preview_empty');
          const url = currentTab === 'enh' ? lastEnh : lastRaw;
          if (url) {
            img.src = url + '?_=' + Date.now();
            img.style.display = 'block';
            empty.style.display = 'none';
          } else {
            img.style.display = 'none';
            empty.style.display = 'block';
          }
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
          const opts = { width: parseInt(document.getElementById('w').value), height: parseInt(document.getElementById('h').value) };
          sketchup.render(JSON.stringify(opts));
        }
        function cmd(name) { sketchup[name](''); }
        function loadHistoryItem(rawUrl, enhUrl) { setPreview(rawUrl, enhUrl); }
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
      pairs[stem] = { raw: raw, enh: File.exist?(enh) ? enh : nil }
    end

    items = pairs.keys.sort.reverse[0,12]
    return "<div class='empty' style='padding:8px;opacity:.5'>No renders yet</div>" if items.empty?

    items.map do |stem|
      p = pairs[stem]
      thumb = p[:enh] || p[:raw]
      raw_url = "file://" + (p[:raw] || "").gsub("\\", "/")
      enh_url = p[:enh] ? "file://" + p[:enh].gsub("\\", "/") : "null"
      ts = stem[0,15].gsub(/^(\d{8})_(\d{6})/, '\1 \2')
      "<div class='item' onclick=\"loadHistoryItem(#{raw_url.to_json}, #{enh_url == 'null' ? 'null' : enh_url.to_json})\">" +
      "<img src=\"file://#{thumb.gsub('\\','/')}\"><span class='ts'>#{ts}</span></div>"
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
        do_render_async(opts["width"].to_i, opts["height"].to_i)
      rescue => e
        push_status("Failed: #{e.message}", "err")
      end
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
    @tray.execute_script("setPreview(#{raw_url.to_json}, #{enh_url.to_json})")
  end

  def self.push_history
    return unless @tray && @tray.visible?
    html = render_history_html
    @tray.execute_script("setHistory(#{html.to_json})")
  end

  # ------ async render -------------------------------------------------------
  def self.do_render_async(width, height)
    api_key = get_api_key
    return unless api_key

    if @bg_thread && @bg_thread.alive?
      UI.messagebox("Already rendering. Wait for the current job to finish.")
      return
    end

    cfg = load_config
    prompt = cfg["prompt"] || DEFAULT_PROMPT
    cfg["width"] = width; cfg["height"] = height; save_config(cfg)

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

    push_status("Calling Poe GPT-Image-2 (~30-60s)...", "busy")

    # Background HTTP — Net::HTTP releases GIL during I/O so this DOES run async.
    @bg_thread = Thread.new do
      begin
        url = call_poe(api_key, raw_path, prompt)
        out_path = raw_path.sub(/_raw\.png$/, "_enhanced.png")
        download(url, out_path)
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
      uri = URI.parse(UPDATE_MANIFEST_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.read_timeout = 10
      http.open_timeout = 5
      res = http.request(Net::HTTP::Get.new(uri.request_uri))
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
      uri = URI.parse(UPDATE_MANIFEST_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      res = http.request(Net::HTTP::Get.new(uri.request_uri))
      raise "manifest HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
      data = JSON.parse(res.body)
      rb_url = data["rb_url"].to_s
      raise "no rb_url in manifest" if rb_url.empty?

      uri2 = URI.parse(rb_url)
      http2 = Net::HTTP.new(uri2.host, uri2.port); http2.use_ssl = (uri2.scheme == "https")
      res2 = http2.request(Net::HTTP::Get.new(uri2.request_uri))
      raise "rb HTTP #{res2.code}" unless res2.is_a?(Net::HTTPSuccess)

      target = __FILE__
      File.binwrite(target, res2.body)
      UI.messagebox("Updated to v#{data['version']}.\n\nRestart SketchUp to take effect.\n\nFile updated: #{target}")
    rescue => e
      UI.messagebox("Update failed: #{e.message}")
    end
  end

  # ------ menu ---------------------------------------------------------------
  unless file_loaded?(__FILE__)
    menu = UI.menu("Extensions").add_submenu(PLUGIN_NAME)
    menu.add_item("Show Tray") { SuGptRender.show_tray }
    menu.add_item("Edit Prompt...") { SuGptRender.edit_prompt }
    menu.add_separator
    menu.add_item("Set Poe API Key...") { SuGptRender.set_api_key }
    menu.add_item("Check for Updates") { SuGptRender.check_update(true) }
    file_loaded(__FILE__)
  end
end

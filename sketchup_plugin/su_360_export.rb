# su_360_export.rb — SketchUp Ruby plugin: 「Send room to 360 render」
#
# Install:
#   1. SketchUp → Window → Extension Manager → Install Extension
#      (or copy this file to Plugins folder)
#   2. SketchUp → Extensions → 360 Render → Export Current Scene
#
# Workflow:
#   - 開定 .skp
#   - 切去想 export 嘅 Scene (camera angle 已 saved)
#   - 可選: 選一個 Group 做「room contents」，否則用 active scene 全部可見 entity
#   - Menu → Extensions → 360 Render → Export Current Scene
#   - Dialog 問 project name → 確認 → 寫入 inbox folder
#   - Pipeline 端自動 pick up，render 完出 URL
#
# Inbox: ~/Dropbox/PC (7)/Documents/Drawing 2021/360_inbox/  (Windows 路徑)
#  Linux WSL 端 sync 到 /home/timothy/mydocs/360_inbox/

require 'sketchup.rb'
require 'extensions.rb'
require 'fileutils'
require 'json'

module Su360
  PLUGIN_VERSION = "0.1.0"

  # Dropbox-synced inbox folder. Edit if your Dropbox path differs.
  # On Windows w/ Dropbox PC (7): C:\Users\Timothy\Dropbox\PC (7)\Documents\Drawing 2021\360_inbox
  def self.inbox_dir
    return @inbox_dir if @inbox_dir
    candidates = [
      File.expand_path("~/Dropbox/PC (7)/Documents/Drawing 2021/360_inbox"),
      File.expand_path("~/Dropbox/360_inbox"),
      File.expand_path("~/Documents/360_inbox"),
      File.expand_path("~/Desktop/360_inbox"),
    ]
    @inbox_dir = candidates.find { |c| File.directory?(File.dirname(c)) }
    @inbox_dir ||= candidates.last  # fallback Desktop
    FileUtils.mkdir_p(@inbox_dir)
    @inbox_dir
  end

  def self.export_current_scene
    model = Sketchup.active_model
    unless model
      UI.messagebox("無 active model")
      return
    end
    if model.path.nil? || model.path.empty?
      UI.messagebox("Model 未 save。請先 File → Save 個 .skp，再 export。")
      return
    end

    page = model.pages.selected_page
    unless page
      UI.messagebox("請先去返你想 export 嘅 Scene。\n(Window → Scenes → 揀一個)")
      return
    end

    # Project name dialog
    default_name = File.basename(model.path, ".skp") + " — " + page.name.to_s.strip
    inputs = UI.inputbox(
      ["Project name", "Render quality (1=draft / 2=normal / 3=high)", "AI enhance? (yes/no)"],
      [default_name, "2", "yes"],
      "360 Render Export"
    )
    return unless inputs
    proj_name, quality_str, ai_str = inputs
    quality = (quality_str.to_i.clamp(1, 3))
    ai_enhance = ai_str.to_s.downcase.start_with?("y")

    # Job folder
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    safe_proj = proj_name.gsub(/[^A-Za-z0-9一-鿿_\-]/, "_")
    job_id = "#{timestamp}_#{safe_proj}"
    job_dir = File.join(inbox_dir, job_id)
    FileUtils.mkdir_p(job_dir)

    # Camera info from current scene
    cam = page.camera || model.active_view.camera
    eye = cam.eye
    target = cam.target
    up = cam.up

    # Helper to convert inches → mm
    in_to_mm = ->(p) { [(p.x.to_f * 25.4), (p.y.to_f * 25.4), (p.z.to_f * 25.4)] }

    # Determine room bbox: prefer a group named "Room:" or selected entities,
    # else the active scene's visible entity bbox.
    room_entities = nil
    sel = model.selection.to_a
    if sel.length == 1 && [Sketchup::Group, Sketchup::ComponentInstance].any? { |k| sel.first.is_a?(k) }
      room_entities = [sel.first]
    else
      named_room = model.entities.find { |e|
        (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) &&
        e.respond_to?(:name) && e.name.to_s.start_with?("Room:")
      }
      room_entities = named_room ? [named_room] : nil
    end

    bbox = Geom::BoundingBox.new
    if room_entities
      room_entities.each { |e| bbox.add(e.bounds) }
    else
      model.entities.each do |e|
        next unless e.respond_to?(:bounds)
        next if e.respond_to?(:hidden?) && e.hidden?
        bbox.add(e.bounds)
      end
    end

    bbox_min_mm = in_to_mm.call(bbox.min)
    bbox_max_mm = in_to_mm.call(bbox.max)

    # Manifest
    manifest = {
      "schema_version" => 1,
      "plugin_version" => PLUGIN_VERSION,
      "created_at"     => Time.now.iso8601,
      "project_name"   => proj_name,
      "scene_name"     => page.name.to_s,
      "scene_description" => page.description.to_s,
      "model_filename" => File.basename(model.path),
      "model_units_mm" => true,
      "camera" => {
        "eye_mm"    => in_to_mm.call(eye),
        "target_mm" => in_to_mm.call(target),
        "up"        => [up.x.to_f, up.y.to_f, up.z.to_f],
        "fov_deg"   => cam.perspective? ? cam.fov : nil,
        "perspective" => cam.perspective?
      },
      "room" => {
        "source" => room_entities ? "selected_or_named_group" : "scene_visible_bbox",
        "bbox_min_mm" => bbox_min_mm,
        "bbox_max_mm" => bbox_max_mm,
        "padding_mm" => 1500
      },
      "options" => {
        "quality" => quality,
        "ai_enhance" => ai_enhance,
      }
    }

    File.write(File.join(job_dir, "manifest.json"),
               JSON.pretty_generate(manifest))

    # Save SKP into job folder. SaveAsCopy keeps current model path unchanged.
    skp_dst = File.join(job_dir, "model.skp")
    if model.respond_to?(:save_copy)
      model.save_copy(skp_dst)
    else
      # Fallback: file copy
      FileUtils.cp(model.path, skp_dst)
    end

    UI.messagebox(
      "Job submitted!\n\n" +
      "Project: #{proj_name}\n" +
      "Job ID: #{job_id}\n" +
      "Inbox: #{job_dir}\n\n" +
      "Pipeline 會自動 pick up。\n" +
      "Render 完成後個 360° URL 會寫去同 folder 嘅 status.json。"
    )

    # Open the inbox folder in Finder/Explorer
    UI.openURL("file://" + job_dir.gsub("\\", "/"))
  end

  unless file_loaded?(__FILE__)
    menu = UI.menu("Extensions").add_submenu("360 Render")
    menu.add_item("Export Current Scene") { Su360.export_current_scene }
    menu.add_item("Show Inbox Folder") { UI.openURL("file://" + Su360.inbox_dir.gsub("\\", "/")) }
    file_loaded(__FILE__)
  end
end

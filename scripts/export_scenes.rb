# export_scenes.rb — Batch export every Scene in current SketchUp model as PNG.
#
# How to run:
#   1. SketchUp 入面開 寶翠園5.skp
#   2. Window → Ruby Console
#   3. 將呢個 file 全部內容 paste 入 console，按 Enter
#   4. 48 張 PNG 會出喺 OUTPUT_DIR（model 同 folder 個 scenes/ subfolder）
#
# Tested with SketchUp 2021+. SketchUp Make 2017 / 2018 都 should work（API 一樣）.

require 'fileutils'

# === 設定 ===
WIDTH      = 2400          # 輸出 PNG 闊度（px）
HEIGHT     = 1500          # 高度（px）
ANTIALIAS  = true
TRANSPARENT = false

# === Helpers ===
def safe_filename(name)
  # Windows / cross-platform safe：去走唔合法 chars，head/tail trim
  name.to_s.strip.gsub(/[\\\/:*?"<>|]/, '_').gsub(/\s+/, ' ')
end

# === Main ===
model = Sketchup.active_model
abort "No active model" unless model

model_path = model.path
if model_path.nil? || model_path.empty?
  puts "[!] Model 未 save。請先 save 過個 .skp file，再跑呢個 script。"
  return
end

output_dir = File.join(File.dirname(model_path), "scenes")
FileUtils.mkdir_p(output_dir)

pages = model.pages.to_a
if pages.empty?
  puts "[!] 無 Scene 可以 export。"
  return
end

puts "Exporting #{pages.length} scenes to: #{output_dir}"
puts "Resolution: #{WIDTH}×#{HEIGHT}"
puts "-" * 50

pages.each_with_index do |page, idx|
  # Switch view 到該 scene（必須 set selected_page 先 active_view 至 follow camera）
  model.pages.selected_page = page

  # 等 view update（SketchUp 2018+ 內部 transition 動畫，set transitions = 0 可加快）
  Sketchup.active_model.active_view.refresh

  base = sprintf("%02d_%s", idx, safe_filename(page.name))
  filename = File.join(output_dir, "#{base}.png")

  options = {
    :filename     => filename,
    :width        => WIDTH,
    :height       => HEIGHT,
    :antialias    => ANTIALIAS,
    :transparent  => TRANSPARENT
  }

  begin
    success = model.active_view.write_image(options)
    if success
      puts sprintf("[%2d/%2d] %s  →  %s", idx + 1, pages.length, page.name, File.basename(filename))
    else
      puts sprintf("[%2d/%2d] %s  →  FAILED", idx + 1, pages.length, page.name)
    end
  rescue => e
    puts sprintf("[%2d/%2d] %s  →  ERROR: %s", idx + 1, pages.length, page.name, e.message)
  end
end

puts "-" * 50
puts "Done. Output folder:"
puts "  #{output_dir}"

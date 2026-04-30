# export_layout.rb — Send the active SketchUp model to LayOut
#
# `Sketchup.active_model.send_to_layout(path)` 同 SketchUp UI 嘅
# File → Send to LayOut menu 一樣。生成嘅 .layout file 會：
# - 包括所有 Scenes 做 viewport pages
# - 嵌入當前 SketchUp model 嘅 reference
# - 可以喺 LayOut app 開嚟編輯／加註解／導出 PDF
#
# How to run:
#   1. SketchUp 入面開 寶翠園5.skp
#   2. Window → Ruby Console
#   3. Paste 全部呢個 file 內容，按 Enter
#   4. .layout file 出現喺 OUTPUT_PATH

require 'fileutils'

model = Sketchup.active_model
abort "No active model" unless model

src_path = model.path
if src_path.nil? || src_path.empty?
  puts "[!] Model 未 save。請先 save 個 .skp file。"
  return
end

# Output: 同 .skp 同 folder，自動命名
dir = File.dirname(src_path)
basename = File.basename(src_path, ".skp")
out_path = File.join(dir, "#{basename}.layout")

puts "Sending to LayOut: #{out_path}"
result = model.send_to_layout(out_path)

if result
  puts "OK: #{out_path}"
  puts "File size: #{File.size(out_path)} bytes"
else
  puts "FAILED. send_to_layout returned false."
  puts "可能原因："
  puts "  - LayOut app 未裝（呢個 method 需要 LayOut runtime）"
  puts "  - 唔夠權限寫 #{dir}"
  puts "  - SketchUp version 太舊（需要 SketchUp 2018+）"
end

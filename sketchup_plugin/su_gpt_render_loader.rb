# SketchUp registers this loader file from the Plugins folder.
# It in turn loads the actual plugin code from the su_gpt_render/ subfolder.

require 'sketchup.rb'
require 'extensions.rb'

module SuGptRenderExt
  ext = SketchupExtension.new("GPT Render", File.join(File.dirname(__FILE__), "su_gpt_render", "su_gpt_render.rb"))
  ext.version     = "0.1.0"
  ext.creator     = "timothy / claude"
  ext.copyright   = "2026"
  ext.description = "Render current view via Poe GPT-Image-2 to a photorealistic interior image."
  Sketchup.register_extension(ext, true)
end

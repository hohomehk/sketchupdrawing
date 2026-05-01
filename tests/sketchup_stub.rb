# sketchup_stub.rb — Minimal in-process stubs for SketchUp Ruby API,
# enough to load and exercise the non-GUI logic of su_gpt_render.rb.
#
# Loaded BEFORE the plugin file. The plugin requires 'sketchup.rb' /
# 'extensions.rb' which we satisfy by adding them to $LOADED_FEATURES.

require "logger"
require "tempfile"

$STUB_LOG = Logger.new(STDOUT)
$STUB_LOG.level = Logger::WARN
$STUB_LOG.formatter = ->(sev, _, _, msg) { "    [stub #{sev}] #{msg}\n" }

# ----- Sketchup -----
module Sketchup
  @@status_text = ""

  def self.active_model
    @@model ||= ModelStub.new
  end

  def self.version
    "21.1.279 (mocked)"
  end

  def self.status_text=(v)
    @@status_text = v
    $STUB_LOG.info "Sketchup.status_text = #{v.inspect}"
  end

  def self.status_text; @@status_text; end

  def self.reset_model!
    @@model = ModelStub.new
  end

  class ModelStub
    attr_accessor :path, :selection, :pages
    def initialize
      @path = ""
      @selection = []
      @pages = PagesStub.new
    end

    def active_view
      @view ||= ViewStub.new
    end

    def entities; []; end
  end

  class PagesStub
    def selected_page; nil; end
    def each(&b); end
    def each_with_index(&b); end
    def length; 0; end
    def to_a; []; end
  end

  class ViewStub
    attr_reader :write_image_calls
    def initialize; @write_image_calls = []; end
    def write_image(opts)
      @write_image_calls << opts
      File.binwrite(opts[:filename], "FAKE_PNG_BYTES")
      true
    end
    def refresh; end
  end
end

# ----- UI -----
module UI
  @@menu_items = []
  @@messages = []
  @@inputbox_response = nil
  @@open_urls = []
  @@timers = {}
  @@timer_counter = 0

  def self.menu(name)
    MenuStub.new(name)
  end

  class MenuStub
    def initialize(name); @name = name; end
    def add_submenu(name); MenuStub.new("#{@name}/#{name}"); end
    def add_item(label, &block)
      UI.record_menu_item(@name, label, block)
    end
    def add_separator; end
  end

  def self.record_menu_item(parent, label, block)
    @@menu_items << { parent: parent, label: label, block: block }
  end
  def self.menu_items; @@menu_items; end

  def self.messagebox(msg)
    @@messages << msg
    $STUB_LOG.info "messagebox: #{msg.to_s.lines.first&.strip}"
  end
  def self.messages; @@messages; end
  def self.clear_messages!; @@messages.clear; end

  def self.inputbox(prompts, defaults, title)
    @@inputbox_response || defaults
  end
  def self.set_inputbox_response(arr); @@inputbox_response = arr; end

  def self.openURL(url)
    @@open_urls << url
    $STUB_LOG.info "openURL: #{url}"
  end
  def self.opened_urls; @@open_urls; end

  def self.start_timer(seconds, repeat = false, &block)
    @@timer_counter += 1
    id = @@timer_counter
    @@timers[id] = { seconds: seconds, repeat: repeat, block: block, fired: 0 }
    id
  end
  def self.stop_timer(id); @@timers.delete(id); end
  def self.timers; @@timers; end
  # Manually fire a timer once (test helper)
  def self.fire_timer(id)
    t = @@timers[id] or raise "no timer #{id}"
    t[:fired] += 1
    t[:block].call
    @@timers.delete(id) unless t[:repeat]
  end

  def self.reset!
    @@menu_items.clear
    @@messages.clear
    @@open_urls.clear
    @@timers.clear
    @@timer_counter = 0
    @@inputbox_response = nil
  end

  class HtmlDialog
    STYLE_DIALOG  = 0
    STYLE_UTILITY = 1
    STYLE_WINDOW  = 2

    attr_reader :html, :callbacks, :scripts

    def initialize(opts)
      @opts = opts
      @callbacks = {}
      @scripts = []
      @html = ""
      @visible = false
    end

    def set_html(html); @html = html; end
    def add_action_callback(name, &block); @callbacks[name] = block; end
    def show; @visible = true; end
    def visible?; @visible; end
    def close; @visible = false; end
    def bring_to_front; end
    def execute_script(js); @scripts << js; end

    def trigger(name, *args)
      cb = @callbacks[name] or raise "no callback #{name}"
      cb.call(self, *args)
    end
  end
end

# Top-level helpers used by SU plugins
def file_loaded?(path)
  $loaded_paths ||= {}
  $loaded_paths[path]
end

def file_loaded(path)
  $loaded_paths ||= {}
  $loaded_paths[path] = true
end

# Pretend sketchup.rb / extensions.rb are required
$LOADED_FEATURES << "sketchup.rb" << "extensions.rb"

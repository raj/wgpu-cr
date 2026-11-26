# Windowed render example through the object layer: the same triangle as
# examples/triangle.cr, without a single manual `*_release`.
#
#   crystal run examples/triangle_oo.cr
#   WGPU_FRAMES=120 crystal run examples/triangle_oo.cr   # auto-quit after 120 frames
#
# macOS uses the Cocoa/Metal native surface, Linux Wayland (or X11). The
# windowing glue lives in examples/lib_glfw.cr — it is not part of the binding.
require "../src/wgpu"
require "./lib_glfw"

WIDTH  = 800
HEIGHT = 600

WGSL = <<-SHADER
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  var p = array<vec2<f32>, 3>(
    vec2<f32>( 0.0,  0.5),
    vec2<f32>(-0.5, -0.5),
    vec2<f32>( 0.5, -0.5),
  );
  return vec4<f32>(p[i], 0.0, 1.0);
}

@fragment
fn fs_main() -> @location(0) vec4<f32> {
  return vec4<f32>(1.0, 0.45, 0.1, 1.0);
}
SHADER

# Creates a surface for the GLFW window from its native handles.
def create_surface(instance : WGPU::Instance, window : Void*) : WGPU::Surface
  {% if flag?(:darwin) %}
    none = Pointer(Void).null
    layer = LibObjC.msg_send(LibObjC.get_class("CAMetalLayer"), LibObjC.register_name("layer"), none)
    view = LibObjC.msg_send(LibGLFW.get_cocoa_window(window), LibObjC.register_name("contentView"), none)
    LibObjC.msg_send(view, LibObjC.register_name("setWantsLayer:"), Pointer(Void).new(1_u64)) # YES
    LibObjC.msg_send(view, LibObjC.register_name("setLayer:"), layer)
    instance.create_surface(metal_layer: layer)
  {% else %}
    wl_display = LibGLFW.get_wayland_display
    unless wl_display.null?
      return instance.create_surface(wayland_display: wl_display, wayland_surface: LibGLFW.get_wayland_window(window))
    end
    x11_display = LibGLFW.get_x11_display
    unless x11_display.null?
      return instance.create_surface(xlib_display: x11_display, xlib_window: LibGLFW.get_x11_window(window))
    end
    abort "Neither Wayland nor X11 display available from GLFW"
  {% end %}
end

# --- Window -----------------------------------------------------------------
abort "glfwInit failed" if LibGLFW.init == 0
LibGLFW.window_hint(LibGLFW::CLIENT_API, LibGLFW::NO_API) # no OpenGL context: wgpu owns the surface
window = LibGLFW.create_window(WIDTH, HEIGHT, "wgpu-cr — triangle (object layer)", nil, nil)
abort "glfwCreateWindow failed" if window.null?

WGPU::Instance.new do |instance|
  # The surface must not outlive the window: `use` releases it at block exit.
  # The pipeline, shader, device… are released when the GC collects them.
  create_surface(instance, window).use do |surface|
    adapter = instance.request_adapter(compatible_surface: surface)
    device = adapter.request_device
    puts "wgpu-cr #{WGPU::VERSION} (wgpu-native #{WGPU::NATIVE_VERSION}) on #{adapter.info.description}"

    format = surface.capabilities(adapter).formats.first? || abort "surface has no supported format"
    LibGLFW.get_framebuffer_size(window, out fb_w, out fb_h)
    surface.configure(device, format, fb_w, fb_h)

    shader = device.create_shader_module(WGSL)
    pipeline = device.create_render_pipeline(
      WGPU::VertexState.new(shader, "vs_main"),
      WGPU::FragmentState.new(shader, [WGPU::ColorTargetState.new(format)], "fs_main"))

    # Set WGPU_FRAMES=N to auto-quit after N frames (handy for headless testing).
    max_frames = ENV["WGPU_FRAMES"]?.try(&.to_i?)
    frames = 0
    puts "Rendering — close the window to quit."
    while LibGLFW.window_should_close(window) == 0
      break if max_frames && frames >= max_frames
      LibGLFW.poll_events

      texture = surface.current_texture
      unless texture
        # Outdated/Lost (e.g. after a resize): reconfigure, then skip the frame.
        if surface.last_status.try { |st| st.outdated? || st.lost? }
          LibGLFW.get_framebuffer_size(window, out w, out h)
          surface.configure(device, format, w, h) if w > 0 && h > 0
        end
        next
      end

      texture.use do
        texture.create_view.use do |view|
          encoder = device.create_command_encoder
          encoder.begin_render_pass([WGPU::ColorAttachment.new(view, clear_value: {0.02, 0.02, 0.05, 1.0})]) do |pass|
            pass.set_pipeline(pipeline)
            pass.draw(3)
          end
          device.queue.submit(encoder.finish) # consumes the encoder and the command buffer
          surface.present
        end
      end
      frames += 1
    end
    puts "#{frames} frames rendered."
  end
end

LibGLFW.destroy_window(window)
LibGLFW.terminate

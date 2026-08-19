# Windowed render example: draws a triangle in a GLFW window.
#
#   crystal run examples/triangle.cr
#
# Demonstrates the render path: GLFW window → Metal surface → adapter/device →
# render pipeline → per-frame (acquire texture → render pass → present).
#
# macOS only for now (uses the Cocoa/Metal native surface). The windowing glue
# lives in examples/lib_glfw.cr — it is not part of the core binding.
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

# Creates a wgpu surface backed by a CAMetalLayer attached to the GLFW window.
def make_metal_surface(instance : LibWGPU::Instance, window : Void*) : LibWGPU::Surface
  ns_window = LibGLFW.get_cocoa_window(window)

  none = Pointer(Void).null

  # layer = [CAMetalLayer layer]
  metal_class = LibObjC.get_class("CAMetalLayer")
  layer = LibObjC.msg_send(metal_class, LibObjC.register_name("layer"), none)

  # view = [ns_window contentView]; [view setWantsLayer:YES]; [view setLayer:layer]
  view = LibObjC.msg_send(ns_window, LibObjC.register_name("contentView"), none)
  LibObjC.msg_send(view, LibObjC.register_name("setWantsLayer:"), Pointer(Void).new(1_u64)) # YES
  LibObjC.msg_send(view, LibObjC.register_name("setLayer:"), layer)

  source = LibWGPU::SurfaceSourceMetalLayer.new
  source.chain.s_type = LibWGPU::SType::SurfaceSourceMetalLayer
  source.layer = layer

  desc = LibWGPU::SurfaceDescriptor.new
  desc.label = WGPU.empty_string_view
  desc.next_in_chain = pointerof(source).as(Pointer(LibWGPU::ChainedStruct))
  LibWGPU.instance_create_surface(instance, pointerof(desc))
end

# --- Window -----------------------------------------------------------------
abort "glfwInit failed" if LibGLFW.init == 0
LibGLFW.window_hint(LibGLFW::CLIENT_API, LibGLFW::NO_API) # no OpenGL context: wgpu owns the surface
window = LibGLFW.create_window(WIDTH, HEIGHT, "wgpu-cr — triangle", nil, nil)
abort "glfwCreateWindow failed" if window.null?

# --- wgpu setup -------------------------------------------------------------
instance = WGPU.create_instance
surface = make_metal_surface(instance, window)
adapter = WGPU.request_adapter(instance, compatible_surface: surface)
device = WGPU.request_device(instance, adapter)
queue = LibWGPU.device_get_queue(device)

puts "wgpu-cr #{WGPU::VERSION} (wgpu-native #{WGPU::NATIVE_VERSION})"

# Pick the surface's preferred format.
caps = LibWGPU::SurfaceCapabilities.new
caps_status = LibWGPU.surface_get_capabilities(surface, adapter, pointerof(caps))
if !caps_status.success? || caps.format_count == 0
  LibWGPU.surface_capabilities_free_members(caps)
  abort "surface_get_capabilities failed (status: #{caps_status}, format_count: #{caps.format_count})"
end
format = caps.formats[0]
LibWGPU.surface_capabilities_free_members(caps)

# Configure the surface for rendering.
LibGLFW.get_framebuffer_size(window, out fb_w, out fb_h)
config = LibWGPU::SurfaceConfiguration.new
config.device = device
config.format = format
config.usage = LibWGPU::TextureUsage::RenderAttachment
config.width = fb_w.to_u32
config.height = fb_h.to_u32
config.present_mode = LibWGPU::PresentMode::Fifo
config.alpha_mode = LibWGPU::CompositeAlphaMode::Auto
LibWGPU.surface_configure(surface, pointerof(config))

# --- Render pipeline --------------------------------------------------------
code = WGPU.string_view(WGSL)
wgsl = LibWGPU::ShaderSourceWGSL.new
wgsl.chain.s_type = LibWGPU::SType::ShaderSourceWGSL
wgsl.code = code
sdesc = LibWGPU::ShaderModuleDescriptor.new
sdesc.next_in_chain = pointerof(wgsl).as(Pointer(LibWGPU::ChainedStruct))
sdesc.label = WGPU.empty_string_view
shader = LibWGPU.device_create_shader_module(device, pointerof(sdesc))

vs_entry = WGPU.string_view("vs_main")
fs_entry = WGPU.string_view("fs_main")

vertex = LibWGPU::VertexState.new
vertex.module_ = shader
vertex.entry_point = vs_entry

target = LibWGPU::ColorTargetState.new
target.format = format
target.write_mask = LibWGPU::ColorWriteMask::All

fragment = LibWGPU::FragmentState.new
fragment.module_ = shader
fragment.entry_point = fs_entry
fragment.target_count = 1_u64
fragment.targets = pointerof(target)

primitive = LibWGPU::PrimitiveState.new
primitive.topology = LibWGPU::PrimitiveTopology::TriangleList
primitive.front_face = LibWGPU::FrontFace::CCW
primitive.cull_mode = LibWGPU::CullMode::None

multisample = LibWGPU::MultisampleState.new
multisample.count = 1_u32
multisample.mask = 0xFFFFFFFF_u32

rp_desc = LibWGPU::RenderPipelineDescriptor.new
rp_desc.label = WGPU.empty_string_view
rp_desc.layout = WGPU.null(LibWGPU::PipelineLayout) # auto
rp_desc.vertex = vertex
rp_desc.primitive = primitive
rp_desc.multisample = multisample
rp_desc.fragment = pointerof(fragment)
pipeline = LibWGPU.device_create_render_pipeline(device, pointerof(rp_desc))

# --- Render loop ------------------------------------------------------------
# Set WGPU_FRAMES=N to auto-quit after N frames (handy for headless testing).
max_frames = ENV["WGPU_FRAMES"]?.try(&.to_i?)
frame = 0
puts "Rendering — close the window to quit."
while LibGLFW.window_should_close(window) == 0
  break if max_frames && frame >= max_frames
  LibGLFW.poll_events

  st = LibWGPU::SurfaceTexture.new
  LibWGPU.surface_get_current_texture(surface, pointerof(st))
  unless st.status.success_optimal? || st.status.success_suboptimal?
    # Non-optimal acquisitions can still hand out a texture: release it to
    # avoid leaking one per skipped frame.
    LibWGPU.texture_release(st.texture) unless st.texture.null?
    next # texture not ready (resize/outdated) — skip this frame
  end

  view = LibWGPU.texture_create_view(st.texture, Pointer(LibWGPU::TextureViewDescriptor).null)

  color = LibWGPU::RenderPassColorAttachment.new
  color.view = view
  color.depth_slice = 0xFFFFFFFF_u32 # WGPU_DEPTH_SLICE_UNDEFINED
  color.load_op = LibWGPU::LoadOp::Clear
  color.store_op = LibWGPU::StoreOp::Store
  color.clear_value = LibWGPU::Color.new(r: 0.02, g: 0.02, b: 0.05, a: 1.0)

  pass_desc = LibWGPU::RenderPassDescriptor.new
  pass_desc.label = WGPU.empty_string_view
  pass_desc.color_attachment_count = 1_u64
  pass_desc.color_attachments = pointerof(color)

  enc_desc = LibWGPU::CommandEncoderDescriptor.new
  enc_desc.label = WGPU.empty_string_view
  encoder = LibWGPU.device_create_command_encoder(device, pointerof(enc_desc))

  pass = LibWGPU.command_encoder_begin_render_pass(encoder, pointerof(pass_desc))
  LibWGPU.render_pass_encoder_set_pipeline(pass, pipeline)
  LibWGPU.render_pass_encoder_draw(pass, 3_u32, 1_u32, 0_u32, 0_u32)
  LibWGPU.render_pass_encoder_end(pass)

  cmd_desc = LibWGPU::CommandBufferDescriptor.new
  cmd_desc.label = WGPU.empty_string_view
  cmd = LibWGPU.command_encoder_finish(encoder, pointerof(cmd_desc))
  cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
  LibWGPU.queue_submit(queue, 1_u64, cmds.to_unsafe)

  LibWGPU.surface_present(surface)

  LibWGPU.command_buffer_release(cmd)
  LibWGPU.render_pass_encoder_release(pass)
  LibWGPU.command_encoder_release(encoder)
  LibWGPU.texture_view_release(view)
  LibWGPU.texture_release(st.texture)
  frame += 1
end

# --- Cleanup ----------------------------------------------------------------
LibWGPU.render_pipeline_release(pipeline)
LibWGPU.shader_module_release(shader)
LibWGPU.surface_release(surface)
LibWGPU.queue_release(queue)
LibWGPU.device_release(device)
LibWGPU.adapter_release(adapter)
LibWGPU.instance_release(instance)
LibGLFW.destroy_window(window)
LibGLFW.terminate

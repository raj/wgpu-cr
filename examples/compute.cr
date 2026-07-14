# Compute example: doubles each element of a float array on the GPU.
#
#   crystal run examples/compute.cr
#
# Demonstrates the full pipeline: instance → adapter → device → buffer →
# WGSL shader → compute pipeline → bind group → command encoder →
# dispatch → copy → mapping → read back.
require "../src/wgpu"

WGSL = <<-SHADER
@group(0) @binding(0)
var<storage, read_write> data: array<f32>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x;
  if (i < arrayLength(&data)) {
    data[i] = data[i] * 2.0;
  }
}
SHADER

input = Array(Float32).new(256) { |i| i.to_f32 }
n = input.size
byte_size = (n * sizeof(Float32)).to_u64

puts "wgpu-cr #{WGPU::VERSION} (wgpu-native #{WGPU::NATIVE_VERSION})"
puts "Input  : #{input.first(8).join(", ")}, … (#{n} elements)"

instance = WGPU.create_instance
adapter = WGPU.request_adapter(instance)
device = WGPU.request_device(instance, adapter)
queue = LibWGPU.device_get_queue(device)

# --- Storage buffer (read/written by the shader, copyable) ---
desc = LibWGPU::BufferDescriptor.new
desc.label = WGPU.empty_string_view
desc.usage = LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopySrc | LibWGPU::BufferUsage::CopyDst
desc.size = byte_size
desc.mapped_at_creation = 0_u32
storage = LibWGPU.device_create_buffer(device, pointerof(desc))

# Upload the input data.
LibWGPU.queue_write_buffer(queue, storage, 0_u64, input.to_unsafe.as(Void*), byte_size)

# --- WGSL shader module ---
src = WGPU.string_view(WGSL)
wgsl = LibWGPU::ShaderSourceWGSL.new
wgsl.chain.s_type = LibWGPU::SType::ShaderSourceWGSL
wgsl.code = src

shader_desc = LibWGPU::ShaderModuleDescriptor.new
shader_desc.next_in_chain = pointerof(wgsl).as(Pointer(LibWGPU::ChainedStruct))
shader_desc.label = WGPU.empty_string_view
shader_module = LibWGPU.device_create_shader_module(device, pointerof(shader_desc))

# --- Compute pipeline (auto layout) ---
entry_point = WGPU.string_view("main")
state = LibWGPU::ComputeState.new
state.module_ = shader_module
state.entry_point = entry_point

pipe_desc = LibWGPU::ComputePipelineDescriptor.new
pipe_desc.label = WGPU.empty_string_view
pipe_desc.layout = WGPU.null(LibWGPU::PipelineLayout) # auto
pipe_desc.compute = state
pipeline = LibWGPU.device_create_compute_pipeline(device, pointerof(pipe_desc))

# --- Bind group connecting the buffer to binding 0 ---
layout = LibWGPU.compute_pipeline_get_bind_group_layout(pipeline, 0_u32)

entry = LibWGPU::BindGroupEntry.new
entry.binding = 0_u32
entry.buffer = storage
entry.offset = 0_u64
entry.size = byte_size

bg_desc = LibWGPU::BindGroupDescriptor.new
bg_desc.label = WGPU.empty_string_view
bg_desc.layout = layout
bg_desc.entry_count = 1_u64
bg_desc.entries = pointerof(entry)
bind_group = LibWGPU.device_create_bind_group(device, pointerof(bg_desc))

# --- Command encoding ---
enc_desc = LibWGPU::CommandEncoderDescriptor.new
enc_desc.label = WGPU.empty_string_view
encoder = LibWGPU.device_create_command_encoder(device, pointerof(enc_desc))

pass_desc = LibWGPU::ComputePassDescriptor.new
pass_desc.label = WGPU.empty_string_view
pass = LibWGPU.command_encoder_begin_compute_pass(encoder, pointerof(pass_desc))
LibWGPU.compute_pass_encoder_set_pipeline(pass, pipeline)
LibWGPU.compute_pass_encoder_set_bind_group(pass, 0_u32, bind_group, 0_u64, Pointer(UInt32).null)
workgroups = ((n + 63) // 64).to_u32
LibWGPU.compute_pass_encoder_dispatch_workgroups(pass, workgroups, 1_u32, 1_u32)
LibWGPU.compute_pass_encoder_end(pass)

# --- Readback buffer (mappable) + copy ---
read_desc = LibWGPU::BufferDescriptor.new
read_desc.label = WGPU.empty_string_view
read_desc.usage = LibWGPU::BufferUsage::MapRead | LibWGPU::BufferUsage::CopyDst
read_desc.size = byte_size
read_desc.mapped_at_creation = 0_u32
readback = LibWGPU.device_create_buffer(device, pointerof(read_desc))

LibWGPU.command_encoder_copy_buffer_to_buffer(encoder, storage, 0_u64, readback, 0_u64, byte_size)

cmd_desc = LibWGPU::CommandBufferDescriptor.new
cmd_desc.label = WGPU.empty_string_view
cmd = LibWGPU.command_encoder_finish(encoder, pointerof(cmd_desc))

cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
LibWGPU.queue_submit(queue, 1_u64, cmds.to_unsafe)

# --- Map and read the result ---
WGPU.map_buffer_read(instance, readback, byte_size)
ptr = LibWGPU.buffer_get_mapped_range(readback, 0_u64, byte_size).as(Float32*)
output = Array(Float32).new(n) { |i| ptr[i] }
LibWGPU.buffer_unmap(readback)

puts "Output : #{output.first(8).join(", ")}, …"
ok = output.each_with_index.all? { |v, i| (v - input[i] * 2).abs < 1e-5 }
puts ok ? "✅ GPU computation correct (each element × 2)" : "❌ Unexpected result"

# --- Cleanup ---
LibWGPU.buffer_release(readback)
LibWGPU.bind_group_release(bind_group)
LibWGPU.bind_group_layout_release(layout)
LibWGPU.compute_pipeline_release(pipeline)
LibWGPU.shader_module_release(shader_module)
LibWGPU.buffer_release(storage)
LibWGPU.queue_release(queue)
LibWGPU.device_release(device)
LibWGPU.adapter_release(adapter)
LibWGPU.instance_release(instance)

exit(ok ? 0 : 1)

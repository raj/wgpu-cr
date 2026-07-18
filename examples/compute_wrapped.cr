# Same "double each f32" compute as examples/compute.cr, but written with the
# high-level WGPU.* compute helpers instead of the raw FFI.
#
#   crystal run examples/compute_wrapped.cr
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

input = Slice(Float32).new(256) { |i| i.to_f32 }
n = input.size
byte_size = input.bytesize.to_u64

puts "wgpu-cr #{WGPU::VERSION} (wgpu-native #{WGPU::NATIVE_VERSION})"
puts "Input  : #{input.to_a.first(8).join(", ")}, … (#{n} elements)"

WGPU.set_log_stderr(LibWGPU::LogLevel::Warn)

instance = WGPU.create_instance
adapter = WGPU.request_adapter(instance)
device = WGPU.request_device(instance, adapter)

storage = WGPU.create_buffer_with_data(device, input,
  LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopySrc, "storage")

shader = WGPU.create_shader_module(device, WGSL, "double")
pipeline = WGPU.create_compute_pipeline(device, shader, "main", label: "double")
layout = WGPU.compute_bind_group_layout(pipeline)
bind_group = WGPU.create_bind_group(device, layout, [{0_u32, storage, byte_size}])

workgroups = ((n + 63) // 64).to_u32
WGPU.dispatch(device, pipeline, bind_group, workgroups)

bytes = WGPU.read_buffer(instance, device, storage, byte_size)
output = bytes.unsafe_slice_of(Float32)

puts "Output : #{output.to_a.first(8).join(", ")}, …"
ok = (0...n).all? { |i| (output[i] - input[i] * 2).abs < 1e-5 }
puts ok ? "✅ GPU computation correct (each element × 2)" : "❌ Unexpected result"

exit(ok ? 0 : 1)

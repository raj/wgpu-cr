# Same "double each f32" compute as examples/compute.cr and
# examples/compute_wrapped.cr, written with the object layer: no handle to
# pass around, no manual `*_release`.
#
#   crystal run examples/compute_oo.cr
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

puts "wgpu-cr #{WGPU::VERSION} (wgpu-native #{WGPU::NATIVE_VERSION})"
puts "Input  : #{input.to_a.first(8).join(", ")}, … (#{n} elements)"

WGPU.set_log_stderr(LibWGPU::LogLevel::Warn)

ok = WGPU::Instance.new do |instance|
  instance.request_adapter do |adapter|
    adapter.request_device do |device|
      storage = device.create_buffer_with_data(input,
        LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopySrc, label: "storage")

      # A WGSL error here would raise WGPU::ValidationError with wgpu's message.
      shader = device.create_shader_module(WGSL, label: "double")
      pipeline = device.create_compute_pipeline(shader, label: "double")
      bind_group = device.create_bind_group(pipeline.bind_group_layout(0), {0 => storage})

      # One-liner: device.dispatch(pipeline, bind_group, workgroups).
      # Spelled out here to show the encoder and the compute pass.
      encoder = device.create_command_encoder
      encoder.begin_compute_pass do |pass|
        pass.set_pipeline(pipeline)
        pass.set_bind_group(0, bind_group)
        pass.dispatch_workgroups((n + 63) // 64)
      end
      device.queue.submit(encoder.finish)

      output = device.read_buffer(storage).unsafe_slice_of(Float32)
      puts "Output : #{output.to_a.first(8).join(", ")}, …"
      (0...n).all? { |i| (output[i] - input[i] * 2).abs < 1e-5 }
    end # device released here (its resources are released by the GC)
  end
end

puts ok ? "✅ GPU computation correct (each element × 2)" : "❌ Unexpected result"
exit(ok ? 0 : 1)

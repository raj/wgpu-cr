require "./spec_helper"

describe WGPU do
  it "exposes the wgpu-native version" do
    WGPU::NATIVE_VERSION.should_not be_empty
  end

  it "creates an instance then requests adapter/device" do
    instance = WGPU.create_instance
    instance.null?.should be_false

    adapter = WGPU.request_adapter(instance)
    adapter.null?.should be_false

    device = WGPU.request_device(instance, adapter)
    device.null?.should be_false

    LibWGPU.device_release(device)
    LibWGPU.adapter_release(adapter)
    LibWGPU.instance_release(instance)
  end

  it "runs a compute shader (doubles an array)" do
    instance = WGPU.create_instance
    adapter = WGPU.request_adapter(instance)
    device = WGPU.request_device(instance, adapter)
    queue = LibWGPU.device_get_queue(device)

    input = Array(Float32).new(64) { |i| i.to_f32 }
    bytes = (input.size * sizeof(Float32)).to_u64

    bdesc = LibWGPU::BufferDescriptor.new
    bdesc.label = WGPU.empty_string_view
    bdesc.usage = LibWGPU::BufferUsage.new(
      LibWGPU::BufferUsage::Storage.value |
      LibWGPU::BufferUsage::CopySrc.value |
      LibWGPU::BufferUsage::CopyDst.value)
    bdesc.size = bytes
    storage = LibWGPU.device_create_buffer(device, pointerof(bdesc))
    LibWGPU.queue_write_buffer(queue, storage, 0_u64, input.to_unsafe.as(Void*), bytes)

    wgsl_src = <<-W
    @group(0) @binding(0) var<storage, read_write> d: array<f32>;
    @compute @workgroup_size(64) fn main(@builtin(global_invocation_id) g: vec3<u32>) {
      if (g.x < arrayLength(&d)) { d[g.x] = d[g.x] * 2.0; }
    }
    W
    code = WGPU.string_view(wgsl_src)
    wgsl = LibWGPU::ShaderSourceWGSL.new
    wgsl.chain.s_type = LibWGPU::SType::ShaderSourceWGSL
    wgsl.code = code
    sdesc = LibWGPU::ShaderModuleDescriptor.new
    sdesc.next_in_chain = pointerof(wgsl).as(Pointer(LibWGPU::ChainedStruct))
    sdesc.label = WGPU.empty_string_view
    shader = LibWGPU.device_create_shader_module(device, pointerof(sdesc))

    ep = WGPU.string_view("main")
    state = LibWGPU::ComputeState.new
    state.module_ = shader
    state.entry_point = ep
    pdesc = LibWGPU::ComputePipelineDescriptor.new
    pdesc.label = WGPU.empty_string_view
    pdesc.layout = WGPU.null(LibWGPU::PipelineLayout)
    pdesc.compute = state
    pipeline = LibWGPU.device_create_compute_pipeline(device, pointerof(pdesc))

    bgl = LibWGPU.compute_pipeline_get_bind_group_layout(pipeline, 0_u32)
    entry = LibWGPU::BindGroupEntry.new
    entry.binding = 0_u32
    entry.buffer = storage
    entry.size = bytes
    bgdesc = LibWGPU::BindGroupDescriptor.new
    bgdesc.label = WGPU.empty_string_view
    bgdesc.layout = bgl
    bgdesc.entry_count = 1_u64
    bgdesc.entries = pointerof(entry)
    bind_group = LibWGPU.device_create_bind_group(device, pointerof(bgdesc))

    edesc = LibWGPU::CommandEncoderDescriptor.new
    edesc.label = WGPU.empty_string_view
    encoder = LibWGPU.device_create_command_encoder(device, pointerof(edesc))
    cpdesc = LibWGPU::ComputePassDescriptor.new
    cpdesc.label = WGPU.empty_string_view
    pass = LibWGPU.command_encoder_begin_compute_pass(encoder, pointerof(cpdesc))
    LibWGPU.compute_pass_encoder_set_pipeline(pass, pipeline)
    LibWGPU.compute_pass_encoder_set_bind_group(pass, 0_u32, bind_group, 0_u64, Pointer(UInt32).null)
    LibWGPU.compute_pass_encoder_dispatch_workgroups(pass, 1_u32, 1_u32, 1_u32)
    LibWGPU.compute_pass_encoder_end(pass)

    rdesc = LibWGPU::BufferDescriptor.new
    rdesc.label = WGPU.empty_string_view
    rdesc.usage = LibWGPU::BufferUsage.new(
      LibWGPU::BufferUsage::MapRead.value | LibWGPU::BufferUsage::CopyDst.value)
    rdesc.size = bytes
    readback = LibWGPU.device_create_buffer(device, pointerof(rdesc))
    LibWGPU.command_encoder_copy_buffer_to_buffer(encoder, storage, 0_u64, readback, 0_u64, bytes)
    cbdesc = LibWGPU::CommandBufferDescriptor.new
    cbdesc.label = WGPU.empty_string_view
    cmd = LibWGPU.command_encoder_finish(encoder, pointerof(cbdesc))
    cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
    LibWGPU.queue_submit(queue, 1_u64, cmds.to_unsafe)

    WGPU.map_buffer_read(instance, readback, bytes)
    ptr = LibWGPU.buffer_get_mapped_range(readback, 0_u64, bytes).as(Float32*)
    output = Array(Float32).new(input.size) { |i| ptr[i] }
    LibWGPU.buffer_unmap(readback)

    output.should eq(input.map { |v| v * 2 })

    LibWGPU.instance_release(instance)
  end

  # Same compute round-trip as above, but driven entirely through the WGPU.*
  # ergonomic helper layer (create_shader_module/create_buffer_with_data/
  # create_compute_pipeline/create_bind_group/dispatch/read_buffer). Regression
  # test so those helpers stay wired up correctly.
  it "runs a compute shader through the WGPU.* helpers" do
    instance = WGPU.create_instance
    adapter = WGPU.request_adapter(instance)
    device = WGPU.request_device(instance, adapter)

    input = Slice(Float32).new(64) { |i| i.to_f32 }
    size = input.bytesize.to_u64

    storage = WGPU.create_buffer_with_data(device, input,
      LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopySrc)

    wgsl_src = <<-W
    @group(0) @binding(0) var<storage, read_write> d: array<f32>;
    @compute @workgroup_size(64) fn main(@builtin(global_invocation_id) g: vec3<u32>) {
      if (g.x < arrayLength(&d)) { d[g.x] = d[g.x] * 2.0; }
    }
    W
    shader = WGPU.create_shader_module(device, wgsl_src)
    pipeline = WGPU.create_compute_pipeline(device, shader)
    layout = WGPU.compute_bind_group_layout(pipeline)
    bind_group = WGPU.create_bind_group(device, layout, [{0_u32, storage, size}])

    WGPU.dispatch(device, pipeline, bind_group, 1_u32)

    bytes = WGPU.read_buffer(instance, device, storage, size)
    output = bytes.unsafe_slice_of(Float32).to_a

    output.should eq(input.to_a.map { |v| v * 2 })

    LibWGPU.instance_release(instance)
  end
end

# ABI guards: assert the memory layout of structs we pass to wgpu-native by value matches the
# C `webgpu.h` this binding targets. These sizes are derived from the vendored header
# (vendor/wgpu-native/include/webgpu/webgpu.h) on a 64-bit target (pointer = size_t = 8 bytes,
# WGPUFlags = uint64_t, C enums = 4 bytes). If a wgpu-native bump changes a struct, one of these
# fails instead of silently corrupting arguments at runtime.
describe "LibWGPU struct ABI" do
  it "keeps WGPUFlags-based enums 64-bit (the linchpin for many struct offsets)" do
    # typedef uint64_t WGPUFlags; WGPUShaderStage / WGPUBufferUsage are WGPUFlags.
    sizeof(LibWGPU::ShaderStage).should eq(8)
    alignof(LibWGPU::ShaderStage).should eq(8)
    sizeof(LibWGPU::BufferUsage).should eq(8)
  end

  it "keeps the foundational structs stable" do
    # WGPUChainedStruct { ptr next; WGPUSType sType(enum=4) } -> 8 + 4 + pad = 16.
    sizeof(LibWGPU::ChainedStruct).should eq(16)
    alignof(LibWGPU::ChainedStruct).should eq(8)
    # WGPUStringView { char const* data; size_t length } -> 8 + 8 = 16.
    sizeof(LibWGPU::StringView).should eq(16)
    # WGPUColor { double r,g,b,a } -> 4 * 8 = 32.
    sizeof(LibWGPU::Color).should eq(32)
    # WGPUExtent3D { uint32 width,height,depthOrArrayLayers } -> 3 * 4 = 12, align 4.
    sizeof(LibWGPU::Extent3D).should eq(12)
    alignof(LibWGPU::Extent3D).should eq(4)
  end

  it "keeps recently-changed structs matching the header (previously unverified)" do
    # WGPUInstanceDescriptor { ptr; size_t requiredFeatureCount; ptr requiredFeatures;
    #   ptr requiredLimits } -> inline (no InstanceCapabilities sub-struct) -> 4 * 8 = 32.
    sizeof(LibWGPU::InstanceDescriptor).should eq(32)
    # WGPUBindGroupLayoutEntry { ptr; uint32 binding; WGPUShaderStage visibility(8);
    #   uint32 bindingArraySize; buffer; sampler; texture; storageTexture } -> 120.
    sizeof(LibWGPU::BindGroupLayoutEntry).should eq(120)
    # WGPULimits: 30 fields ending in uint32 maxImmediateSize, three uint64s -> 152.
    sizeof(LibWGPU::Limits).should eq(152)
    # WGPUBindGroupEntry { ptr; uint32 binding; ptr buffer; uint64 offset; uint64 size;
    #   ptr sampler; ptr textureView } -> 56.
    sizeof(LibWGPU::BindGroupEntry).should eq(56)
  end

  it "keeps the DeviceDescriptor callback-info structs matching the header (passed by value to adapter_request_device)" do
    # WGPUDeviceLostCallbackInfo { ptr; WGPUCallbackMode mode(enum=4, +4 pad);
    #   callback; userdata1; userdata2 } -> 8 + 8 + 8 + 8 + 8 = 40.
    sizeof(LibWGPU::DeviceLostCallbackInfo).should eq(40)
    # WGPUUncapturedErrorCallbackInfo { ptr; callback; userdata1; userdata2 }
    #   (no mode field) -> 4 * 8 = 32.
    sizeof(LibWGPU::UncapturedErrorCallbackInfo).should eq(32)
    # WGPUDeviceDescriptor { ptr; StringView(16); size_t; ptr; ptr; QueueDescriptor(24);
    #   DeviceLostCallbackInfo(40); UncapturedErrorCallbackInfo(32) } -> 144.
    sizeof(LibWGPU::DeviceDescriptor).should eq(144)
  end
end

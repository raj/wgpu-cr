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
end

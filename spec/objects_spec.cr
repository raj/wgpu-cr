require "./spec_helper"

private USAGE_RW = LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopySrc | LibWGPU::BufferUsage::CopyDst

private DOUBLE_WGSL = <<-W
  @group(0) @binding(0) var<storage, read_write> d: array<f32>;
  @compute @workgroup_size(64) fn main(@builtin(global_invocation_id) g: vec3<u32>) {
    if (g.x < arrayLength(&d)) { d[g.x] = d[g.x] * 2.0; }
  }
  W

# Creates a device in a separate frame and drops every reference to it, so the
# GC is free to finalize the whole chain.
private def make_garbage : Nil
  instance = WGPU::Instance.new
  device = instance.request_adapter.request_device
  device.create_buffer(64, USAGE_RW)
  device.create_shader_module(DOUBLE_WGSL)
  device.queue
  nil
end

describe "WGPU object layer" do
  it "chains Instance → Adapter → Device and releases each at block exit" do
    instance_ref = adapter_ref = device_ref = nil

    WGPU::Instance.new do |instance|
      instance_ref = instance
      instance.request_adapter do |adapter|
        adapter_ref = adapter
        adapter.instance.should be(instance)
        adapter.request_device do |device|
          device_ref = device
          device.adapter.should be(adapter)
          device.instance.should be(instance)
          device.released?.should be_false
        end
        device_ref.not_nil!.released?.should be_true
        adapter.released?.should be_false
      end
      adapter_ref.not_nil!.released?.should be_true
    end
    instance_ref.not_nil!.released?.should be_true
  end

  it "round-trips data through queue.write_buffer / queue.read_buffer" do
    WGPU::Instance.new do |instance|
      device = instance.request_adapter.request_device
      data = Slice(UInt32).new(8) { |i| (i * 3).to_u32 }

      device.create_buffer(data.bytesize, USAGE_RW, label: "roundtrip") do |buffer|
        buffer.size.should eq(data.bytesize)
        buffer.usage.should eq(USAGE_RW)
        buffer.label.should eq("roundtrip")

        device.queue.write_buffer(buffer, data)
        device.queue.read_buffer(buffer).unsafe_slice_of(UInt32).to_a.should eq(data.to_a)
      end
      device.release
    end
  end

  it "interoperates with the static WGPU.* API through to_unsafe" do
    WGPU::Instance.new do |instance|
      adapter = instance.request_adapter
      device = adapter.request_device

      input = Slice(Float32).new(64) { |i| i.to_f32 }
      storage = device.create_buffer(input.bytesize, USAGE_RW)
      device.queue.write_buffer(storage, input)
      shader = device.create_shader_module(DOUBLE_WGSL, label: "double")

      WGPU.create_compute_pipeline(device.to_unsafe, shader.to_unsafe) do |pipeline|
        WGPU.compute_bind_group_layout(pipeline) do |layout|
          WGPU.create_bind_group(device.to_unsafe, layout, [{0_u32, storage.to_unsafe, storage.size}]) do |bind_group|
            WGPU.dispatch(device.to_unsafe, pipeline, bind_group, 1_u32)
          end
        end
      end

      output = device.queue.read_buffer(storage).unsafe_slice_of(Float32).to_a
      output.should eq(input.to_a.map { |v| v * 2 })

      # Objects also pass straight to LibWGPU funs (Crystal calls to_unsafe).
      LibWGPU.buffer_get_size(storage).should eq(input.bytesize)

      [shader, storage, device, adapter].each(&.release)
    end
  end

  it "makes release idempotent and raises on use after release" do
    WGPU::Instance.new do |instance|
      device = instance.request_adapter.request_device
      buffer = device.create_buffer(16, USAGE_RW)

      buffer.release
      buffer.release
      buffer.released?.should be_true
      buffer.to_s.should contain("released")
      expect_raises(WGPU::Error, /Buffer used after release/) { buffer.size }
      expect_raises(WGPU::Error, /used after release/) { buffer.to_unsafe }

      device.release
      device.release
    end
  end

  it "owns its queue: one cached Queue, released with the device" do
    WGPU::Instance.new do |instance|
      device = instance.request_adapter.request_device
      queue = device.queue
      device.queue.should be(queue)
      queue.instance.should be(instance)

      device.release
      queue.released?.should be_true
      expect_raises(WGPU::Error, /Queue used after release/) { queue.submit([] of LibWGPU::CommandBuffer) }
    end
  end

  it "does not cascade to the queue when the GC finalizes the device" do
    WGPU::Instance.new do |instance|
      device = instance.request_adapter.request_device
      queue = device.queue
      data = Slice[7_u32, 8_u32]
      buffer = device.create_buffer(data.bytesize, USAGE_RW)

      device.finalize # what the GC would run
      device.released?.should be_true
      queue.released?.should be_false

      # The queue holds its own reference on the C device: still fully usable
      # (read_buffer creates a staging buffer on that device and pumps events).
      queue.write_buffer(buffer, data)
      queue.read_buffer(buffer).unsafe_slice_of(UInt32).to_a.should eq(data.to_a)

      buffer.release
      queue.release
    end
  end

  it "lets the GC finalize abandoned objects safely" do
    3.times { make_garbage }
    GC.collect
    GC.collect

    # The library still works after the finalizers ran.
    WGPU::Instance.new { |instance| instance.request_adapter { |adapter| adapter.has_feature?(LibWGPU::FeatureName::ShaderF16).should be_a(Bool) } }
  end

  it "exposes adapter and device info, limits and features" do
    WGPU::Instance.new do |instance|
      instance.request_adapter do |adapter|
        info = adapter.info
        info.description.should be_a(String)
        info.backend_type.should_not eq(LibWGPU::BackendType::Undefined)
        adapter.limits.max_bind_groups.should be > 0

        adapter.request_device do |device|
          device.adapter_info.backend_type.should eq(info.backend_type)
          device.limits.max_bind_groups.should be > 0
          device.features.each { |f| device.has_feature?(f).should be_true }
          device.create_buffer(4, USAGE_RW, label: "tagged") do |buffer|
            buffer.to_s.should contain(%(label: "tagged"))
          end
        end
      end
    end
  end
end

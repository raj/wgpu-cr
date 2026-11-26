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

  describe "phase 2: device resources" do
    it "runs the compute ×2 entirely through the object layer (auto layout)" do
      WGPU::Instance.new do |instance|
        instance.request_adapter do |adapter|
          adapter.request_device do |device|
            input = Slice(Float32).new(256) { |i| i.to_f32 }
            storage = device.create_buffer_with_data(input, LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopySrc)
            shader = device.create_shader_module(DOUBLE_WGSL)
            pipeline = device.create_compute_pipeline(shader)
            bind_group = device.create_bind_group(pipeline.bind_group_layout(0), {0 => storage})

            device.dispatch(pipeline, bind_group, 4)
            output = device.read_buffer(storage).unsafe_slice_of(Float32).to_a
            output.should eq(input.to_a.map { |v| v * 2 })
          end
        end
      end
    end

    it "runs compute with explicit layouts, a buffer range and a manual encoder" do
      wgsl = <<-W
        @group(0) @binding(0) var<storage, read> src: array<u32>;
        @group(0) @binding(1) var<storage, read_write> dst: array<u32>;
        @compute @workgroup_size(8) fn main(@builtin(global_invocation_id) g: vec3<u32>) {
          if (g.x < arrayLength(&dst)) { dst[g.x] = src[g.x] + 100u; }
        }
        W
      WGPU::Instance.new do |instance|
        device = instance.request_adapter.request_device
        compute = LibWGPU::ShaderStage::Compute
        bgl = device.create_bind_group_layout([
          WGPU::LayoutEntry.buffer(0, compute, LibWGPU::BufferBindingType::ReadOnlyStorage),
          WGPU::LayoutEntry.buffer(1, compute),
        ], label: "io")
        layout = device.create_pipeline_layout([bgl])
        pipeline = device.create_compute_pipeline(device.create_shader_module(wgsl), layout: layout)

        # 128 values in, only 8 bound at offset 256 bytes (storage offsets must
        # be multiples of min_storage_buffer_offset_alignment, 256 at most).
        src = device.create_buffer_with_data(Slice(UInt32).new(128) { |i| i.to_u32 }, LibWGPU::BufferUsage::Storage)
        dst = device.create_buffer(32, USAGE_RW)
        staging = device.create_buffer(32, LibWGPU::BufferUsage::MapRead | LibWGPU::BufferUsage::CopyDst)
        bind_group = device.create_bind_group(bgl, {0 => WGPU::BufferBinding.new(src, 256_u64, 32_u64), 1 => dst})

        device.dispatch(pipeline, bind_group, 1)
        encoder = device.create_command_encoder
        encoder.copy_buffer_to_buffer(dst, 0, staging, 0, 32)
        device.queue.submit(encoder.finish)

        staging.map_read { |bytes| bytes.unsafe_slice_of(UInt32).to_a }.should eq((164_u32..171_u32).to_a)
        staging.mapped?.should be_false
        device.release
      end
    end

    it "maps buffers for writing and reading" do
      WGPU::Instance.new do |instance|
        device = instance.request_adapter.request_device
        data = Slice(Int32).new(8) { |i| -i }

        # mapped_at_creation → write → unmap → GPU copy → map_read
        upload = device.create_buffer(32, LibWGPU::BufferUsage::MapWrite | LibWGPU::BufferUsage::CopySrc, mapped_at_creation: true)
        upload.mapped?.should be_true
        upload.write_mapped(data)
        upload.unmap
        upload.mapped?.should be_false

        readback = device.create_buffer(32, LibWGPU::BufferUsage::MapRead | LibWGPU::BufferUsage::CopyDst)
        encoder = device.create_command_encoder
        encoder.copy_buffer_to_buffer(upload, 0, readback, 0, 32)
        device.queue.submit(encoder.finish)

        readback.map_read
        readback.mapped?.should be_true
        readback.read_mapped.unsafe_slice_of(Int32).to_a.should eq(data.to_a)
        readback.read_mapped(8, 8).unsafe_slice_of(Int32).to_a.should eq([-2, -3])
        view = readback.const_mapped_range
        view.read_only?.should be_true
        readback.unmap

        # map_write block form on an already-used buffer
        upload.map_write { |bytes| bytes.fill(0xAB_u8) }
        upload.mapped?.should be_false
        encoder = device.create_command_encoder
        encoder.copy_buffer_to_buffer(upload, 0, readback, 0, 32)
        device.queue.submit(encoder.finish)
        readback.map_read { |bytes| bytes.all?(0xAB_u8) }.should be_true

        device.release
      end
    end

    it "consumes the encoder on finish and the command buffer on submit" do
      WGPU::Instance.new do |instance|
        device = instance.request_adapter.request_device
        buffer = device.create_buffer_with_data(Slice(UInt32).new(4, 0xFFFFFFFF_u32), USAGE_RW)

        encoder = device.create_command_encoder
        encoder.clear_buffer(buffer, 4, 8) # zero the middle two values
        cmd = encoder.finish
        encoder.released?.should be_true
        expect_raises(WGPU::Error, /used after release/) { encoder.clear_buffer(buffer) }

        device.queue.submit(cmd)
        cmd.released?.should be_true
        device.read_buffer(buffer).unsafe_slice_of(UInt32).to_a.should eq([0xFFFFFFFF_u32, 0_u32, 0_u32, 0xFFFFFFFF_u32])
        device.release
      end
    end

    it "uploads, copies back and samples a texture" do
      wgsl = <<-W
        @group(0) @binding(0) var tex: texture_2d<f32>;
        @group(0) @binding(1) var samp: sampler;
        @group(0) @binding(2) var<storage, read_write> result: array<f32>;
        @compute @workgroup_size(1) fn main() {
          result[0] = textureLoad(tex, vec2<i32>(1, 0), 0).r;
          result[1] = textureSampleLevel(tex, samp, vec2<f32>(0.125, 0.125), 0.0).g;
        }
        W
      WGPU::Instance.new do |instance|
        device = instance.request_adapter.request_device
        usage = LibWGPU::TextureUsage::TextureBinding | LibWGPU::TextureUsage::CopyDst | LibWGPU::TextureUsage::CopySrc
        texture = device.create_texture(4, 4, format: LibWGPU::TextureFormat::RGBA8Unorm, usage: usage, label: "checker")

        {texture.width, texture.height, texture.depth_or_array_layers}.should eq({4, 4, 1})
        {texture.mip_level_count, texture.sample_count}.should eq({1, 1})
        texture.dimension.should eq(LibWGPU::TextureDimension::N2D)
        texture.format.should eq(LibWGPU::TextureFormat::RGBA8Unorm)
        texture.usage.should eq(usage)

        # texel (x, y) = RGBA(x * 50, y * 50 + 1, 0, 255)
        pixels = Bytes.new(4 * 4 * 4)
        4.times { |y| 4.times { |x| i = (y * 4 + x) * 4; pixels[i] = (x * 50).to_u8; pixels[i + 1] = (y * 50 + 1).to_u8; pixels[i + 3] = 255_u8 } }
        device.queue.write_texture(texture, pixels, bytes_per_row: 16)

        # Copy back row 2 (bytes_per_row must be 256-aligned for buffer copies).
        row = device.create_buffer(256, LibWGPU::BufferUsage::MapRead | LibWGPU::BufferUsage::CopyDst)
        encoder = device.create_command_encoder
        encoder.copy_texture_to_buffer(texture, row, bytes_per_row: 256, height: 1, origin: {0, 2, 0})
        device.queue.submit(encoder.finish)
        row.map_read(0, 16) { |bytes| bytes.to_a }.should eq(pixels[32, 16].to_a)

        sampler = device.create_sampler(label: "nearest")
        pipeline = device.create_compute_pipeline(device.create_shader_module(wgsl))
        result = device.create_buffer(8, USAGE_RW)
        bind_group = device.create_bind_group(pipeline.bind_group_layout(0),
          {0 => texture.create_view, 1 => sampler, 2 => result})
        device.dispatch(pipeline, bind_group, 1)

        values = device.read_buffer(result).unsafe_slice_of(Float32)
        values[0].should be_close(50 / 255.0, 1e-3)
        values[1].should be_close(1 / 255.0, 1e-3)
        device.release
      end
    end

    it "keeps layout entries and views in sync with the C structs" do
      entry = WGPU::LayoutEntry.texture(3, LibWGPU::ShaderStage::Fragment, LibWGPU::TextureSampleType::Depth)
      entry.binding.should eq(3)
      entry.texture.sample_type.should eq(LibWGPU::TextureSampleType::Depth)
      entry.buffer.type_.should eq(LibWGPU::BufferBindingType::BindingNotUsed)
      entry.sampler.type_.should eq(LibWGPU::SamplerBindingType::BindingNotUsed)

      WGPU::Instance.new do |instance|
        device = instance.request_adapter.request_device
        texture = device.create_texture(8, 8, depth_or_array_layers: 2,
          format: LibWGPU::TextureFormat::R32Float, usage: LibWGPU::TextureUsage::TextureBinding)
        view = texture.create_view(dimension: LibWGPU::TextureViewDimension::N2D, base_array_layer: 1, array_layer_count: 1)
        view.texture.should be(texture)
        device.release
      end
    end
  end
end

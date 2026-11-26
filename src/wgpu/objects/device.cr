module WGPU
  # A logical device, obtained from `Adapter#request_device`: creates the GPU
  # resources. Keeps its `Adapter` (and so its `Instance`) alive.
  class Device < GPUObject(LibWGPU::Device)
    getter adapter : Adapter
    @queue : Queue? = nil

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@adapter : Adapter, handle : LibWGPU::Device)
      super(handle)
    end

    def instance : Instance
      @adapter.instance
    end

    # The device's queue, created on first access and owned by the device:
    # `#release` releases it too (later use raises `WGPU::Error`).
    def queue : Queue
      @queue ||= Queue.new(self)
    end

    # Releases the device and its queue. Idempotent.
    def release : Nil
      @queue.try &.release
      super
    end

    # Info of the adapter this device was created from.
    #
    # NOTE: reads it from the `Adapter`: `wgpuDeviceGetAdapterInfo` is an
    # `unimplemented!()` stub that aborts the process in wgpu-native v29.
    def adapter_info : AdapterInfo
      @adapter.info
    end

    def limits : LibWGPU::Limits
      limits = LibWGPU::Limits.new
      status = LibWGPU.device_get_limits(handle, pointerof(limits))
      raise Error.new("device_get_limits failed") unless status.success?
      limits
    end

    def features : Array(LibWGPU::FeatureName)
      supported = LibWGPU::SupportedFeatures.new
      LibWGPU.device_get_features(handle, pointerof(supported))
      Internal.features(supported)
    end

    def has_feature?(feature : LibWGPU::FeatureName) : Bool
      LibWGPU.device_has_feature(handle, feature) != 0
    end

    # ------------------------------------------------------------------
    # Resource creation
    # ------------------------------------------------------------------

    # Allocates a GPU buffer of `size` bytes.
    #
    #   device.create_buffer(1024, LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopySrc)
    def create_buffer(size : Int, usage : LibWGPU::BufferUsage,
                      label : String? = nil, mapped_at_creation : Bool = false) : Buffer
      raw = WGPU.create_buffer(handle, size.to_u64, usage, label, mapped_at_creation)
      Buffer.new(self, raw, label, mapped: mapped_at_creation)
    end

    # Yields a new buffer and releases it when the block exits.
    def create_buffer(size : Int, usage : LibWGPU::BufferUsage,
                      label : String? = nil, mapped_at_creation : Bool = false, &)
      create_buffer(size, usage, label, mapped_at_creation).use { |buffer| yield buffer }
    end

    # Compiles a WGSL source into a shader module.
    def create_shader_module(wgsl : String, label : String? = nil) : ShaderModule
      ShaderModule.new(self, WGPU.create_shader_module(handle, wgsl, label), label)
    end

    # Yields a new shader module and releases it when the block exits.
    def create_shader_module(wgsl : String, label : String? = nil, &)
      create_shader_module(wgsl, label).use { |mod| yield mod }
    end

    # Allocates a buffer and uploads `data` (any typed Slice) into it.
    # `CopyDst` is added to `usage` (the upload needs it).
    def create_buffer_with_data(data : Slice, usage : LibWGPU::BufferUsage, label : String? = nil) : Buffer
      buffer = create_buffer(data.bytesize, usage | LibWGPU::BufferUsage::CopyDst, label)
      queue.write_buffer(buffer, data)
      buffer
    end

    # Creates a texture of `width × height × depth_or_array_layers` texels.
    #
    #   device.create_texture(256, 256, format: LibWGPU::TextureFormat::RGBA8Unorm,
    #     usage: LibWGPU::TextureUsage::TextureBinding | LibWGPU::TextureUsage::CopyDst)
    def create_texture(width : Int, height : Int = 1, *,
                       format : LibWGPU::TextureFormat, usage : LibWGPU::TextureUsage,
                       depth_or_array_layers : Int = 1,
                       dimension : LibWGPU::TextureDimension = LibWGPU::TextureDimension::N2D,
                       mip_level_count : Int = 1, sample_count : Int = 1,
                       view_formats : Array(LibWGPU::TextureFormat)? = nil,
                       label : String? = nil) : Texture
      desc = LibWGPU::TextureDescriptor.new(
        label: Internal.label_view(label),
        usage: usage,
        dimension: dimension,
        size: Internal.extent(width, height, depth_or_array_layers),
        format: format,
        mip_level_count: mip_level_count.to_u32,
        sample_count: sample_count.to_u32,
      )
      if formats = view_formats
        desc.view_format_count = LibC::SizeT.new(formats.size)
        desc.view_formats = formats.to_unsafe
      end
      Texture.new(self, LibWGPU.device_create_texture(handle, pointerof(desc)), label)
    end

    # Creates a sampler. The defaults are WebGPU's: clamp to edge, nearest
    # filtering, LOD clamp 0..32, no comparison, no anisotropy.
    def create_sampler(address_mode_u : LibWGPU::AddressMode = LibWGPU::AddressMode::ClampToEdge,
                       address_mode_v : LibWGPU::AddressMode = LibWGPU::AddressMode::ClampToEdge,
                       address_mode_w : LibWGPU::AddressMode = LibWGPU::AddressMode::ClampToEdge,
                       mag_filter : LibWGPU::FilterMode = LibWGPU::FilterMode::Nearest,
                       min_filter : LibWGPU::FilterMode = LibWGPU::FilterMode::Nearest,
                       mipmap_filter : LibWGPU::MipmapFilterMode = LibWGPU::MipmapFilterMode::Nearest,
                       lod_min_clamp : Float32 = 0.0_f32, lod_max_clamp : Float32 = 32.0_f32,
                       compare : LibWGPU::CompareFunction = LibWGPU::CompareFunction::Undefined,
                       max_anisotropy : Int = 1, label : String? = nil) : Sampler
      desc = LibWGPU::SamplerDescriptor.new(
        label: Internal.label_view(label),
        address_mode_u: address_mode_u, address_mode_v: address_mode_v, address_mode_w: address_mode_w,
        mag_filter: mag_filter, min_filter: min_filter, mipmap_filter: mipmap_filter,
        lod_min_clamp: lod_min_clamp, lod_max_clamp: lod_max_clamp,
        compare: compare, max_anisotropy: max_anisotropy.to_u16,
      )
      Sampler.new(self, LibWGPU.device_create_sampler(handle, pointerof(desc)), label)
    end

    # Creates a bind group layout from entries built with `WGPU::LayoutEntry`.
    def create_bind_group_layout(entries : Enumerable(LibWGPU::BindGroupLayoutEntry), label : String? = nil) : BindGroupLayout
      list = entries.to_a
      desc = LibWGPU::BindGroupLayoutDescriptor.new(
        label: Internal.label_view(label),
        entry_count: LibC::SizeT.new(list.size),
        entries: list.to_unsafe,
      )
      BindGroupLayout.new(self, LibWGPU.device_create_bind_group_layout(handle, pointerof(desc)), label)
    end

    # Creates a pipeline layout: bind group layout `i` is used for group `i`.
    def create_pipeline_layout(bind_group_layouts : Enumerable(BindGroupLayout), label : String? = nil) : PipelineLayout
      handles = bind_group_layouts.map(&.to_unsafe)
      desc = LibWGPU::PipelineLayoutDescriptor.new(
        label: Internal.label_view(label),
        bind_group_layout_count: LibC::SizeT.new(handles.size),
        bind_group_layouts: handles.to_unsafe,
      )
      PipelineLayout.new(self, LibWGPU.device_create_pipeline_layout(handle, pointerof(desc)), label)
    end

    # Binds resources to `layout`, keyed by binding number. A value is a
    # `Buffer` (whole buffer), a `BufferBinding` (a range), a `Sampler` or a
    # `TextureView`.
    #
    #   device.create_bind_group(pipeline.bind_group_layout(0), {0 => input, 1 => output})
    def create_bind_group(layout : BindGroupLayout, entries : Hash(K, V), label : String? = nil) : BindGroup forall K, V
      list = entries.map { |binding, resource| Internal.bind_group_entry(binding, resource) }
      desc = LibWGPU::BindGroupDescriptor.new(
        label: Internal.label_view(label),
        layout: layout.to_unsafe,
        entry_count: LibC::SizeT.new(list.size),
        entries: list.to_unsafe,
      )
      BindGroup.new(self, LibWGPU.device_create_bind_group(handle, pointerof(desc)), label)
    end

    # Creates a compute pipeline running `entry_point` of `shader`. Without
    # `layout`, wgpu derives the layout from the shader ("auto" layout): get
    # it back with `ComputePipeline#bind_group_layout`.
    def create_compute_pipeline(shader : ShaderModule, entry_point : String = "main",
                                layout : PipelineLayout? = nil, label : String? = nil) : ComputePipeline
      raw_layout = layout ? layout.to_unsafe : Internal.null(LibWGPU::PipelineLayout)
      raw = WGPU.create_compute_pipeline(handle, shader.to_unsafe, entry_point, raw_layout, label)
      ComputePipeline.new(self, raw, label)
    end

    def create_command_encoder(label : String? = nil) : CommandEncoder
      desc = LibWGPU::CommandEncoderDescriptor.new(label: Internal.label_view(label))
      CommandEncoder.new(self, LibWGPU.device_create_command_encoder(handle, pointerof(desc)), label)
    end

    # ------------------------------------------------------------------
    # Shortcuts (parity with the static WGPU.* helpers)
    # ------------------------------------------------------------------

    # Records and submits one compute pass: `pipeline` with `bind_group` at
    # group 0, `x × y × z` workgroups. Does not wait: `read_buffer` does.
    def dispatch(pipeline : ComputePipeline, bind_group : BindGroup, x : Int, y : Int = 1, z : Int = 1) : Nil
      WGPU.dispatch(handle, pipeline.to_unsafe, bind_group.to_unsafe, x.to_u32, y.to_u32, z.to_u32)
    end

    # Same as `queue.write_buffer`.
    def write_buffer(buffer : Buffer, data : Slice, offset : Int = 0) : Nil
      queue.write_buffer(buffer, data, offset)
    end

    # Same as `queue.read_buffer`.
    def read_buffer(buffer : Buffer, size : Int = buffer.size) : Bytes
      queue.read_buffer(buffer, size)
    end

    private def release_handle : Nil
      LibWGPU.device_release(@handle)
    end
  end
end

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
      Buffer.new(self, raw, label)
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

    private def release_handle : Nil
      LibWGPU.device_release(@handle)
    end
  end
end

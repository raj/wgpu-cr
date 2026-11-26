module WGPU
  # Description of the physical device behind an `Adapter` (or a `Device`),
  # copied out of `WGPUAdapterInfo`.
  record AdapterInfo,
    vendor : String,
    architecture : String,
    device : String,
    description : String,
    backend_type : LibWGPU::BackendType,
    adapter_type : LibWGPU::AdapterType,
    vendor_id : UInt32,
    device_id : UInt32,
    subgroup_min_size : UInt32,
    subgroup_max_size : UInt32

  # A physical GPU (or software implementation), obtained from
  # `Instance#request_adapter`. Keeps its `Instance` alive.
  class Adapter < GPUObject(LibWGPU::Adapter)
    getter instance : Instance

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@instance : Instance, handle : LibWGPU::Adapter)
      super(handle)
    end

    # Requests a device, blocking (pumping the event loop) until wgpu answers.
    # Device loss and uncaptured errors are logged through `WGPU::Log` unless
    # you pass your own callbacks. Raises `WGPU::Error` on failure or timeout.
    def request_device(device_lost_callback : LibWGPU::DeviceLostCallback? = nil,
                       uncaptured_error_callback : LibWGPU::UncapturedErrorCallback? = nil,
                       timeout : Time::Span = 5.seconds) : Device
      raw = WGPU.request_device(@instance.to_unsafe, handle, device_lost_callback, uncaptured_error_callback, timeout)
      Device.new(self, raw)
    end

    # Yields a device and releases it (and its queue) when the block exits.
    def request_device(device_lost_callback : LibWGPU::DeviceLostCallback? = nil,
                       uncaptured_error_callback : LibWGPU::UncapturedErrorCallback? = nil,
                       timeout : Time::Span = 5.seconds, &)
      request_device(device_lost_callback, uncaptured_error_callback, timeout).use { |device| yield device }
    end

    def info : AdapterInfo
      info = LibWGPU::AdapterInfo.new
      status = LibWGPU.adapter_get_info(handle, pointerof(info))
      Internal.adapter_info(info, status)
    end

    def limits : LibWGPU::Limits
      limits = LibWGPU::Limits.new
      status = LibWGPU.adapter_get_limits(handle, pointerof(limits))
      raise Error.new("adapter_get_limits failed") unless status.success?
      limits
    end

    def features : Array(LibWGPU::FeatureName)
      supported = LibWGPU::SupportedFeatures.new
      LibWGPU.adapter_get_features(handle, pointerof(supported))
      Internal.features(supported)
    end

    def has_feature?(feature : LibWGPU::FeatureName) : Bool
      LibWGPU.adapter_has_feature(handle, feature) != 0
    end

    private def release_handle : Nil
      LibWGPU.adapter_release(@handle)
    end
  end

  module Internal
    # Copies a filled `WGPUAdapterInfo` into an `AdapterInfo` and frees the C
    # strings. Raises if `status` is not Success.
    def adapter_info(info : LibWGPU::AdapterInfo, status : LibWGPU::Status) : AdapterInfo
      raise Error.new("get_adapter_info failed") unless status.success?
      begin
        AdapterInfo.new(
          vendor: view_to_s(info.vendor),
          architecture: view_to_s(info.architecture),
          device: view_to_s(info.device),
          description: view_to_s(info.description),
          backend_type: info.backend_type,
          adapter_type: info.adapter_type,
          vendor_id: info.vendor_id,
          device_id: info.device_id,
          subgroup_min_size: info.subgroup_min_size,
          subgroup_max_size: info.subgroup_max_size,
        )
      ensure
        LibWGPU.adapter_info_free_members(info)
      end
    end

    # Copies a filled `WGPUSupportedFeatures` into an Array and frees it.
    def features(supported : LibWGPU::SupportedFeatures) : Array(LibWGPU::FeatureName)
      Array.new(supported.feature_count.to_i) { |i| supported.features[i] }
    ensure
      LibWGPU.supported_features_free_members(supported)
    end
  end
end

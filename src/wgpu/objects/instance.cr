module WGPU
  # Entry point of the object layer: owns a `WGPUInstance`.
  #
  #   WGPU::Instance.new do |instance|
  #     instance.request_adapter do |adapter|
  #       adapter.request_device do |device|
  #         # …
  #       end
  #     end
  #   end
  class Instance < GPUObject(LibWGPU::Instance)
    def initialize
      super(WGPU.create_instance)
    end

    # Yields a new instance and releases it when the block exits.
    def self.new(&)
      new.use { |instance| yield instance }
    end

    # Requests an adapter, blocking (pumping the event loop) until wgpu answers.
    # Raises `WGPU::Error` on failure or after `timeout`.
    def request_adapter(power_preference : LibWGPU::PowerPreference = LibWGPU::PowerPreference::HighPerformance,
                        compatible_surface : LibWGPU::Surface = Internal.null(LibWGPU::Surface),
                        timeout : Time::Span = 5.seconds) : Adapter
      Adapter.new(self, WGPU.request_adapter(handle, power_preference, compatible_surface, timeout))
    end

    # Yields an adapter and releases it when the block exits.
    def request_adapter(power_preference : LibWGPU::PowerPreference = LibWGPU::PowerPreference::HighPerformance,
                        compatible_surface : LibWGPU::Surface = Internal.null(LibWGPU::Surface),
                        timeout : Time::Span = 5.seconds, &)
      request_adapter(power_preference, compatible_surface, timeout).use { |adapter| yield adapter }
    end

    # Runs pending wgpu callbacks (those registered with `AllowProcessEvents`).
    def process_events : Nil
      LibWGPU.instance_process_events(handle)
    end

    # NOTE: no WGSL language feature queries: `wgpuInstanceHasWGSLLanguageFeature`
    # and `wgpuInstanceGetWGSLLanguageFeatures` are `unimplemented!()` stubs
    # that abort the process in wgpu-native v29.

    private def release_handle : Nil
      LibWGPU.instance_release(@handle)
    end
  end
end

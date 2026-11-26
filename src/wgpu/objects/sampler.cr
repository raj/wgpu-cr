module WGPU
  # A texture sampler, created by `Device#create_sampler`. Keeps its `Device` alive.
  class Sampler < GPUObject(LibWGPU::Sampler)
    getter device : Device

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@device : Device, handle : LibWGPU::Sampler, label : String? = nil)
      super(handle, label)
    end

    private def release_handle : Nil
      LibWGPU.sampler_release(@handle)
    end
  end
end

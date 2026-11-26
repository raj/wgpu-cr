module WGPU
  # A compiled shader, created by `Device#create_shader_module`. Keeps its
  # `Device` alive.
  class ShaderModule < GPUObject(LibWGPU::ShaderModule)
    getter device : Device

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@device : Device, handle : LibWGPU::ShaderModule, label : String? = nil)
      super(handle, label)
    end

    private def release_handle : Nil
      LibWGPU.shader_module_release(@handle)
    end
  end
end

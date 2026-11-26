module WGPU
  # A GPU buffer, created by `Device#create_buffer`. Keeps its `Device` alive.
  #
  # Phase 1 of the object layer: creation, getters, label and destroy.
  # Mapping (`map_read`, `mapped_range`, …) comes in phase 2.
  class Buffer < GPUObject(LibWGPU::Buffer)
    getter device : Device

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@device : Device, handle : LibWGPU::Buffer, label : String? = nil)
      super(handle, label)
    end

    # Size in bytes.
    def size : UInt64
      LibWGPU.buffer_get_size(handle)
    end

    def usage : LibWGPU::BufferUsage
      LibWGPU.buffer_get_usage(handle)
    end

    # Frees the GPU memory now. The wrapper still has to be released
    # (explicitly, by a block form or by the GC).
    def destroy : Nil
      LibWGPU.buffer_destroy(handle)
    end

    private def release_handle : Nil
      LibWGPU.buffer_release(@handle)
    end
  end
end

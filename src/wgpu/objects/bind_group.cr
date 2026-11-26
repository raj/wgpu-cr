module WGPU
  # Resources bound to a pipeline, from `Device#create_bind_group`.
  #
  # wgpu keeps the bound resources alive on the C side, so the wrappers of
  # the buffers, views and samplers may be released before the bind group.
  class BindGroup < GPUObject(LibWGPU::BindGroup)
    getter device : Device
    # Buffers bound by this group (checked by `Queue#submit`, see `CommandEncoder`).
    getter buffers : Array(Buffer)

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@device : Device, handle : LibWGPU::BindGroup, label : String? = nil,
                   @buffers : Array(Buffer) = [] of Buffer)
      super(handle, label)
    end

    private def release_handle : Nil
      LibWGPU.bind_group_release(@handle)
    end
  end

  module Internal
    # The buffer behind a bind group resource, if any.
    def bound_buffer(resource : Buffer) : Buffer?
      resource
    end

    def bound_buffer(resource : BufferBinding) : Buffer?
      resource.buffer
    end

    def bound_buffer(resource : Sampler | TextureView) : Buffer?
      nil
    end

    # One `WGPUBindGroupEntry` per kind of bindable resource. Overloads, so a
    # Hash whose values are a union dispatches per entry at runtime, and an
    # unsupported resource type is a compile-time error.
    def bind_group_entry(binding : Int, buffer : Buffer) : LibWGPU::BindGroupEntry
      bind_group_entry(binding, BufferBinding.new(buffer))
    end

    def bind_group_entry(binding : Int, range : BufferBinding) : LibWGPU::BindGroupEntry
      LibWGPU::BindGroupEntry.new(binding: binding.to_u32, buffer: range.buffer.to_unsafe,
        offset: range.offset, size: range.size)
    end

    def bind_group_entry(binding : Int, sampler : Sampler) : LibWGPU::BindGroupEntry
      LibWGPU::BindGroupEntry.new(binding: binding.to_u32, sampler: sampler.to_unsafe)
    end

    def bind_group_entry(binding : Int, view : TextureView) : LibWGPU::BindGroupEntry
      LibWGPU::BindGroupEntry.new(binding: binding.to_u32, texture_view: view.to_unsafe)
    end
  end
end

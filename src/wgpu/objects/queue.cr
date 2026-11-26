module WGPU
  # A device's command queue, obtained from `Device#queue`.
  #
  # The queue holds no Crystal reference to its `Device` (the device caches the
  # queue, so a back-reference would form a cycle the GC never finalizes, see
  # `GPUObject`). It keeps its own reference on the C device handle instead,
  # plus the `Instance` needed to pump events while waiting.
  class Queue < GPUObject(LibWGPU::Queue)
    getter instance : Instance
    @device_handle : LibWGPU::Device

    def initialize(device : Device)
      @instance = device.instance
      raw = LibWGPU.device_get_queue(device) # owned (+1) reference
      @device_handle = device.to_unsafe
      super(raw)
      LibWGPU.device_add_ref(@device_handle)
    end

    # Uploads `data` (any typed Slice, e.g. `Slice(Float32)` or `Bytes`) into
    # `buffer` at `offset` bytes. The buffer must have `CopyDst` usage.
    def write_buffer(buffer : Buffer, data : Slice, offset : Int = 0) : Nil
      LibWGPU.queue_write_buffer(handle, buffer, offset.to_u64,
        data.to_unsafe.as(Void*), LibC::SizeT.new(data.bytesize))
    end

    # Reads `size` bytes of `buffer` back to the CPU, blocking until the GPU
    # work submitted so far is done. `buffer` must have `CopySrc` usage.
    # Reinterpret the result with e.g. `bytes.unsafe_slice_of(Float32)`.
    def read_buffer(buffer : Buffer, size : Int = buffer.size) : Bytes
      WGPU.read_buffer(@instance.to_unsafe, @device_handle, buffer.to_unsafe, size.to_u64)
    end

    # Submits finished command buffers for execution.
    def submit(command_buffers : Enumerable(LibWGPU::CommandBuffer)) : Nil
      cmds = command_buffers.to_a
      LibWGPU.queue_submit(handle, LibC::SizeT.new(cmds.size), cmds.to_unsafe)
    end

    private def release_handle : Nil
      LibWGPU.queue_release(@handle)
      LibWGPU.device_release(@device_handle)
    end
  end
end

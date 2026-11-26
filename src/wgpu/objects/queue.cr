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

    # Same as `Device#error_checks?` (kept in sync by `Device#error_checks=`):
    # writes, reads and submits raise `WGPU::ValidationError` instead of
    # failing silently or aborting the process.
    property? error_checks : Bool

    def initialize(device : Device)
      @instance = device.instance
      @error_checks = device.error_checks?
      raw = LibWGPU.device_get_queue(device) # owned (+1) reference
      @device_handle = device.to_unsafe
      super(raw)
      LibWGPU.device_add_ref(@device_handle)
    end

    # Uploads `data` (any typed Slice, e.g. `Slice(Float32)` or `Bytes`) into
    # `buffer` at `offset` bytes. The buffer must have `CopyDst` usage.
    def write_buffer(buffer : Buffer, data : Slice, offset : Int = 0) : Nil
      checked do
        LibWGPU.queue_write_buffer(handle, buffer, offset.to_u64,
          data.to_unsafe.as(Void*), LibC::SizeT.new(data.bytesize))
      end
    end

    # Reads `size` bytes of `buffer` back to the CPU, blocking until the GPU
    # work submitted so far is done. `buffer` must have `CopySrc` usage.
    # Reinterpret the result with e.g. `bytes.unsafe_slice_of(Float32)`.
    def read_buffer(buffer : Buffer, size : Int = buffer.size) : Bytes
      Internal.check_submittable([buffer], "Queue#read_buffer")
      WGPU.read_buffer(@instance.to_unsafe, @device_handle, buffer.to_unsafe, size.to_u64)
    end

    # Submits command buffers for execution. They are consumed: released
    # here, so any further use raises `WGPU::Error`.
    #
    #   queue.submit(encoder.finish)
    def submit(*command_buffers : CommandBuffer) : Nil
      submit(command_buffers)
    end

    # :ditto:
    #
    # Raises `WGPU::ValidationError` (without submitting) if a buffer the
    # commands use is still mapped or was destroyed: wgpu-native aborts the
    # process on these submit-time errors, error scopes cannot catch them.
    def submit(command_buffers : Enumerable(CommandBuffer)) : Nil
      cmds = command_buffers.to_a
      cmds.each { |cmd| Internal.check_submittable(cmd.used_buffers, "Queue#submit") }
      raw = cmds.map(&.to_unsafe)
      LibWGPU.queue_submit(handle, LibC::SizeT.new(raw.size), raw.to_unsafe)
    ensure
      cmds.try &.each(&.release)
    end

    # Submits raw command buffer handles (interop with `LibWGPU`). The caller
    # keeps ownership of them.
    def submit(command_buffers : Enumerable(LibWGPU::CommandBuffer)) : Nil
      cmds = command_buffers.to_a
      LibWGPU.queue_submit(handle, LibC::SizeT.new(cmds.size), cmds.to_unsafe)
    end

    # Uploads `data` (any typed Slice) into `texture`. `bytes_per_row` is the
    # stride of `data` (no 256 alignment needed here, unlike buffer copies).
    # Covers the whole mip level 0 by default, starting at `origin`.
    def write_texture(texture : Texture, data : Slice, *, bytes_per_row : Int,
                      width : Int = texture.width, height : Int = texture.height,
                      depth_or_array_layers : Int = texture.depth_or_array_layers,
                      rows_per_image : Int = height, data_offset : Int = 0,
                      mip_level : Int = 0, origin : {Int, Int, Int} = {0, 0, 0},
                      aspect : LibWGPU::TextureAspect = LibWGPU::TextureAspect::All) : Nil
      dst = Internal.texel_copy_texture(texture, mip_level, origin, aspect)
      layout = Internal.texel_copy_buffer_layout(data_offset, bytes_per_row, rows_per_image)
      extent = Internal.extent(width, height, depth_or_array_layers)
      checked do
        LibWGPU.queue_write_texture(handle, pointerof(dst), data.to_unsafe.as(Void*),
          LibC::SizeT.new(data.bytesize), pointerof(layout), pointerof(extent))
      end
    end

    private def checked(&)
      return yield unless @error_checks
      Internal.checked(@device_handle) { yield }
    end

    private def release_handle : Nil
      LibWGPU.queue_release(@handle)
      LibWGPU.device_release(@device_handle)
    end
  end
end

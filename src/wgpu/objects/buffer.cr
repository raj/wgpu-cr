module WGPU
  # A GPU buffer, created by `Device#create_buffer`. Keeps its `Device` alive.
  #
  # Mapping is synchronous (it pumps the instance's event loop):
  #
  #   staging.map_read { |bytes| bytes.unsafe_slice_of(Float32).to_a }   # map, read, unmap
  #   upload.map_write { |bytes| bytes.copy_from(data.to_unsafe_bytes) }
  #
  # The map state is tracked by the wrapper (`#mapped?`): in wgpu-native v29
  # `wgpuBufferGetMapState` is an `unimplemented!()` stub that aborts the
  # process. Map and unmap through the wrapper to keep it accurate.
  class Buffer < GPUObject(LibWGPU::Buffer)
    getter device : Device

    # Wraps `handle`, taking ownership of one reference. Pass `mapped: true`
    # for a buffer created with `mapped_at_creation`.
    def initialize(@device : Device, handle : LibWGPU::Buffer, label : String? = nil, @mapped : Bool = false)
      super(handle, label)
    end

    # Size in bytes.
    def size : UInt64
      LibWGPU.buffer_get_size(handle)
    end

    # Usage flags the buffer was created with.
    def usage : LibWGPU::BufferUsage
      LibWGPU.buffer_get_usage(handle)
    end

    # True while the buffer is mapped (after `map_read`/`map_write`, or when
    # created with `mapped_at_creation`) and until `unmap`.
    def mapped? : Bool
      @mapped
    end

    # Maps `size` bytes at `offset` for reading (needs `MapRead` usage), blocking
    # until the GPU work using the buffer is done. `offset` must be a multiple
    # of 8 and `size` a multiple of 4. Raises `WGPU::Error` on failure.
    def map_read(offset : Int = 0, size : Int = self.size - offset, timeout : Time::Span = 5.seconds) : Nil
      map(LibWGPU::MapMode::Read, offset, size, timeout)
    end

    # Maps for reading, yields a read-only view of the range, then unmaps.
    # Returns the block's value. Copy what you need: the view dies with the unmap.
    def map_read(offset : Int = 0, size : Int = self.size - offset, timeout : Time::Span = 5.seconds, &)
      map_read(offset, size, timeout)
      begin
        yield const_mapped_range(offset, size)
      ensure
        unmap
      end
    end

    # Maps `size` bytes at `offset` for writing (needs `MapWrite` usage).
    # Same alignment rules and blocking behavior as `map_read`.
    def map_write(offset : Int = 0, size : Int = self.size - offset, timeout : Time::Span = 5.seconds) : Nil
      map(LibWGPU::MapMode::Write, offset, size, timeout)
    end

    # Maps for writing, yields a writable view of the range, then unmaps.
    # Returns the block's value.
    def map_write(offset : Int = 0, size : Int = self.size - offset, timeout : Time::Span = 5.seconds, &)
      map_write(offset, size, timeout)
      begin
        yield mapped_range(offset, size)
      ensure
        unmap
      end
    end

    # Read-only view of a mapped range (mapped for reading or writing).
    #
    # WARNING: no copy. The view points into memory owned by wgpu and is
    # invalid after `unmap`. Use `read_mapped` for a copy.
    def const_mapped_range(offset : Int = 0, size : Int = self.size - offset) : Bytes
      ptr = LibWGPU.buffer_get_const_mapped_range(handle, LibC::SizeT.new(offset), LibC::SizeT.new(size))
      raise Error.new("buffer_get_const_mapped_range returned NULL (is the buffer mapped?)") if ptr.null?
      Bytes.new(ptr.as(UInt8*), size, read_only: true)
    end

    # Writable view of a range mapped for writing (or `mapped_at_creation`).
    #
    # WARNING: no copy. The view points into memory owned by wgpu and is
    # invalid after `unmap`. Use `write_mapped` to copy data in.
    def mapped_range(offset : Int = 0, size : Int = self.size - offset) : Bytes
      ptr = LibWGPU.buffer_get_mapped_range(handle, LibC::SizeT.new(offset), LibC::SizeT.new(size))
      raise Error.new("buffer_get_mapped_range returned NULL (is the buffer mapped for writing?)") if ptr.null?
      Bytes.new(ptr.as(UInt8*), size)
    end

    # Copies `size` bytes at `offset` out of the mapped buffer.
    # (`wgpuBufferReadMappedRange` is unimplemented in wgpu-native v29, so
    # this copies from `const_mapped_range`.)
    def read_mapped(offset : Int = 0, size : Int = self.size - offset) : Bytes
      Bytes.new(size).tap(&.copy_from(const_mapped_range(offset, size)))
    end

    # Copies `data` (any typed Slice) into the mapped buffer at `offset` bytes.
    # (`wgpuBufferWriteMappedRange` is unimplemented in wgpu-native v29, so
    # this copies into `mapped_range`.)
    def write_mapped(data : Slice, offset : Int = 0) : Nil
      mapped_range(offset, data.bytesize).copy_from(data.to_unsafe_bytes)
    end

    # Unmaps the buffer, invalidating every view of its mapped ranges.
    def unmap : Nil
      LibWGPU.buffer_unmap(handle)
      @mapped = false
    end

    # Frees the GPU memory now. The wrapper still has to be released
    # (explicitly, by a block form or by the GC).
    def destroy : Nil
      LibWGPU.buffer_destroy(handle)
      @mapped = false
      @destroyed = true
    end

    @destroyed = false

    # Why the buffer cannot be used by a submitted command buffer (mapped or
    # destroyed), or nil. Checked by `Queue#submit`: wgpu-native aborts the
    # process on these submit-time errors instead of reporting them.
    protected def submit_error : String?
      if @mapped
        "#{self} is still mapped: unmap it before submitting commands that use it"
      elsif @destroyed
        "#{self} was destroyed: it cannot be used by submitted commands"
      end
    end

    private def map(mode : LibWGPU::MapMode, offset : Int, size : Int, timeout : Time::Span) : Nil
      Internal.map_buffer(@device.instance.to_unsafe, handle, mode, offset.to_u64, size.to_u64, timeout)
      @mapped = true
    end

    private def release_handle : Nil
      LibWGPU.buffer_release(@handle)
    end
  end

  module Internal
    # Raises `WGPU::ValidationError` if one of `buffers` cannot be used by
    # submitted commands (see `Buffer#submit_error`).
    def check_submittable(buffers : Array(Buffer), context : String) : Nil
      buffers.each do |buffer|
        if reason = buffer.submit_error
          raise ValidationError.new("#{context}: #{reason}")
        end
      end
    end
  end

  # A range of a `Buffer` to bind in `Device#create_bind_group`
  # (a bare `Buffer` binds the whole buffer).
  record BufferBinding, buffer : Buffer, offset : UInt64 = 0_u64, size : UInt64 = LibWGPU::WHOLE_SIZE
end

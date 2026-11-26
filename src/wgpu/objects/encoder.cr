module WGPU
  # Records GPU commands, from `Device#create_command_encoder`. `#finish`
  # turns the recording into a `CommandBuffer` for `Queue#submit`.
  #
  #   encoder = device.create_command_encoder
  #   encoder.copy_buffer_to_buffer(src, 0, dst, 0, src.size)
  #   device.queue.submit(encoder.finish)
  #
  # Compute and render passes come in phase 3 (meanwhile, see `Device#dispatch`).
  class CommandEncoder < GPUObject(LibWGPU::CommandEncoder)
    getter device : Device

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@device : Device, handle : LibWGPU::CommandEncoder, label : String? = nil)
      super(handle, label)
    end

    # Copies `size` bytes from `source` (`CopySrc` usage) to `destination`
    # (`CopyDst` usage). Offsets and size must be multiples of 4.
    def copy_buffer_to_buffer(source : Buffer, source_offset : Int, destination : Buffer,
                              destination_offset : Int, size : Int) : Nil
      LibWGPU.command_encoder_copy_buffer_to_buffer(handle, source, source_offset.to_u64,
        destination, destination_offset.to_u64, size.to_u64)
    end

    # Fills `size` bytes of `buffer` at `offset` with zeros (whole buffer by default).
    def clear_buffer(buffer : Buffer, offset : Int = 0, size : Int = LibWGPU::WHOLE_SIZE) : Nil
      LibWGPU.command_encoder_clear_buffer(handle, buffer, offset.to_u64, size.to_u64)
    end

    # Copies texels from `buffer` into `texture`. `bytes_per_row` must be a
    # multiple of 256. The copy covers `width × height × depth_or_array_layers`
    # texels (the whole mip level 0 by default), starting at `origin`.
    def copy_buffer_to_texture(buffer : Buffer, texture : Texture, *, bytes_per_row : Int,
                               width : Int = texture.width, height : Int = texture.height,
                               depth_or_array_layers : Int = texture.depth_or_array_layers,
                               rows_per_image : Int = height, buffer_offset : Int = 0,
                               mip_level : Int = 0, origin : {Int, Int, Int} = {0, 0, 0},
                               aspect : LibWGPU::TextureAspect = LibWGPU::TextureAspect::All) : Nil
      src = Internal.texel_copy_buffer(buffer, buffer_offset, bytes_per_row, rows_per_image)
      dst = Internal.texel_copy_texture(texture, mip_level, origin, aspect)
      extent = Internal.extent(width, height, depth_or_array_layers)
      LibWGPU.command_encoder_copy_buffer_to_texture(handle, pointerof(src), pointerof(dst), pointerof(extent))
    end

    # Copies texels from `texture` into `buffer`. Same parameters as
    # `copy_buffer_to_texture`.
    def copy_texture_to_buffer(texture : Texture, buffer : Buffer, *, bytes_per_row : Int,
                               width : Int = texture.width, height : Int = texture.height,
                               depth_or_array_layers : Int = texture.depth_or_array_layers,
                               rows_per_image : Int = height, buffer_offset : Int = 0,
                               mip_level : Int = 0, origin : {Int, Int, Int} = {0, 0, 0},
                               aspect : LibWGPU::TextureAspect = LibWGPU::TextureAspect::All) : Nil
      src = Internal.texel_copy_texture(texture, mip_level, origin, aspect)
      dst = Internal.texel_copy_buffer(buffer, buffer_offset, bytes_per_row, rows_per_image)
      extent = Internal.extent(width, height, depth_or_array_layers)
      LibWGPU.command_encoder_copy_texture_to_buffer(handle, pointerof(src), pointerof(dst), pointerof(extent))
    end

    # Ends the recording and returns the command buffer. The encoder is
    # consumed: it is released here, and any further use raises `WGPU::Error`.
    def finish(label : String? = nil) : CommandBuffer
      desc = LibWGPU::CommandBufferDescriptor.new(label: Internal.label_view(label))
      raw = LibWGPU.command_encoder_finish(handle, pointerof(desc))
      release
      CommandBuffer.new(@device, raw, label)
    end

    private def release_handle : Nil
      LibWGPU.command_encoder_release(@handle)
    end
  end

  # Recorded commands, from `CommandEncoder#finish`. Consumed (released) by
  # `Queue#submit`.
  class CommandBuffer < GPUObject(LibWGPU::CommandBuffer)
    getter device : Device

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@device : Device, handle : LibWGPU::CommandBuffer, label : String? = nil)
      super(handle, label)
    end

    private def release_handle : Nil
      LibWGPU.command_buffer_release(@handle)
    end
  end

  module Internal
    def texel_copy_buffer(buffer : Buffer, offset : Int, bytes_per_row : Int, rows_per_image : Int) : LibWGPU::TexelCopyBufferInfo
      LibWGPU::TexelCopyBufferInfo.new(
        buffer: buffer.to_unsafe,
        layout: texel_copy_buffer_layout(offset, bytes_per_row, rows_per_image),
      )
    end

    def texel_copy_buffer_layout(offset : Int, bytes_per_row : Int, rows_per_image : Int) : LibWGPU::TexelCopyBufferLayout
      LibWGPU::TexelCopyBufferLayout.new(offset: offset.to_u64,
        bytes_per_row: bytes_per_row.to_u32, rows_per_image: rows_per_image.to_u32)
    end

    def texel_copy_texture(texture : Texture, mip_level : Int, origin : {Int, Int, Int},
                           aspect : LibWGPU::TextureAspect) : LibWGPU::TexelCopyTextureInfo
      LibWGPU::TexelCopyTextureInfo.new(
        texture: texture.to_unsafe,
        mip_level: mip_level.to_u32,
        origin: LibWGPU::Origin3D.new(x: origin[0].to_u32, y: origin[1].to_u32, z: origin[2].to_u32),
        aspect: aspect,
      )
    end

    def extent(width : Int, height : Int, depth_or_array_layers : Int) : LibWGPU::Extent3D
      LibWGPU::Extent3D.new(width: width.to_u32, height: height.to_u32,
        depth_or_array_layers: depth_or_array_layers.to_u32)
    end
  end
end

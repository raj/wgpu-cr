module WGPU
  # A GPU texture, created by `Device#create_texture`. Keeps its `Device` alive.
  class Texture < GPUObject(LibWGPU::Texture)
    getter device : Device

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@device : Device, handle : LibWGPU::Texture, label : String? = nil)
      super(handle, label)
    end

    def width : UInt32
      LibWGPU.texture_get_width(handle)
    end

    def height : UInt32
      LibWGPU.texture_get_height(handle)
    end

    def depth_or_array_layers : UInt32
      LibWGPU.texture_get_depth_or_array_layers(handle)
    end

    def mip_level_count : UInt32
      LibWGPU.texture_get_mip_level_count(handle)
    end

    def sample_count : UInt32
      LibWGPU.texture_get_sample_count(handle)
    end

    def dimension : LibWGPU::TextureDimension
      LibWGPU.texture_get_dimension(handle)
    end

    def format : LibWGPU::TextureFormat
      LibWGPU.texture_get_format(handle)
    end

    def usage : LibWGPU::TextureUsage
      LibWGPU.texture_get_usage(handle)
    end

    # NOTE: no `texture_binding_view_dimension`: `wgpuTextureGetTextureBindingViewDimension`
    # is an `unimplemented!()` stub that aborts the process in wgpu-native v29.

    # Creates a view of the texture. The defaults (`Undefined` format and
    # dimension, every mip level and array layer) give a view of the whole
    # texture as it was created.
    def create_view(format : LibWGPU::TextureFormat = LibWGPU::TextureFormat::Undefined,
                    dimension : LibWGPU::TextureViewDimension = LibWGPU::TextureViewDimension::Undefined,
                    base_mip_level : Int = 0,
                    mip_level_count : Int = LibWGPU::MIP_LEVEL_COUNT_UNDEFINED,
                    base_array_layer : Int = 0,
                    array_layer_count : Int = LibWGPU::ARRAY_LAYER_COUNT_UNDEFINED,
                    aspect : LibWGPU::TextureAspect = LibWGPU::TextureAspect::All,
                    usage : LibWGPU::TextureUsage = LibWGPU::TextureUsage::None,
                    label : String? = nil) : TextureView
      desc = LibWGPU::TextureViewDescriptor.new(
        label: Internal.label_view(label),
        format: format,
        dimension: dimension,
        base_mip_level: base_mip_level.to_u32,
        mip_level_count: mip_level_count.to_u32,
        base_array_layer: base_array_layer.to_u32,
        array_layer_count: array_layer_count.to_u32,
        aspect: aspect,
        usage: usage,
      )
      TextureView.new(self, LibWGPU.texture_create_view(handle, pointerof(desc)), label)
    end

    # Frees the GPU memory now. The wrapper still has to be released.
    def destroy : Nil
      LibWGPU.texture_destroy(handle)
    end

    private def release_handle : Nil
      LibWGPU.texture_release(@handle)
    end
  end

  # A view of a `Texture` (for binding or as a render target). Keeps its
  # `Texture` alive.
  class TextureView < GPUObject(LibWGPU::TextureView)
    getter texture : Texture

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@texture : Texture, handle : LibWGPU::TextureView, label : String? = nil)
      super(handle, label)
    end

    private def release_handle : Nil
      LibWGPU.texture_view_release(@handle)
    end
  end
end

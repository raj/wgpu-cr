module WGPU
  # Builders of `LibWGPU::BindGroupLayoutEntry` for `Device#create_bind_group_layout`.
  # Each sets one binding kind; the zeroed others mean "not used".
  #
  #   device.create_bind_group_layout([
  #     WGPU::LayoutEntry.buffer(0, LibWGPU::ShaderStage::Compute, LibWGPU::BufferBindingType::ReadOnlyStorage),
  #     WGPU::LayoutEntry.buffer(1, LibWGPU::ShaderStage::Compute),
  #   ])
  module LayoutEntry
    extend self

    def buffer(binding : Int, visibility : LibWGPU::ShaderStage,
               type : LibWGPU::BufferBindingType = LibWGPU::BufferBindingType::Storage,
               has_dynamic_offset : Bool = false, min_binding_size : Int = 0) : LibWGPU::BindGroupLayoutEntry
      LibWGPU::BindGroupLayoutEntry.new(
        binding: binding.to_u32, visibility: visibility,
        buffer: LibWGPU::BufferBindingLayout.new(
          type_: type, has_dynamic_offset: has_dynamic_offset ? 1_u32 : 0_u32, min_binding_size: min_binding_size.to_u64),
      )
    end

    def sampler(binding : Int, visibility : LibWGPU::ShaderStage,
                type : LibWGPU::SamplerBindingType = LibWGPU::SamplerBindingType::Filtering) : LibWGPU::BindGroupLayoutEntry
      LibWGPU::BindGroupLayoutEntry.new(
        binding: binding.to_u32, visibility: visibility,
        sampler: LibWGPU::SamplerBindingLayout.new(type_: type),
      )
    end

    def texture(binding : Int, visibility : LibWGPU::ShaderStage,
                sample_type : LibWGPU::TextureSampleType = LibWGPU::TextureSampleType::Float,
                view_dimension : LibWGPU::TextureViewDimension = LibWGPU::TextureViewDimension::N2D,
                multisampled : Bool = false) : LibWGPU::BindGroupLayoutEntry
      LibWGPU::BindGroupLayoutEntry.new(
        binding: binding.to_u32, visibility: visibility,
        texture: LibWGPU::TextureBindingLayout.new(
          sample_type: sample_type, view_dimension: view_dimension, multisampled: multisampled ? 1_u32 : 0_u32),
      )
    end

    def storage_texture(binding : Int, visibility : LibWGPU::ShaderStage, format : LibWGPU::TextureFormat,
                        access : LibWGPU::StorageTextureAccess = LibWGPU::StorageTextureAccess::WriteOnly,
                        view_dimension : LibWGPU::TextureViewDimension = LibWGPU::TextureViewDimension::N2D) : LibWGPU::BindGroupLayoutEntry
      LibWGPU::BindGroupLayoutEntry.new(
        binding: binding.to_u32, visibility: visibility,
        storage_texture: LibWGPU::StorageTextureBindingLayout.new(
          access: access, format: format, view_dimension: view_dimension),
      )
    end
  end

  # Layout of one bind group: from `Device#create_bind_group_layout`, or
  # derived from a pipeline's shader with `ComputePipeline#bind_group_layout`.
  class BindGroupLayout < GPUObject(LibWGPU::BindGroupLayout)
    getter device : Device

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@device : Device, handle : LibWGPU::BindGroupLayout, label : String? = nil)
      super(handle, label)
    end

    private def release_handle : Nil
      LibWGPU.bind_group_layout_release(@handle)
    end
  end

  # The bind group layouts of a pipeline, from `Device#create_pipeline_layout`.
  class PipelineLayout < GPUObject(LibWGPU::PipelineLayout)
    getter device : Device

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@device : Device, handle : LibWGPU::PipelineLayout, label : String? = nil)
      super(handle, label)
    end

    private def release_handle : Nil
      LibWGPU.pipeline_layout_release(@handle)
    end
  end

  # A compute pipeline, from `Device#create_compute_pipeline`.
  class ComputePipeline < GPUObject(LibWGPU::ComputePipeline)
    getter device : Device

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@device : Device, handle : LibWGPU::ComputePipeline, label : String? = nil)
      super(handle, label)
    end

    # Layout of bind group `group`. With an auto layout (no `layout:` at
    # creation) this is the layout wgpu derived from the shader.
    def bind_group_layout(group : Int = 0) : BindGroupLayout
      @device.checked { BindGroupLayout.new(@device, WGPU.compute_bind_group_layout(handle, group.to_u32)) }
    end

    private def release_handle : Nil
      LibWGPU.compute_pipeline_release(@handle)
    end
  end
end

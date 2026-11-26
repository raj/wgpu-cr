module WGPU
  # One attribute of a vertex buffer: `format` at byte `offset` in each
  # element, read by `@location(shader_location)` in the vertex shader.
  record VertexAttribute, format : LibWGPU::VertexFormat, offset : UInt64, shader_location : UInt32

  # Layout of one vertex buffer: elements of `array_stride` bytes.
  record VertexBufferLayout,
    array_stride : UInt64,
    attributes : Array(VertexAttribute),
    step_mode : LibWGPU::VertexStepMode = LibWGPU::VertexStepMode::Vertex

  # Vertex stage of a render pipeline. A nil `entry_point` lets wgpu pick
  # the shader's only `@vertex` function.
  record VertexState,
    shader : ShaderModule,
    entry_point : String? = nil,
    buffers : Array(VertexBufferLayout) = [] of VertexBufferLayout

  # One color output of the fragment stage. `blend` nil means no blending.
  record ColorTargetState,
    format : LibWGPU::TextureFormat,
    blend : LibWGPU::BlendState? = nil,
    write_mask : LibWGPU::ColorWriteMask = LibWGPU::ColorWriteMask::All

  # Fragment stage of a render pipeline. A nil `entry_point` lets wgpu pick
  # the shader's only `@fragment` function.
  record FragmentState,
    shader : ShaderModule,
    targets : Array(ColorTargetState),
    entry_point : String? = nil

  record PrimitiveState,
    topology : LibWGPU::PrimitiveTopology = LibWGPU::PrimitiveTopology::TriangleList,
    strip_index_format : LibWGPU::IndexFormat = LibWGPU::IndexFormat::Undefined,
    front_face : LibWGPU::FrontFace = LibWGPU::FrontFace::CCW,
    cull_mode : LibWGPU::CullMode = LibWGPU::CullMode::None,
    unclipped_depth : Bool = false

  # Depth/stencil state. The defaults give a classic depth test (`Less`,
  # depth writes on) with stencil disabled.
  record DepthStencilState,
    format : LibWGPU::TextureFormat,
    depth_write_enabled : Bool = true,
    depth_compare : LibWGPU::CompareFunction = LibWGPU::CompareFunction::Less,
    stencil_front : LibWGPU::StencilFaceState = DepthStencilState.stencil_face,
    stencil_back : LibWGPU::StencilFaceState = DepthStencilState.stencil_face,
    stencil_read_mask : UInt32 = 0xFFFFFFFF_u32,
    stencil_write_mask : UInt32 = 0xFFFFFFFF_u32,
    depth_bias : Int32 = 0,
    depth_bias_slope_scale : Float32 = 0.0_f32,
    depth_bias_clamp : Float32 = 0.0_f32 do
    # Stencil face that always passes and keeps the stencil value.
    def self.stencil_face(compare : LibWGPU::CompareFunction = LibWGPU::CompareFunction::Always,
                          fail_op : LibWGPU::StencilOperation = LibWGPU::StencilOperation::Keep,
                          depth_fail_op : LibWGPU::StencilOperation = LibWGPU::StencilOperation::Keep,
                          pass_op : LibWGPU::StencilOperation = LibWGPU::StencilOperation::Keep) : LibWGPU::StencilFaceState
      LibWGPU::StencilFaceState.new(compare: compare, fail_op: fail_op, depth_fail_op: depth_fail_op, pass_op: pass_op)
    end
  end

  record MultisampleState,
    count : UInt32 = 1_u32,
    mask : UInt32 = 0xFFFFFFFF_u32,
    alpha_to_coverage_enabled : Bool = false

  # A render pipeline, from `Device#create_render_pipeline`.
  class RenderPipeline < GPUObject(LibWGPU::RenderPipeline)
    getter device : Device

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@device : Device, handle : LibWGPU::RenderPipeline, label : String? = nil)
      super(handle, label)
    end

    # Layout of bind group `group`. With an auto layout (no `layout:` at
    # creation) this is the layout wgpu derived from the shaders.
    def bind_group_layout(group : Int = 0) : BindGroupLayout
      BindGroupLayout.new(@device, LibWGPU.render_pipeline_get_bind_group_layout(handle, group.to_u32))
    end

    private def release_handle : Nil
      LibWGPU.render_pipeline_release(@handle)
    end
  end

  class Device
    # Creates a render pipeline. Without `fragment` it only writes depth;
    # without `layout` wgpu derives the layout from the shaders ("auto").
    #
    #   shader = device.create_shader_module(WGSL)
    #   pipeline = device.create_render_pipeline(
    #     WGPU::VertexState.new(shader, "vs_main"),
    #     WGPU::FragmentState.new(shader, [WGPU::ColorTargetState.new(format)], "fs_main"))
    def create_render_pipeline(vertex : VertexState, fragment : FragmentState? = nil, *,
                               layout : PipelineLayout? = nil,
                               primitive : PrimitiveState = PrimitiveState.new,
                               depth_stencil : DepthStencilState? = nil,
                               multisample : MultisampleState = MultisampleState.new,
                               label : String? = nil) : RenderPipeline
      # Every array below must outlive the FFI call: the descriptor only
      # holds pointers into them.
      attributes = vertex.buffers.map { |buf| buf.attributes.map { |a| Internal.vertex_attribute(a) } }
      buffers = vertex.buffers.map_with_index do |buf, i|
        LibWGPU::VertexBufferLayout.new(
          step_mode: buf.step_mode,
          array_stride: buf.array_stride,
          attribute_count: LibC::SizeT.new(attributes[i].size),
          attributes: attributes[i].to_unsafe,
        )
      end
      vertex_c = LibWGPU::VertexState.new(
        module_: vertex.shader.to_unsafe,
        entry_point: Internal.entry_point_view(vertex.entry_point),
        buffer_count: LibC::SizeT.new(buffers.size),
        buffers: buffers.to_unsafe,
      )

      desc = LibWGPU::RenderPipelineDescriptor.new(
        label: Internal.label_view(label),
        layout: layout ? layout.to_unsafe : Internal.null(LibWGPU::PipelineLayout),
        vertex: vertex_c,
        primitive: Internal.primitive_state(primitive),
        multisample: LibWGPU::MultisampleState.new(
          count: multisample.count,
          mask: multisample.mask,
          alpha_to_coverage_enabled: multisample.alpha_to_coverage_enabled ? 1_u32 : 0_u32,
        ),
      )

      depth_c = depth_stencil.try { |ds| Internal.depth_stencil_state(ds) } || LibWGPU::DepthStencilState.new
      desc.depth_stencil = pointerof(depth_c) if depth_stencil

      blends = [] of LibWGPU::BlendState
      targets = [] of LibWGPU::ColorTargetState
      fragment_c = LibWGPU::FragmentState.new
      if frag = fragment
        # `blends` is complete before pointers into it are taken.
        blends = frag.targets.map { |t| t.blend || LibWGPU::BlendState.new }
        targets = frag.targets.map_with_index do |t, i|
          LibWGPU::ColorTargetState.new(
            format: t.format,
            blend: t.blend ? blends.to_unsafe + i : Pointer(LibWGPU::BlendState).null,
            write_mask: t.write_mask,
          )
        end
        fragment_c = LibWGPU::FragmentState.new(
          module_: frag.shader.to_unsafe,
          entry_point: Internal.entry_point_view(frag.entry_point),
          target_count: LibC::SizeT.new(targets.size),
          targets: targets.to_unsafe,
        )
        desc.fragment = pointerof(fragment_c)
      end

      RenderPipeline.new(self, LibWGPU.device_create_render_pipeline(handle, pointerof(desc)), label)
    end

    # Creates an encoder recording a `RenderBundle` for render passes whose
    # attachments have these formats and sample count.
    def create_render_bundle_encoder(color_formats : Array(LibWGPU::TextureFormat),
                                     depth_stencil_format : LibWGPU::TextureFormat = LibWGPU::TextureFormat::Undefined,
                                     sample_count : Int = 1, depth_read_only : Bool = false,
                                     stencil_read_only : Bool = false, label : String? = nil) : RenderBundleEncoder
      desc = LibWGPU::RenderBundleEncoderDescriptor.new(
        label: Internal.label_view(label),
        color_format_count: LibC::SizeT.new(color_formats.size),
        color_formats: color_formats.to_unsafe,
        depth_stencil_format: depth_stencil_format,
        sample_count: sample_count.to_u32,
        depth_read_only: depth_read_only ? 1_u32 : 0_u32,
        stencil_read_only: stencil_read_only ? 1_u32 : 0_u32,
      )
      RenderBundleEncoder.new(self, LibWGPU.device_create_render_bundle_encoder(handle, pointerof(desc)), label)
    end
  end

  module Internal
    # Entry point view: the name, or a NULL view (wgpu picks the only entry
    # point of the right stage).
    def entry_point_view(name : String?) : LibWGPU::StringView
      name ? string_view(name) : null_string_view
    end

    def vertex_attribute(a : VertexAttribute) : LibWGPU::VertexAttribute
      LibWGPU::VertexAttribute.new(format: a.format, offset: a.offset, shader_location: a.shader_location)
    end

    def primitive_state(p : PrimitiveState) : LibWGPU::PrimitiveState
      LibWGPU::PrimitiveState.new(
        topology: p.topology,
        strip_index_format: p.strip_index_format,
        front_face: p.front_face,
        cull_mode: p.cull_mode,
        unclipped_depth: p.unclipped_depth ? 1_u32 : 0_u32,
      )
    end

    def depth_stencil_state(ds : DepthStencilState) : LibWGPU::DepthStencilState
      LibWGPU::DepthStencilState.new(
        format: ds.format,
        depth_write_enabled: ds.depth_write_enabled ? LibWGPU::OptionalBool::True : LibWGPU::OptionalBool::False,
        depth_compare: ds.depth_compare,
        stencil_front: ds.stencil_front,
        stencil_back: ds.stencil_back,
        stencil_read_mask: ds.stencil_read_mask,
        stencil_write_mask: ds.stencil_write_mask,
        depth_bias: ds.depth_bias,
        depth_bias_slope_scale: ds.depth_bias_slope_scale,
        depth_bias_clamp: ds.depth_bias_clamp,
      )
    end
  end
end

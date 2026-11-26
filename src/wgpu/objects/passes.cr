# Commands shared by every pass and bundle encoder (`prefix` is the FFI
# function prefix, e.g. `render_pass_encoder`). File-private macros: macros
# defined inside `module WGPU` are not visible from its nested classes.
private macro wgpu_common_pass_commands(prefix)
  # Binds `bind_group` at group `index`, with optional dynamic offsets.
  def set_bind_group(index : Int, bind_group : BindGroup, dynamic_offsets : Array(UInt32)? = nil) : Nil
    track(bind_group.buffers)
    count = dynamic_offsets ? dynamic_offsets.size : 0
    offsets = dynamic_offsets ? dynamic_offsets.to_unsafe : Pointer(UInt32).null
    LibWGPU.{{prefix.id}}_set_bind_group(handle, index.to_u32, bind_group, LibC::SizeT.new(count), offsets)
  end

  # Opens a labeled group of commands (shown by GPU debuggers).
  def push_debug_group(label : String) : Nil
    LibWGPU.{{prefix.id}}_push_debug_group(handle, Internal.string_view(label))
  end

  # Closes the innermost debug group.
  def pop_debug_group : Nil
    LibWGPU.{{prefix.id}}_pop_debug_group(handle)
  end

  # Inserts a single labeled marker.
  def insert_debug_marker(label : String) : Nil
    LibWGPU.{{prefix.id}}_insert_debug_marker(handle, Internal.string_view(label))
  end
end

# Draw commands shared by `RenderPassEncoder` and `RenderBundleEncoder`
# (which also expand `wgpu_common_pass_commands`).
private macro wgpu_render_commands(prefix)
  # Selects the render pipeline for the next draws.
  def set_pipeline(pipeline : RenderPipeline) : Nil
    LibWGPU.{{prefix.id}}_set_pipeline(handle, pipeline)
  end

  # Binds `buffer` (`Vertex` usage) to vertex buffer `slot`.
  def set_vertex_buffer(slot : Int, buffer : Buffer, offset : Int = 0, size : Int = LibWGPU::WHOLE_SIZE) : Nil
    track(buffer)
    LibWGPU.{{prefix.id}}_set_vertex_buffer(handle, slot.to_u32, buffer, offset.to_u64, size.to_u64)
  end

  # Binds `buffer` (`Index` usage) as the index buffer.
  def set_index_buffer(buffer : Buffer, format : LibWGPU::IndexFormat, offset : Int = 0, size : Int = LibWGPU::WHOLE_SIZE) : Nil
    track(buffer)
    LibWGPU.{{prefix.id}}_set_index_buffer(handle, buffer, format, offset.to_u64, size.to_u64)
  end

  # Draws `vertex_count` vertices, `instance_count` times.
  def draw(vertex_count : Int, instance_count : Int = 1, first_vertex : Int = 0, first_instance : Int = 0) : Nil
    LibWGPU.{{prefix.id}}_draw(handle, vertex_count.to_u32, instance_count.to_u32, first_vertex.to_u32, first_instance.to_u32)
  end

  # Draws `index_count` indices of the index buffer, `instance_count` times.
  def draw_indexed(index_count : Int, instance_count : Int = 1, first_index : Int = 0,
                   base_vertex : Int = 0, first_instance : Int = 0) : Nil
    LibWGPU.{{prefix.id}}_draw_indexed(handle, index_count.to_u32, instance_count.to_u32, first_index.to_u32,
      base_vertex.to_i32, first_instance.to_u32)
  end

  # Draws with arguments read from `buffer` (`Indirect` usage) at `offset`.
  def draw_indirect(buffer : Buffer, offset : Int = 0) : Nil
    track(buffer)
    LibWGPU.{{prefix.id}}_draw_indirect(handle, buffer, offset.to_u64)
  end

  # Indexed draw with arguments read from `buffer` (`Indirect` usage).
  def draw_indexed_indirect(buffer : Buffer, offset : Int = 0) : Nil
    track(buffer)
    LibWGPU.{{prefix.id}}_draw_indexed_indirect(handle, buffer, offset.to_u64)
  end
end

module WGPU
  # A color target of a render pass (`CommandEncoder#begin_render_pass`).
  # `clear_value` is RGBA in 0.0..1.0, used when `load_op` is `Clear`.
  record ColorAttachment,
    view : TextureView,
    clear_value : {Float64, Float64, Float64, Float64} = {0.0, 0.0, 0.0, 1.0},
    load_op : LibWGPU::LoadOp = LibWGPU::LoadOp::Clear,
    store_op : LibWGPU::StoreOp = LibWGPU::StoreOp::Store,
    resolve_target : TextureView? = nil,
    depth_slice : UInt32 = LibWGPU::DEPTH_SLICE_UNDEFINED

  # The depth/stencil target of a render pass. The defaults suit a
  # depth-only format (stencil ops `Undefined`): clear to 1.0 and store.
  record DepthStencilAttachment,
    view : TextureView,
    depth_clear_value : Float32 = 1.0_f32,
    depth_load_op : LibWGPU::LoadOp = LibWGPU::LoadOp::Clear,
    depth_store_op : LibWGPU::StoreOp = LibWGPU::StoreOp::Store,
    depth_read_only : Bool = false,
    stencil_clear_value : UInt32 = 0_u32,
    stencil_load_op : LibWGPU::LoadOp = LibWGPU::LoadOp::Undefined,
    stencil_store_op : LibWGPU::StoreOp = LibWGPU::StoreOp::Undefined,
    stencil_read_only : Bool = false

  # A compute pass, from `CommandEncoder#begin_compute_pass`. Keeps its
  # `CommandEncoder` alive.
  class ComputePassEncoder < GPUObject(LibWGPU::ComputePassEncoder)
    getter encoder : CommandEncoder

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@encoder : CommandEncoder, handle : LibWGPU::ComputePassEncoder, label : String? = nil)
      super(handle, label)
    end

    # Records buffer use on the parent encoder (see `CommandEncoder#track`).
    private def track(buffers : Buffer | Array(Buffer)) : Nil
      @encoder.track(buffers)
    end

    wgpu_common_pass_commands(compute_pass_encoder)

    # Selects the compute pipeline for the next dispatches.
    def set_pipeline(pipeline : ComputePipeline) : Nil
      LibWGPU.compute_pass_encoder_set_pipeline(handle, pipeline)
    end

    # Runs `x × y × z` workgroups.
    def dispatch_workgroups(x : Int, y : Int = 1, z : Int = 1) : Nil
      LibWGPU.compute_pass_encoder_dispatch_workgroups(handle, x.to_u32, y.to_u32, z.to_u32)
    end

    # Dispatches with workgroup counts read from `buffer` (`Indirect` usage).
    def dispatch_workgroups_indirect(buffer : Buffer, offset : Int = 0) : Nil
      track(buffer)
      LibWGPU.compute_pass_encoder_dispatch_workgroups_indirect(handle, buffer, offset.to_u64)
    end

    # Ends the pass. The pass encoder is consumed (released here).
    def end_pass : Nil
      LibWGPU.compute_pass_encoder_end(handle)
      release
    end

    private def release_handle : Nil
      LibWGPU.compute_pass_encoder_release(@handle)
    end
  end

  # A render pass, from `CommandEncoder#begin_render_pass`. Keeps its
  # `CommandEncoder` alive.
  class RenderPassEncoder < GPUObject(LibWGPU::RenderPassEncoder)
    getter encoder : CommandEncoder

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@encoder : CommandEncoder, handle : LibWGPU::RenderPassEncoder, label : String? = nil)
      super(handle, label)
    end

    # Records buffer use on the parent encoder (see `CommandEncoder#track`).
    private def track(buffers : Buffer | Array(Buffer)) : Nil
      @encoder.track(buffers)
    end

    wgpu_common_pass_commands(render_pass_encoder)
    wgpu_render_commands(render_pass_encoder)

    # Maps clip space to this rectangle of the attachments (in pixels).
    def set_viewport(x : Number, y : Number, width : Number, height : Number,
                     min_depth : Number = 0.0, max_depth : Number = 1.0) : Nil
      LibWGPU.render_pass_encoder_set_viewport(handle, x.to_f32, y.to_f32, width.to_f32, height.to_f32,
        min_depth.to_f32, max_depth.to_f32)
    end

    # Discards fragments outside this rectangle (in pixels).
    def set_scissor_rect(x : Int, y : Int, width : Int, height : Int) : Nil
      LibWGPU.render_pass_encoder_set_scissor_rect(handle, x.to_u32, y.to_u32, width.to_u32, height.to_u32)
    end

    # Constant color for the `Constant` blend factors.
    def set_blend_constant(r : Number, g : Number, b : Number, a : Number = 1.0) : Nil
      color = LibWGPU::Color.new(r: r.to_f64, g: g.to_f64, b: b.to_f64, a: a.to_f64)
      LibWGPU.render_pass_encoder_set_blend_constant(handle, pointerof(color))
    end

    # Reference value for the stencil tests.
    def set_stencil_reference(reference : Int) : Nil
      LibWGPU.render_pass_encoder_set_stencil_reference(handle, reference.to_u32)
    end

    # Replays pre-recorded render bundles.
    def execute_bundles(bundles : Enumerable(RenderBundle)) : Nil
      list = bundles.to_a
      list.each { |bundle| track(bundle.used_buffers) }
      raw = list.map(&.to_unsafe)
      LibWGPU.render_pass_encoder_execute_bundles(handle, LibC::SizeT.new(raw.size), raw.to_unsafe)
    end

    # :ditto:
    def execute_bundles(*bundles : RenderBundle) : Nil
      execute_bundles(bundles)
    end

    # Ends the pass. The pass encoder is consumed (released here).
    def end_pass : Nil
      LibWGPU.render_pass_encoder_end(handle)
      release
    end

    private def release_handle : Nil
      LibWGPU.render_pass_encoder_release(@handle)
    end
  end

  # Records draw commands once to replay them in many render passes, from
  # `Device#create_render_bundle_encoder`.
  class RenderBundleEncoder < GPUObject(LibWGPU::RenderBundleEncoder)
    getter device : Device

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@device : Device, handle : LibWGPU::RenderBundleEncoder, label : String? = nil)
      super(handle, label)
    end

    @used_buffers = [] of Buffer

    private def track(buffer : Buffer) : Nil
      @used_buffers << buffer
    end

    private def track(buffers : Array(Buffer)) : Nil
      @used_buffers.concat(buffers)
    end

    wgpu_common_pass_commands(render_bundle_encoder)
    wgpu_render_commands(render_bundle_encoder)

    # Ends the recording. The bundle encoder is consumed (released here).
    def finish(label : String? = nil) : RenderBundle
      desc = LibWGPU::RenderBundleDescriptor.new(label: Internal.label_view(label))
      @device.checked do
        raw = LibWGPU.render_bundle_encoder_finish(handle, pointerof(desc))
        release
        RenderBundle.new(@device, raw, label, @used_buffers)
      end
    end

    private def release_handle : Nil
      LibWGPU.render_bundle_encoder_release(@handle)
    end
  end

  # Pre-recorded draw commands, from `RenderBundleEncoder#finish`.
  class RenderBundle < GPUObject(LibWGPU::RenderBundle)
    getter device : Device
    # Buffers used by the recorded commands (see `CommandEncoder`).
    getter used_buffers : Array(Buffer)

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@device : Device, handle : LibWGPU::RenderBundle, label : String? = nil,
                   @used_buffers : Array(Buffer) = [] of Buffer)
      super(handle, label)
    end

    private def release_handle : Nil
      LibWGPU.render_bundle_release(@handle)
    end
  end

  class CommandEncoder
    # Starts a compute pass. End it with `ComputePassEncoder#end_pass`.
    def begin_compute_pass(label : String? = nil) : ComputePassEncoder
      desc = LibWGPU::ComputePassDescriptor.new(label: Internal.label_view(label))
      ComputePassEncoder.new(self, LibWGPU.command_encoder_begin_compute_pass(handle, pointerof(desc)), label)
    end

    # Yields a compute pass and ends it when the block returns (it is only
    # released if the block raises). Returns the block's value.
    #
    #   encoder.begin_compute_pass do |pass|
    #     pass.set_pipeline(pipeline)
    #     pass.set_bind_group(0, bind_group)
    #     pass.dispatch_workgroups(4)
    #   end
    def begin_compute_pass(label : String? = nil, &)
      pass = begin_compute_pass(label)
      begin
        result = yield pass
        pass.end_pass
        result
      ensure
        pass.release
      end
    end

    # Starts a render pass drawing into `color_attachments` (and the optional
    # depth/stencil attachment). End it with `RenderPassEncoder#end_pass`.
    def begin_render_pass(color_attachments : Enumerable(ColorAttachment),
                          depth_stencil_attachment : DepthStencilAttachment? = nil,
                          label : String? = nil) : RenderPassEncoder
      colors = color_attachments.to_a.map { |att| Internal.color_attachment(att) }
      depth = depth_stencil_attachment.try { |att| Internal.depth_stencil_attachment(att) } ||
              LibWGPU::RenderPassDepthStencilAttachment.new
      desc = LibWGPU::RenderPassDescriptor.new(
        label: Internal.label_view(label),
        color_attachment_count: LibC::SizeT.new(colors.size),
        color_attachments: colors.to_unsafe,
        depth_stencil_attachment: depth_stencil_attachment ? pointerof(depth) : Pointer(LibWGPU::RenderPassDepthStencilAttachment).null,
      )
      RenderPassEncoder.new(self, LibWGPU.command_encoder_begin_render_pass(handle, pointerof(desc)), label)
    end

    # Yields a render pass and ends it when the block returns (it is only
    # released if the block raises). Returns the block's value.
    #
    #   encoder.begin_render_pass([WGPU::ColorAttachment.new(view)]) do |pass|
    #     pass.set_pipeline(pipeline)
    #     pass.draw(3)
    #   end
    def begin_render_pass(color_attachments : Enumerable(ColorAttachment),
                          depth_stencil_attachment : DepthStencilAttachment? = nil,
                          label : String? = nil, &)
      pass = begin_render_pass(color_attachments, depth_stencil_attachment, label)
      begin
        result = yield pass
        pass.end_pass
        result
      ensure
        pass.release
      end
    end
  end

  module Internal
    def color_attachment(att : ColorAttachment) : LibWGPU::RenderPassColorAttachment
      r, g, b, a = att.clear_value
      LibWGPU::RenderPassColorAttachment.new(
        view: att.view.to_unsafe,
        depth_slice: att.depth_slice,
        resolve_target: att.resolve_target.try(&.to_unsafe) || null(LibWGPU::TextureView),
        load_op: att.load_op,
        store_op: att.store_op,
        clear_value: LibWGPU::Color.new(r: r, g: g, b: b, a: a),
      )
    end

    def depth_stencil_attachment(att : DepthStencilAttachment) : LibWGPU::RenderPassDepthStencilAttachment
      LibWGPU::RenderPassDepthStencilAttachment.new(
        view: att.view.to_unsafe,
        depth_load_op: att.depth_load_op,
        depth_store_op: att.depth_store_op,
        depth_clear_value: att.depth_clear_value,
        depth_read_only: att.depth_read_only ? 1_u32 : 0_u32,
        stencil_load_op: att.stencil_load_op,
        stencil_store_op: att.stencil_store_op,
        stencil_clear_value: att.stencil_clear_value,
        stencil_read_only: att.stencil_read_only ? 1_u32 : 0_u32,
      )
    end
  end
end

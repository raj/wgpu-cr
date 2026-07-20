# wgpu-native logging (from wgpu.h — not the standard webgpu.h the binding is
# generated from, so declared here by hand).
lib LibWGPU
  enum LogLevel
    Off   = 0
    Error = 1
    Warn  = 2
    Info  = 3
    Debug = 4
    Trace = 5
  end

  alias LogCallback = (LogLevel, StringView, Void*) -> Void

  fun set_log_callback = wgpuSetLogCallback(callback : LogCallback, userdata : Void*)
  fun set_log_level = wgpuSetLogLevel(level : LogLevel)
end

module WGPU
  # Error raised by the helpers when a wgpu request fails.
  class Error < Exception
  end

  # Non-capturing callback (a valid C function pointer) forwarding wgpu-native's log
  # to STDERR. Held in a constant so the GC never frees it while the C side holds it.
  WGPU_LOG_CALLBACK = ->(level : LibWGPU::LogLevel, message : LibWGPU::StringView, _ud : Void*) do
    STDERR.puts("[wgpu][#{level.to_s.downcase}] #{WGPU.to_s(message)}")
    nil
  end

  # Forwards wgpu-native's internal log to STDERR at (and above) `level`. The internal
  # log carries the real cause behind terse "Validation Error" messages.
  def self.set_log_stderr(level : LibWGPU::LogLevel = LibWGPU::LogLevel::Warn) : Nil
    LibWGPU.set_log_callback(WGPU_LOG_CALLBACK, Pointer(Void).null)
    LibWGPU.set_log_level(level)
  end

  # Null (opaque pointer) handle of the given type.
  #   WGPU.null(LibWGPU::PipelineLayout)
  # The lib's `type X = Void*` typedefs don't expose `.null`, hence this helper.
  def self.null(t : T.class) : T forall T
    Pointer(Void).null.unsafe_as(T)
  end

  # ------------------------------------------------------------------
  # StringView: the C API replaces `char const *` with { data, length }.
  # ------------------------------------------------------------------

  # Builds a `WGPUStringView` pointing into `str`.
  #
  # WARNING: the view does not copy — `str` must stay alive (not collected by
  # the GC) for as long as the C side reads the view. Keep a reference on the
  # Crystal side.
  def self.string_view(str : String) : LibWGPU::StringView
    LibWGPU::StringView.new(data: str.to_unsafe, length: str.bytesize.to_u64)
  end

  # Empty (NULL) view — used for optional labels.
  def self.empty_string_view : LibWGPU::StringView
    LibWGPU::StringView.new(data: Pointer(LibC::Char).null, length: 0_u64)
  end

  # Converts a `WGPUStringView` returned by the C side into a Crystal String.
  def self.to_s(view : LibWGPU::StringView) : String
    return "" if view.data.null? || view.length == 0
    String.new(view.data.as(UInt8*), view.length)
  end

  # ------------------------------------------------------------------
  # Feature queries
  #
  # The raw `*_has_feature` funs in native.cr are typed to return `LibWGPU::Bool`,
  # which is an alias for `UInt32` (that is what WGPUBool is on the C side). In
  # Crystal EVERY integer is truthy — even `0_u32` — so writing
  #   if LibWGPU.device_has_feature(device, feature)
  # is ALWAYS taken, silently, regardless of the real answer. These thin helpers
  # convert the C boolean to a genuine Crystal `Bool` via `!= 0` so they behave
  # correctly in conditionals. The raw lib signatures are deliberately left
  # unchanged (they must keep matching the C ABI).
  # ------------------------------------------------------------------

  # True if the wgpu-native instance layer supports `feature`.
  def self.has_instance_feature?(feature : LibWGPU::InstanceFeatureName) : Bool
    LibWGPU.has_instance_feature(feature) != 0
  end

  # True if `adapter` supports `feature`.
  def self.adapter_has_feature?(adapter : LibWGPU::Adapter, feature : LibWGPU::FeatureName) : Bool
    LibWGPU.adapter_has_feature(adapter, feature) != 0
  end

  # True if `device` supports `feature`.
  def self.device_has_feature?(device : LibWGPU::Device, feature : LibWGPU::FeatureName) : Bool
    LibWGPU.device_has_feature(device, feature) != 0
  end

  # True if `instance` supports the given WGSL language `feature`.
  def self.instance_has_wgsl_language_feature?(instance : LibWGPU::Instance, feature : LibWGPU::WGSLLanguageFeatureName) : Bool
    LibWGPU.instance_has_wgsl_language_feature(instance, feature) != 0
  end

  # ------------------------------------------------------------------
  # Instance
  # ------------------------------------------------------------------

  def self.create_instance : LibWGPU::Instance
    inst = LibWGPU.create_instance(nil)
    raise Error.new("wgpuCreateInstance returned NULL") if inst.null?
    inst
  end

  # ------------------------------------------------------------------
  # Adapter request (asynchronous in C, exposed synchronously here).
  #
  # The callback is deliberately *non-capturing*: a Crystal closure cannot be
  # passed to C. The result flows through `userdata1`, a pointer to a struct
  # that stays alive on the stack during the call.
  # ------------------------------------------------------------------

  private struct AdapterResult
    property handle : LibWGPU::Adapter = Pointer(Void).null.unsafe_as(LibWGPU::Adapter)
    property status : LibWGPU::RequestAdapterStatus = LibWGPU::RequestAdapterStatus::Error
    property message : String = ""
    property done : Bool = false
  end

  def self.request_adapter(instance : LibWGPU::Instance,
                           power_preference : LibWGPU::PowerPreference = LibWGPU::PowerPreference::HighPerformance,
                           compatible_surface : LibWGPU::Surface = WGPU.null(LibWGPU::Surface)) : LibWGPU::Adapter
    result = AdapterResult.new

    options = LibWGPU::RequestAdapterOptions.new
    options.power_preference = power_preference
    options.compatible_surface = compatible_surface unless compatible_surface.null?

    callback = ->(status : LibWGPU::RequestAdapterStatus, adapter : LibWGPU::Adapter, message : LibWGPU::StringView, u1 : Void*, _u2 : Void*) do
      r = u1.as(Pointer(AdapterResult))
      r.value.handle = adapter
      r.value.status = status
      r.value.message = WGPU.to_s(message)
      r.value.done = true
      nil
    end

    info = LibWGPU::RequestAdapterCallbackInfo.new
    info.mode = LibWGPU::CallbackMode::AllowProcessEvents
    info.callback = callback
    info.userdata1 = pointerof(result).as(Void*)

    LibWGPU.instance_request_adapter(instance, pointerof(options), info)
    wait_until(instance) { result.done }

    unless result.status.success?
      raise Error.new("request_adapter failed: #{result.status} #{result.message}")
    end
    result.handle
  end

  # ------------------------------------------------------------------
  # Device request
  # ------------------------------------------------------------------

  private struct DeviceResult
    property handle : LibWGPU::Device = Pointer(Void).null.unsafe_as(LibWGPU::Device)
    property status : LibWGPU::RequestDeviceStatus = LibWGPU::RequestDeviceStatus::Error
    property message : String = ""
    property done : Bool = false
  end

  def self.request_device(instance : LibWGPU::Instance, adapter : LibWGPU::Adapter) : LibWGPU::Device
    result = DeviceResult.new

    descriptor = LibWGPU::DeviceDescriptor.new

    callback = ->(status : LibWGPU::RequestDeviceStatus, device : LibWGPU::Device, message : LibWGPU::StringView, u1 : Void*, _u2 : Void*) do
      r = u1.as(Pointer(DeviceResult))
      r.value.handle = device
      r.value.status = status
      r.value.message = WGPU.to_s(message)
      r.value.done = true
      nil
    end

    info = LibWGPU::RequestDeviceCallbackInfo.new
    info.mode = LibWGPU::CallbackMode::AllowProcessEvents
    info.callback = callback
    info.userdata1 = pointerof(result).as(Void*)

    LibWGPU.adapter_request_device(adapter, pointerof(descriptor), info)
    wait_until(instance) { result.done }

    unless result.status.success?
      raise Error.new("request_device failed: #{result.status} #{result.message}")
    end
    result.handle
  end

  # ------------------------------------------------------------------
  # Buffer mapping (for reading) — synchronous.
  # ------------------------------------------------------------------

  private struct MapResult
    property status : LibWGPU::MapAsyncStatus = LibWGPU::MapAsyncStatus::Error
    property message : String = ""
    property done : Bool = false
  end

  def self.map_buffer_read(instance : LibWGPU::Instance, buffer : LibWGPU::Buffer, size : UInt64, offset : UInt64 = 0_u64)
    result = MapResult.new

    callback = ->(status : LibWGPU::MapAsyncStatus, message : LibWGPU::StringView, u1 : Void*, _u2 : Void*) do
      r = u1.as(Pointer(MapResult))
      r.value.status = status
      r.value.message = WGPU.to_s(message)
      r.value.done = true
      nil
    end

    info = LibWGPU::BufferMapCallbackInfo.new
    info.mode = LibWGPU::CallbackMode::AllowProcessEvents
    info.callback = callback
    info.userdata1 = pointerof(result).as(Void*)

    LibWGPU.buffer_map_async(buffer, LibWGPU::MapMode::Read, offset, size, info)
    wait_until(instance) { result.done }

    unless result.status.success?
      raise Error.new("buffer_map_async failed: #{result.status} #{result.message}")
    end
  end

  # Pumps the instance event loop until `block` returns true.
  # Guards against waiting forever if a callback never fires.
  private def self.wait_until(instance : LibWGPU::Instance, max_iterations = 100_000, &block : -> Bool)
    iterations = 0
    until block.call
      LibWGPU.instance_process_events(instance)
      sleep(0.001)
      iterations += 1
      raise Error.new("timed out waiting for a wgpu callback") if iterations > max_iterations
    end
  end

  # ==================================================================
  # Teardown helpers
  #
  # Each wgpu handle type is a distinct `*_release` FFI call, and the handles are
  # all `Void*` typedefs — so a single "detect the type and release it" method is
  # impossible (Crystal collapses the typedefs to `Void*` and can neither overload
  # nor branch on them). Instead these group the handles that a render pass always
  # produces together, releasing each with its correct function in dependency order.
  # ==================================================================

  # Releases the transient handles of one render pass: the submitted command
  # buffer, then the pass encoder, then the command encoder. Pass them in that
  # order (their types are all `Void*`, so the order is the contract).
  def self.release_pass(command_buffer : LibWGPU::CommandBuffer,
                        pass : LibWGPU::RenderPassEncoder,
                        encoder : LibWGPU::CommandEncoder) : Nil
    LibWGPU.command_buffer_release(command_buffer)
    LibWGPU.render_pass_encoder_release(pass)
    LibWGPU.command_encoder_release(encoder)
  end

  # Releases a surface frame's view and its backing surface texture (after
  # `surface_present`).
  def self.release_surface(view : LibWGPU::TextureView, texture : LibWGPU::Texture) : Nil
    LibWGPU.texture_view_release(view)
    LibWGPU.texture_release(texture)
  end

  # ==================================================================
  # Compute
  #
  # High-level helpers over the raw compute FFI in `native.cr`. They cover the
  # usual GPGPU chain: shader -> buffers -> pipeline (auto layout) -> bind group
  # -> dispatch -> readback.
  #
  # GC note: `WGPU.string_view` does not copy, so every `String` passed here
  # (WGSL source, entry point, labels) must stay alive for the duration of the
  # call. They do — each is a method argument, alive until the wgpu call that
  # consumes it returns, and wgpu copies the bytes at creation time.
  # ==================================================================

  # Compiles a WGSL source into a shader module.
  def self.create_shader_module(device : LibWGPU::Device, wgsl : String, label : String? = nil) : LibWGPU::ShaderModule
    # Build the inner structs whole (never `x.chain.s_type = ...`): a lib-struct
    # getter returns a copy, so nested field assignment would be silently lost.
    chain = LibWGPU::ChainedStruct.new(s_type: LibWGPU::SType::ShaderSourceWGSL)
    source = LibWGPU::ShaderSourceWGSL.new(chain: chain, code: string_view(wgsl))

    desc = LibWGPU::ShaderModuleDescriptor.new(
      next_in_chain: pointerof(source).as(Pointer(LibWGPU::ChainedStruct)),
      label: label ? string_view(label) : empty_string_view,
    )

    mod = LibWGPU.device_create_shader_module(device, pointerof(desc))
    raise Error.new("device_create_shader_module returned NULL") if mod.null?
    mod
  end

  # Allocates a GPU buffer of `size` bytes with the given usage flags.
  #
  #   WGPU.create_buffer(device, 1024_u64, LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopySrc)
  def self.create_buffer(device : LibWGPU::Device, size : UInt64, usage : LibWGPU::BufferUsage,
                         label : String? = nil, mapped_at_creation : Bool = false) : LibWGPU::Buffer
    # The `mapped_at_creation` field is declared `Bool` in native.cr but wgpu's
    # WGPUBool is a uint32: assigning a Crystal Bool trips a to_unsafe mismatch,
    # so feed it 0/1 (same trick as examples/compute.cr).
    desc = LibWGPU::BufferDescriptor.new(
      label: label ? string_view(label) : empty_string_view,
      usage: usage,
      size: size,
      mapped_at_creation: (mapped_at_creation ? 1_u32 : 0_u32),
    )
    buffer = LibWGPU.device_create_buffer(device, pointerof(desc))
    raise Error.new("device_create_buffer returned NULL") if buffer.null?
    buffer
  end

  # Allocates a buffer and uploads `data` into it in one step. `CopyDst` is
  # OR-ed into the usage automatically (required by the upload).
  #
  #   data = Slice(Float32).new(256) { |i| i.to_f32 }
  #   buf  = WGPU.create_buffer_with_data(device, data, LibWGPU::BufferUsage::Storage)
  def self.create_buffer_with_data(device : LibWGPU::Device, data : Slice, usage : LibWGPU::BufferUsage,
                                   label : String? = nil) : LibWGPU::Buffer
    size = data.bytesize.to_u64
    buffer = create_buffer(device, size, usage | LibWGPU::BufferUsage::CopyDst, label)
    write_buffer(device, buffer, data)
    buffer
  end

  # Uploads `data` (any typed Slice, e.g. `Slice(Float32)` or `Bytes`) into an
  # existing buffer at `offset` bytes. The buffer must have `CopyDst` usage.
  def self.write_buffer(device : LibWGPU::Device, buffer : LibWGPU::Buffer, data : Slice, offset : UInt64 = 0_u64) : Nil
    queue = LibWGPU.device_get_queue(device)
    LibWGPU.queue_write_buffer(queue, buffer, offset, data.to_unsafe.as(Pointer(Void)), LibC::SizeT.new(data.bytesize))
    LibWGPU.queue_release(queue) # device_get_queue returns an owned (ref-counted) handle
  end

  # Creates a compute pipeline from a shader module and entry point.
  #
  # With the default `layout` (NULL) wgpu derives the bind group layouts from
  # the shader ("auto" layout) — grab them back with `compute_bind_group_layout`.
  def self.create_compute_pipeline(device : LibWGPU::Device, mod : LibWGPU::ShaderModule,
                                   entry_point : String = "main",
                                   layout : LibWGPU::PipelineLayout = WGPU.null(LibWGPU::PipelineLayout),
                                   label : String? = nil) : LibWGPU::ComputePipeline
    state = LibWGPU::ComputeState.new(module_: mod, entry_point: string_view(entry_point))
    desc = LibWGPU::ComputePipelineDescriptor.new(
      label: label ? string_view(label) : empty_string_view,
      layout: layout,
      compute: state,
    )
    pipeline = LibWGPU.device_create_compute_pipeline(device, pointerof(desc))
    raise Error.new("device_create_compute_pipeline returned NULL") if pipeline.null?
    pipeline
  end

  # Returns the auto-derived bind group layout of a compute pipeline for `group`.
  def self.compute_bind_group_layout(pipeline : LibWGPU::ComputePipeline, group : UInt32 = 0_u32) : LibWGPU::BindGroupLayout
    layout = LibWGPU.compute_pipeline_get_bind_group_layout(pipeline, group)
    raise Error.new("compute_pipeline_get_bind_group_layout returned NULL") if layout.null?
    layout
  end

  # Binds buffers to a layout. Each entry is `{binding, buffer, size_in_bytes}`
  # (offset 0, whole binding). Pass the buffer's own size for `size_in_bytes`.
  #
  #   bg = WGPU.create_bind_group(device, layout, [
  #     {0_u32, input_buf,  in_size},
  #     {1_u32, output_buf, out_size},
  #   ])
  def self.create_bind_group(device : LibWGPU::Device, layout : LibWGPU::BindGroupLayout,
                             buffers : Array(Tuple(UInt32, LibWGPU::Buffer, UInt64)),
                             label : String? = nil) : LibWGPU::BindGroup
    entries = buffers.map do |(binding, buffer, size)|
      LibWGPU::BindGroupEntry.new(binding: binding, buffer: buffer, offset: 0_u64, size: size)
    end

    desc = LibWGPU::BindGroupDescriptor.new(
      label: label ? string_view(label) : empty_string_view,
      layout: layout,
      entry_count: LibC::SizeT.new(entries.size),
      entries: entries.to_unsafe,
    )
    bind_group = LibWGPU.device_create_bind_group(device, pointerof(desc))
    raise Error.new("device_create_bind_group returned NULL") if bind_group.null?
    bind_group
  end

  # Records and submits a single compute pass: set pipeline + bind group (at
  # group 0), dispatch `(x, y, z)` workgroups, submit to the queue.
  #
  # This does NOT wait for completion. Use `read_buffer` (which maps, and so
  # blocks until the submitted work is done) to read results back.
  def self.dispatch(device : LibWGPU::Device, pipeline : LibWGPU::ComputePipeline, bind_group : LibWGPU::BindGroup,
                    workgroups_x : UInt32, workgroups_y : UInt32 = 1_u32, workgroups_z : UInt32 = 1_u32) : Nil
    queue = LibWGPU.device_get_queue(device)

    # Track the transient encoder/pass so `ensure` can release them even if a
    # raise fires mid-record; both start NULL and are released only once created.
    encoder = WGPU.null(LibWGPU::CommandEncoder)
    pass = WGPU.null(LibWGPU::ComputePassEncoder)
    begin
      enc_desc = LibWGPU::CommandEncoderDescriptor.new(label: empty_string_view)
      encoder = LibWGPU.device_create_command_encoder(device, pointerof(enc_desc))
      raise Error.new("device_create_command_encoder returned NULL") if encoder.null?

      pass_desc = LibWGPU::ComputePassDescriptor.new(label: empty_string_view)
      pass = LibWGPU.command_encoder_begin_compute_pass(encoder, pointerof(pass_desc))
      raise Error.new("command_encoder_begin_compute_pass returned NULL") if pass.null?

      LibWGPU.compute_pass_encoder_set_pipeline(pass, pipeline)
      LibWGPU.compute_pass_encoder_set_bind_group(pass, 0_u32, bind_group, LibC::SizeT.new(0), Pointer(UInt32).null)
      LibWGPU.compute_pass_encoder_dispatch_workgroups(pass, workgroups_x, workgroups_y, workgroups_z)
      LibWGPU.compute_pass_encoder_end(pass)

      cmd_desc = LibWGPU::CommandBufferDescriptor.new(label: empty_string_view)
      cmd = LibWGPU.command_encoder_finish(encoder, pointerof(cmd_desc))
      LibWGPU.queue_submit(queue, LibC::SizeT.new(1), pointerof(cmd))
      LibWGPU.command_buffer_release(cmd)
    ensure
      LibWGPU.compute_pass_encoder_release(pass) unless pass.null?
      LibWGPU.command_encoder_release(encoder) unless encoder.null?
      LibWGPU.queue_release(queue) # device_get_queue returns an owned (ref-counted) handle
    end
  end

  # Reads `size` bytes back from a GPU buffer into a `Bytes` on the CPU.
  #
  # Copies `source` into a transient MapRead staging buffer, submits, then
  # blocks (via `map_buffer_read`) until the copy completes. `source` must have
  # `CopySrc` usage. Reinterpret the result with e.g. `bytes.unsafe_slice_of(Float32)`.
  def self.read_buffer(instance : LibWGPU::Instance, device : LibWGPU::Device,
                       source : LibWGPU::Buffer, size : UInt64) : Bytes
    staging = create_buffer(device, size,
      LibWGPU::BufferUsage::MapRead | LibWGPU::BufferUsage::CopyDst, "wgpu-cr readback")

    # `staging` must be released even if mapping or read-back raises. `mapped`
    # tracks whether the buffer got mapped, so `ensure` only unmaps a mapped one.
    mapped = false
    begin
      queue = LibWGPU.device_get_queue(device)
      enc_desc = LibWGPU::CommandEncoderDescriptor.new(label: empty_string_view)
      encoder = LibWGPU.device_create_command_encoder(device, pointerof(enc_desc))
      LibWGPU.command_encoder_copy_buffer_to_buffer(encoder, source, 0_u64, staging, 0_u64, size)
      cmd_desc = LibWGPU::CommandBufferDescriptor.new(label: empty_string_view)
      cmd = LibWGPU.command_encoder_finish(encoder, pointerof(cmd_desc))
      LibWGPU.queue_submit(queue, LibC::SizeT.new(1), pointerof(cmd))
      LibWGPU.command_buffer_release(cmd)
      LibWGPU.command_encoder_release(encoder)
      LibWGPU.queue_release(queue) # device_get_queue returns an owned (ref-counted) handle

      map_buffer_read(instance, staging, size)
      mapped = true

      ptr = LibWGPU.buffer_get_const_mapped_range(staging, LibC::SizeT.new(0), LibC::SizeT.new(size))
      raise Error.new("buffer_get_const_mapped_range returned NULL") if ptr.null?

      bytes = Bytes.new(size)
      bytes.copy_from(ptr.as(UInt8*), size)
      bytes
    ensure
      LibWGPU.buffer_unmap(staging) if mapped
      LibWGPU.buffer_release(staging)
    end
  end
end

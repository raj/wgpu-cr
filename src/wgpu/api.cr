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
end

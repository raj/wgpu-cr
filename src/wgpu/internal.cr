# Shared internals of the `WGPU` helpers: StringView conversions, typed null
# handles and the synchronous wait loop over wgpu's asynchronous callbacks.
#
# Single source of truth for this logic: the static `WGPU.*` API (api.cr)
# delegates here, and the object layer (`WGPU::Device`, …) builds on it too.
# Not part of the public API — use the `WGPU.*` entry points instead.
module WGPU
  # :nodoc:
  module Internal
    extend self

    # Null (opaque pointer) handle of the given type.
    # The lib's `type X = Void*` typedefs don't expose `.null`, hence this helper.
    def null(t : T.class) : T forall T
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
    def string_view(str : String) : LibWGPU::StringView
      LibWGPU::StringView.new(data: str.to_unsafe, length: str.bytesize.to_u64)
    end

    # Canonical NULL StringView ({NULL, WGPU_STRLEN}) per webgpu.h.
    def null_string_view : LibWGPU::StringView
      LibWGPU::StringView.new(data: Pointer(LibC::Char).null, length: LibC::SizeT::MAX)
    end

    # Empty view with 0 length — used for optional labels.
    def empty_string_view : LibWGPU::StringView
      LibWGPU::StringView.new(data: Pointer(LibC::Char).null, length: 0_u64)
    end

    # View of an optional label: the label's bytes, or an empty view for nil.
    # Same lifetime rule as `string_view`.
    def label_view(label : String?) : LibWGPU::StringView
      label ? string_view(label) : empty_string_view
    end

    # Converts a `WGPUStringView` returned by the C side into a Crystal String.
    # Handles both explicit-length views and null-terminated views (WGPU_STRLEN / SIZE_MAX).
    def view_to_s(view : LibWGPU::StringView) : String
      return "" if view.data.null? || view.length == 0
      if view.length == LibC::SizeT::MAX
        String.new(view.data.as(UInt8*))
      else
        String.new(view.data.as(UInt8*), view.length)
      end
    end

    # ------------------------------------------------------------------
    # Buffer mapping — synchronous.
    # ------------------------------------------------------------------

    private struct MapResult
      property status : LibWGPU::MapAsyncStatus = LibWGPU::MapAsyncStatus::Error
      property message : String = ""
      property done : Bool = false
    end

    # Maps `size` bytes of `buffer` at `offset` for `mode` (Read or Write),
    # blocking until wgpu answers. Raises `WGPU::Error` on failure or timeout.
    def map_buffer(instance : LibWGPU::Instance, buffer : LibWGPU::Buffer, mode : LibWGPU::MapMode,
                   offset : UInt64, size : UInt64, timeout : Time::Span = 5.seconds) : Nil
      # Box on the heap: the C side keeps this pointer as `userdata1` and may
      # fire the callback after a timeout has unwound this frame (see `wait_until`).
      result = Pointer(MapResult).malloc(1)
      result.value = MapResult.new

      callback = ->(status : LibWGPU::MapAsyncStatus, message : LibWGPU::StringView, u1 : Void*, _u2 : Void*) do
        r = u1.as(Pointer(MapResult))
        r.value.status = status
        r.value.message = Internal.view_to_s(message)
        r.value.done = true
        nil
      end

      info = LibWGPU::BufferMapCallbackInfo.new
      info.mode = LibWGPU::CallbackMode::AllowProcessEvents
      info.callback = callback
      info.userdata1 = result.as(Void*)

      LibWGPU.buffer_map_async(buffer, mode, LibC::SizeT.new(offset), LibC::SizeT.new(size), info)
      wait_until(instance, result.as(Void*), timeout) { result.value.done }

      unless result.value.status.success?
        raise WGPU::Error.new("buffer_map_async failed: #{result.value.status} #{result.value.message}")
      end
    end

    # ------------------------------------------------------------------
    # Error scopes — synchronous.
    # ------------------------------------------------------------------

    private struct PopErrorScopeResult
      property status : LibWGPU::PopErrorScopeStatus = LibWGPU::PopErrorScopeStatus::Error
      property type : LibWGPU::ErrorType = LibWGPU::ErrorType::NoError
      property message : String = ""
      property done : Bool = false
    end

    # Pops the device's innermost error scope. Returns the captured error as
    # an exception (not raised), or nil.
    #
    # Uses `AllowSpontaneous`: wgpu-native v29 fires this callback
    # synchronously, inside `wgpuDevicePopErrorScope` (verified), so no event
    # pumping (and no instance) is needed. If it ever does not, `instance` is
    # pumped when given; without one, a `WGPU::Error` is raised.
    def pop_error_scope(device : LibWGPU::Device, instance : LibWGPU::Instance? = nil,
                        timeout : Time::Span = 5.seconds) : WGPU::Error?
      # Heap box: see `map_buffer` / `wait_until`.
      result = Pointer(PopErrorScopeResult).malloc(1)
      result.value = PopErrorScopeResult.new

      callback = ->(status : LibWGPU::PopErrorScopeStatus, type : LibWGPU::ErrorType, message : LibWGPU::StringView, u1 : Void*, _u2 : Void*) do
        r = u1.as(Pointer(PopErrorScopeResult))
        r.value.status = status
        r.value.type = type
        r.value.message = Internal.view_to_s(message)
        r.value.done = true
        nil
      end

      info = LibWGPU::PopErrorScopeCallbackInfo.new(
        mode: LibWGPU::CallbackMode::AllowSpontaneous,
        callback: callback,
        userdata1: result.as(Void*),
      )
      LibWGPU.device_pop_error_scope(device, info)
      unless result.value.done
        raise WGPU::Error.new("pop_error_scope did not complete synchronously") unless instance
        wait_until(instance, result.as(Void*), timeout) { result.value.done }
      end

      unless result.value.status.success?
        raise WGPU::Error.new("pop_error_scope failed: #{result.value.status} #{result.value.message}")
      end
      gpu_error(result.value.type, result.value.message)
    end

    # Runs the block inside an error scope of `device` and raises the error
    # it captured, if any (releasing a `GPUObject` the block returned, which
    # is invalid then). Returns the block's value. If the block itself
    # raises, the captured GPU error (wgpu's real cause) wins.
    def error_scope(device : LibWGPU::Device, filter : LibWGPU::ErrorFilter, &)
      LibWGPU.device_push_error_scope(device, filter)
      begin
        result = yield
      rescue ex
        raise pop_error_scope(device) || ex
      end
      if error = pop_error_scope(device)
        result.release if result.is_a?(GPUObject)
        raise error
      end
      result
    end

    # `error_scope` for Validation and OutOfMemory errors at once.
    def checked(device : LibWGPU::Device, &)
      error_scope(device, LibWGPU::ErrorFilter::OutOfMemory) do
        error_scope(device, LibWGPU::ErrorFilter::Validation) { yield }
      end
    end

    # The exception matching a wgpu error type (nil for NoError).
    def gpu_error(type : LibWGPU::ErrorType, message : String) : WGPU::Error?
      case type
      when .no_error?      then nil
      when .validation?    then WGPU::ValidationError.new(message)
      when .out_of_memory? then WGPU::OutOfMemoryError.new(message)
      when .internal?      then WGPU::InternalError.new(message)
      else                      WGPU::Error.new("#{type}: #{message}")
      end
    end

    # ------------------------------------------------------------------
    # Synchronous wait over asynchronous callbacks
    # ------------------------------------------------------------------

    # Retains boxed callback results whose wait timed out while the C future was
    # still pending. The C side still holds a raw `userdata1` pointer into that
    # heap box, so a late callback would write through it after `wait_until`
    # raised; keeping the box referenced here means it lands in live memory
    # rather than an allocation the GC has reclaimed and reused. Only ever grows
    # on the fatal timeout path (which raises), so it does not leak in practice.
    PENDING_TIMEOUT_MUTEX   = Mutex.new
    PENDING_TIMEOUT_RESULTS = [] of Void*

    # Pumps the instance event loop until `block` returns true.
    # Guards against waiting forever if a callback never fires.
    #
    # `keep_alive`, when non-null, points at the heap box the pending C callback
    # writes into (its `userdata1`). On timeout the box is retained (see
    # `PENDING_TIMEOUT_RESULTS`) before raising, so a late write cannot corrupt
    # reclaimed memory.
    #
    # NOTE: wgpu-native's `wgpuInstanceWaitAny` (a native timed wait, exposed as
    # `LibWGPU.instance_wait_any`) would avoid the polling, but in the
    # vendored v29 binary that entry point is an `unimplemented!()` stub that
    # aborts the process (verified: both poll-mode timeout=0 and timed waits
    # panic, with or without the TimedWaitAny instance feature). Keep polling
    # `wgpuInstanceProcessEvents` until wgpu-native actually implements it.
    def wait_until(instance : LibWGPU::Instance,
                   keep_alive : Void* = Pointer(Void).null,
                   timeout : Time::Span = 5.seconds,
                   &block : -> Bool) : Nil
      start_time = Time.monotonic
      until block.call
        LibWGPU.instance_process_events(instance)
        break if block.call
        if Time.monotonic - start_time > timeout
          PENDING_TIMEOUT_MUTEX.synchronize do
            PENDING_TIMEOUT_RESULTS << keep_alive unless keep_alive.null?
          end
          raise WGPU::Error.new("timed out waiting for a wgpu callback")
        end
        sleep(1.millisecond)
      end
    end
  end
end

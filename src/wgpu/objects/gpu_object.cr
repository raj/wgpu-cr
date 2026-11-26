module WGPU
  # Base class of the object layer. A `GPUObject` owns one reference (+1) to a
  # wgpu handle of type `H` and releases it exactly once: explicitly with
  # `#release`, at the end of a block form (`#use`, `request_device { … }`), or
  # as a last resort when the GC finalizes the wrapper.
  #
  # Ownership rules (see docs/plan-object-layer.md §2.3):
  # * every child keeps a strong Crystal reference to its parent
  #   (`Buffer → Device → Adapter → Instance`), so a parent's finalizer never
  #   runs before its children's;
  # * a parent never keeps a Crystal reference back to its children. Crystal
  #   registers finalizers in Boehm's *ordered* mode, where a reference cycle
  #   between finalizable objects is never collected, so a back-reference
  #   would leak both objects. The only exception is `Device#queue`: the
  #   `Queue` holds no reference to the `Device` object, so it stays one-way.
  #
  # Releasing in any order is safe: wgpu ref-counts each handle on its own, and
  # a child handle keeps its parent alive on the C side.
  abstract class GPUObject(H)
    @released = false

    # Label given at creation (nil when there is none).
    #
    # NOTE: labels can only be set at creation. Every `wgpu*SetLabel` entry
    # point of wgpu-native v29 is an `unimplemented!()` stub that aborts the
    # process, so the wrappers expose no `label=`.
    getter label : String?

    # Takes ownership of `handle` (one reference). Raises `WGPU::Error` if it is NULL.
    def initialize(@handle : H, @label : String? = nil)
      raise Error.new("#{self.class.name}: wgpu returned a NULL handle") if @handle.null?
    end

    # True once the handle has been released. Any further use raises `WGPU::Error`.
    def released? : Bool
      @released
    end

    # Releases the handle. Idempotent: later calls do nothing.
    def release : Nil
      release_once
    end

    # GC safety net: releases the handle if it was not released explicitly.
    # Must never raise, so it bypasses any `release` override (no cascade).
    def finalize
      release_once
    end

    # Yields `self`, then releases it when the block exits (even on raise).
    # Returns the block's value.
    #
    #   device.create_buffer(64, usage).use { |buf| queue.write_buffer(buf, data) }
    def use(&)
      yield self
    ensure
      release
    end

    # The raw handle, for `LibWGPU` calls and the static `WGPU.*` helpers. The
    # wrapper keeps ownership: do not release the returned handle yourself.
    # Raises `WGPU::Error` if the object was released.
    def to_unsafe : H
      handle
    end

    def to_s(io : IO) : Nil
      io << self.class.name << "(0x"
      @handle.address.to_s(io, 16)
      if label = @label
        io << ", label: "
        label.inspect(io)
      end
      io << ", released" if @released
      io << ')'
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end

    # The handle, or `WGPU::Error` when the object was already released
    # (instead of a use-after-free on the C side).
    protected def handle : H
      raise Error.new("#{self.class.name} used after release") if @released
      @handle
    end

    private def release_once : Nil
      return if @released
      @released = true
      release_handle
    end

    # Calls the type-specific `wgpu*Release`. Handles are all `Void*`
    # typedefs, so the dispatch has to happen on the wrapper class.
    # Runs inside `finalize`, so it must neither raise nor allocate GC memory:
    # allocating from a Boehm finalizer deadlocks the process (verified).
    private abstract def release_handle : Nil
  end
end

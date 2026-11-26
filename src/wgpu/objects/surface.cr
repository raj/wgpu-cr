module WGPU
  # What a surface supports with a given adapter (`Surface#capabilities`).
  # The first format is the preferred one.
  record SurfaceCapabilities,
    formats : Array(LibWGPU::TextureFormat),
    present_modes : Array(LibWGPU::PresentMode),
    alpha_modes : Array(LibWGPU::CompositeAlphaMode),
    usages : LibWGPU::TextureUsage

  # A window surface to present rendered frames, from `Instance#create_surface`.
  # Keeps its `Instance` alive, and the `Device` it is configured with.
  #
  #   surface.configure(device, format, width, height)
  #   if texture = surface.current_texture
  #     view = texture.create_view
  #     # … render into view, submit …
  #     surface.present
  #     view.release
  #     texture.release
  #   end
  class Surface < GPUObject(LibWGPU::Surface)
    getter instance : Instance
    # The device given to the last `configure` (nil before, or after `unconfigure`).
    getter device : Device?

    # Wraps `handle`, taking ownership of one reference.
    def initialize(@instance : Instance, handle : LibWGPU::Surface, label : String? = nil)
      @device = nil
      super(handle, label)
    end

    # Formats, present modes, alpha modes and usages the surface supports with `adapter`.
    def capabilities(adapter : Adapter) : SurfaceCapabilities
      caps = LibWGPU::SurfaceCapabilities.new
      status = LibWGPU.surface_get_capabilities(handle, adapter, pointerof(caps))
      begin
        raise Error.new("surface_get_capabilities failed") unless status.success?
        SurfaceCapabilities.new(
          formats: Array.new(caps.format_count.to_i) { |i| caps.formats[i] },
          present_modes: Array.new(caps.present_mode_count.to_i) { |i| caps.present_modes[i] },
          alpha_modes: Array.new(caps.alpha_mode_count.to_i) { |i| caps.alpha_modes[i] },
          usages: caps.usages,
        )
      ensure
        LibWGPU.surface_capabilities_free_members(caps)
      end
    end

    # Configures the swapchain: `width × height` textures of `format`. Call
    # it again on resize (or when `current_texture` returns nil).
    def configure(device : Device, format : LibWGPU::TextureFormat, width : Int, height : Int,
                  usage : LibWGPU::TextureUsage = LibWGPU::TextureUsage::RenderAttachment,
                  present_mode : LibWGPU::PresentMode = LibWGPU::PresentMode::Fifo,
                  alpha_mode : LibWGPU::CompositeAlphaMode = LibWGPU::CompositeAlphaMode::Auto,
                  view_formats : Array(LibWGPU::TextureFormat)? = nil) : Nil
      config = LibWGPU::SurfaceConfiguration.new(
        device: device.to_unsafe,
        format: format,
        usage: usage,
        width: width.to_u32,
        height: height.to_u32,
        alpha_mode: alpha_mode,
        present_mode: present_mode,
      )
      if formats = view_formats
        config.view_format_count = LibC::SizeT.new(formats.size)
        config.view_formats = formats.to_unsafe
      end
      LibWGPU.surface_configure(handle, pointerof(config))
      @device = device
    end

    # Releases the swapchain textures (configure again before rendering).
    def unconfigure : Nil
      LibWGPU.surface_unconfigure(handle)
      @device = nil
    end

    # Acquires the next texture to render into. Returns nil when no frame is
    # available right now (`Timeout`, `Outdated`, `Lost`): skip the frame and,
    # for `Outdated`/`Lost`, `configure` again. Raises `WGPU::Error` on a
    # fatal status or when the surface is not configured.
    def current_texture : Texture?
      device = @device || raise Error.new("Surface#current_texture: configure the surface first")
      st = LibWGPU::SurfaceTexture.new
      LibWGPU.surface_get_current_texture(handle, pointerof(st))
      @last_status = st.status
      case st.status
      when .success_optimal?, .success_suboptimal?
        Texture.new(device, st.texture)
      when .timeout?, .outdated?, .lost?
        LibWGPU.texture_release(st.texture) unless st.texture.null?
        nil
      else
        LibWGPU.texture_release(st.texture) unless st.texture.null?
        raise Error.new("surface_get_current_texture failed: #{st.status}")
      end
    end

    # Status of the last `current_texture` (e.g. to tell `Outdated` from `Timeout`).
    getter last_status : LibWGPU::SurfaceGetCurrentTextureStatus? = nil

    # Presents the texture acquired by `current_texture`.
    def present : Nil
      status = LibWGPU.surface_present(handle)
      raise Error.new("surface_present failed") unless status.success?
    end

    private def release_handle : Nil
      LibWGPU.surface_release(@handle)
    end
  end

  class Instance
    # Creates a surface from native window handles. One overload per
    # platform, selected by the named arguments:
    #
    #   instance.create_surface(wayland_display: display, wayland_surface: surface)
    #   instance.create_surface(xlib_display: display, xlib_window: window)
    #   instance.create_surface(xcb_connection: connection, xcb_window: window)
    #   instance.create_surface(metal_layer: layer)            # macOS (CAMetalLayer)
    #   instance.create_surface(hinstance: hinstance, hwnd: hwnd) # Windows
    #   instance.create_surface(android_window: window)
    #
    # The windowing library stays outside the binding (see examples/lib_glfw.cr).
    def create_surface(*, wayland_display : Void*, wayland_surface : Void*, label : String? = nil) : Surface
      source = LibWGPU::SurfaceSourceWaylandSurface.new(
        chain: Internal.chain(LibWGPU::SType::SurfaceSourceWaylandSurface),
        display: wayland_display, surface: wayland_surface)
      create_surface_from(pointerof(source).as(LibWGPU::ChainedStruct*), label)
    end

    # :ditto:
    def create_surface(*, xlib_display : Void*, xlib_window : Int, label : String? = nil) : Surface
      source = LibWGPU::SurfaceSourceXlibWindow.new(
        chain: Internal.chain(LibWGPU::SType::SurfaceSourceXlibWindow),
        display: xlib_display, window: xlib_window.to_u64)
      create_surface_from(pointerof(source).as(LibWGPU::ChainedStruct*), label)
    end

    # :ditto:
    def create_surface(*, xcb_connection : Void*, xcb_window : Int, label : String? = nil) : Surface
      source = LibWGPU::SurfaceSourceXCBWindow.new(
        chain: Internal.chain(LibWGPU::SType::SurfaceSourceXCBWindow),
        connection: xcb_connection, window: xcb_window.to_u32)
      create_surface_from(pointerof(source).as(LibWGPU::ChainedStruct*), label)
    end

    # :ditto:
    def create_surface(*, metal_layer : Void*, label : String? = nil) : Surface
      source = LibWGPU::SurfaceSourceMetalLayer.new(
        chain: Internal.chain(LibWGPU::SType::SurfaceSourceMetalLayer), layer: metal_layer)
      create_surface_from(pointerof(source).as(LibWGPU::ChainedStruct*), label)
    end

    # :ditto:
    def create_surface(*, hinstance : Void*, hwnd : Void*, label : String? = nil) : Surface
      source = LibWGPU::SurfaceSourceWindowsHWND.new(
        chain: Internal.chain(LibWGPU::SType::SurfaceSourceWindowsHWND), hinstance: hinstance, hwnd: hwnd)
      create_surface_from(pointerof(source).as(LibWGPU::ChainedStruct*), label)
    end

    # :ditto:
    def create_surface(*, android_window : Void*, label : String? = nil) : Surface
      source = LibWGPU::SurfaceSourceAndroidNativeWindow.new(
        chain: Internal.chain(LibWGPU::SType::SurfaceSourceAndroidNativeWindow), window: android_window)
      create_surface_from(pointerof(source).as(LibWGPU::ChainedStruct*), label)
    end

    # Requests an adapter able to present to `surface`.
    def request_adapter(compatible_surface : Surface,
                        power_preference : LibWGPU::PowerPreference = LibWGPU::PowerPreference::HighPerformance,
                        timeout : Time::Span = 5.seconds) : Adapter
      request_adapter(power_preference, compatible_surface.to_unsafe, timeout)
    end

    private def create_surface_from(source : LibWGPU::ChainedStruct*, label : String?) : Surface
      desc = LibWGPU::SurfaceDescriptor.new(next_in_chain: source, label: Internal.label_view(label))
      Surface.new(self, LibWGPU.instance_create_surface(handle, pointerof(desc)), label)
    end
  end

  module Internal
    def chain(s_type : LibWGPU::SType) : LibWGPU::ChainedStruct
      LibWGPU::ChainedStruct.new(s_type: s_type)
    end
  end
end

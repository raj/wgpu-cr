# Minimal GLFW + Objective-C bindings used by the windowed render example.
#
# GLFW gives us a cross-platform window; on macOS we then use the Objective-C
# runtime to attach a CAMetalLayer to the window's content view, which is what
# wgpu-native needs to create a Metal surface. These bindings are intentionally
# kept in the examples (not in the core lib): windowing is out of scope for the
# wgpu binding itself.

@[Link(ldflags: "-L/opt/homebrew/lib -lglfw -Wl,-rpath,/opt/homebrew/lib -framework Cocoa -framework QuartzCore -framework Metal -lobjc")]
lib LibGLFW
  CLIENT_API = 0x00022001
  NO_API     =          0

  fun init = glfwInit : Int32
  fun terminate = glfwTerminate : Void
  fun window_hint = glfwWindowHint(hint : Int32, value : Int32) : Void
  fun create_window = glfwCreateWindow(width : Int32, height : Int32, title : LibC::Char*, monitor : Void*, share : Void*) : Void*
  fun destroy_window = glfwDestroyWindow(window : Void*) : Void
  fun window_should_close = glfwWindowShouldClose(window : Void*) : Int32
  fun poll_events = glfwPollEvents : Void
  fun get_framebuffer_size = glfwGetFramebufferSize(window : Void*, width : Int32*, height : Int32*) : Void
  fun get_cocoa_window = glfwGetCocoaWindow(window : Void*) : Void*
end

# Objective-C runtime (libobjc, part of the system). We only need a few
# message sends to build and attach a CAMetalLayer.
#
# objc_msgSend can only be bound once (Crystal tracks the C symbol's signature
# globally). On Apple arm64 it is non-variadic, so a single fixed signature
# works for every call: pointer-sized args go in registers, and a method that
# takes fewer args simply ignores the extra register. A BOOL argument is just a
# pointer-sized value (1 = YES).
lib LibObjC
  fun get_class = objc_getClass(name : LibC::Char*) : Void*
  fun register_name = sel_registerName(name : LibC::Char*) : Void*
  fun msg_send = objc_msgSend(receiver : Void*, sel : Void*, arg : Void*) : Void*
end

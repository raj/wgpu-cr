# wgpu-cr

[![build](https://img.shields.io/github/actions/workflow/status/raj/wgpu-cr/ci.yml?branch=main&label=build)](https://github.com/raj/wgpu-cr/actions/workflows/ci.yml)
[![tests](https://img.shields.io/github/actions/workflow/status/raj/wgpu-cr/ci.yml?branch=main&label=tests)](https://github.com/raj/wgpu-cr/actions/workflows/ci.yml)
[![coverage](https://coveralls.io/repos/github/raj/wgpu-cr/badge.svg?branch=main)](https://coveralls.io/github/raj/wgpu-cr?branch=main)
[![version](https://img.shields.io/github/v/tag/raj/wgpu-cr?label=version&color=blue)](https://github.com/raj/wgpu-cr/tags)
[![license](https://img.shields.io/github/license/raj/wgpu-cr?color=blue)](LICENSE)

**Crystal** bindings for [wgpu-native](https://github.com/gfx-rs/wgpu-native) (the Rust implementation of WebGPU), in the spirit of [wgpu-py](https://github.com/pygfx/wgpu-py).

The project exposes three levels:

| Level | Module | Description |
|-------|--------|-------------|
| Object layer (**recommended**) | `WGPU::Instance`, `WGPU::Device`, `WGPU::Buffer`… | wgpu-py–style objects that own their handle: `device.create_buffer(…)`, automatic release, errors raised as exceptions. |
| Static helpers | `WGPU.*` | Functions over raw handles (synchronous adapter/device requests, buffer mapping, compute helpers…). |
| Low level (FFI) | `LibWGPU` | 1:1 binding to the WebGPU C API, **generated automatically** from `webgpu.h`. |

The levels interoperate: every object passes to `LibWGPU` functions as is
(Crystal calls its `to_unsafe`), and `obj.to_unsafe` gives the handle to the
static helpers.

## Status

✅ Working today:
- Automatic download of wgpu-native (lib + headers + spec).
- Full FFI binding generation: **199 functions, 92 structs, 54 enums, 5 bitflags, 23 handles, 10 callbacks, 11 constants**.
- ✅ **Object layer** (see below): buffers (synchronous mapping), textures,
  samplers, bind groups, compute and render pipelines, command encoders,
  compute/render passes, render bundles, surfaces — with automatic release and
  WebGPU errors raised as Crystal exceptions.
- End-to-end **compute** (tested: a WGSL shader doubling an array on the GPU).
- **Rendering**: vertex/index buffers, uniforms, textures, samplers, depth,
  scissor, render bundles (tested headless by reading pixels back).
- **Windowed rendering** — a triangle in a GLFW window via a Metal surface (macOS)
  or a Wayland / X11 surface (Linux).
- Log forwarding: `wgpuSetLogCallback`/`wgpuSetLogLevel` (wgpu.h) + `WGPU.set_log_stderr(level)`.

🚧 Coming next:
- Windows (HWND) surfaces: `instance.create_surface(hinstance:, hwnd:)` exists but is untested.
- Query sets (occlusion, timestamps), async pipeline creation, shader compilation info.
- Bindings for the native `wgpu.h` extensions (DevicePoll, etc.).

## Requirements

- [Crystal](https://crystal-lang.org) ≥ 1.16
- `curl` and `unzip`

Linux (Ubuntu), for the windowed example (wgpu-native renders through Vulkan):

```sh
sudo apt install libglfw3-dev        # GLFW (build + run)
sudo apt install mesa-vulkan-drivers # Vulkan loader + driver (runtime; vendor drivers otherwise)
```

## Installation

```sh
git clone <repo> && cd wgpu-cr
shards install            # triggers the postinstall (download_wgpu.sh)
```

Or manually:

```sh
./scripts/download_wgpu.sh            # the wgpu-native version the bindings target
crystal run scripts/generate_bindings.cr
```

### Downloading wgpu-native

The script detects the OS/architecture, fetches the right release and installs
`vendor/wgpu-native/` (lib + headers + `webgpu.yml`), then writes the link flags
into `src/wgpu/link.cr`.

```sh
./scripts/download_wgpu.sh                 # pinned version (matches src/wgpu/native.cr)
./scripts/download_wgpu.sh v29.0.1.1       # a given version
./scripts/download_wgpu.sh latest          # newest upstream release (regenerate the bindings!)
WGPU_NATIVE_BUILD=debug ./scripts/download_wgpu.sh
```

Variables: `WGPU_NATIVE_VERSION`, `WGPU_NATIVE_BUILD` (`release`/`debug`),
`WGPU_NATIVE_OS`, `WGPU_NATIVE_ARCH`.

### Regenerating the binding

The binding is generated from `vendor/wgpu-native/include/webgpu/webgpu.h`
(the ABI source of truth):

```sh
crystal run scripts/generate_bindings.cr   # writes src/wgpu/native.cr
```

## Object layer

```crystal
require "wgpu"

WGPU::Instance.new do |instance|
  device = instance.request_adapter.request_device

  input   = Slice(Float32).new(256) { |i| i.to_f32 }
  storage = device.create_buffer_with_data(input, LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopySrc)

  pipeline   = device.create_compute_pipeline(device.create_shader_module(WGSL))
  bind_group = device.create_bind_group(pipeline.bind_group_layout(0), {0 => storage})

  device.dispatch(pipeline, bind_group, 4)
  device.read_buffer(storage).unsafe_slice_of(Float32) # => 0.0, 2.0, 4.0, …
end
```

| Static helpers / FFI | Object layer |
|---|---|
| `inst = WGPU.create_instance` … `LibWGPU.instance_release(inst)` | `WGPU::Instance.new { \|instance\| … }` |
| `WGPU.request_adapter(inst)` / `WGPU.request_device(inst, adapter)` | `instance.request_adapter` / `adapter.request_device` |
| `WGPU.create_buffer(device, size, usage)` | `device.create_buffer(size, usage)` |
| `WGPU.write_buffer(device, buf, data)` | `device.queue.write_buffer(buf, data)` |
| `WGPU.read_buffer(inst, device, buf, size)` | `device.read_buffer(buf)` / `buf.map_read { \|bytes\| … }` |
| `WGPU.create_bind_group(device, layout, [{0_u32, buf, size}])` | `device.create_bind_group(layout, {0 => buf, 1 => view, 2 => sampler})` |
| encoder + pass + `*_end` + `finish` + `submit` + 4 `*_release` | `encoder.begin_compute_pass { \|pass\| … }` then `queue.submit(encoder.finish)` |
| `LibWGPU::RenderPipelineDescriptor` + 6 nested structs | `device.create_render_pipeline(WGPU::VertexState.new(shader), WGPU::FragmentState.new(shader, [WGPU::ColorTargetState.new(format)]))` |

**Ownership.** Each object owns one reference to its wgpu handle and releases
it exactly once: with `#release` (idempotent), at the end of a block form
(`Instance.new { }`, `request_device { }`, `begin_render_pass { }`,
`obj.use { }`), or when the GC collects it. Using a released object raises
`WGPU::Error` instead of crashing. Objects that WebGPU *consumes* are released
for you: `encoder.finish`, `pass.end_pass`, `queue.submit(cmd)`.
Children keep their parent alive (`Buffer → Device → Adapter → Instance`).

**Errors.** wgpu reports most mistakes asynchronously, and wgpu-native aborts
the process when an invalid command buffer is submitted. The object layer runs
every `create_*`, `finish` and queue write inside error scopes and raises
`WGPU::ValidationError` (or `OutOfMemoryError`, `InternalError`) with wgpu's
message right where the mistake is:

```crystal
device.create_shader_module("fn main( {")
# => WGPU::ValidationError: … expected identifier
```

`Queue#submit` also refuses commands that use a buffer still mapped or
destroyed (wgpu-native would abort on these, even inside an error scope). The
checks cost one quick round trip per call; `device.error_checks = false` turns
them off. Manual scopes: `device.error_scope { … }`, `device.push_error_scope`
/ `device.pop_error_scope`.

**wgpu-native v29 limitations.** Some entry points are `unimplemented!()`
stubs that abort the process: every `wgpu*SetLabel`, `wgpuDeviceGetAdapterInfo`,
`wgpuInstanceHasWGSLLanguageFeature` / `GetWGSLLanguageFeatures`,
`wgpuBufferGetMapState`, `wgpuBufferRead/WriteMappedRange`,
`wgpuTextureGetTextureBindingViewDimension`, `wgpuInstanceWaitAny`,
`wgpuHasInstanceFeature`. The object layer never calls them (labels are set at
creation, the map state is tracked in Crystal, mapped ranges are copied through
`GetMappedRange`…); avoid them when using `LibWGPU` directly.

## Example — compute

```sh
crystal run examples/compute.cr
```

```
wgpu-cr 0.1.0 (wgpu-native v29.0.1.1)
Input  : 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, … (256 elements)
Output : 0.0, 2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, …
✅ GPU computation correct (each element × 2)
```

The same computation at the three levels:
[`examples/compute_oo.cr`](examples/compute_oo.cr) (object layer),
[`examples/compute_wrapped.cr`](examples/compute_wrapped.cr) (static helpers),
[`examples/compute.cr`](examples/compute.cr) (raw FFI: instance → adapter →
device → buffer → WGSL shader → pipeline → bind group → dispatch → copy →
mapping → read back).

## Example — triangle in a window

```sh
crystal run examples/triangle_oo.cr   # object layer
crystal run examples/triangle.cr      # raw FFI
```

Opens a GLFW window and renders a triangle. The windowing glue lives in
[`examples/lib_glfw.cr`](examples/lib_glfw.cr) (GLFW + a few platform calls to
attach the native surface) — kept out of the core binding on purpose.

- **macOS** (Cocoa/Metal native surface) and **Linux** (Wayland, or X11).
  With the object layer: `instance.create_surface(wayland_display:, wayland_surface:)`,
  `(xlib_display:, xlib_window:)`, `(xcb_connection:, xcb_window:)`,
  `(metal_layer:)`, `(hinstance:, hwnd:)`, `(android_window:)`.
- Requires GLFW: `brew install glfw` (macOS) or `apt install libglfw3-dev` (Linux).
  On Linux, wgpu-native renders through Vulkan.
- `WGPU_FRAMES=N` auto-quits after N frames (used for headless testing).

The render path: GLFW window → native surface (Metal/Wayland) → adapter/device
→ render pipeline → per-frame (acquire texture → render pass → present).

## Tests

```sh
crystal spec
```

Headless (a software Vulkan device such as lavapipe is enough): the specs run
compute shaders, render offscreen and check the pixels, and cover the release,
GC finalization and error paths.

Design notes and the implementation plan of the object layer:
[`docs/plan-object-layer.md`](docs/plan-object-layer.md).

## Architecture

```
scripts/download_wgpu.sh      # fetches wgpu-native (lib + headers + spec)
scripts/generate_bindings.cr  # webgpu.h -> src/wgpu/native.cr (lib LibWGPU)
src/wgpu.cr                   # entry point (require "wgpu")
src/wgpu/native.cr            # generated FFI binding (do not edit)
src/wgpu/link.cr              # generated link flags (do not edit)
src/wgpu/api.cr               # static WGPU.* helpers (+ WGPU::Error classes)
src/wgpu/internal.cr          # shared internals (wait loop, StringView, mapping, error scopes)
src/wgpu/objects/             # object layer (GPUObject base, Instance, Device, Buffer…)
examples/compute_oo.cr        # GPU compute, object layer
examples/compute_wrapped.cr   # GPU compute, static helpers
examples/compute.cr          # GPU compute, raw FFI (headless)
examples/triangle_oo.cr       # windowed render, object layer
examples/triangle.cr         # windowed render, raw FFI (GLFW, macOS/Linux)
examples/lib_glfw.cr         # GLFW + platform glue for the window example
vendor/wgpu-native/           # downloaded artifacts (gitignored)
```

The generator parses the C header directly (it is regular and itself
generated): it extracts handles, enums, bitflags, callbacks, structs and
functions, then emits a `lib LibWGPU` whose memory layout matches the C ABI
exactly.

## macOS / linker note

Some Homebrew installs ship an `lld` whose version does not match `libLLVM`,
which breaks Crystal's default link
(`Symbol not found … llvm::cl::ParseCommandLineOptions`). The binding therefore
forces Apple's system linker (`-fuse-ld=/usr/bin/ld`) in `src/wgpu/link.cr`.
The "clean" system-side fix is `brew reinstall lld` to align the versions.

## License

MIT — see [LICENSE](LICENSE).

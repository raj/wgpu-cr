# wgpu-cr

**Crystal** bindings for [wgpu-native](https://github.com/gfx-rs/wgpu-native) (the Rust implementation of WebGPU), in the spirit of [wgpu-py](https://github.com/pygfx/wgpu-py).

Like wgpu-py, the project exposes two levels:

| Level | Module | Description |
|-------|--------|-------------|
| Low level (FFI) | `LibWGPU` | 1:1 binding to the WebGPU C API, **generated automatically** from `webgpu.h`. |
| High level | `WGPU` | Idiomatic helpers (StringView, synchronous adapter/device requests, buffer mapping…). |

## Status

✅ Working today:
- Automatic download of wgpu-native (lib + headers + spec).
- Full FFI binding generation: **199 functions, 92 structs, 54 enums, 5 bitflags, 23 handles, 10 callbacks**.
- End-to-end **compute** (tested: a WGSL shader doubling an array on the GPU).
- **Windowed rendering** — a triangle in a GLFW window via a Metal surface (macOS).
- Adapter/device requests and buffer mapping (C ↔ Crystal callbacks).

🚧 Coming next (wgpu-py parity):
- A complete object layer (`Device#create_buffer`, etc.) on top of the FFI.
- Surfaces on Linux (X11/Wayland) and Windows (HWND) — structs are bound, examples pending.
- Render helpers (vertex buffers, textures, samplers, depth).
- Bindings for the native `wgpu.h` extensions (DevicePoll, etc.).

## Requirements

- [Crystal](https://crystal-lang.org) ≥ 1.16
- `curl` and `unzip`

## Installation

```sh
git clone <repo> && cd wgpu-cr
shards install            # triggers the postinstall (download_wgpu.sh)
```

Or manually:

```sh
./scripts/download_wgpu.sh            # latest wgpu-native release
crystal run scripts/generate_bindings.cr
```

### Downloading wgpu-native

The script detects the OS/architecture, fetches the right release and installs
`vendor/wgpu-native/` (lib + headers + `webgpu.yml`), then writes the link flags
into `src/wgpu/link.cr`.

```sh
./scripts/download_wgpu.sh                 # latest version
./scripts/download_wgpu.sh v29.0.0.0       # pinned version
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

## Example — compute

```sh
crystal run examples/compute.cr
```

```
wgpu-cr 0.1.0 (wgpu-native v29.0.0.0)
Input  : 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, … (256 elements)
Output : 0.0, 2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, …
✅ GPU computation correct (each element × 2)
```

See [`examples/compute.cr`](examples/compute.cr) for the full pipeline:
instance → adapter → device → buffer → WGSL shader → pipeline → bind group →
dispatch → copy → mapping → read back.

## Example — triangle in a window

```sh
crystal run examples/triangle.cr
```

Opens a GLFW window and renders a triangle. The windowing glue lives in
[`examples/lib_glfw.cr`](examples/lib_glfw.cr) (GLFW + a few Objective-C calls
to attach a `CAMetalLayer`) — kept out of the core binding on purpose.

- **macOS only** for now (Cocoa/Metal native surface). Linux (X11/Wayland) and
  Windows (HWND) surfaces are bound in `LibWGPU` but not yet wired into an example.
- Requires GLFW: `brew install glfw`.
- `WGPU_FRAMES=N` auto-quits after N frames (used for headless testing).

The render path: GLFW window → Metal surface → adapter/device → render pipeline
→ per-frame (acquire texture → render pass → present).

## Tests

```sh
crystal spec
```

## Architecture

```
scripts/download_wgpu.sh      # fetches wgpu-native (lib + headers + spec)
scripts/generate_bindings.cr  # webgpu.h -> src/wgpu/native.cr (lib LibWGPU)
src/wgpu.cr                   # entry point (require "wgpu")
src/wgpu/native.cr            # generated FFI binding (do not edit)
src/wgpu/link.cr              # generated link flags (do not edit)
src/wgpu/api.cr               # idiomatic WGPU layer
examples/compute.cr          # GPU compute (headless)
examples/triangle.cr         # windowed render (GLFW, macOS)
examples/lib_glfw.cr         # GLFW + Objective-C glue for the window example
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

MIT

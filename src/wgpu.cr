# wgpu — Crystal bindings for wgpu-native (WebGPU), inspired by wgpu-py.
#
#   require "wgpu"
#
# Two API levels:
#   * `LibWGPU`    — raw FFI binding generated from webgpu.h (1:1 with the C).
#   * `WGPU`       — idiomatic helpers (StringView, synchronous requests…).
require "./wgpu/native"
require "./wgpu/api"

module WGPU
  VERSION = "0.1.0"

  # Version of wgpu-native the binding was generated against
  # (read at compile time from vendor/wgpu-native/VERSION).
  NATIVE_VERSION = {% if v = read_file?("#{__DIR__}/../vendor/wgpu-native/VERSION") %}{{ v.strip }}{% else %}"unknown"{% end %}
end

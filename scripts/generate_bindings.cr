# Crystal FFI bindings generator for wgpu-native.
#
# Reads the C header `vendor/wgpu-native/include/webgpu/webgpu.h` (the ABI
# source of truth) and emits `src/wgpu/native.cr` containing `lib LibWGPU`.
#
# Usage : crystal run scripts/generate_bindings.cr
#         (or: shards run wgpu-gen)
#
# The header is regular and machine-generated: we don't need a real C
# preprocessor. We strip comments + attribute macros, then parse each
# construct with a regular expression.

ROOT    = File.expand_path("..", __DIR__)
HEADER  = File.join(ROOT, "vendor", "wgpu-native", "include", "webgpu", "webgpu.h")
OUT     = File.join(ROOT, "src", "wgpu", "native.cr")
VERSION = (v = File.join(ROOT, "vendor", "wgpu-native", "VERSION")) && File.exists?(v) ? File.read(v).strip : "unknown"

abort "Header not found: #{HEADER}\nRun scripts/download_wgpu.sh first" unless File.exists?(HEADER)

# Crystal keywords that are forbidden as field identifiers.
KEYWORDS = %w[
  abstract alias as begin break case class def do else elsif end ensure enum
  extend false for fun if in include is_a lib macro module next nil of out
  pointerof private protected require rescue return select self sizeof struct
  super then true type typeof uninitialized union unless until verbatim when
  while with yield offsetof annotation asm instance_sizeof
].to_set

# Primitive C types -> Crystal types.
BASE_TYPES = {
  "void"     => "Void",
  "char"     => "LibC::Char",
  "float"    => "Float32",
  "double"   => "Float64",
  "uint8_t"  => "UInt8",
  "uint16_t" => "UInt16",
  "uint32_t" => "UInt32",
  "uint64_t" => "UInt64",
  "int8_t"   => "Int8",
  "int16_t"  => "Int16",
  "int32_t"  => "Int32",
  "int64_t"  => "Int64",
  "size_t"   => "LibC::SizeT",
  "int"      => "LibC::Int",
}

# --- Cleanup ----------------------------------------------------------------

src = File.read(HEADER)
# Block comments then line comments.
src = src.gsub(/\/\*.*?\*\//m, " ")
src = src.gsub(/\/\/[^\n]*/, " ")
# Attribute macros and qualifiers with no effect on the Crystal ABI.
%w[WGPU_NULLABLE WGPU_OBJECT_ATTRIBUTE WGPU_ENUM_ATTRIBUTE WGPU_STRUCTURE_ATTRIBUTE
  WGPU_FUNCTION_ATTRIBUTE WGPU_EXPORT].each do |m|
  src = src.gsub(/\b#{m}\b/, " ")
end

# --- Helpers ----------------------------------------------------------------

# camelCase / PascalCase -> snake_case (handles acronyms: GPUDevice -> gpu_device).
def snake(s : String) : String
  s.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
    .gsub(/([a-z0-9])([A-Z])/, "\\1_\\2")
    .downcase
end

# Crystal type name from a C name (strips the WGPU prefix).
def type_name(c : String) : String
  n = c.lchop("WGPU")
  case n
  when "Bool"  then "Bool" # alias defined inside the lib
  when "Flags" then "Flags"
  when "Proc"  then "ProcFn" # avoid clashing with Crystal's ::Proc
  else              n
  end
end

# Maps a C type (already stripped of comments) to the Crystal type.
def map_type(raw : String) : String
  t = raw.strip
  t = t.gsub(/\bconst\b/, " ").gsub(/\bstruct\b/, " ").gsub(/\benum\b/, " ")
  stars = t.count('*')
  t = t.delete('*').strip.gsub(/\s+/, " ")

  base =
    if BASE_TYPES.has_key?(t)
      BASE_TYPES[t]
    elsif t.starts_with?("WGPU")
      type_name(t)
    elsif t.empty?
      "Void"
    else
      # unknown type: pass it through as-is (will be flagged at compile time).
      t
    end

  # `void*` becomes Pointer(Void); otherwise we stack the pointers.
  stars.times { base = "Pointer(#{base})" }
  base
end

# Safe Crystal field identifier.
def field_name(c : String) : String
  n = snake(c)
  n = "_#{n}" if n =~ /^[0-9]/
  n = "#{n}_" if KEYWORDS.includes?(n)
  n
end

# Valid Crystal enum member (constants cannot start with a digit).
def enum_member(name : String) : String
  name =~ /^[0-9]/ ? "N#{name}" : name
end

# --- Collection -------------------------------------------------------------

handles = [] of String # opaque type names
enums = [] of {String, Array({String, String})}
flags = [] of {String, Array({String, String})}
callbacks = [] of {String, String, String} # name, raw params, raw return
structs = [] of {String, Array({String, String})}
funcs = [] of {String, String, String, String} # crystal_name, c_name, params, ret

# Opaque handles: typedef struct XImpl* WGPUX;
src.scan(/typedef\s+struct\s+\w+Impl\s*\*\s*(WGPU\w+)\s*;/) do |m|
  handles << type_name(m[1])
end

# Special base typedefs.
bool_alias = src.matches?(/typedef\s+uint32_t\s+WGPUBool\s*;/)
flags_alias = src.matches?(/typedef\s+uint64_t\s+WGPUFlags\s*;/)

# Enums: typedef enum WGPUName { ... } WGPUName;
src.scan(/typedef\s+enum\s+(WGPU\w+)\s*\{(.*?)\}\s*WGPU\w+\s*;/m) do |m|
  cname = m[1]
  entries = [] of {String, String}
  m[2].scan(/#{Regex.escape(cname)}_(\w+)\s*=\s*(0x[0-9A-Fa-f]+|\d+)/) do |e|
    entries << {enum_member(e[1]), e[2]}
  end
  enums << {type_name(cname), entries}
end

# Bitflags: typedef WGPUFlags WGPUName; + static const WGPUName WGPUName_X = 0x..;
src.scan(/typedef\s+WGPUFlags\s+(WGPU\w+)\s*;/) do |m|
  cname = m[1]
  entries = [] of {String, String}
  src.scan(/static\s+const\s+#{Regex.escape(cname)}\s+#{Regex.escape(cname)}_(\w+)\s*=\s*(0x[0-9A-Fa-f]+)/) do |e|
    entries << {enum_member(e[1]), e[2]}
  end
  flags << {type_name(cname), entries}
end

# Callbacks: typedef RET (*WGPUName)(PARAMS);
# We skip the `WGPUProc*` typedefs (Dawn-style dispatch table, unused here).
src.scan(/typedef\s+([\w\s]+?\**)\s*\(\s*\*\s*(WGPU\w+)\s*\)\s*\((.*?)\)\s*;/m) do |m|
  next if m[2].starts_with?("WGPUProc")
  callbacks << {type_name(m[2]), m[3], m[1]}
end

# Structs: typedef struct WGPUName { FIELDS } WGPUName;
src.scan(/typedef\s+struct\s+(WGPU\w+)\s*\{(.*?)\}\s*WGPU\w+\s*;/m) do |m|
  cname = m[1]
  fields = [] of {String, String}
  m[2].split(';').each do |raw|
    decl = raw.strip.gsub(/\s+/, " ")
    next if decl.empty?
    # decl = "<type tokens...> <name>" (no arrays: verified against webgpu.h)
    if md = decl.match(/^(.*?)(\w+)$/)
      type_part = md[1]
      name_part = md[2]
      fields << {field_name(name_part), map_type(type_part)}
    end
  end
  structs << {type_name(cname), fields}
end

# Functions: RET wgpuName(PARAMS);
src.scan(/(?<![\w*])([\w\s]+?\**)\s+(wgpu\w+)\s*\((.*?)\)\s*;/m) do |m|
  ret = m[1]
  cname = m[2]
  params = m[3]
  cryname = snake(cname.lchop("wgpu"))
  cryname = "#{cryname}_" if KEYWORDS.includes?(cryname)
  funcs << {cryname, cname, params, ret}
end

# Splits a C parameter list at top-level commas and maps each type.
def map_params(raw : String) : String
  raw = raw.strip
  return "" if raw.empty? || raw == "void"
  parts = [] of String
  raw.split(',').each do |p|
    p = p.strip
    next if p.empty?
    # keep only the type: "TYPE name" -> drop the trailing identifier
    if md = p.match(/^(.*?)(\w+)$/m)
      type_part = md[1].strip
      type_part = p if type_part.empty? # e.g. "void"
      parts << map_type(type_part)
    else
      parts << map_type(p)
    end
  end
  parts.join(", ")
end

# --- Emission ---------------------------------------------------------------

io = String::Builder.new
io << <<-HEADER
# ====================================================================
# GENERATED by scripts/generate_bindings.cr — DO NOT EDIT.
# Source: wgpu-native #{VERSION} (webgpu.h)
# Regenerate: crystal run scripts/generate_bindings.cr
# ====================================================================
require "./link"

lib LibWGPU
  alias Bool  = UInt32
  alias Flags = UInt64
  alias ProcFn = -> Void


HEADER

io << "  # --- Opaque handles ---\n"
handles.sort.each { |h| io << "  type #{h} = Void*\n" }
io << "\n"

io << "  # --- Enums ---\n"
enums.each do |name, entries|
  io << "  enum #{name}\n"
  entries.each { |mname, val| io << "    #{mname} = #{val}\n" }
  io << "  end\n\n"
end

io << "  # --- Bitflags (WGPUFlags = UInt64) ---\n"
flags.each do |name, entries|
  io << "  @[Flags]\n"
  io << "  enum #{name} : UInt64\n"
  entries.each { |mname, val| io << "    #{mname} = #{val}\n" }
  io << "  end\n\n"
end

io << "  # --- Callbacks ---\n"
callbacks.each do |name, params, ret|
  mp = map_params(params)
  rt = map_type(ret)
  rt_part = rt == "Void" ? "Void" : rt
  io << "  alias #{name} = (#{mp}) -> #{rt_part}\n"
end
io << "\n"

io << "  # --- Structs ---\n"
structs.each do |name, fields|
  if fields.empty?
    io << "  struct #{name}\n    _unused : UInt8\n  end\n\n"
  else
    io << "  struct #{name}\n"
    fields.each { |fname, ftype| io << "    #{fname} : #{ftype}\n" }
    io << "  end\n\n"
  end
end

io << "  # --- Functions ---\n"
funcs.each do |cryname, cname, params, ret|
  mp = map_params(params)
  rt = map_type(ret)
  io << "  fun #{cryname} = #{cname}(#{mp}) : #{rt}\n"
end

io << "end\n"

Dir.mkdir_p(File.dirname(OUT))
File.write(OUT, io.to_s)

puts "Generated #{OUT}"
puts "  handles:   #{handles.size}"
puts "  enums:     #{enums.size}"
puts "  bitflags:  #{flags.size}"
puts "  callbacks: #{callbacks.size}"
puts "  structs:   #{structs.size}"
puts "  functions: #{funcs.size}"

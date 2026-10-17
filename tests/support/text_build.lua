-- Encoder for the documented Gen 6 text file format (test-only; the plugin only decodes).
-- Layout: header (u16 sections=1, u16 lines, u32 total, u32 key=0, u32 sdo=0x10), at sdo a u32
-- section length, an 8-byte table entry per line (i32 offset from sdo, i16 length, 2 pad), then the
-- lines: UTF-16LE words xor key, key = rotl16(key, 3), key(i) = 0x7C89 + i * 0x2983.
local formats = require("formats")
local M = {}

-- UTF-8 string -> list of UTF-16 code units
function M.units(s)
  local out = {}
  for _, c in utf8.codes(s) do
    if c >= 0x10000 then
      c = c - 0x10000
      out[#out + 1] = 0xD800 + (c >> 10)
      out[#out + 1] = 0xDC00 + (c & 0x3FF)
    else
      out[#out + 1] = c
    end
  end
  return out
end

-- A variable: 0x0010, count (code + args), code, args...
function M.var(code, ...)
  local args = { ... }
  local u = { 0x0010, 1 + #args, code }
  for _, a in ipairs(args) do u[#u + 1] = a end
  return u
end

-- lines: strings, or lists of parts (string | list of units)
function M.build(lines)
  local count = #lines
  local data, offs, lens = {}, {}, {}
  local pos = 4 + count * 8
  for i, line in ipairs(lines) do
    local units = {}
    if type(line) == "string" then
      units = M.units(line)
    else
      for _, part in ipairs(line) do
        for _, u in ipairs(type(part) == "string" and M.units(part) or part) do units[#units + 1] = u end
      end
    end
    units[#units + 1] = 0
    local key = (0x7C89 + (i - 1) * 0x2983) & 0xFFFF
    local words = {}
    for j, u in ipairs(units) do
      words[j] = string.pack("<I2", u ~ key)
      key = ((key << 3) | (key >> 13)) & 0xFFFF
    end
    data[i] = table.concat(words)
    offs[i], lens[i] = pos, #units
    pos = pos + #data[i]
  end
  local total = pos
  local tbl = {}
  for i = 1, count do tbl[i] = string.pack("<i4i2", offs[i], lens[i]) .. "\0\0" end
  return string.pack("<I2I2I4I4I4", 1, count, total, 0, 0x10) .. string.pack("<I4", total)
    .. table.concat(tbl) .. table.concat(data)
end

-- A gametext GARC: by_index[file index] = text file data (default: junk), 120 entries.
function M.garc(by_index)
  local files = {}
  for i = 0, 119 do files[i + 1] = by_index[i] or "junk" end
  return formats.garc(files)
end

return M

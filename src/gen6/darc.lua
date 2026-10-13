-- Parser for DARC archives (3DS UI archives), read-only, bounds-checked.
-- Format (3dbrew "DARC"): header "darc", u16 BOM, u16 header size (0x1C), u32 version,
-- u32 file size, u32 file table offset, u32 file table length, u32 data offset.
-- File table: 12-byte entries {u32 flags<<24 | name offset, u32 a, u32 b}; flag 1 =
-- directory (a = parent index, b = index after its last descendant), else file
-- (a = data offset from file start, b = length). Entry 0 is the root and its b is
-- the entry count. Names (UTF-16LE, zero terminated) start behind the entry table.
local M = {}

M.MAX_ENTRIES = 4096

local function name_at(s, base, off)
  local pos, chars = base + off + 1, {}
  while #chars < 128 do
    if pos + 1 > #s then return nil end
    local c = string.unpack("<I2", s, pos)
    if c == 0 then break end
    chars[#chars + 1] = c < 128 and string.char(c) or "?"
    pos = pos + 2
  end
  return table.concat(chars)
end

-- Returns an array of { path, offset, length } (offset 0-based) or nil, message.
function M.parse(s)
  if type(s) ~= "string" or #s < 0x1C or s:sub(1, 4) ~= "darc" then return nil, "not a darc" end
  local tbl_off, tbl_len = string.unpack("<I4I4", s, 0x11)
  if tbl_off < 0x1C or tbl_off + 12 > #s or tbl_off + tbl_len > #s then return nil, "bad table" end
  local count = string.unpack("<I4", s, tbl_off + 8 + 1)
  if count < 1 or count > M.MAX_ENTRIES or tbl_off + count * 12 > #s then return nil, "bad count" end
  local names = tbl_off + count * 12
  local out, stack = {}, {}
  for i = 1, count - 1 do
    local nf, a, b = string.unpack("<I4I4I4", s, tbl_off + i * 12 + 1)
    while #stack > 0 and i >= stack[#stack].last do stack[#stack] = nil end
    local name = name_at(s, names, nf & 0xFFFFFF)
    if not name then return nil, "bad name" end
    if (nf >> 24) == 1 then
      if b <= i or b > count or #stack >= 16 then return nil, "bad directory" end
      stack[#stack + 1] = { name = name, last = b }
    else
      if a + b > #s then return nil, "bad file" end
      local parts = {}
      for _, d in ipairs(stack) do parts[#parts + 1] = d.name end
      parts[#parts + 1] = name
      out[#out + 1] = { path = table.concat(parts, "/"), offset = a, length = b }
    end
  end
  return out
end

return M

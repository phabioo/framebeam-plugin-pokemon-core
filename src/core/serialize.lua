-- Deterministic serialization (sorted keys), used to compare values for changes.
local M = {}

local function ser(v, out)
  local t = type(v)
  if t == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta < tb end
      return a < b
    end)
    out[#out + 1] = "{"
    for _, k in ipairs(keys) do
      out[#out + 1] = type(k) == "string" and string.format("%q", k) or tostring(k)
      out[#out + 1] = "="
      ser(v[k], out)
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
  elseif t == "string" then
    out[#out + 1] = string.format("%q", v)
  else
    out[#out + 1] = tostring(v)
  end
end

function M.serialize(v)
  local out = {}
  ser(v, out)
  return table.concat(out)
end

return M

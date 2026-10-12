-- Tiny test helpers.
local t = { passed = 0, failed = 0, skipped = 0, file = "?" }

local function show(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. show(v[k]) end
    return "{" .. table.concat(out, ", ") .. "}"
  end
  return tostring(v)
end

local function equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

function t.eq(actual, expected, msg)
  if not equal(actual, expected) then
    error((msg and (msg .. ": ") or "") .. "expected " .. show(expected) .. ", got " .. show(actual), 2)
  end
end

function t.ok(v, msg)
  if not v then error(msg or "expected truthy value", 2) end
end

function t.case(name, fn)
  local ok, err = pcall(fn)
  if ok then
    t.passed = t.passed + 1
  else
    t.failed = t.failed + 1
    print(string.format("FAIL %s: %s: %s", t.file, name, tostring(err)))
  end
end

function t.skip(reason)
  t.skipped = t.skipped + 1
  print(string.format("SKIP %s: %s", t.file, reason))
end

return t

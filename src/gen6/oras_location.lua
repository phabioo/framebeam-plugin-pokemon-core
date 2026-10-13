-- Current zone id of Omega Ruby / Alpha Sapphire, read from emulator memory.
-- The RAM address is not known yet: ZONE_ADDR is empty until a local probe finds
-- it. Meanwhile an address (hex) can be set without a release in the plugin
-- cache file config/zone_addr.txt (read once at attach; reload the plugin).
local M = {}

-- Fill from local probe, keyed by revision name of gen6.oras (rev2, rev0_1).
-- Value: virtual address of the u16 zone id.
M.ZONE_ADDR = {}
M.OVERRIDE_FILE = "config/zone_addr.txt"

-- "0x08C12345" or "08C12345" -> integer; nil when not a nonzero 32 bit hex number.
function M.parse_addr(s)
  if type(s) ~= "string" then return nil end
  local h = s:match("^%s*0[xX](%x+)%s*$") or s:match("^%s*(%x+)%s*$")
  if not h or #h > 8 then return nil end
  local n = tonumber(h, 16)
  if not n or n == 0 then return nil end
  return n
end

function M.new(fb)
  local self = {}
  local override
  if fb.cache and fb.cache.read then
    local ok, v = pcall(fb.cache.read, M.OVERRIDE_FILE)
    if ok then override = M.parse_addr(v) end
  end

  if override then fb.memory.watch("oras.zone", override, 2) end
  for rev, addr in pairs(M.ZONE_ADDR) do fb.memory.watch("oras." .. rev .. ".zone", addr, 2) end

  -- Address for a revision (nil = revision unknown); the override wins.
  function self.address(rev)
    if override then return override end
    if rev then return M.ZONE_ADDR[rev] end
    return nil
  end

  -- True when some address could apply (override, or any table entry).
  function self.configured()
    return override ~= nil or next(M.ZONE_ADDR) ~= nil
  end

  -- { zone = u16, source = "memory" } or nil, "unsupported" | "not_ready"
  function self.zone(rev)
    if not self.configured() then return nil, "unsupported" end
    local addr = self.address(rev)
    if not addr then return nil, "not_ready" end
    local z = fb.memory.u16(addr)
    if z == nil then return nil, "not_ready" end
    return { zone = z, source = "memory" }
  end

  return self
end

return M

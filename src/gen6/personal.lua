-- Growth rate per species, read at runtime from the user's own game files
-- (RomFS personal GARC). Nothing from the game is shipped or persisted; the
-- values live in a Lua table cache only.
--
-- ORAS personal data (community-documented, all to verify locally):
--   path  : candidates "/a/1/9/5" and "/a/1/9/6", tried in order; the first one
--           whose data validates as a personal table is used (see validate)
--   entry : 0x50 bytes per species (PKHeX PersonalInfoORAS), index = Dex number
--   growth: byte 0x15 of the entry (PersonalInfoORAS.EXPGrowth), values 0..5
-- Accepted shapes: one file with length % 0x50 == 0 and >= 722 entries, or
-- >= 722 files of 0x50 bytes (file species + 1 is the entry of that species).
local M = {}

M.CANDIDATE_PATHS = { "/a/1/9/5", "/a/1/9/6" }
M.ENTRY_SIZE = 0x50
M.GROWTH_OFFSET = 0x15
M.MIN_ENTRIES = 722 -- species 0..721
M.MAX_ATTEMPTS = 3

function M.new(fb, opts)
  opts = opts or {}
  local paths = opts.paths or M.CANDIDATE_PATHS
  local esize = opts.entry_size or M.ENTRY_SIZE
  local goff = opts.growth_offset or M.GROWTH_OFFSET
  local self = {}
  local rates, attempts = nil, 0

  -- Returns a table species -> rate (1..721) or nil when data is not a personal table.
  local function validate(data)
    local g = fb.codec.garc(data)
    if type(g) ~= "table" or type(g.count) ~= "number" then return nil end
    local out = {}
    if g.count == 1 then
      local whole = fb.codec.garc_file(data, 1, 1)
      if type(whole) ~= "string" or #whole % esize ~= 0 or #whole // esize < M.MIN_ENTRIES then
        return nil
      end
      for s = 1, M.MIN_ENTRIES - 1 do
        local r = whole:byte(s * esize + goff + 1)
        if not r or r > 5 then return nil end
        out[s] = r
      end
    elseif g.count >= M.MIN_ENTRIES then
      for s = 1, M.MIN_ENTRIES - 1 do
        local e = fb.codec.garc_file(data, s + 1, 1)
        if type(e) ~= "string" or #e ~= esize then return nil end
        local r = e:byte(goff + 1)
        if r > 5 then return nil end
        out[s] = r
      end
    else
      return nil
    end
    return out
  end

  local function load()
    if rates then return true end
    if attempts >= M.MAX_ATTEMPTS then return false end
    attempts = attempts + 1
    if not (fb and fb.rom and fb.rom.romfs and fb.codec and fb.codec.garc and fb.codec.garc_file) then
      return false
    end
    for _, path in ipairs(paths) do
      local data = fb.rom.romfs(path)
      if type(data) == "string" then
        local r = validate(data)
        if r then
          rates = r
          self.path = path
          if fb.log and fb.log.info then fb.log.info("personal data accepted at " .. path) end
          return true
        end
      end
    end
    return false
  end

  -- Growth rate 0..5 for a species (Dex number 1..721), or nil.
  function self.growth_rate(species)
    if math.type(species) ~= "integer" or species < 1 then return nil end
    if not load() then return nil end
    return rates[species]
  end

  -- Forget failures and cached values (e.g. after a game change).
  function self.reset()
    rates, attempts, self.path = nil, 0, nil
  end

  return self
end

return M

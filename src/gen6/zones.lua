-- Zones and encounter areas of Omega Ruby / Alpha Sapphire, read at runtime from the player's
-- own RomFS (encdata GARC /a/0/1/3). Entries are classified by content, not by index:
-- first byte 0x11 = LZ11 (decompress); "ZO" mini pack = one zone; "EN" mini pack = encounter copy
-- (ignored); no magic and size divisible by 0x38 = zonedata table.
-- Formats: pk3DS RSWE.cs / OWSEStructs.cs / mini.cs (docs/games/omega-ruby-alpha-sapphire.md).
-- Scanning is a step-wise state machine (a bounded batch of entries per step). Only derived
-- numbers are kept, in memory; no names (names come from the game text).
local M = {}

M.GARC_PATH = "/a/0/1/3"
M.ZONE_RECORD = 0x38
M.LOCATION_OFFSET = 0x1C   -- u16, low 10 bits = location name index
M.LOCATION_MASK = 0x3FF
M.ENC_FILE = 4             -- ZO sub-file [3] (1-based 4) holds the wild encounters
M.ENC_OFFSET = 0x0E        -- ORAS: slots start 0x0E into the sub-file
M.ENC_MIN = 0xF6           -- ORAS: shorter than this means no encounter table
M.ENC_BYTES = 0xF4         -- 61 slots x 4 bytes
M.MAX_SPECIES = 721
M.ENTRIES_PER_STEP = 8
M.MAX_ENTRIES = 2000
M.MAX_LZ_OUTPUT = 4 * 1024 * 1024

-- slot groups in file order; horde A/B/C are merged into "horde"
M.GROUPS = {
  { "grass", 12 }, { "tall_grass", 12 }, { "swarm", 3 }, { "surf", 5 }, { "rock_smash", 5 },
  { "old_rod", 3 }, { "good_rod", 3 }, { "super_rod", 3 }, { "horde", 5 }, { "horde", 5 }, { "horde", 5 },
}

-- Mini pack: 2-byte magic, u16 count, (count + 1) u32 offsets. Returns the sub-file list
-- { {first, last}, ... } (1-based inclusive) or nil.
function M.mini(data, magic)
  if #data < 8 or data:sub(1, 2) ~= magic then return nil end
  local count = string.unpack("<I2", data, 3)
  if count > 64 or 4 + (count + 1) * 4 > #data then return nil end
  local offs = {}
  for i = 0, count do offs[i + 1] = string.unpack("<I4", data, 5 + i * 4) end
  local subs = {}
  for i = 1, count do
    local a, b = offs[i], offs[i + 1]
    if a > b or b > #data then return nil end
    subs[i] = { a + 1, b }
  end
  return subs
end

-- 61 encounter slots from the raw 0xF4 bytes -> { grass = { {species, form, min, max}, ... }, ... }
-- (identical entries removed). Returns the table and the number of valid slots.
function M.decode_slots(raw)
  local out, seen, n, pos = {}, {}, 0, 1
  for _, g in ipairs(M.GROUPS) do
    local name = g[1]
    out[name] = out[name] or {}
    seen[name] = seen[name] or {}
    for _ = 1, g[2] do
      local v, lo, hi = string.unpack("<I2I1I1", raw, pos)
      pos = pos + 4
      local species, form = v & 0x7FF, v >> 11
      if species >= 1 and species <= M.MAX_SPECIES then
        n = n + 1
        local key = species .. ":" .. form .. ":" .. lo .. ":" .. hi
        if not seen[name][key] then
          seen[name][key] = true
          out[name][#out[name] + 1] = { species = species, form = form, min = lo, max = hi }
        end
      end
    end
  end
  return out, n
end

-- Classifies one decoded GARC entry. Returns "zo", rec0, enc_raw | "en" | "table", data | nil.
function M.classify(d)
  local magic = d:sub(1, 2)
  if magic == "ZO" then
    local subs = M.mini(d, "ZO")
    if not subs then return nil end
    local rec0, enc
    local s0 = subs[1]
    if s0 and s0[2] - s0[1] + 1 >= M.ZONE_RECORD then rec0 = d:sub(s0[1], s0[1] + M.ZONE_RECORD - 1) end
    if #subs >= 4 then
      local e = subs[M.ENC_FILE]
      local start = e[1] + M.ENC_OFFSET
      local stop = (subs[5] and subs[5][1] or (e[2] + 1)) -- offsets[4]: start of sub-file 5 or end
      if stop - start >= M.ENC_MIN and start + M.ENC_BYTES - 1 <= #d then
        enc = d:sub(start, start + M.ENC_BYTES - 1)
      end
    end
    return "zo", rec0, enc
  elseif magic == "EN" then
    return "en"
  elseif #d > 0 and #d % M.ZONE_RECORD == 0 then
    return "table", d
  end
  return nil
end

local function location_of(rec)
  if not rec or #rec < M.LOCATION_OFFSET + 2 then return nil end
  return string.unpack("<I2", rec, M.LOCATION_OFFSET + 1) & M.LOCATION_MASK
end

-- env.name(kind, id) -> string or nil (optional, for names).
function M.new(fb, env)
  env = env or {}
  local self = {}
  local codec = fb.codec
  local can = fb.rom and fb.rom.romfs and codec and codec.garc and codec.garc_file and true or false
  local state = can and "idle" or "unsupported" -- idle | scan | done | unsupported
  local data, count, nextidx = nil, 0, 1
  local zos, table_data = {}, nil
  local zones, area_list, last_zone = {}, {}, -1

  local function open()
    local d = fb.rom.romfs(M.GARC_PATH)
    if type(d) ~= "string" then
      state = "unsupported"
      if fb.log and fb.log.warn then fb.log.warn("encounter data not found at " .. M.GARC_PATH) end
      return
    end
    local ok, g = pcall(codec.garc, d)
    if not ok or type(g) ~= "table" or type(g.count) ~= "number" or g.count < 1 then
      state = "unsupported"
      return
    end
    data, count, nextidx = d, math.min(g.count, M.MAX_ENTRIES), 1
    state = "scan"
  end

  local function entry(i)
    local e = codec.garc_file(data, i, 1)
    if type(e) ~= "string" or #e == 0 then return nil end
    if e:byte(1) == 0x11 and codec.lz_decompress then
      local ok, out = pcall(codec.lz_decompress, e)
      if not ok or type(out) ~= "string" or #out > M.MAX_LZ_OUTPUT then return nil end
      e = out
    end
    return e
  end

  local function build()
    -- zone id = GARC index (0-based); the ordinal among ZO packs is the alternative. The zonedata
    -- table (record z belongs to zone z) tells which is right: ZO sub-file 1 is a copy of the record.
    local function score(idof)
      if not table_data then return 0 end
      local ok = 0
      for rank, z in ipairs(zos) do
        local id = idof(rank, z)
        local rec = table_data:sub(id * M.ZONE_RECORD + 1, (id + 1) * M.ZONE_RECORD)
        if z.rec0 and #rec == M.ZONE_RECORD and rec == z.rec0 then ok = ok + 1 end
      end
      return ok
    end
    local by_index = function(_, z) return z.gi - 1 end
    local by_rank = function(rank) return rank - 1 end
    local idof, how = by_index, "garc index"
    if table_data and score(by_rank) > score(by_index) then idof, how = by_rank, "ordinal" end
    zones = {}
    local max = -1
    for rank, z in ipairs(zos) do
      local id = idof(rank, z)
      local loc
      if table_data and (id + 1) * M.ZONE_RECORD <= #table_data then
        loc = location_of(table_data:sub(id * M.ZONE_RECORD + 1, (id + 1) * M.ZONE_RECORD))
      end
      loc = loc or location_of(z.rec0)
      zones[id] = { location = loc, enc = z.enc }
      if id > max then max = id end
    end
    last_zone = max
    -- areas: zones with at least one encounter slot, grouped by location name id in zone order
    local by_loc, order = {}, {}
    for id = 0, max do
      local zi = zones[id]
      if zi and zi.enc and zi.location then
        local enc, n = M.decode_slots(zi.enc)
        if n > 0 then
          local a = by_loc[zi.location]
          if not a then
            a = { id = zi.location, zones = {}, encounters = {}, seen = {} }
            by_loc[zi.location] = a
            order[#order + 1] = a
          end
          a.zones[#a.zones + 1] = id
          for kind, list in pairs(enc) do
            local dst = a.encounters[kind]
            if not dst and #list > 0 then dst = {}; a.encounters[kind] = dst; a.seen[kind] = {} end
            for _, e in ipairs(list) do
              local key = e.species .. ":" .. e.form .. ":" .. e.min .. ":" .. e.max
              if not a.seen[kind][key] then a.seen[kind][key] = true; dst[#dst + 1] = e end
            end
          end
        end
      end
    end
    area_list = order
    for _, a in ipairs(area_list) do a.seen = nil end
    zos, table_data, data = {}, nil, nil
    state = "done"
    if fb.log and fb.log.info then
      fb.log.info("zones scanned: " .. #area_list .. " areas, zone ids by " .. how)
    end
  end

  local function advance()
    if state == "idle" then open()
    elseif state == "scan" then
      local last = math.min(nextidx + M.ENTRIES_PER_STEP - 1, count)
      for i = nextidx, last do
        local e = entry(i)
        if e then
          local kind, a, b = M.classify(e)
          if kind == "zo" then zos[#zos + 1] = { gi = i, rec0 = a, enc = b }
          elseif kind == "table" and not table_data then table_data = a end
        end
      end
      nextidx = last + 1
      if nextidx > count then build() end
    end
  end

  -- One bounded step. Never raises.
  function self.step()
    if state == "done" or state == "unsupported" then return end
    local ok, err = pcall(advance)
    if not ok then
      state = "unsupported"
      if fb.log and fb.log.error then fb.log.error("zone scan failed: " .. tostring(err)) end
    end
  end

  function self.state() return state end
  function self.found() return state == "done" and #area_list > 0 end

  local function name_of(loc)
    if env.name and loc then
      local n = env.name("location", loc)
      if type(n) == "string" then return n end
    end
    return nil
  end

  -- { zone, location, name } or nil, "not_ready" | "unsupported" | "unknown_zone"
  function self.zone_info(zone, quiet)
    if state == "unsupported" then return nil, "unsupported" end
    if state ~= "done" then
      if not quiet then self.step() end
      return nil, "not_ready"
    end
    local z = math.type(zone) == "integer" and zones[zone] or nil
    if not z or not z.location then return nil, "unknown_zone" end
    return { zone = zone, location = z.location, name = name_of(z.location) }
  end

  -- List of { id, name, zones, encounters } in game order, or nil, "not_ready" | "unsupported"
  function self.areas()
    if state == "unsupported" then return nil, "unsupported" end
    if state ~= "done" then self.step(); return nil, "not_ready" end
    local out = {}
    for i, a in ipairs(area_list) do
      out[i] = { id = a.id, name = name_of(a.id), zones = a.zones, encounters = a.encounters }
    end
    return out
  end

  return self
end

return M

-- Zones and encounter areas of Omega Ruby / Alpha Sapphire, read at runtime from the player's
-- own RomFS (encdata GARC /a/0/1/3). Entries are classified by content, not by index:
-- first byte 0x11 = LZ11 (decompress); "ZO" mini pack = one zone; "EN" mini pack = encounter copy
-- (ignored); no magic and size divisible by 0x38 = zonedata table.
-- Formats: pk3DS RSWE.cs / OWSEStructs.cs / mini.cs (docs/games/omega-ruby-alpha-sapphire.md).
-- Parsing is lenient: a broken sub-file offset only loses that sub-file, never the whole pack, and the
-- end of the encounter sub-file is the next larger offset (or the end of the pack).
-- Scanning is a step-wise state machine (a bounded batch of entries per step). Only derived
-- numbers are kept, in memory; no names (names come from the game text).
local M = {}

M.GARC_PATH = "/a/0/1/3"
M.ZONE_RECORD = 0x38
M.LOCATION_OFFSET = 0x1C   -- u16, low 10 bits = location name index
M.LOCATION_MASK = 0x3FF
M.ENC_FILE = 4             -- ZO sub-file [3] (1-based 4) holds the wild encounters
M.ENC_OFFSET = 0x0E        -- ORAS: slots start 0x0E into the sub-file
M.ENC_MIN = 0xF4           -- pk3DS tests < 0xF6 on a 0xF6-byte tail; 0xF4 (the slots) is enough here
M.OPEN_RETRIES = 20        -- the archive may not be readable yet
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
-- { {first, last}, ... } (1-based inclusive) and the raw offsets (0-based, count + 1), or nil.
-- Offsets outside the pack or out of order only empty the affected sub-file.
function M.mini(data, magic)
  if #data < 8 or data:sub(1, 2) ~= magic then return nil end
  local count = string.unpack("<I2", data, 3)
  if count > 64 or 4 + (count + 1) * 4 > #data then return nil end
  local offs = {}
  for i = 0, count do offs[i + 1] = string.unpack("<I4", data, 5 + i * 4) end
  local subs = {}
  for i = 1, count do
    local a, b = offs[i], offs[i + 1]
    if a > #data then a = #data end
    if b > #data then b = #data end
    if b < a then b = a end
    subs[i] = { a + 1, b }
  end
  return subs, offs
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

-- Classifies one decoded GARC entry. Returns "zo", rec0, enc_raw, reason | "en" | "table", data |
-- nil, reason. `reason` names why a pack gave no encounter table or was rejected (diagnostics).
function M.classify(d)
  local magic = d:sub(1, 2)
  if magic == "ZO" then
    local subs, offs = M.mini(d, "ZO")
    if not subs then return nil, "zo_bad_header" end
    local rec0, enc, reason
    local s0 = subs[1]
    if s0 and s0[2] - s0[1] + 1 >= M.ZONE_RECORD then rec0 = d:sub(s0[1], s0[1] + M.ZONE_RECORD - 1) end
    if #subs < M.ENC_FILE then
      reason = "zo_few_subfiles"
    else
      local off = offs[M.ENC_FILE]
      local start = off + M.ENC_OFFSET + 1
      local stop = #d + 1 -- exclusive; the next larger offset ends the sub-file
      for j = M.ENC_FILE + 1, #offs do
        if offs[j] > off and offs[j] <= #d and offs[j] + 1 < stop then stop = offs[j] + 1 end
      end
      if stop - start < M.ENC_MIN then
        reason = "enc_too_short"
      elseif start + M.ENC_BYTES - 1 > #d then
        reason = "enc_out_of_range"
      else
        enc = d:sub(start, start + M.ENC_BYTES - 1)
      end
    end
    return "zo", rec0, enc, reason
  elseif magic == "EN" then
    return "en"
  elseif #d > 0 and #d % M.ZONE_RECORD == 0 then
    return "table", d
  end
  return nil, "unknown_entry"
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
  local zones, area_list, loc_list, last_zone = {}, {}, {}, -1
  local open_tries = 0
  local first_reason, ngarc = nil, 0

  local function log(level, msg)
    if fb.log and fb.log[level] then fb.log[level](msg) end
  end

  local function note_reason(r)
    if r and not first_reason then first_reason = r end
  end

  local function open()
    open_tries = open_tries + 1
    local d = fb.rom.romfs(M.GARC_PATH)
    if type(d) ~= "string" then
      if open_tries >= M.OPEN_RETRIES then
        state = "unsupported"
        log("warn", "encounter data not found at " .. M.GARC_PATH)
      end
      return
    end
    local ok, g = pcall(codec.garc, d)
    if not ok or type(g) ~= "table" or type(g.count) ~= "number" or g.count < 1 then
      state = "unsupported"
      log("warn", "encounter data at " .. M.GARC_PATH .. " is not a readable GARC")
      return
    end
    data, count, nextidx, ngarc = d, math.min(g.count, M.MAX_ENTRIES), 1, g.count
    state = "scan"
  end

  local function entry(i)
    local okf, e = pcall(codec.garc_file, data, i, 1)
    if not okf or type(e) ~= "string" or #e == 0 then return nil end
    if e:byte(1) == 0x11 and codec.lz_decompress then
      local ok, out = pcall(codec.lz_decompress, e)
      if not ok or type(out) ~= "string" or #out > M.MAX_LZ_OUTPUT then return nil, "lz_failed" end
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
    local s_index, s_rank = score(by_index), score(by_rank)
    local best = s_index
    if table_data and s_rank > s_index then idof, how, best = by_rank, "ordinal", s_rank end
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
    -- every record of the zonedata table is a zone, also those without a ZO pack (towns);
    -- trusted when it matched the packs (or when there are no packs at all)
    local nrec = table_data and #table_data // M.ZONE_RECORD or 0
    local table_zones = 0
    if nrec > 0 and ((#zos > 0 and best > 0) or (#zos == 0 and nrec >= 100)) then
      for id = 0, nrec - 1 do
        if not zones[id] then
          local rec = table_data:sub(id * M.ZONE_RECORD + 1, (id + 1) * M.ZONE_RECORD)
          if rec:find("[^%z]") then
            zones[id] = { location = location_of(rec) }
            table_zones = table_zones + 1
            if id > max then max = id end
          end
        end
      end
    end
    last_zone = max
    -- areas: zones with at least one encounter slot, grouped by location name id in zone order;
    -- locations: every zone with a location, grouped the same way
    local by_loc, order = {}, {}
    local by_all, all = {}, {}
    local with_enc = 0
    for id = 0, max do
      local zi = zones[id]
      if zi and zi.location then
        local l = by_all[zi.location]
        if not l then
          l = { id = zi.location, zones = {}, has_encounters = false }
          by_all[zi.location] = l
          all[#all + 1] = l
        end
        l.zones[#l.zones + 1] = id
        if zi.enc then
          local enc, n = M.decode_slots(zi.enc)
          if n > 0 then
            with_enc = with_enc + 1
            l.has_encounters = true
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
          else
            note_reason("slots_empty")
          end
        end
      end
    end
    area_list, loc_list = order, all
    for _, a in ipairs(area_list) do a.seen = nil end
    local nzo = #zos
    zos, table_data, data = {}, nil, nil
    state = "done"
    log("info", "zones scanned: " .. ngarc .. " zone files, " .. nzo .. " ZO packs, " .. with_enc ..
      " zones with encounters, " .. #area_list .. " areas, " .. #loc_list .. " locations (" ..
      table_zones .. " zones from the table only), zone ids by " .. how)
    if #area_list == 0 and nzo > 0 then
      log("warn", "no encounter areas although " .. nzo .. " ZO packs were found; first reason: " ..
        tostring(first_reason or "none"))
    end
  end

  local function advance()
    if state == "idle" then open()
    elseif state == "scan" then
      local last = math.min(nextidx + M.ENTRIES_PER_STEP - 1, count)
      for i = nextidx, last do
        local e, why = entry(i)
        if e then
          local kind, a, b, reason = M.classify(e)
          if kind == "zo" then
            zos[#zos + 1] = { gi = i, rec0 = a, enc = b }
            if not b and reason ~= "zo_few_subfiles" then note_reason(reason) end
          elseif kind == "table" then
            if not table_data or #a > #table_data then table_data = a end -- the zonedata table is the largest
          elseif kind == nil then
            note_reason(a)
          end
        else
          note_reason(why)
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
      log("error", "zone scan failed: " .. tostring(err))
    end
  end

  function self.state() return state end
  function self.found() return state == "done" and #area_list > 0 end
  function self.has_locations() return state == "done" and #loc_list > 0 end

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

  -- List of { id, name, zones, has_encounters } of every location with a zone, in zone order, or
  -- nil, "not_ready" | "unsupported"
  function self.locations()
    if state == "unsupported" then return nil, "unsupported" end
    if state ~= "done" then self.step(); return nil, "not_ready" end
    local out = {}
    for i, l in ipairs(loc_list) do
      local zs = {}
      for j, z in ipairs(l.zones) do zs[j] = z end
      out[i] = { id = l.id, name = name_of(l.id), zones = zs, has_encounters = l.has_encounters }
    end
    return out
  end

  return self
end

return M

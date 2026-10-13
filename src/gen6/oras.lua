-- Adapter for Pokemon Omega Ruby / Alpha Sapphire (3DS, Gen 6).
-- Addresses: docs/games/omega-ruby-alpha-sapphire.md. Only team, boxes and
-- revision are backed, plus icon() (gen6.icons) and location() (gen6.oras_location,
-- active only once a zone address is configured); battle/encounters/badges are not implemented.
local pk6 = require("gen6.pk6")
local growth = require("gen6.growth")
local personal = require("gen6.personal")
local icons = require("gen6.icons")
local maps = require("gen6.maps")
local oras_location = require("gen6.oras_location")

local M = {}

M.PARTY_SLOTS = 6
M.PARTY_STRIDE = 0x1E4 -- Rev 2 EUR: member 2 sits at +0x3C8 = 2 x stride; order/stride still open
M.PARTY_SIZE = pk6.SIZE_PARTY
M.BOX_COUNT = 31
M.BOX_SLOTS = 30
M.BOX_SIZE = pk6.SIZE_STORED
M.ICON_START_TICK = 90 -- ticks before icon discovery starts
M.ICON_STEP_EVERY = 8  -- ticks between discovery steps
M.MAP_START_TICK = 120 -- map scan starts later; steps are offset from icon steps
M.MAP_STEP_EVERY = 8 -- steps fall on the odd half of the icon cadence
M.ORIGIN_AS, M.ORIGIN_OR = 26, 27 -- PKHeX GameVersion (X 24, Y 25)

-- Candidate address sets, checked in this order.
M.REVISIONS = {
  { name = "rev2", party = 0x08CF727C, box = 0x08C9A144 },   -- verified: Omega Ruby EUR Rev 2
  { name = "rev0_1", party = 0x08CFB26C, box = 0x08C9E134 }, -- community addresses, unverified
}

local PARTY_LEN = (M.PARTY_SLOTS - 1) * M.PARTY_STRIDE + M.PARTY_SIZE
local BOX_LEN = M.BOX_COUNT * M.BOX_SLOTS * M.BOX_SIZE

local function read_record(fb, addr, size)
  local raw = fb.memory.bytes(addr, size)
  if not raw or #raw < size then return nil end
  if not (fb.codec and fb.codec.pk6_decrypt) then return nil end
  local plain, ok = fb.codec.pk6_decrypt(raw)
  if not plain or not ok then return nil end
  local rec = pk6.parse(plain)
  if not rec or rec.species < 1 or rec.species > pk6.MAX_SPECIES then return nil end
  return rec
end

function M.attach(ctx)
  local fb = ctx.fb
  local pers = personal.new(fb)
  local icon_store = icons.new(fb, pers)
  local zone = oras_location.new(fb)
  local ticks = 0
  local map_store
  local chosen

  for _, set in ipairs(M.REVISIONS) do
    fb.memory.watch("oras." .. set.name .. ".party", set.party, PARTY_LEN)
    fb.memory.watch("oras." .. set.name .. ".box", set.box, BOX_LEN)
  end

  local function detect()
    if chosen then return chosen end
    for _, set in ipairs(M.REVISIONS) do
      if read_record(fb, set.party, M.PARTY_SIZE) then chosen = set; return chosen end
    end
    return nil
  end

  local function finish(rec)
    local rate = pers.growth_rate(rec.species)
    if rate then rec.level = growth.level_from_exp(rate, rec.exp) end
    return rec
  end

  local obj = {}
  map_store = maps.new(fb, ctx.game and ctx.game.id, function() return chosen and chosen.name end)

  function obj:revision()
    local set = detect()
    if not set then return nil, "not_ready" end
    return set.name
  end

  -- Heuristic (no save-block language offset is sourced): the language of the
  -- player's own catches. Party records with origin game AS/OR (PKHeX
  -- GameVersion 26/27) are grouped by OT ID/SID; the largest group (earliest
  -- slot on ties) is taken as the player's and its first member's language
  -- is returned. A Pokemon traded in from another-language OR/AS game can
  -- fool it. nil when there is no such record.
  function obj:language()
    local team = self:team()
    if not team then return nil end
    local groups, order = {}, {}
    for _, r in ipairs(team) do
      if (r.origin_game == M.ORIGIN_AS or r.origin_game == M.ORIGIN_OR) and r.language then
        local key = r.ot_id .. ":" .. r.ot_sid
        if not groups[key] then groups[key] = { n = 0, first = r }; order[#order + 1] = key end
        groups[key].n = groups[key].n + 1
      end
    end
    local best
    for _, key in ipairs(order) do
      if not best or groups[key].n > best.n then best = groups[key] end
    end
    return best and best.first.language or nil
  end

  -- Called every tick by main.lua: spreads icon discovery over many ticks.
  function obj:tick()
    ticks = ticks + 1
    if ticks >= M.MAP_START_TICK and ticks % M.MAP_STEP_EVERY == M.MAP_STEP_EVERY // 2 and map_store.state() ~= "done" then
      map_store.step()
    end
    if ticks >= M.ICON_START_TICK and ticks % M.ICON_STEP_EVERY == 0 and icon_store.state() ~= "done" then
      icon_store.step()
    end
  end

  -- Feature overrides: icons only once the GARC is found, location only with an address.
  function obj:features()
    return { icons = icon_store.found(), location = zone.configured(), map = map_store.found() }
  end

  function obj:icon(species, form)
    return icon_store.icon(species, form)
  end

  function obj:map_candidates() return map_store.candidates() end
  function obj:map_image(id) return map_store.image(id) end
  function obj:map_selected() return map_store.selected() end

  function obj:location()
    return zone.zone(chosen and chosen.name or nil)
  end

  function obj:team()
    local set = detect()
    if not set then return nil, "not_ready" end
    local out = {}
    for i = 1, M.PARTY_SLOTS do
      local rec = read_record(fb, set.party + (i - 1) * M.PARTY_STRIDE, M.PARTY_SIZE)
      if rec then rec.slot = i; out[#out + 1] = finish(rec) end
    end
    return out
  end

  function obj:box_count()
    if not detect() then return nil, "not_ready" end
    return M.BOX_COUNT
  end

  function obj:box(n)
    local set = detect()
    if not set then return nil, "not_ready" end
    if math.type(n) ~= "integer" or n < 1 or n > M.BOX_COUNT then return nil, "out_of_range" end
    local base = set.box + (n - 1) * M.BOX_SLOTS * M.BOX_SIZE
    if not fb.memory.bytes(base, M.BOX_SLOTS * M.BOX_SIZE) then return nil, "not_ready" end
    local out = {}
    for s = 1, M.BOX_SLOTS do
      local rec = read_record(fb, base + (s - 1) * M.BOX_SIZE, M.BOX_SIZE)
      if rec then rec.slot = s; rec.box = n; out[#out + 1] = finish(rec) end
    end
    return out
  end

  return obj
end

return M

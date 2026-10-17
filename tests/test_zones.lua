local t = require("t")
local fb_mock = require("fb_mock")
local formats = require("formats")
local zones = require("gen6.zones")

local function u16(v) return string.pack("<I2", v) end

-- zone record 0x38 with the location name index in the low 10 bits of u16 @0x1C
local function record(loc, hi)
  return string.rep("\0", 0x1C) .. u16((hi or 0) << 10 | loc) .. string.rep("\0", 0x38 - 0x1E)
end

-- 61 slots from { {group, index(1-based inside group), species, form, min, max}, ... }
local function slots(list)
  local starts, pos = {}, 0
  local order = { "grass", "tall_grass", "swarm", "surf", "rock_smash", "old_rod", "good_rod", "super_rod", "hordeA", "hordeB", "hordeC" }
  local sizes = { 12, 12, 3, 5, 5, 3, 3, 3, 5, 5, 5 }
  for i, g in ipairs(order) do starts[g] = pos; pos = pos + sizes[i] end
  local b = {}
  for i = 1, 61 do b[i] = string.pack("<I2I1I1", 0, 0, 0) end
  for _, s in ipairs(list) do
    b[starts[s[1]] + s[2]] = string.pack("<I2I1I1", s[3] | ((s[4] or 0) << 11), s[5], s[6])
  end
  return table.concat(b)
end

local function pack(magic, subs)
  local n = #subs
  local head = magic .. u16(n)
  local off = 4 + (n + 1) * 4
  local offs, body = {}, {}
  for i = 1, n do offs[i] = string.pack("<I4", off); body[i] = subs[i]; off = off + #subs[i] end
  offs[n + 1] = string.pack("<I4", off)
  return head .. table.concat(offs) .. table.concat(body)
end

-- ORAS ZO pack: [0] zone record, [1] entities, [2] script, [3] encounters, [4] unknown
local function zo(loc, enc)
  local e
  if enc then e = string.rep("\1", 0x0E) .. slots(enc) .. "\0\0" else e = string.rep("\2", 0x10) end
  return pack("ZO", { record(loc), string.rep("e", 8), string.rep("s", 4), e, string.rep("u", 4) })
end

local function world(opts)
  opts = opts or {}
  local z = {
    zo(10, { { "grass", 1, 25, 0, 3, 5 }, { "grass", 2, 25, 0, 3, 5 }, { "grass", 3, 16, 0, 2, 3 } }), -- zone 0
    zo(10, { { "surf", 1, 7, 0, 20, 30 } }),                                    -- zone 1, same location
    zo(20),                                                                     -- zone 2, town
    zo(30, { { "hordeA", 1, 19, 0, 10, 12 }, { "hordeB", 1, 19, 0, 10, 12 }, { "hordeC", 2, 19, 1, 10, 12 } }), -- zone 3
    pack("ZO", { record(12), "a", "b" }),                                       -- zone 4: too few sub-files
    zo(30, { { "old_rod", 1, 129, 0, 5, 10 }, { "tall_grass", 3, 722, 0, 1, 1 }, { "super_rod", 1, 0, 0, 9, 9 } }), -- zone 5
  }
  local table_data = {}
  local locs = { 10, 10, 20, 30, 12, 30 }
  for i, l in ipairs(locs) do table_data[i] = record(l) end
  local entries = {}
  for i, d in ipairs(z) do entries[i] = (i % 2 == 1) and formats.lz11_literal(d) or d end
  local tbl, en = table.concat(table_data), pack("EN", { "copy", "copy2" })
  if opts.table_first then
    table.insert(entries, 1, en); table.insert(entries, 1, tbl)
  else
    entries[#entries + 1] = tbl; entries[#entries + 1] = en
  end
  return { ["/a/0/1/3"] = formats.garc(entries) }
end

local function make(romfs, names)
  local mock = fb_mock.new({ game = { system = "3ds" }, codec = formats.fake_codec(), i18n_dir = "plugin/i18n", romfs = romfs })
  local reads, fileCalls = 0, 0
  local ro, gf = mock.fb.rom.romfs, mock.fb.codec.garc_file
  mock.fb.rom.romfs = function(p) reads = reads + 1; return ro(p) end
  local store = zones.new(mock.fb, { name = function(kind, id) return names and names[id] end })
  local peak = 0
  mock.fb.codec.garc_file = function(...) fileCalls = fileCalls + 1; return gf(...) end
  local function run()
    for _ = 1, 100 do
      if store.state() == "done" or store.state() == "unsupported" then return end
      fileCalls = 0
      store.step()
      peak = math.max(peak, fileCalls)
    end
  end
  return store, mock, run, function() return reads, peak end
end

t.case("slot decoding: groups, form bits, dedup, species range", function()
  local out, n = zones.decode_slots(slots({
    { "grass", 1, 25, 0, 3, 5 }, { "grass", 2, 25, 0, 3, 5 }, { "grass", 3, 25, 0, 3, 6 },
    { "surf", 5, 7, 2, 1, 2 }, { "hordeA", 1, 19, 0, 10, 12 }, { "hordeC", 5, 19, 0, 10, 12 },
    { "grass", 4, 722, 0, 1, 1 },
  }))
  t.eq(n, 6)
  t.eq(out.grass, { { species = 25, form = 0, min = 3, max = 5 }, { species = 25, form = 0, min = 3, max = 6 } })
  t.eq(out.surf, { { species = 7, form = 2, min = 1, max = 2 } })
  t.eq(out.horde, { { species = 19, form = 0, min = 10, max = 12 } })
  t.eq(out.swarm, {})
end)

t.case("classify by content: ZO, EN, table, no encounters, junk", function()
  local kind, rec0, enc = zones.classify(zo(33, { { "grass", 1, 25, 0, 3, 5 } }))
  t.eq(kind, "zo"); t.eq(#rec0, 0x38); t.eq(#enc, 0xF4)
  kind, rec0, enc = zones.classify(zo(33))
  t.eq(kind, "zo"); t.eq(enc, nil)
  t.eq((zones.classify(pack("EN", { "x" }))), "en")
  t.eq((zones.classify(string.rep("\0", 0x38 * 3))), "table")
  t.eq(zones.classify(string.rep("j", 55)), nil)
  t.eq(zones.classify("ZO"), nil)
  t.eq(zones.classify("ZO" .. u16(9) .. string.rep("\255", 8)), nil)
end)

t.case("scan builds zones and areas grouped by location in zone order", function()
  local store, _, run, stats = make(world())
  t.eq({ store.areas() }, { nil, "not_ready" })
  run()
  t.eq(store.state(), "done")
  t.ok(store.found())
  local areas = store.areas()
  t.eq(#areas, 2)
  t.eq(areas[1].id, 10); t.eq(areas[1].zones, { 0, 1 })
  t.eq(areas[1].encounters.grass, { { species = 25, form = 0, min = 3, max = 5 }, { species = 16, form = 0, min = 2, max = 3 } })
  t.eq(areas[1].encounters.surf, { { species = 7, form = 0, min = 20, max = 30 } })
  t.eq(areas[2].id, 30); t.eq(areas[2].zones, { 3, 5 })
  t.eq(areas[2].encounters.horde, { { species = 19, form = 0, min = 10, max = 12 }, { species = 19, form = 1, min = 10, max = 12 } })
  t.eq(areas[2].encounters.old_rod, { { species = 129, form = 0, min = 5, max = 10 } })
  t.eq(areas[2].encounters.tall_grass, nil, "species 722 is not a slot")
  local reads, peak = stats()
  t.eq(reads, 1)
  t.ok(peak <= zones.ENTRIES_PER_STEP)
end)

t.case("zone_info covers towns and unknown zones; names come from the text", function()
  local store, _, run = make(world(), { [10] = "Route A", [20] = "Town B" })
  t.eq({ store.zone_info(2) }, { nil, "not_ready" })
  run()
  t.eq(store.zone_info(2), { zone = 2, location = 20, name = "Town B" })
  t.eq(store.zone_info(4), { zone = 4, location = 12 })
  t.eq(store.zone_info(0).name, "Route A")
  t.eq({ store.zone_info(99) }, { nil, "unknown_zone" })
  t.eq({ store.zone_info("x") }, { nil, "unknown_zone" })
  t.eq(store.areas()[1].name, "Route A")
  t.eq(store.areas()[2].name, nil)
end)

t.case("zonedata table in front shifts the GARC index: the ordinal is used", function()
  local store, _, run = make(world({ table_first = true }))
  run()
  t.eq(store.zone_info(2).location, 20)
  t.eq(store.zone_info(5).location, 30)
  t.eq(store.areas()[1].zones, { 0, 1 })
end)

t.case("missing or broken archives never raise", function()
  local store, _, run = make({})
  run()
  t.eq(store.state(), "unsupported")
  t.eq({ store.areas() }, { nil, "unsupported" })
  local junk, _, run2 = make({ ["/a/0/1/3"] = formats.garc({ "junk", "more junk" }) })
  run2()
  t.eq(junk.state(), "done")
  t.eq(junk.found(), false)
  t.eq(junk.areas(), {})
  local mock = fb_mock.new({ i18n_dir = "plugin/i18n" })
  t.eq(zones.new(mock.fb, {}).state(), "unsupported")
end)

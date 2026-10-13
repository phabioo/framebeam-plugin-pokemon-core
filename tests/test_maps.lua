local t = require("t")
local fb_mock = require("fb_mock")
local formats = require("formats")
local darc = require("gen6.darc")
local maps = require("gen6.maps")
local oras = require("gen6.oras")
local crypto = require("pk6_crypto")

local function marker(w, h, m) -- bclim whose first pixel red byte is m
  return formats.bclim(w, h, string.char(m, 0, 0, 255) .. string.rep("\0\0\0\255", w * h - 1))
end

local DARC_BIG = marker(300, 200, 7)

local function world()
  local r = {
    ["/a/0/0/0"] = formats.garc({
      marker(256, 128, 1),                                   -- 1: plain, exactly at threshold
      marker(64, 64, 2),                                     -- 2: too small
      formats.lz11_literal(marker(512, 256, 3)),             -- 3: LZ11 wrapped
      formats.darc({ { path = "timg/map.bclim", data = DARC_BIG },
        { path = "timg/icon.bclim", data = marker(16, 16, 4) } }), -- 4: DARC
      string.rep("junk", 50),                                -- 5: junk
      marker(255, 128, 5),                                   -- 6: one pixel too narrow
    }),
    ["/a/0/0/1"] = marker(400, 300, 9),                      -- plain BCLIM file, no GARC
    ["/a/0/1/2"] = string.rep("z", 300),
  }
  for i = 1, 12 do r[string.format("/a/5/%02d", i)] = string.rep("q", 100 + i) end
  return r
end

local function make(opts)
  opts = opts or {}
  local mock = fb_mock.new({ game = { system = "3ds" }, codec = opts.codec or formats.fake_codec(),
    i18n_dir = "plugin/i18n", romfs = opts.romfs or world(), cache = opts.cache })
  local reads, lists = {}, 0
  local ro, lo = mock.fb.rom.romfs, mock.fb.rom.romfs_list
  mock.fb.rom.romfs = function(p) reads[#reads + 1] = p; return ro(p) end
  mock.fb.rom.romfs_list = function(d) lists = lists + 1; return lo(d) end
  local store = maps.new(mock.fb, "pokemon_omega_ruby", function() return "rev2" end)
  return store, mock, reads, function() return lists end
end

local function finish(store)
  for _ = 1, 5000 do
    if store.state() == "done" then return true end
    store.step()
  end
  return false
end

t.case("darc parser lists files with directory paths", function()
  local d = formats.darc({ { path = "top.bin", data = "AAAA" }, { path = "timg/a.bclim", data = "BBBBBB" },
    { path = "timg/b.bclim", data = "C" } })
  local list = assert(darc.parse(d))
  local got = {}
  for _, f in ipairs(list) do got[f.path] = d:sub(f.offset + 1, f.offset + f.length) end
  t.eq(got, { ["top.bin"] = "AAAA", ["timg/a.bclim"] = "BBBBBB", ["timg/b.bclim"] = "C" })
end)

t.case("darc parser rejects garbage without raising", function()
  t.eq(darc.parse("nope"), nil)
  t.eq(darc.parse("darc" .. string.rep("\255", 40)), nil)
  local d = formats.darc({ { path = "a.bin", data = "AAAA" } })
  t.eq(darc.parse(d:sub(1, 30)), nil)
end)

t.case("bclim_size reads the footer", function()
  t.eq({ maps.bclim_size(formats.bclim(40, 30)) }, { 40, 30 })
  t.eq(maps.bclim_size("short"), nil)
  t.eq(maps.bclim_size(string.rep("x", 100)), nil)
end)

t.case("scan finds plain, LZ11, DARC and loose candidates sorted by area", function()
  local store, mock = make()
  t.eq({ store.candidates() }, { nil, "not_ready" })
  t.ok(finish(store))
  local list = store.candidates()
  local ids = {}
  for i, c in ipairs(list) do ids[i] = c.id end
  t.eq(ids, { "/a/0/0/0#3", "/a/0/0/1#1", "/a/0/0/0#4/timg/map.bclim", "/a/0/0/0#1" })
  t.eq(list[1], { id = "/a/0/0/0#3", w = 512, h = 256 })
  t.eq(store.found(), true)
  t.eq(mock.cache_files["map/index.txt"]:match("^[^\n]+"), "complete")
end)

t.case("files over 32 MiB are skipped and nothing found means no feature", function()
  local r = { ["/a/0/big"] = string.rep("\0", maps.MAX_FILE_SIZE + 1), ["/a/0/small"] = string.rep("s", 100) }
  local store, _, reads = make({ romfs = r })
  t.ok(finish(store))
  t.eq(reads, { "/a/0/small" })
  t.eq(store.found(), false)
  t.eq(store.candidates(), {})
end)

t.case("each scan step reads at most one file", function()
  local store, _, reads = make()
  for _ = 1, 5000 do
    local n = #reads
    store.step()
    t.ok(#reads - n <= 1)
    if store.state() == "done" then break end
  end
end)

t.case("scan resumes from saved progress without rereading finished files", function()
  local store, mock = make()
  for _ = 1, 5000 do
    store.step()
    if mock.cache_files["map/progress.txt"] == "10" then break end
  end
  t.eq(mock.cache_files["map/progress.txt"], "10")
  local first10 = {}
  local sorted = {}
  for l in mock.cache_files["map/files.txt"]:gmatch("[^\n]+") do sorted[#sorted + 1] = l end
  for i = 1, 10 do first10[sorted[i]] = true end
  local s2, _, reads, lists = make({ cache = mock.cache_files })
  t.ok(finish(s2))
  for _, p in ipairs(reads) do t.ok(not first10[p], "reread " .. p) end
  t.eq(lists(), 0, "directories not listed again")
  t.eq(#s2.candidates(), 4)
end)

t.case("a complete index skips the scan entirely", function()
  local store, mock = make()
  finish(store)
  local s2, _, reads, lists = make({ cache = mock.cache_files })
  t.ok(s2.candidates())
  t.eq(#reads, 0); t.eq(lists(), 0)
  t.eq(#s2.candidates(), 4)
end)

t.case("map_image converts and caches; unknown and bad ids rejected", function()
  local store, mock, reads = make()
  finish(store)
  local id = "/a/0/0/0#4/timg/map.bclim"
  local png = assert(store.image(id))
  t.eq({ string.unpack("<I2I2", png, 9) }, { 300, 200, 13 })
  t.eq(png:byte(13), 7)
  local n = #reads
  t.eq(store.image(id), png)
  t.eq(#reads, n, "cached")
  local cached = 0
  for k in pairs(mock.cache_files) do if k:match("^map/%x+%.png$") then cached = cached + 1 end end
  t.eq(cached, 1)
  t.eq(store.image("/a/0/0/1#1"):byte(13), 9)         -- loose file
  t.eq(store.image("/a/0/0/0#3"):byte(13), 3)         -- LZ11 entry
  t.eq({ store.image("/a/0/0/0#2") }, { nil, "unknown_map" })
  t.eq({ store.image("garbage") }, { nil, "unknown_map" })
  t.eq({ store.image(nil) }, { nil, "unknown_map" })
end)

t.case("map_image during the scan is not_ready; oversize PNG is too_large", function()
  local store = make()
  t.eq({ store.image("/a/0/0/1#1") }, { nil, "not_ready" })
  local codec = formats.fake_codec({ png = function() return string.rep("p", maps.MAX_PNG + 1) end })
  local s2 = make({ codec = codec })
  finish(s2)
  t.eq({ s2.image("/a/0/0/1#1") }, { nil, "too_large" })
end)

t.case("candidate list is capped", function()
  local files = {}
  for i = 1, 60 do files[#files + 1] = formats.bclim(256, 128) end
  local store = make({ romfs = { ["/a/x/big"] = formats.garc(files) } })
  finish(store)
  t.eq(#store.candidates(), maps.LIST_CAP)
end)

t.case("map_selected from MAP_ID by game and revision", function()
  local store = make()
  t.eq(store.selected(), nil)
  maps.MAP_ID.pokemon_omega_ruby = "/a/x#1"
  t.eq(store.selected(), "/a/x#1")
  maps.MAP_ID.pokemon_omega_ruby = { rev2 = "/a/y#2", rev0_1 = "/a/z#3" }
  t.eq(store.selected(), "/a/y#2")
  maps.MAP_ID.pokemon_omega_ruby = nil
end)

t.case("unsupported without codec", function()
  local store = make({ codec = {} })
  t.eq({ store.candidates() }, { nil, "unsupported" })
  t.eq({ store.image("/a#1") }, { nil, "unsupported" })
end)

t.case("adapter exposes map methods and feature after ticks", function()
  local codec = formats.fake_codec()
  codec.pk6_decrypt = crypto.decrypt
  local mock = fb_mock.new({ game = { system = "3ds" }, codec = codec, i18n_dir = "plugin/i18n", romfs = world() })
  local a = oras.attach({ fb = mock.fb, game = { id = "pokemon_omega_ruby" }, detected = {} })
  t.eq(a:features().map, false)
  t.eq({ a:map_candidates() }, { nil, "not_ready" })
  for _ = 1, 20000 do
    if a:features().map then break end
    a:tick()
  end
  t.eq(a:features().map, true)
  t.eq(#a:map_candidates(), 4)
  t.eq(a:map_selected(), nil)
end)

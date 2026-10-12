local t = require("t")
local fb_mock = require("fb_mock")
local crypto = require("pk6_crypto")
local build = require("pk6_build")
local oras = require("gen6.oras")

local REV2 = { party = 0x08CF727C, box = 0x08C9A144 }
local REV01 = { party = 0x08CFB26C, box = 0x08C9E134 }
local STRIDE, BOX_BYTES = 0x1E4, 31 * 30 * 232

local function party_blob(slots)
  local parts = {}
  for i = 1, 6 do
    local f = slots[i]
    if f then
      local c = {}
      for k, v in pairs(f) do c[k] = v end
      c.party = c.party or {}
      f = c
    end
    local s = f and build.encrypted(f) or string.rep("\0", 260)
    parts[i] = s .. string.rep("\0", STRIDE - 260)
  end
  return table.concat(parts)
end

local function box_blob(entries) -- entries[box][slot] = fields
  local parts = {}
  for b = 1, 31 do
    for s = 1, 30 do
      local f = entries[b] and entries[b][s]
      parts[#parts + 1] = f and crypto.encrypt(build.build(f)) or string.rep("\0", 232)
    end
  end
  return table.concat(parts)
end

local function codec()
  return { pk6_decrypt = crypto.decrypt }
end

local function make(set, slots, boxes, extra)
  local memory = {}
  if set then
    memory[#memory + 1] = { addr = set.party, data = party_blob(slots or {}) }
    memory[#memory + 1] = { addr = set.box, data = box_blob(boxes or {}) }
  end
  local opts = { game = { system = "3ds", code = "000400000011C400" }, memory = memory, codec = codec(),
    i18n_dir = "plugin/i18n" }
  for k, v in pairs(extra or {}) do opts[k] = v end
  local mock = fb_mock.new(opts)
  local a = oras.attach({ fb = mock.fb, game = {}, detected = {} })
  return a, mock
end

t.case("watches both candidate sets", function()
  local _, mock = make(REV2, { { species = 255, exp = 5 } })
  local n = 0
  for _ in pairs(mock.watches) do n = n + 1 end
  t.eq(n, 4)
  t.eq(mock.watches["oras.rev2.party"].addr, REV2.party)
  t.eq(mock.watches["oras.rev0_1.box"].addr, REV01.box)
end)

t.case("rev2 chosen", function()
  local a = make(REV2, { { species = 255, exp = 5, nickname = "Colonel" } })
  t.eq(a:revision(), "rev2")
  local team = a:team()
  t.eq(#team, 1)
  t.eq(team[1].species, 255); t.eq(team[1].slot, 1); t.eq(team[1].nickname, "Colonel")
  t.eq(team[1].level, nil)
end)

t.case("rev0_1 chosen", function()
  local a = make(REV01, { { species = 7, exp = 5 } })
  t.eq(a:revision(), "rev0_1")
  t.eq(a:team()[1].species, 7)
  t.eq(a:box_count(), 31)
end)

t.case("nothing valid -> not_ready", function()
  local a = make(nil)
  t.eq({ a:revision() }, { nil, "not_ready" })
  t.eq({ a:team() }, { nil, "not_ready" })
  t.eq({ a:box(1) }, { nil, "not_ready" })
  t.eq({ a:box_count() }, { nil, "not_ready" })
  -- invalid checksum / species 0 / species out of range in slot 1
  local bad = build.build({ species = 255 })
  local enc = crypto.encrypt(bad)
  enc = enc:sub(1, 30) .. string.char(enc:byte(31) ~ 0xFF) .. enc:sub(32)
  local mock = fb_mock.new({ memory = { { addr = REV2.party, data = enc .. string.rep("\0", 1000) } },
    codec = codec(), i18n_dir = "plugin/i18n" })
  t.eq({ oras.attach({ fb = mock.fb }):revision() }, { nil, "not_ready" })
  local a2 = make(REV2, { { species = 800 } })
  t.eq({ a2:revision() }, { nil, "not_ready" })
  t.eq(a:language(), nil)
end)

t.case("party with gaps", function()
  local a = make(REV2, {
    { species = 1, exp = 1 }, nil, { species = 4, exp = 2 }, nil, nil, { species = 7, exp = 3 },
  })
  local team = a:team()
  t.eq(#team, 3)
  t.eq({ team[1].slot, team[2].slot, team[3].slot }, { 1, 3, 6 })
  t.eq(team[3].species, 7)
end)

t.case("box 1 and box 31", function()
  local a = make(REV2, { { species = 1 } }, {
    [1] = { [1] = { species = 265 }, [30] = { species = 10 } },
    [31] = { [2] = { species = 721 } },
  })
  local b1 = a:box(1)
  t.eq(#b1, 2)
  t.eq({ b1[1].species, b1[1].slot, b1[1].box }, { 265, 1, 1 })
  t.eq({ b1[2].species, b1[2].slot }, { 10, 30 })
  local b31 = a:box(31)
  t.eq(#b31, 1)
  t.eq({ b31[1].species, b31[1].slot, b31[1].box }, { 721, 2, 31 })
  t.eq(#a:box(2), 0)
  t.eq({ a:box(0) }, { nil, "out_of_range" })
  t.eq({ a:box(32) }, { nil, "out_of_range" })
end)

-- synthetic personal GARC: growth rate of species s = s % 6; entry size 0x50, byte 0x15
local function personal_stubs(layout, romfs_valid)
  local entries = {}
  for s = 0, 721 do
    local e = {}
    for i = 1, 0x50 do e[i] = "\0" end
    e[0x15 + 1] = string.char(s % 6)
    entries[s] = table.concat(e)
  end
  local whole = {}
  for s = 0, 721 do whole[#whole + 1] = entries[s] end
  whole = table.concat(whole)
  -- data strings are markers: "valid" parses as a table, anything else as garbage
  return {
    pk6_decrypt = crypto.decrypt,
    garc = function(d)
      if d ~= "valid" then return { count = 3, data_offset = 0, files = {} } end
      return { count = layout == "single" and 1 or 722, data_offset = 0, files = {} }
    end,
    garc_file = function(d, i, sub)
      if d ~= "valid" then return string.rep("\9", 5) end
      if layout == "single" then return whole end
      return entries[i - 1]
    end,
  }
end

local function level_case(name, layout, romfs, expect_path)
  t.case(name, function()
    local g = require("gen6.growth")
    -- species 255: 255 % 6 = 3 medium slow; species 12: rate 0
    local a, mock = make(REV2, { { species = 255, exp = g.exp_for_level(3, 8) + 1 }, { species = 12, exp = 1000 } }, nil, {
      codec = personal_stubs(layout), romfs = romfs,
    })
    local team = a:team()
    t.eq(team[1].level, expect_path and 8 or nil)
    t.eq(team[2].level, expect_path and 10 or nil)
    local logged = 0
    for _, l in ipairs(mock.logs) do
      if l.level == "info" and l.text:find(expect_path or "\0", 1, true) then logged = logged + 1 end
    end
    t.eq(logged, expect_path and 1 or 0)
  end)
end

for _, layout in ipairs({ "single", "per_entry" }) do
  level_case("personal valid at 1/9/6 only (" .. layout .. ")", layout, { ["/a/1/9/6"] = "valid" }, "/a/1/9/6")
  level_case("personal valid at 1/9/5 only (" .. layout .. ")", layout, { ["/a/1/9/5"] = "valid" }, "/a/1/9/5")
  level_case("garbage at 1/9/5, valid at 1/9/6 (" .. layout .. ")", layout,
    { ["/a/1/9/5"] = "junk", ["/a/1/9/6"] = "valid" }, "/a/1/9/6")
  level_case("nothing valid (" .. layout .. ")", layout, { ["/a/1/9/5"] = "junk", ["/a/1/9/6"] = "junk" }, nil)
end

t.case("level nil without romfs files or without garc codec", function()
  local a = make(REV2, { { species = 255, exp = 100 } }, nil, { codec = personal_stubs("single") })
  t.eq(a:team()[1].level, nil)
  local b = make(REV2, { { species = 255, exp = 100 } }, nil, { romfs = { ["/a/1/9/6"] = "valid" } })
  t.eq(b:team()[1].level, nil)
end)

t.case("growth byte out of range rejects the table", function()
  local c = personal_stubs("single")
  local good = c.garc_file("valid", 1, 1)
  local bad = good:sub(1, 5 * 0x50 + 0x15) .. "\7" .. good:sub(5 * 0x50 + 0x17)
  c.garc_file = function() return bad end
  local a = make(REV2, { { species = 255, exp = 100 } }, nil, { codec = c, romfs = { ["/a/1/9/6"] = "valid" } })
  t.eq(a:team()[1].level, nil)
end)

t.case("language heuristic", function()
  local own = { tid = 11, sid = 22, origin_game = 27, language_id = 5 } -- de
  local a = make(REV2, { own, { species = 4, tid = 11, sid = 22, origin_game = 27, language_id = 5 } })
  t.eq(a:language(), "de")
  -- traded-in en Pokemon in slot 1 is outvoted by two own de catches
  local b = make(REV2, {
    { tid = 99, sid = 98, origin_game = 26, language_id = 2 },
    { species = 4, tid = 11, sid = 22, origin_game = 27, language_id = 5 },
    { species = 7, tid = 11, sid = 22, origin_game = 27, language_id = 5 },
  })
  t.eq(b:language(), "de")
  -- only foreign-origin Pokemon (e.g. XY, default origin 0x2C) -> nil
  local c = make(REV2, { { origin_game = 24, language_id = 5 }, { species = 4, origin_game = 44, language_id = 2 } })
  t.eq(c:language(), nil)
  t.eq(make(nil):language(), nil)
end)

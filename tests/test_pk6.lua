local t = require("t")
local crypto = require("pk6_crypto")
local build = require("pk6_build")
local pk6 = require("gen6.pk6")

t.case("crypto round trip stored and party, several shuffles", function()
  for _, ec in ipairs({ 0, 1, 0x2000, 0x4000, 0xBADF00D, 0xFFFFFFFF, 0x1234ABCD, 0x31A000 }) do
    for _, party in ipairs({ false, true }) do
      local plain = build.build({ ec = ec, species = 255, exp = 77, nickname = "Abc",
        party = party and { level = 9, hp = 30, max_hp = 31 } or nil })
      local enc = crypto.encrypt(plain)
      t.eq(#enc, #plain)
      t.ok(enc ~= plain)
      local back, ok = crypto.decrypt(enc)
      t.eq(back, plain)
      t.eq(ok, true)
    end
  end
end)

t.case("checksum mismatch is reported", function()
  local enc = crypto.encrypt(build.build({ species = 7 }))
  local bad = enc:sub(1, 20) .. string.char((enc:byte(21) ~ 1)) .. enc:sub(22)
  local _, ok = crypto.decrypt(bad)
  t.eq(ok, false)
end)

t.case("parse basic fields", function()
  local plain = build.build({
    species = 261, form = 2, exp = 1234, held_item = 17, tid = 100, sid = 200,
    pid = 0x00FF1234, ability = 65, nature = 12, gender = 1, fateful = true,
    moves = { 33, 45, 0, 10 }, nickname = "Fiffyen", nicknamed = true,
    ot_name = "Ash", language_id = 5, origin_game = 0x2C,
    ivs = { hp = 31, atk = 0, def = 1, spe = 2, spa = 3, spd = 30 },
    evs = { hp = 4, atk = 5, def = 6, spe = 7, spa = 8, spd = 9 },
  })
  local r = pk6.parse(plain)
  t.eq(r.species, 261); t.eq(r.form, 2); t.eq(r.exp, 1234); t.eq(r.held_item, 17)
  t.eq(r.ot_id, 100); t.eq(r.ot_sid, 200); t.eq(r.personality, 0x00FF1234)
  t.eq(r.ability, 65); t.eq(r.nature, 12); t.eq(r.gender, "female")
  t.eq(r.moves, { 33, 45, 10 })
  t.eq(r.nickname, "Fiffyen"); t.eq(r.ot_name, "Ash"); t.eq(r.nicknamed, true)
  t.eq(r.language, "de"); t.eq(r.egg, false); t.eq(r.shiny, false)
  t.eq(r.ivs, { hp = 31, atk = 0, def = 1, spe = 2, spa = 3, spd = 30 })
  t.eq(r.evs.spd, 9)
  t.eq(r.level, nil); t.eq(r.hp, nil); t.eq(r.status, nil); t.eq(r.party_ext, nil)
end)

t.case("nickname utf-8, umlauts, emoji, terminator", function()
  local r = pk6.parse(build.build({ nickname = "Käfer\u{1F600}x", ot_name = "Jörg" }))
  t.eq(r.nickname, "Käfer\u{1F600}x")
  t.eq(r.ot_name, "Jörg")
  t.eq(pk6.parse(build.build({ nickname = "" })).nickname, "")
  t.eq(pk6.utf16le_to_utf8("A\0\0\0B\0", 12), "A")
  t.eq(pk6.utf16le_to_utf8("\0\216A\0", 12), "\u{FFFD}A")
end)

t.case("shiny rule", function()
  -- tid ^ sid ^ hi ^ lo < 16
  local base = { tid = 0x1111, sid = 0x2222, pid = (0x3333 << 16) | 0x4444 }
  local xor = 0x1111 ~ 0x2222 ~ 0x3333 ~ 0x4444
  t.eq(pk6.parse(build.build(base)).shiny, xor < 16)
  base.pid = (0x3333 << 16) | (0x4444 ~ xor ~ 15)
  t.eq(pk6.parse(build.build(base)).shiny, true)
  base.pid = (0x3333 << 16) | (0x4444 ~ xor ~ 16)
  t.eq(pk6.parse(build.build(base)).shiny, false)
end)

t.case("egg flag", function()
  t.eq(pk6.parse(build.build({ egg = true })).egg, true)
  t.eq(pk6.parse(build.build({ egg = true, nicknamed = false })).nicknamed, false)
end)

t.case("party extension only in party_ext", function()
  local r = pk6.parse(build.build({ party = { status = 4, level = 9, hp = 20, max_hp = 31 } }))
  t.eq(r.level, nil); t.eq(r.hp, nil); t.eq(r.max_hp, nil); t.eq(r.status, nil)
  t.eq(r.party_ext.level, 9); t.eq(r.party_ext.hp, 20); t.eq(r.party_ext.max_hp, 31)
  t.eq(r.party_ext.status, 4)
end)

t.case("bad input", function()
  t.eq(select(2, pk6.parse(string.rep("\0", 100))), "bad_length")
  t.eq(select(2, pk6.parse(nil)), "bad_type")
end)

t.case("language byte: 7 is Spanish, 6 is unused (PKHeX LanguageID)", function()
  local function lang(id) return pk6.parse(build.build({ language_id = id })).language end
  t.eq(lang(7), "es")
  t.eq(lang(6), nil)
  t.eq({ lang(1), lang(2), lang(3), lang(4), lang(5), lang(8) }, { "ja", "en", "fr", "it", "de", "ko" })
end)

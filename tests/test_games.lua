local t = require("t")
local games = require("core.games")

local by_id = {}
for _, e in ipairs(games.GAMES) do by_id[e.id] = e end

t.case("table size and fields", function()
  t.eq(#games.GAMES, 22)
  for _, e in ipairs(games.GAMES) do
    t.ok(e.id and e.name and e.gen and e.system and e.codes and e.version, "fields of " .. tostring(e.id))
  end
end)

t.case("3ds title ids detect exactly, any case", function()
  local ids = {
    ["0004000000055D00"] = "pokemon_x", ["0004000000055E00"] = "pokemon_y",
    ["000400000011C400"] = "pokemon_omega_ruby", ["000400000011C500"] = "pokemon_alpha_sapphire",
    ["0004000000164800"] = "pokemon_sun", ["0004000000175E00"] = "pokemon_moon",
    ["00040000001B5000"] = "pokemon_ultra_sun", ["00040000001B5100"] = "pokemon_ultra_moon",
  }
  for code, id in pairs(ids) do
    local e, info = games.detect({ system = "3ds", code = code })
    t.eq(e and e.id, id)
    t.eq(info, {})
    t.eq((games.detect({ system = "3DS", code = code:lower() })).id, id)
  end
  t.eq(games.detect({ system = "3ds", code = "0004000000055D01" }), nil)
  t.eq(games.detect({ system = "3ds", code = "0004000000055D0" }), nil)
end)

t.case("adapters", function()
  t.eq(by_id.pokemon_omega_ruby.adapter, "gen6.oras")
  t.eq(by_id.pokemon_alpha_sapphire.adapter, "gen6.oras")
  t.eq(by_id.pokemon_x.adapter, nil)
  t.eq(by_id.pokemon_y.adapter, nil)
end)

t.case("nds and gba prefixes", function()
  local prefixes = {
    ADA = { "pokemon_diamond", 4, "nds" }, APA = { "pokemon_pearl", 4, "nds" },
    CPU = { "pokemon_platinum", 4, "nds" }, IPK = { "pokemon_heartgold", 4, "nds" },
    IPG = { "pokemon_soulsilver", 4, "nds" }, IRB = { "pokemon_black", 5, "nds" },
    IRA = { "pokemon_white", 5, "nds" }, IRE = { "pokemon_black_2", 5, "nds" },
    IRD = { "pokemon_white_2", 5, "nds" }, AXV = { "pokemon_ruby", 3, "gba" },
    AXP = { "pokemon_sapphire", 3, "gba" }, BPR = { "pokemon_firered", 3, "gba" },
    BPG = { "pokemon_leafgreen", 3, "gba" }, BPE = { "pokemon_emerald", 3, "gba" },
  }
  for p, want in pairs(prefixes) do
    local e, info = games.detect({ system = want[3], code = p .. "D" })
    t.eq(e and e.id, want[1], p)
    t.eq(e.gen, want[2])
    t.eq(info.region_letter, "D")
    t.eq(info.language, "de")
  end
end)

t.case("language letters", function()
  local langs = { D = "de", F = "fr", I = "it", S = "es", E = "en", P = "en", J = "ja", K = "ko" }
  for letter, lang in pairs(langs) do
    local _, info = games.detect({ system = "nds", code = "IPK" .. letter })
    t.eq(info.language, lang, letter)
    t.eq(info.region_letter, letter)
  end
  local _, info = games.detect({ system = "nds", code = "ipkx" })
  t.eq(info.region_letter, "X")
  t.eq(info.language, nil)
end)

t.case("unknown games and bad input", function()
  t.eq(games.detect({ system = "nds", code = "AMCE" }), nil)
  t.eq(games.detect({ system = "nds", code = "IP" }), nil)
  t.eq(games.detect({ system = "snes", code = "ADAD" }), nil)
  t.eq(games.detect({ system = "gba", code = "ADAD" }), nil)
  t.eq(games.detect({ system = "nds" }), nil)
  t.eq(games.detect({}), nil)
  t.eq(games.detect(nil), nil)
end)

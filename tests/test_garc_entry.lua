local t = require("t")
local formats = require("formats")
local garc_entry = require("gen6.garc_entry")

t.case("fake codec behaves like the fixed Player: magic is CRAG, GARC is rejected", function()
  local codec = formats.fake_codec()
  local g = formats.garc({ "abcd" })
  t.eq(g:sub(1, 4), "CRAG")
  t.ok(codec.garc(g) ~= nil)
  t.eq({ codec.garc("GARC" .. g:sub(5)) }, { nil, "not a garc" })
end)

t.case("decompress: LZ11 entries are unpacked, others stay raw", function()
  local codec = formats.fake_codec()
  local plain = "hello world, this is a plain entry"
  t.eq({ garc_entry.decompress(codec, formats.lz11_literal(plain)) }, { plain, "lz" })
  t.eq({ garc_entry.decompress(codec, "\1\0abc") }, { "\1\0abc", "raw" })
  -- 0x10 is only handled on request (maps)
  t.eq(select(2, garc_entry.decompress(codec, "\16abcdefgh")), "raw")
end)

t.case("decompress: failures keep the raw entry (pk3DS behaviour) and flag lz_failed", function()
  local codec = formats.fake_codec()
  local bad = "\17\5\0\0\1xxxxx" -- fake codec accepts only literal blocks (flag 0)
  t.eq({ garc_entry.decompress(codec, bad) }, { bad, "lz_failed" })
  local boom = formats.fake_codec({ lz_decompress = function() error("boom") end })
  t.eq({ garc_entry.decompress(boom, bad) }, { bad, "lz_failed" })
  -- output over the size limit
  local big = formats.fake_codec({ lz_decompress = function() return string.rep("x", garc_entry.MAX_LZ_OUTPUT + 1) end })
  t.eq(select(2, garc_entry.decompress(big, "\17abc")), "lz_failed")
  -- no codec function: raw
  t.eq({ garc_entry.decompress({}, "\17abc") }, { "\17abc", "raw" })
end)

t.case("entry: reads a GARC file, decompresses LZ11, reports unreadable entries", function()
  local codec = formats.fake_codec()
  local d = formats.garc({ "plain-data", formats.lz11_literal("compressed payload") })
  t.eq({ garc_entry.entry(codec, d, 1) }, { "plain-data", "raw" })
  t.eq({ garc_entry.entry(codec, d, 2) }, { "compressed payload", "lz" })
  t.eq({ garc_entry.entry(codec, d, 3) }, { nil, "no_entry" })
  t.eq({ garc_entry.entry(codec, "not a garc", 1) }, { nil, "no_entry" })
  local boom = { garc_file = function() error("x") end }
  t.eq({ garc_entry.entry(boom, d, 1) }, { nil, "garc_error" })
end)

local t = require("t")
local fb_mock = require("fb_mock")
local formats = require("formats")
local tb = require("text_build")
local text = require("gen6.text")

t.case("parse round trip: plain, special characters, variables, surrogates", function()
  local data = tb.build({
    "Alpha",
    "",
    { "Mal", { 0xE08E }, " and fem", { 0xE08F }, { 0xE07F }, { 0xE08D } },
    { "A", tb.var(0xFF00, 5), "B", tb.var(0xBE00, 0), "C", tb.var(0xBE01, 0), "D", tb.var(0xBE02, 30), tb.var(0xBDFF, 7) },
    "smile \u{1F600} end",
    "Line\nbreak",
  })
  local f = assert(text.parse(data))
  t.eq(f.count, 6)
  t.eq(f.line(0), "Alpha")
  t.eq(f.line(1), "")
  t.eq(f.line(2), "Mal\u{2642} and fem\u{2640}\u{202F}\u{2026}")
  t.eq(f.line(3), "A[VAR FF00]B\rC\\cD[WAIT]")
  t.eq(f.line(4), "smile \u{1F600} end")
  t.eq(f.line(5), "Line\nbreak")
  t.eq(f.line(6), nil)
  t.eq(f.line(-1), nil)
end)

t.case("every line uses its own key", function()
  local data = tb.build({ "same", "same", "same" })
  -- the three encrypted lines must differ although the text is identical
  local f = assert(text.parse(data))
  t.eq(f.line(0), "same"); t.eq(f.line(1), "same"); t.eq(f.line(2), "same")
  local sdo = 0x10
  local o0 = string.unpack("<i4", data, sdo + 4 + 1)
  local o1 = string.unpack("<i4", data, sdo + 4 + 8 + 1)
  t.ok(data:sub(sdo + o0 + 1, sdo + o0 + 10) ~= data:sub(sdo + o1 + 1, sdo + o1 + 10))
end)

t.case("parse rejects bad files without raising", function()
  local good = tb.build({ "x" })
  t.eq({ text.parse("short") }, { nil, "too_short" })
  t.eq({ text.parse(good .. "\0") }, { nil, "bad_length" })
  local broken = good:sub(1, 0x10) .. string.pack("<I4", 99) .. good:sub(0x15)
  t.eq({ text.parse(broken) }, { nil, "bad_section" })
  local f = assert(text.parse(good))
  t.ok(f.line(0) == "x")
  -- a line table entry pointing outside the file yields nil
  local evil = good:sub(1, 0x14) .. string.pack("<i4i2", 5000, 5) .. "\0\0" .. good:sub(0x1D)
  t.eq(assert(text.parse(evil)).line(0), nil)
end)

local function lines(prefix, n)
  local l = {}
  for i = 0, n - 1 do l[#l + 1] = prefix .. i end
  return l
end

-- language archive: species 98, moves 14, locations 90, types 18 (marked by language)
local function archive(tag)
  return tb.garc({
    [98] = tb.build(lines(tag .. "S", 30)), [14] = tb.build(lines(tag .. "M", 20)),
    [18] = tb.build(lines(tag .. "T", 18)), [90] = tb.build(lines(tag .. "L", 40)),
    [5] = tb.build(lines(tag .. "F", 10)),
  })
end

local function make(romfs, lang)
  local reads = {}
  local mock = fb_mock.new({ game = { system = "3ds" }, codec = formats.fake_codec(), i18n_dir = "plugin/i18n", romfs = romfs })
  local ro = mock.fb.rom.romfs
  mock.fb.rom.romfs = function(p) reads[#reads + 1] = p; return ro(p) end
  local cur = { lang = lang }
  local store = text.new(mock.fb, { language_fn = function() return cur.lang end })
  return store, mock, reads, cur
end

local function load(store)
  for n = 1, 100 do
    if store.state() == "done" then return n end
    store.step()
  end
  return nil
end

t.case("german text archive is chosen by language and loaded in bounded steps", function()
  local store, _, reads = make({ ["/a/0/7/6"] = archive("de"), ["/a/0/7/3"] = archive("en") }, "de")
  t.eq({ store.name("species", 3) }, { nil, "not_ready" })
  t.ok(load(store), "loaded")
  t.eq(store.name("species", 3), "deS3")
  t.eq(store.name("move", 5), "deM5")
  t.eq(store.name("type", 17), "deT17")
  t.eq(store.name("location", 39), "deL39")
  t.eq(store.name("form", 2), "deF2")
  t.eq(store.name("item", 1), nil) -- file missing in the archive
  t.eq(store.name("species", 30), nil) -- out of range
  t.eq({ store.name("banana", 1) }, { nil, "unknown_kind" })
  t.eq(reads, { "/a/0/7/6" }) -- one archive read, the others are entries of it
  t.ok(store.ready())
end)

t.case("each step does at most one archive read", function()
  local store, _, reads = make({ ["/a/0/7/4"] = archive("fr") }, "fr")
  local before = 0
  for _ = 1, 100 do
    if store.state() == "done" then break end
    store.step()
    t.ok(#reads - before <= 1)
    before = #reads
  end
  t.eq(store.name("species", 1), "frS1")
end)

t.case("falls back to EN, then to the first readable archive", function()
  local s1 = make({ ["/a/0/7/3"] = archive("en") }, "de")
  t.ok(load(s1)); t.eq(s1.name("species", 0), "enS0")
  local s2 = make({ ["/a/0/7/5"] = archive("it") }, "de")
  t.ok(load(s2)); t.eq(s2.name("species", 0), "itS0")
  local s3 = make({ ["/a/0/7/2"] = archive("kanji"), ["/a/0/7/1"] = archive("kana") }, "ja")
  t.ok(load(s3)); t.eq(s3.name("species", 0), "kanjiS0")
  local s4 = make({ ["/a/0/7/3"] = archive("en") }, "zh-Hans")
  t.ok(load(s4)); t.eq(s4.name("species", 0), "enS0")
end)

t.case("an archive without species text is skipped", function()
  local broken = tb.garc({ [14] = tb.build(lines("x", 5)) })
  local store = make({ ["/a/0/7/6"] = broken, ["/a/0/7/3"] = archive("en") }, "de")
  t.ok(load(store)); t.eq(store.name("species", 2), "enS2")
end)

t.case("no archive: unsupported; no codec: unsupported", function()
  local store = make({}, "de")
  for _ = 1, 40 do store.step() end
  t.eq(store.state(), "unsupported")
  t.eq({ store.name("species", 1) }, { nil, "unsupported" })
  local mock = fb_mock.new({ i18n_dir = "plugin/i18n" })
  t.eq(text.new(mock.fb, {}).state(), "unsupported")
end)

t.case("waits for the language, falls back after a while and reloads when it becomes known", function()
  local store, _, _, cur = make({ ["/a/0/7/6"] = archive("de"), ["/a/0/7/3"] = archive("en") }, nil)
  for _ = 1, 20 do store.step() end
  t.eq(store.state(), "idle")
  for _ = 1, text.FALLBACK_STEPS do store.step() end
  t.ok(load(store))
  t.eq(store.name("species", 1), "enS1")
  cur.lang = "de"
  for _ = 1, 30 do store.step() end
  t.eq(store.name("species", 1), "deS1")
end)

t.case("decoded lines are cached in memory, nothing is written to the cache", function()
  local store, mock = make({ ["/a/0/7/3"] = archive("en") }, "en")
  load(store)
  store.name("species", 1)
  t.eq(next(mock.cache_files), nil)
end)

-- Gen 6 PK6 parser for decrypted data (232 stored / 260 party bytes).
-- Layout: PKHeX PK6.cs (kwsch/PKHeX, PKHeX.Core/PKM/PK6.cs), offsets below are
-- from that file; cross-check: Project Pokemon "Pokemon X/Y save structure".
-- Strings are UTF-16LE, 12 characters + terminator (0x1A bytes).
local M = {}

M.SIZE_STORED = 232
M.SIZE_PARTY = 260
M.MAX_SPECIES = 721 -- ORAS National Dex

local OFF = {
  ec = 0x00, checksum = 0x06, species = 0x08, held_item = 0x0A, tid = 0x0C, sid = 0x0E,
  exp = 0x10, ability = 0x14, pid = 0x18, nature = 0x1C, flags = 0x1D, evs = 0x1E,
  nickname = 0x40, moves = 0x5A, iv32 = 0x74, ot_name = 0xB0, version = 0xDF, language = 0xE3,
  -- party extension (not trusted for live party memory, see parse)
  status = 0xE8, level = 0xEC, hp = 0xF0, max_hp = 0xF2, stats = 0xF4,
}
M.OFF = OFF

-- Language byte (PKHeX LanguageID; 6 is unused, 7 = Spanish) -> language code
local LANG = { [1] = "ja", [2] = "en", [3] = "fr", [4] = "it", [5] = "de", [7] = "es",
  [8] = "ko", [9] = "zh-Hans", [10] = "zh-Hant" }
M.LANGUAGES = LANG

local GENDER = { [0] = "male", [1] = "female", [2] = "genderless" }

-- UTF-16LE (up to max_chars code units, stops at 0x0000) -> UTF-8
function M.utf16le_to_utf8(s, max_chars)
  local out, i, n = {}, 1, 0
  max_chars = max_chars or (#s // 2)
  while n < max_chars and i + 1 <= #s do
    local u = string.unpack("<I2", s, i)
    i = i + 2
    n = n + 1
    if u == 0 then break end
    if u >= 0xD800 and u <= 0xDBFF and n < max_chars and i + 1 <= #s then
      local lo = string.unpack("<I2", s, i)
      if lo >= 0xDC00 and lo <= 0xDFFF then
        i = i + 2
        n = n + 1
        out[#out + 1] = utf8.char(0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00))
      else
        out[#out + 1] = utf8.char(0xFFFD)
      end
    elseif u >= 0xD800 and u <= 0xDFFF then
      out[#out + 1] = utf8.char(0xFFFD)
    else
      out[#out + 1] = utf8.char(u)
    end
  end
  return table.concat(out)
end

-- plain: decrypted PK6 (232 or 260 bytes). Returns record or nil, reason.
-- Level/HP/status of the live party are NOT filled from 0xE8+ (unreliable in
-- running ORAS memory); they are exposed as record.party_ext only.
function M.parse(plain)
  if type(plain) ~= "string" then return nil, "bad_type" end
  if #plain ~= M.SIZE_STORED and #plain ~= M.SIZE_PARTY then return nil, "bad_length" end
  local function u8(o) return (string.unpack("<I1", plain, o + 1)) end
  local function u16(o) return (string.unpack("<I2", plain, o + 1)) end
  local function u32(o) return (string.unpack("<I4", plain, o + 1)) end

  local pid, tid, sid = u32(OFF.pid), u16(OFF.tid), u16(OFF.sid)
  local flags = u8(OFF.flags)
  local iv32 = u32(OFF.iv32)
  local moves = {}
  for i = 0, 3 do
    local m = u16(OFF.moves + i * 2)
    if m ~= 0 then moves[#moves + 1] = m end
  end
  local evs, ivs = {}, {}
  for i, k in ipairs({ "hp", "atk", "def", "spe", "spa", "spd" }) do
    evs[k] = u8(OFF.evs + i - 1)
    ivs[k] = (iv32 >> (5 * (i - 1))) & 0x1F
  end
  local lang_id = u8(OFF.language)

  local rec = {
    species = u16(OFF.species),
    form = flags >> 3,
    nickname = M.utf16le_to_utf8(plain:sub(OFF.nickname + 1, OFF.nickname + 0x1A), 12),
    nicknamed = (iv32 >> 31) & 1 == 1,
    exp = u32(OFF.exp),
    personality = pid,
    encryption_constant = u32(OFF.ec),
    shiny = ((tid ~ sid ~ (pid >> 16) ~ (pid & 0xFFFF)) < 16),
    gender = GENDER[(flags >> 1) & 3],
    fateful = flags & 1 == 1,
    nature = u8(OFF.nature),
    ability = u8(OFF.ability),
    held_item = u16(OFF.held_item),
    moves = moves,
    ot_name = M.utf16le_to_utf8(plain:sub(OFF.ot_name + 1, OFF.ot_name + 0x1A), 12),
    ot_id = tid,
    ot_sid = sid,
    language = LANG[lang_id],
    language_id = lang_id,
    origin_game = u8(OFF.version),
    egg = (iv32 >> 30) & 1 == 1,
    ivs = ivs,
    evs = evs,
    -- level, hp, max_hp, status: nil here; level comes from growth
  }
  if #plain == M.SIZE_PARTY then
    local stats = {}
    for i, k in ipairs({ "atk", "def", "spe", "spa", "spd" }) do
      stats[k] = u16(OFF.stats + (i - 1) * 2)
    end
    rec.party_ext = {
      status = u32(OFF.status), level = u8(OFF.level),
      hp = u16(OFF.hp), max_hp = u16(OFF.max_hp), stats = stats,
    }
  end
  return rec
end

return M

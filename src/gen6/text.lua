-- Game text of Omega Ruby / Alpha Sapphire, read at runtime from the player's own
-- RomFS (gametext GARC) and kept in memory only. Nothing is shipped or cached.
--
-- Format (pk3DS TextFile.cs, see docs/games/omega-ruby-alpha-sapphire.md):
--   header   : u16 sections, u16 line count, u32 total length, u32 initial key, u32 section data offset (SDO)
--   at SDO   : u32 section length (== total length; SDO + total == file length)
--   line tab : at SDO+4, 8 bytes per line: i32 offset (relative to SDO), i16 length (UTF-16 units), 2 pad
--   line i   : UTF-16LE words, each xor key, key = rotl16(key, 3); key(i) = 0x7C89 + i * 0x2983 (16 bit)
--   markup   : 0x0010 = variable (count, code, count-1 args); 0x0000 ends the line
local M = {}

M.GARC_BASE = 1 -- ORAS gametext of language index 0 is /a/0/7/1
M.GARC_DIR = "/a/0/7/"
M.KEY_BASE, M.KEY_ADVANCE, M.KEY_VARIABLE = 0x7C89, 0x2983, 0x0010

-- gametext file index per name kind (ORAS, pk3DS TextReference.cs)
M.FILES = { form = 5, move = 14, type = 18, ability = 37, nature = 51, location = 90, species = 98, item = 114 }
M.KIND_ORDER = { "species", "move", "type", "ability", "nature", "location", "item", "form" }
M.REQUIRED = { "species", "move" }
M.MIN_ENTRIES = 115 -- the highest file index used is 114

-- language code -> language indices to try (0 JA kana, 1 JA kanji, 2 EN, 3 FR, 4 IT, 5 DE, 6 ES, 7 KO)
M.LANG_INDEX = { ja = { 1, 0 }, en = { 2 }, fr = { 3 }, it = { 4 }, de = { 5 }, es = { 6 }, ko = { 7 } }
M.FALLBACK_STEPS = 300 -- steps to wait for the game language before falling back to EN

local SPECIAL = { [0xE07F] = 0x202F, [0xE08D] = 0x2026, [0xE08E] = 0x2642, [0xE08F] = 0x2640 }

-- Parses a text file. Returns { count = n, line = function(i) -> string|nil } (i is 0-based), or nil, reason.
function M.parse(data)
  if type(data) ~= "string" or #data < 0x14 then return nil, "too_short" end
  local sections, count, total, _, sdo = string.unpack("<I2I2I4I4I4", data)
  if sections < 1 or sdo < 0x10 or sdo + 4 > #data then return nil, "bad_header" end
  if sdo + total ~= #data then return nil, "bad_length" end
  if string.unpack("<I4", data, sdo + 1) ~= total then return nil, "bad_section" end
  if sdo + 4 + count * 8 > #data then return nil, "bad_table" end
  local file = { count = count }

  function file.line(i)
    if math.type(i) ~= "integer" or i < 0 or i >= count then return nil end
    local off, len = string.unpack("<i4i2", data, sdo + 4 + i * 8 + 1)
    if off < 0 or len < 0 then return nil end
    local first = sdo + off + 1
    if first + len * 2 - 1 > #data then return nil end
    local key = (M.KEY_BASE + i * M.KEY_ADVANCE) & 0xFFFF
    local out, n, p = {}, 0, first
    local stop = first + len * 2
    local function word()
      if p + 1 > stop - 1 then return nil end
      local w = string.unpack("<I2", data, p) ~ key
      key = ((key << 3) | (key >> 13)) & 0xFFFF
      p = p + 2
      return w
    end
    while p < stop do
      local w = word()
      if w == nil or w == 0 then break end
      if w == M.KEY_VARIABLE then
        local cnt, code = word(), word()
        if cnt == nil or code == nil then break end
        local args = {}
        for _ = 2, cnt do
          local a = word()
          if a == nil then break end
          args[#args + 1] = a
        end
        if code == 0xBE00 then n = n + 1; out[n] = "\r"
        elseif code == 0xBE01 then n = n + 1; out[n] = "\\c"
        elseif code == 0xBE02 then n = n + 1; out[n] = "[WAIT]"
        elseif code == 0xBDFF then -- empty-line marker, nothing to show
        else n = n + 1; out[n] = string.format("[VAR %04X]", code) end
      else
        w = SPECIAL[w] or w
        if w >= 0xD800 and w <= 0xDBFF and p < stop then
          local lo = word()
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            w = 0x10000 + ((w - 0xD800) << 10) + (lo - 0xDC00)
          else
            w = 0xFFFD
          end
        elseif w >= 0xD800 and w <= 0xDFFF then
          w = 0xFFFD
        end
        n = n + 1
        out[n] = utf8.char(w)
      end
    end
    return table.concat(out)
  end

  return file
end

-- Store: finds the gametext GARC for the game language and loads the name files in bounded steps
-- (one archive read or one file per step). Decoded lines are kept in memory only.
-- opts.language_fn() -> language code or nil.
function M.new(fb, opts)
  opts = opts or {}
  local self = {}
  local codec = fb.codec
  local can = fb.rom and fb.rom.romfs and codec and codec.garc and codec.garc_file and true or false
  local state = can and "idle" or "unsupported" -- idle | open | fetch | done | unsupported
  local files, lines = {}, {}
  local cands, cand, data, kinds_left
  local waited, fallback_used = 0, false

  local function candidates(lang)
    local out, seen = {}, {}
    local function add(i) if not seen[i] then seen[i] = true; out[#out + 1] = i end end
    for _, i in ipairs(M.LANG_INDEX[lang or ""] or {}) do add(i) end
    add(2)
    for i = 0, 7 do add(i) end
    return out
  end

  local function begin(lang)
    cands, cand, data = candidates(lang), 0, nil
    files, lines = {}, {}
    state = "open"
  end

  local function open_next()
    cand = cand + 1
    if cand > #cands then
      state = "unsupported"
      if fb.log and fb.log.warn then fb.log.warn("no readable game text archive found") end
      return
    end
    local idx = cands[cand]
    local d = fb.rom.romfs(M.GARC_DIR .. (M.GARC_BASE + idx))
    if type(d) ~= "string" then return end
    local ok, g = pcall(codec.garc, d)
    if not ok or type(g) ~= "table" or type(g.count) ~= "number" or g.count < M.MIN_ENTRIES then return end
    data = d
    kinds_left = {}
    for i, k in ipairs(M.KIND_ORDER) do kinds_left[i] = k end
    files = {}
    state = "fetch"
    cands.current = idx
  end

  local function fetch_next()
    local kind = table.remove(kinds_left, 1)
    if kind then
      local raw = codec.garc_file(data, M.FILES[kind] + 1, 1)
      if type(raw) == "string" then
        local f = M.parse(raw)
        if f then files[kind] = f end
      end
    end
    if #kinds_left == 0 then
      for _, k in ipairs(M.REQUIRED) do
        if not files[k] then -- not this language: try the next archive
          data, files, state = nil, {}, "open"
          return
        end
      end
      data = nil
      state = "done"
      if fb.log and fb.log.info then fb.log.info("game text loaded, language index " .. tostring(cands.current)) end
    end
  end

  local function advance()
    if state == "idle" then
      local lang = opts.language_fn and opts.language_fn() or nil
      if lang == nil then
        waited = waited + 1
        if waited < M.FALLBACK_STEPS then return end
        fallback_used = true
      end
      begin(lang)
    elseif state == "open" then
      open_next()
    elseif state == "fetch" then
      fetch_next()
    elseif state == "done" and fallback_used then
      -- loaded without knowing the language: reload once the real one is known
      local lang = opts.language_fn and opts.language_fn() or nil
      if lang ~= nil then fallback_used = false; begin(lang) end
    end
  end

  -- One bounded step. Never raises.
  function self.step()
    if state == "unsupported" then return end
    if state == "done" and not fallback_used then return end
    local ok, err = pcall(advance)
    if not ok then
      state = "unsupported"
      if fb.log and fb.log.error then fb.log.error("game text failed: " .. tostring(err)) end
    end
  end

  function self.state() return state end
  function self.ready() return state == "done" end
  function self.language_index() return cands and cands.current end

  -- Like name() but never advances the loading: the string, or nil when not loaded / unknown.
  function self.peek(kind, id)
    if state ~= "done" then return nil end
    return (self.name(kind, id))
  end

  -- Name from the game text: string, or nil, "not_ready" | "unsupported" | "unknown_kind".
  function self.name(kind, id)
    if not M.FILES[kind] then return nil, "unknown_kind" end
    if state == "unsupported" then return nil, "unsupported" end
    if state ~= "done" then self.step(); return nil, "not_ready" end
    if math.type(id) ~= "integer" then return nil end
    local f = files[kind]
    if not f then return nil end
    local lk = lines[kind]
    if not lk then lk = {}; lines[kind] = lk end
    local v = lk[id]
    if v == nil then
      local ok, s = pcall(f.line, id)
      v = (ok and type(s) == "string" and s ~= "") and s or false
      lk[id] = v
    end
    return v or nil
  end

  return self
end

return M

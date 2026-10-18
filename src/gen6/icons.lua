-- Box icons of Gen 6 games, read at runtime from the player's own RomFS and
-- converted to PNG with fb.codec.bclim + fb.codec.png. Nothing is shipped; the
-- PNGs are derived data in the plugin cache (fb.cache), never in the repository.
--
-- The icon GARC is not hardcoded: it is discovered by walking the RomFS and
-- validated by content (see docs/games/omega-ruby-alpha-sapphire.md, "Icons").
-- Discovery runs one small step per call (one directory listing or one
-- candidate validation) so no entry call comes near the 500 ms / 20M budget.
local garc_entry = require("gen6.garc_entry")
local M = {}

M.CANDIDATE_PATHS = {}      -- known paths are not sourced; discovery finds the file
M.ROOT = "/a"
M.MIN_FILE_SIZE = 256 * 1024       -- assumption: >= ~700 icons of >= 0.4 KiB
M.MAX_FILE_SIZE = 16 * 1024 * 1024
M.MIN_ENTRIES, M.MAX_ENTRIES = 700, 1100
M.SAMPLES = { 1, 25, 150, 300, 500, 700 } -- species whose entries are decoded to validate
M.SIZES = { ["40x30"] = true, ["32x32"] = true, ["64x32"] = true } -- accepted BCLIM sizes
M.MAX_STEPS = 4000
M.INDEX_FILE = "icons/index.txt"      -- first line: RomFS path of the icon GARC
M.OVERRIDE_FILE = "config/icon_garc.txt" -- optional: RomFS path to try first
M.MAX_SPECIES = 721
M.PROBE_PATH = "/a/0/9/1"   -- Project Pokemon ORAS file system: "971 box sprites" (diagnostics probe only)
M.PROBE_ENTRIES = { 1, 25, 700 } -- 0-based GARC entries inspected by diagnostics()

local function first_line(s)
  if type(s) ~= "string" then return nil end
  local l = s:match("^%s*([^\r\n]-)%s*[\r\n]") or s:match("^%s*(.-)%s*$")
  if l and l:match("^/[%w%._%-/]+$") then return l end
  return nil
end

function M.new(fb, personal)
  local self = {}
  local codec = fb.codec
  local can = fb.rom and fb.rom.romfs and fb.rom.romfs_list and codec and codec.garc
    and codec.garc_file and codec.bclim and codec.png and fb.cache and true or false

  local state = can and "idle" or "unsupported" -- idle | scan | done | failed | unsupported
  local data, path
  local forced, dirs, cands, steps = {}, {}, {}, 0

  local function read_cache(name)
    local ok, v = pcall(fb.cache.read, name)
    if ok and type(v) == "string" then return v end
    return nil
  end

  -- Accepts the GARC when sampled entries decode to BCLIM images of an accepted size.
  local first_reject = nil
  local function reject(why) if not first_reject then first_reject = why end; return false end
  local function short(v) return (tostring(v):gsub("[^%w _%.:%-]", "?"):sub(1, 40)) end

  local function validate(d)
    local ok, g, gerr = pcall(codec.garc, d)
    if not ok or type(g) ~= "table" or type(g.count) ~= "number" then
      return reject("garc_rejected: " .. short(ok and gerr or g))
    end
    if g.count < M.MIN_ENTRIES or g.count > M.MAX_ENTRIES then return reject("garc_entries_" .. g.count) end
    for _, s in ipairs(M.SAMPLES) do
      local e = garc_entry.entry(codec, d, s + 1)
      if type(e) ~= "string" then return reject("entry_unreadable_" .. s) end
      local img = codec.bclim(e)
      if type(img) ~= "table" then return reject("bclim_failed_" .. s) end
      local size = tostring(img.width) .. "x" .. tostring(img.height)
      if not M.SIZES[size] then return reject("size_" .. size) end
    end
    return true
  end

  local function try_path(p)
    local d = fb.rom.romfs(p)
    if type(d) ~= "string" or not validate(d) then return false end
    data, path, state = d, p, "done"
    pcall(fb.cache.write, M.INDEX_FILE, p .. "\n")
    if fb.log and fb.log.info then fb.log.info("icon archive accepted at " .. p) end
    return true
  end

  local function start()
    state = "scan"
    local seen = {}
    local function add(p)
      if p and not seen[p] then seen[p] = true; forced[#forced + 1] = p end
    end
    add(first_line(read_cache(M.OVERRIDE_FILE)))
    add(first_line(read_cache(M.INDEX_FILE)))
    for _, p in ipairs(M.CANDIDATE_PATHS) do add(p) end
    dirs = { M.ROOT }
  end

  local function scan_dir(dir)
    local list = fb.rom.romfs_list(dir)
    if type(list) ~= "table" then return end
    for _, e in ipairs(list) do
      local full = dir .. "/" .. tostring(e.name)
      if e.dir then
        dirs[#dirs + 1] = full
      elseif type(e.size) == "number" and e.size >= M.MIN_FILE_SIZE and e.size <= M.MAX_FILE_SIZE then
        cands[#cands + 1] = full
      end
    end
  end

  local function advance()
    if state == "idle" then start() end
    if state ~= "scan" then return end
    steps = steps + 1
    if steps > M.MAX_STEPS then state = "failed"; return end
    if #forced > 0 then
      try_path(table.remove(forced, 1))
    elseif #cands > 0 then
      try_path(table.remove(cands, 1))
    elseif #dirs > 0 then
      scan_dir(table.remove(dirs, 1))
    else
      state = "failed"
      if fb.log and fb.log.warn then fb.log.warn("no box icon archive found in the RomFS") end
    end
  end

  -- One bounded discovery step. Never raises.
  function self.step()
    local ok, err = pcall(advance)
    if not ok then
      state = "failed"
      if fb.log and fb.log.error then fb.log.error("icon discovery failed: " .. tostring(err)) end
    end
  end

  -- Probe of the icon archive for diagnostics(): numbers and short strings only, no pixels, no names.
  -- Read once and cached; the archive is the accepted one or, if none was accepted, M.PROBE_PATH.
  local probe, probe_key
  local function hex(b) return b and string.format("0x%02X", b) or "none" end
  local function probe_entry(out, tag, d, n)
    local ok, raw = pcall(codec.garc_file, d, n + 1, 1)
    if not ok or type(raw) ~= "string" or #raw == 0 then out[tag .. "_first"] = "unreadable"; return end
    out[tag .. "_first"] = hex(raw:byte(1))
    local e, status = garc_entry.decompress(codec, raw)
    out[tag .. "_lz11"] = status == "lz" and 1 or 0
    if status == "lz_failed" then out[tag .. "_lz_failed"] = 1 end
    out[tag .. "_size"] = #e
    local fmt, w, h = -1, -1, -1
    if #e >= 0x28 and e:sub(#e - 0x27, #e - 0x24) == "CLIM" then
      w, h = string.unpack("<I2I2", e, #e - 0x28 + 0x1C + 1)
      fmt = e:byte(#e - 0x28 + 0x20 + 1)
    end
    out[tag .. "_fmt"], out[tag .. "_w"], out[tag .. "_h"] = fmt, w, h
    out[tag .. "_px0"] = #e >= 2 and string.format("0x%04X", string.unpack("<I2", e, 1)) or "none"
  end

  local function run_probe()
    local out = { icons_state = state, icons_path = path or "none", icons_count = -1, icons_garc_ok = 0 }
    if not can then return out end
    local d = data
    if not d then
      local okr, r = pcall(fb.rom.romfs, M.PROBE_PATH)
      d = okr and type(r) == "string" and r or nil
      out.icons_path = M.PROBE_PATH .. (d and "" or " (unreadable)")
    end
    if d then
      local ok, g, gerr = pcall(codec.garc, d)
      if ok and type(g) == "table" and type(g.count) == "number" then
        out.icons_garc_ok, out.icons_count = 1, g.count
        for _, n in ipairs(M.PROBE_ENTRIES) do probe_entry(out, "icon_e" .. n, d, n) end
      else
        out.icons_garc_error = short(ok and gerr or g)
      end
    end
    return out
  end

  function self.diagnostics()
    if not can then return { icons_state = state } end
    -- one probe per archive: the fixed probe path until discovery accepts another archive
    local key = path or M.PROBE_PATH
    if not probe or probe_key ~= key then probe, probe_key = run_probe(), key end
    local out = {}
    for k, v in pairs(probe) do out[k] = v end
    out.icons_state = state
    out.icons_first_rejection = first_reject or "none"
    return out
  end

  function self.found() return state == "done" end
  function self.state() return state end
  function self.path() return path end

  -- Restart discovery (e.g. after a game change).
  function self.reset()
    if can then state = "idle" end
    data, path, forced, dirs, cands, steps = nil, nil, {}, {}, {}, 0
    probe, probe_key, first_reject = nil, nil, nil
  end

  local function entry_for(species, form)
    local idx = personal and personal.form_index(species, form)
    if idx then return idx, true end
    -- no such form or personal table unreadable: base icon, not cached under the form key
    return species, false
  end

  -- PNG string, or nil, "not_ready" | "unsupported" | "unknown_species".
  function self.icon(species, form)
    if math.type(species) ~= "integer" or species < 1 or species > M.MAX_SPECIES then
      return nil, "unknown_species"
    end
    if form == nil then form = 0 end
    if math.type(form) ~= "integer" or form < 0 then return nil, "unknown_species" end
    local key = string.format("icons/%d-%d.png", species, form)
    if state == "unsupported" then return nil, "unsupported" end
    local hit = read_cache(key)
    if hit then return hit end
    if state ~= "done" then
      self.step()
      if state == "failed" then return nil, "unsupported" end
      if state ~= "done" then return nil, "not_ready" end
    end
    local idx, exact = entry_for(species, form)
    local blob = garc_entry.entry(codec, data, idx + 1)
    if type(blob) ~= "string" then return nil, "unknown_species" end
    local img = codec.bclim(blob)
    if type(img) ~= "table" then return nil, "unknown_species" end
    local png = codec.png(img)
    if type(png) ~= "string" then return nil, "unknown_species" end
    if exact then pcall(fb.cache.write, key, png) end
    return png
  end

  return self
end

return M

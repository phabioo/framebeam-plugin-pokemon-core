-- Builds the table for fb.provide("pokemon.core", tbl).
local M = {}

local METHODS = { "team", "box", "box_count", "location", "battle", "encounters", "badges" }
local FEATURE = {
  team = "team", box = "box", location = "location",
  battle = "battle", encounters = "encounters", badges = "badges",
}

local function has(adapter, name)
  return adapter ~= nil and type(adapter[name]) == "function"
end

-- entry: games.lua entry, detected: info from games.detect, adapter: adapter object or nil
function M.new(entry, detected, adapter)
  local api = {}

  function api.info()
    local features = {}
    for method, key in pairs(FEATURE) do features[key] = has(adapter, method) end
    local language = detected and detected.language or nil
    if has(adapter, "language") then language = adapter:language() or language end
    local revision
    if has(adapter, "revision") then revision = adapter:revision() end
    return {
      game_id = entry.id,
      name = entry.name,
      gen = entry.gen,
      system = entry.system,
      version = entry.version,
      language = language,
      revision = revision,
      supported = adapter ~= nil,
      features = features,
    }
  end

  for _, method in ipairs(METHODS) do
    api[method] = function(...)
      if not has(adapter, method) then return nil, "unsupported" end
      return adapter[method](adapter, ...)
    end
  end

  return api
end

return M

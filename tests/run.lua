-- Run all tests: lua5.4 tests/run.lua (from repo root)
package.path = "src/?.lua;tests/?.lua;tests/support/?.lua;" .. package.path

local t = require("t")
local p = assert(io.popen("ls tests"))
local files = {}
for name in p:lines() do
  if name:match("^test_.*%.lua$") then files[#files + 1] = name end
end
p:close()
table.sort(files)

for _, name in ipairs(files) do
  t.file = name
  local ok, err = pcall(dofile, "tests/" .. name)
  if not ok then
    t.failed = t.failed + 1
    print(string.format("FAIL %s: load error: %s", name, tostring(err)))
  end
end

print(string.format("%d passed, %d failed, %d skipped (%d files)", t.passed, t.failed, t.skipped, #files))
os.exit(t.failed > 0 and 1 or 0)

-- EXP <-> level for the six standard growth curves (formulas only, no tables).
-- Rate IDs follow the games' personal data (PKHeX: Experience.GetEXPTable /
-- PersonalInfo.EXPGrowth): 0 medium fast, 1 erratic, 2 fluctuating,
-- 3 medium slow, 4 fast, 5 slow.
-- Formulas: Bulbapedia "Experience" (integer division rounds down).
local M = {}

M.MEDIUM_FAST, M.ERRATIC, M.FLUCTUATING = 0, 1, 2
M.MEDIUM_SLOW, M.FAST, M.SLOW = 3, 4, 5
M.MAX_LEVEL = 100

-- Total EXP needed to reach level n (1..100) with the given rate; nil for bad input.
function M.exp_for_level(rate, n)
  if math.type(n) ~= "integer" or n < 1 or n > 100 then return nil end
  if n == 1 then return 0 end
  local c = n * n * n
  if rate == 0 then
    return c
  elseif rate == 1 then
    if n < 50 then return c * (100 - n) // 50 end
    if n < 68 then return c * (150 - n) // 100 end
    if n < 98 then return c * ((1911 - 10 * n) // 3) // 500 end
    return c * (160 - n) // 100
  elseif rate == 2 then
    if n < 15 then return c * ((n + 1) // 3 + 24) // 50 end
    if n < 36 then return c * (n + 14) // 50 end
    return c * (n // 2 + 32) // 50
  elseif rate == 3 then
    return 6 * c // 5 - 15 * n * n + 100 * n - 140
  elseif rate == 4 then
    return 4 * c // 5
  elseif rate == 5 then
    return 5 * c // 4
  end
  return nil
end

-- Level (1..100) for an EXP value; nil when rate or exp are invalid.
function M.level_from_exp(rate, exp)
  if math.type(exp) ~= "integer" or exp < 0 then return nil end
  if M.exp_for_level(rate, 2) == nil then return nil end
  local level = 1
  for n = 2, 100 do
    if exp >= M.exp_for_level(rate, n) then level = n else break end
  end
  return level
end

return M

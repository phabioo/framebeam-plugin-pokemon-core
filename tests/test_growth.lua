local t = require("t")
local g = require("gen6.growth")

t.case("level 100 thresholds", function()
  t.eq(g.exp_for_level(0, 100), 1000000)
  t.eq(g.exp_for_level(1, 100), 600000)
  t.eq(g.exp_for_level(2, 100), 1640000)
  t.eq(g.exp_for_level(3, 100), 1059860)
  t.eq(g.exp_for_level(4, 100), 800000)
  t.eq(g.exp_for_level(5, 100), 1250000)
end)

t.case("level 1 and bounds", function()
  for rate = 0, 5 do
    t.eq(g.level_from_exp(rate, 0), 1)
    t.eq(g.level_from_exp(rate, g.exp_for_level(rate, 100)), 100)
    t.eq(g.level_from_exp(rate, 99999999), 100)
  end
  t.eq(g.level_from_exp(6, 10), nil)
  t.eq(g.level_from_exp(0, -1), nil)
end)

t.case("formula points", function()
  t.eq(g.exp_for_level(0, 10), 1000)
  t.eq(g.exp_for_level(4, 10), 800)
  t.eq(g.exp_for_level(5, 10), 1250)
  t.eq(g.exp_for_level(3, 10), 560)   -- 6*1000/5 - 1500 + 1000 - 140
  t.eq(g.exp_for_level(1, 10), 1800)  -- 1000*(100-10)/50
  t.eq(g.exp_for_level(2, 10), 540)   -- 1000*(11//3+24)/50
  t.eq(g.exp_for_level(3, 2), 9)
  t.eq(g.exp_for_level(2, 20), 5440)  -- 8000*34/50
end)

t.case("boundaries are exact", function()
  for rate = 0, 5 do
    for n = 2, 100 do
      local e = g.exp_for_level(rate, n)
      t.eq(g.level_from_exp(rate, e), n, "rate " .. rate .. " lvl " .. n)
      t.eq(g.level_from_exp(rate, e - 1) < n, true)
    end
  end
end)

t.case("monotonic", function()
  for rate = 0, 5 do
    for n = 2, 100 do t.ok(g.exp_for_level(rate, n) > g.exp_for_level(rate, n - 1)) end
  end
end)

#!/usr/bin/env texlua
-- Tests for files/engine/live_world.lua (reading the real game state) and for
-- the cache invalidation that depends on it (files/wand_sim_cache.lua).
--
--     texlua tools/test_live_world.lua
--
-- The real Noita API does not exist outside the game, so a tiny fake one is
-- installed as globals BEFORE live_world.lua is loaded: that is exactly the
-- moment the module captures the functions it will use.

local here = arg[0]:match("^(.*)[/\\]") or "."
local support = dofile(here .. "/test_support.lua")
support.install_mod_loader()

local failures = 0
local function passck(name, ok, detail)
	print((ok and "PASS " or "FAIL ") .. name .. (ok and "" or (detail or "")))
	if not ok then failures = failures + 1 end
end

-- ---- a fake game ----------------------------------------------------------------
local game = { hp = 2, max_hp = 4, money = 30, enemies = 3, projectiles = 1,
	toggle = "1", player = true }
local radii = {}

function EntityGetWithTag(tag)
	if tag == "player_unit" then return game.player and { 7 } or {} end
	if tag == "black_hole_giga" then return {} end
	return {}
end
function EntityGetFirstComponent(_, type_name) return type_name end
function ComponentGetValue2(component, field)
	if component == "DamageModelComponent" then return game[field] end
	if component == "WalletComponent" then return game.money end
end
function EntityGetTransform() return 10, 20 end
function EntityGetInRadiusWithTag(_, _, radius, tag)
	radii[tag] = radius
	local n = tag == "homing_target" and game.enemies or game.projectiles
	local out = {}
	for i = 1, n do out[i] = i end
	return out
end
function GlobalsGetValue(_, default) return game.toggle or default end

local live = dofile_once("mods/spell_bracket_visualizer/files/engine/live_world.lua")

local w = live.read()
passck("HP and max HP are read", w.hp == 2 and w.max_hp == 4)
passck("money is read", w.money == 30)
passck("nearby enemies and projectiles are counted", w.n_enemies == 3 and w.n_projectiles == 1)
passck("the radii are the ones the vanilla spells use",
	radii.homing_target == 240 and radii.projectile == 160)
passck("the every-other toggle is read", w.every_other_state == 1)

game.player = false
w = live.read()
passck("no player: HP is left out, not invented", w.hp == nil and w.n_enemies == nil)

-- ---- engine + cache --------------------------------------------------------------
game.player = true
local engine = support.new_engine()
local S = dofile_once("mods/spell_bracket_visualizer/files/wand_structure.lua")
local cache_module = dofile_once("mods/spell_bracket_visualizer/files/wand_sim_cache.lua")

local runs = 0
local cache = cache_module.new(function(wand)
	runs = runs + 1
	return S.simulate(engine, wand)
end, nil, function(sim) return engine.deps_hold(sim.deps) end)

local wand = { tokens = { "IF_HP", "LIGHT_BULLET", "IF_END", "BOUNCY_ORB" } }
engine.set_world(live.read())
cache.get(wand); cache.get(wand)
passck("an unchanged world reuses the cached simulation", runs == 1)

game.hp = 4
engine.set_world(live.read())
cache.get(wand)
passck("a change to a value the wand checked recomputes it", runs == 2)

game.enemies = 9   -- nothing on this wand looks at enemies
engine.set_world(live.read())
cache.get(wand)
passck("a change to a value it never read does not", runs == 2)

local plain = { tokens = { "LIGHT_BULLET" } }
cache.get(plain); game.hp = 1; engine.set_world(live.read()); cache.get(plain)
passck("a wand with no conditional spell is computed once", runs == 3)

print(failures == 0 and "ALL PASS" or (failures .. " FAILED")); os.exit(failures == 0 and 0 or 1)

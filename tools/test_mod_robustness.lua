#!/usr/bin/env texlua
-- Robustness against third-party mods that touch the cast code.
--
--     texlua tools/test_mod_robustness.lua
--
-- Real mods do three things the sandbox must survive:
--   * replace draw_shot and call engine functions that return values
--     (SpellPerformance: `tonumber(ModSettingGet(...))`);
--   * add spells whose body throws;
--   * replace draw_shot with a version that throws.
-- None of them may abort the simulation: the wand must still be computed,
-- the offending card flagged uncertain, and the failure reported.
--
-- The "mods" are small stand-ins patched in after the game's own files load,
-- the way ModLuaFileAppend does in game.

local here = arg[0]:match("^(.*)[/\\]") or "."
local support = dofile(here .. "/test_support.lua")
support.install_mod_loader()
local S = dofile_once("mods/spell_bracket_visualizer/files/wand_structure.lua")
local engine_module = dofile_once("mods/spell_bracket_visualizer/files/engine/engine.lua")

local failures = 0
local function passck(name, ok, extra)
	if ok then print("PASS " .. name) else failures = failures + 1; print("FAIL " .. name .. (extra or "")) end
end

-- An engine whose host dofile appends `patch` (Lua source) after gun.lua loads.
local function engine_with(patch)
	local base = support.gun_ref_dofile()
	local load, G = load, _G
	local host = { dofile = function(path)
		local result = base(path)
		if path:match("gun/gun%.lua$") then assert(load(patch, "=patch", "t", G))() end
		return result
	end }
	return assert(engine_module.new(host))
end

local function sim_of(engine, tokens)
	return S.simulate(engine, { tokens = tokens, spells_per_cast = 1 })
end

-- ---- 1. SpellPerformance-style draw_shot: tonumber(ModSettingGet(...)) ---------
local perf = [[
local original = draw_shot
function draw_shot(shot, instant)
	local setting = tonumber(ModSettingGet("spell_performance.cosmetics_setting"))
	original(shot, instant)
	return setting
end
]]
local engine = engine_with(perf)
local sim = sim_of(engine, { "LIGHT_BULLET", "BOUNCY_ORB" })
passck("a draw_shot reading ModSettingGet no longer kills the simulation",
	sim.error == nil and #sim.casts > 0, " (" .. tostring(sim.error) .. ")")
passck("...and the unset setting is recorded as a guess, not trusted",
	sim.deps["setting:spell_performance.cosmetics_setting"] == nil and sim.uncertain ~= nil)

engine.set_setting_reader(function(key) if key:match("cosmetics") then return "3" end end)
sim = sim_of(engine, { "LIGHT_BULLET" })
passck("with a real setting the wand is certain", sim.uncertain == nil)
passck("...and depends on it", sim.deps["setting:spell_performance.cosmetics_setting"] == "3")
passck("...so a changed setting makes the cached result stale", (function()
	local ok = engine.deps_hold(sim.deps)
	engine.set_setting_reader(function() return "1" end)
	return ok and not engine.deps_hold(sim.deps)
end)())

-- ---- 2. a spell body that throws ----------------------------------------------------
local boom = [[
actions[#actions + 1] = { id = "TEST_BOOM", name = "x", description = "x",
	sprite = "x", type = ACTION_TYPE_OTHER, spawn_level = "0", spawn_probability = "0",
	price = 1, mana = 0, action = function() error("boom") end }
]]
engine = engine_with(boom)
sim = sim_of(engine, { "TEST_BOOM", "LIGHT_BULLET" })
passck("a throwing spell does not abort the wand", sim.error == nil and #sim.casts > 0,
	" (" .. tostring(sim.error) .. ")")
passck("...it is reported as a problem", sim.problems and #sim.problems == 1
	and sim.problems[1]:find("TEST_BOOM", 1, true) ~= nil)
passck("...and the card is flagged uncertain",
	sim.uncertain ~= nil and #S.uncertain_ids(sim) == 1 and S.uncertain_ids(sim)[1] == "TEST_BOOM")
passck("...while the other card is still simulated", (function()
	for _, cast in ipairs(sim.casts) do
		for _, node in ipairs(cast.nodes) do
			if node.id == "LIGHT_BULLET" then return true end
		end
	end
end)())

-- ---- 3. a draw_shot that throws ----------------------------------------------------
engine = engine_with([[
local original = draw_shot
function draw_shot(shot, instant) original(shot, instant); error("late failure") end
]])
sim = sim_of(engine, { "LIGHT_BULLET", "BOUNCY_ORB" })
passck("a throwing draw_shot is contained", sim.error == nil and #sim.casts > 0,
	" (" .. tostring(sim.error) .. ")")
passck("...and reported", sim.problems ~= nil and sim.problems[1]:find("late failure", 1, true) ~= nil)

-- ---- 4. unknown engine calls yield one nil, not zero values ---------------------------
engine = engine_with([[
actions[#actions + 1] = { id = "TEST_NIL", name = "x", description = "x",
	sprite = "x", type = ACTION_TYPE_OTHER, spawn_level = "0", spawn_probability = "0",
	price = 1, mana = 0,
	action = function() local n = tonumber(SomeUnknownEngineCall()); local s = tostring(AnotherOne()) end }
]])
sim = sim_of(engine, { "TEST_NIL" })
passck("tonumber(<unknown engine call>) does not throw", sim.error == nil and sim.problems == nil,
	" (" .. tostring(sim.error) .. ")")
passck("...but the card is still marked as a guess", #S.uncertain_ids(sim) == 1)

print(failures == 0 and "ALL PASS" or (failures .. " FAILED")); os.exit(failures == 0 and 0 or 1)

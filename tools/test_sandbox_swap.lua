#!/usr/bin/env texlua
-- Tests for the global-table swap in files/engine/game_env.lua.
--
--     texlua tools/test_sandbox_swap.lua
--
-- The swap is what keeps the game's cast code away from the live game, so it
-- is checked head on: real globals must come back exactly (even after an
-- error), nothing the sandbox defines may leak out, and nothing real may leak in.

local here = arg[0]:match("^(.*)[/\\]") or "."
local support = dofile(here .. "/test_support.lua")
support.install_mod_loader()

local failures = 0
local function eq(name, got, want)
	if got == want then print("PASS " .. name) return end
	failures = failures + 1
	print("FAIL " .. name .. "\n    expect " .. tostring(want) .. "\n    got    " .. tostring(got))
end

local function snapshot()
	local copy = {}
	for k, v in pairs(_G) do copy[k] = v end
	return copy
end
local function same_globals(a, b)
	for k, v in pairs(a) do if b[k] ~= v then return false, k end end
	for k in pairs(b) do if a[k] == nil then return false, k end end
	return true
end

-- A real "engine function" that must never be reached from inside the sandbox.
local reached = false
SECRET_ENGINE_CALL = function() reached = true end
REAL_ONLY_VALUE = 123

local game_env = dofile_once("mods/spell_bracket_visualizer/files/engine/game_env.lua")
local before = snapshot()
local game = assert(game_env.new(support.gun_ref_dofile()))

eq("building the sandbox leaves the real globals untouched",
	(same_globals(before, snapshot())), true)
eq("gun.lua's own globals did not leak out", rawget(_G, "deck"), nil)
eq("...nor its spell table", rawget(_G, "actions"), nil)

local seen = game.run(function()
	local out = {
		load = rawget(_G, "load"), io = rawget(_G, "io"), os = rawget(_G, "os"),
		real_only = rawget(_G, "REAL_ONLY_VALUE"), actions = #rawget(_G, "actions"),
	}
	SECRET_ENGINE_CALL()
	return out
end)
eq("inside: the sandbox holds the game's spells", seen.actions > 100, true)
eq("inside: no load, io or os", seen.load == nil and seen.io == nil and seen.os == nil, true)
eq("inside: real-only globals are invisible", seen.real_only, nil)
eq("inside: an engine call does NOT reach the real function", reached, false)
eq("inside: ...it is counted as unknown instead", game.report.unknown.SECRET_ENGINE_CALL, 1)
eq("after a run the real globals are back exactly",
	(same_globals(before, snapshot())), true)

local ok, err = pcall(game.run, function() error("boom", 0) end)
eq("an error inside is rethrown", ok == false and err == "boom", true)
eq("...and the real globals are restored anyway",
	(same_globals(before, snapshot())), true)
eq("the sandbox is usable again after an error",
	game.run(function() return #rawget(_G, "actions") end) > 100, true)

local nested_ok = pcall(game.run, function() game.run(function() end) end)
eq("running the sandbox inside itself is refused", nested_ok, false)
eq("...and that too leaves the real globals intact",
	(same_globals(before, snapshot())), true)

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)

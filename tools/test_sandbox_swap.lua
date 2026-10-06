#!/usr/bin/env texlua
-- Tests for the global-table swap in files/engine/game_env.lua.
--
--     texlua tools/test_sandbox_swap.lua
--
-- The swap is what keeps the game's cast code away from the live game, so it
-- is checked head on: real globals must come back exactly (even after an
-- error), nothing the sandbox defines may leak out, and no real engine function
-- (a CamelCase global) may be reachable from inside.

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
-- a C function, like the real engine API: if the sandbox let it through, the
-- missing argument would make it raise
SECRET_ENGINE_CALL = error
-- a CamelCase function written in Lua is code, not the engine: it must keep working
LUA_HELPER = function() return "helper ran" end

-- a lowercase helper stands in for Noita's own `dofile` internals (e.g. __loaded)
__internal_helper = function() return "still here" end

local game_env = dofile_once("mods/spell_bracket_visualizer/files/engine/game_env.lua")
local before = snapshot()
local game = assert(game_env.new({ dofile = support.gun_ref_dofile() }))

eq("building the sandbox leaves the real globals untouched",
	(same_globals(before, snapshot())), true)
eq("gun.lua's own globals did not leak out", rawget(_G, "deck"), nil)
eq("...nor its spell table", rawget(_G, "actions"), nil)

local seen = game.run(function()
	local out = {
		helper = rawget(_G, "__internal_helper")(),
		actions = #rawget(_G, "actions"),
	}
	out.guarded = pcall(SECRET_ENGINE_CALL)
	out.lua_helper = LUA_HELPER()
	return out
end)
eq("inside: the sandbox holds the game's spells", seen.actions > 100, true)
eq("inside: lowercase internals (what dofile needs) stay available", seen.helper, "still here")
eq("inside: an engine call does NOT reach the real function", seen.guarded, true)
eq("inside: a CamelCase function written in Lua keeps working", seen.lua_helper, "helper ran")
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

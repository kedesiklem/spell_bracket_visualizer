#!/usr/bin/env texlua
-- Checks files/engine/lua_compat.lua under the three hosts it has to serve.
--
--     texlua tools/test_lua_compat.lua
--
-- The offline tools run Lua 5.2+, where `setfenv` and `loadstring` do not exist,
-- so the LuaJIT-style paths are exercised by faking those two globals.  What it
-- cannot prove is that the real game behaves the same -- that needs a play-test.

local here = arg[0]:match("^(.*)[/\\]") or "."
local failures = 0
local function eq(name, got, want)
	if got == want then print("PASS " .. name) return end
	failures = failures + 1
	print("FAIL " .. name .. "\n    expect " .. tostring(want) .. "\n    got    " .. tostring(got))
end

local function fresh() return dofile(here .. "/../files/engine/lua_compat.lua") end
local SOURCE = "return answer"

-- 1. plain Lua 5.2+: load with an env argument
eq("5.2+: free names resolve in the sandbox",
	fresh().load_in_env(SOURCE, "t", { answer = 42 })(), 42)

-- A stand-in for LuaJIT's setfenv, built on the 5.3 debug library.
local function fake_setfenv(fn, env)
	debug.upvaluejoin(fn, 1, function() return env end, 1)
	return fn
end

-- 2. LuaJIT-like host that still has loadstring
do
	local saved_load, saved_ls, saved_sf = load, loadstring, setfenv
	loadstring = function(src, name) return saved_load(src, name) end
	setfenv = fake_setfenv
	local chunk = fresh().load_in_env(SOURCE, "t", { answer = 7 })
	eq("setfenv + loadstring: free names resolve in the sandbox", chunk and chunk(), 7)
	loadstring, setfenv = saved_ls, saved_sf
end

-- 3. Noita: setfenv exists but loadstring is nil -> must fall back to load
do
	local saved_ls, saved_sf = loadstring, setfenv
	loadstring = nil
	setfenv = fake_setfenv
	local chunk, err = fresh().load_in_env(SOURCE, "t", { answer = 9 })
	eq("setfenv without loadstring: falls back to load", chunk and chunk(), 9)
	eq("setfenv without loadstring: no error", err, nil)
	loadstring, setfenv = saved_ls, saved_sf
end

-- 4. a syntax error comes back as a message, not a crash
do
	local chunk, err = fresh().load_in_env("return +", "bad", {})
	eq("a bad chunk returns nil and a message", chunk == nil and type(err) == "string", true)
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)

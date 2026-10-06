-- Lua version shims shared by the engine layer.
--
-- Noita embeds LuaJIT (Lua 5.1 semantics: `setfenv`), while the offline test
-- tools run on a stock Lua 5.2+ interpreter (`load` with an env argument).
-- Which compile function exists varies: stock LuaJIT has `loadstring`, but
-- Noita's own Lua environment does NOT expose it (calling it fails with "attempt
-- to call a nil value"), so `load` is the fallback there.  Everything in
-- files/engine/ that has to behave identically in all these places goes through
-- this file, so the rest of the engine never branches on the interpreter.

local M = {}

--- Compile source text with whatever the host offers, WITHOUT choosing an
-- environment yet.  Prefers `loadstring`, falls back to `load`; the reader-
-- function form is tried when `load` refuses a plain string (Lua 5.1-style load).
local function compile(source, chunkname)
	if loadstring then return loadstring(source, chunkname) end
	if not load then return nil, "this Lua has neither loadstring nor load" end
	local chunk, err = load(source, chunkname)
	if chunk then return chunk end
	local given = false
	return load(function()
		if given then return nil end
		given = true
		return source
	end, chunkname) or nil, err
end

--- Compile `source` so that its free names resolve in `env` (a sandbox table).
-- @param source    string  Lua source text.
-- @param chunkname string  Name shown in error messages (e.g. the file path).
-- @param env       table   Environment the chunk runs in.
-- @return function|nil, string|nil  The compiled chunk, or nil plus the error.
function M.load_in_env(source, chunkname, env)
	if setfenv then
		local chunk, err = compile(source, chunkname)
		if not chunk then return nil, err end
		setfenv(chunk, env)
		return chunk
	end
	-- Lua 5.2+: the environment is an argument of load itself.
	return load(source, chunkname, "t", env)
end

--- `table.unpack` under both names.
M.unpack = unpack or table.unpack

return M

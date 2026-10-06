-- Lua version shims shared by the engine layer.
--
-- Noita embeds LuaJIT (Lua 5.1 semantics: `loadstring` + `setfenv`), while the
-- offline test tools run on a stock Lua 5.2+ interpreter (`load` with an env
-- argument).  Everything in files/engine/ that has to behave identically in
-- both places goes through this file, so the rest of the engine never branches
-- on the interpreter version.

local M = {}

--- Compile `source` so that its free names resolve in `env` (a sandbox table).
-- @param source    string  Lua source text.
-- @param chunkname string  Name shown in error messages (e.g. the file path).
-- @param env       table   Environment the chunk runs in.
-- @return function|nil, string|nil  The compiled chunk, or nil plus the error.
function M.load_in_env(source, chunkname, env)
	if setfenv then
		local chunk, err = loadstring(source, chunkname)
		if not chunk then return nil, err end
		setfenv(chunk, env)
		return chunk
	end
	return load(source, chunkname, "t", env)
end

--- `table.unpack` under both names.
M.unpack = unpack or table.unpack

return M

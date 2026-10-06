-- Lua version shims shared by the engine layer.
--
-- Noita embeds LuaJIT (Lua 5.1 semantics), while the offline test tools run on
-- a stock Lua 5.2+ interpreter.  The engine needs to behave identically in
-- both, so the few places where they differ live here.
--
-- Note what is NOT here: a way to compile source text.  Noita's Lua exposes
-- neither `loadstring` nor `load`, so the engine never compiles anything itself;
-- game files are run by the host's `dofile` (see game_env.lua).

local M = {}

--- `table.unpack` under both names.
M.unpack = unpack or table.unpack

return M

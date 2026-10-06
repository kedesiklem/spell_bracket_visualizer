-- Remembers wand simulations, so the game's cast code is run once per wand
-- CHANGE rather than once per frame.
--
-- Running the real gun.lua is far heavier than the table lookups the old
-- simulator did, and the overlay asks about every wand in the inventory every
-- frame.  But a simulation depends only on what is IN the wand -- its cards,
-- always-cast cards, charge counts and cast settings -- so the answer can be
-- keyed by exactly that and reused until the player rearranges something.
--
-- ...unless the result also depended on LIVE game state (the player's HP for
-- "If HP is low", the every-other toggle...).  A result records those values
-- (`result.deps`); `is_fresh` says whether they still hold, and a stale entry
-- is recomputed.  So a wand with no conditional spell is computed once per
-- change, one with an "If" spell once per change of the value it checks.
--
-- Public API
--   M.new(simulate, capacity, is_fresh) -> cache
--     simulate(wand) -> result   the expensive function being memoised
--     capacity                   most results kept (default 24)
--     is_fresh(result) -> bool   optional; false forces a recompute
--   cache.get(wand) -> result    wand = { tokens, always, uses, spells_per_cast, ... }
--   cache.clear()                forget everything (e.g. after a mod list change)

local M = {}

local function key_of(wand)
	local uses = {}
	for slot, count in pairs(wand.uses or {}) do uses[#uses + 1] = slot .. "=" .. count end
	table.sort(uses)
	return table.concat({
		table.concat(wand.tokens, ","),
		table.concat(wand.always or {}, ","),
		table.concat(uses, ","),
		tostring(wand.spells_per_cast or 1),
		wand.shuffle and "s" or "",
	}, "|")
end

function M.new(simulate, capacity, is_fresh)
	capacity = capacity or 24
	local cache = {}
	local entries, order = {}, {}   -- key -> result, and keys oldest first

	function cache.get(wand)
		local key = key_of(wand)
		local hit = entries[key]
		if hit ~= nil and (is_fresh == nil or is_fresh(hit)) then return hit end
		local result = simulate(wand)
		if entries[key] == nil then order[#order + 1] = key end
		entries[key] = result
		if #order > capacity then
			entries[table.remove(order, 1)] = nil
		end
		return result
	end

	function cache.clear()
		entries, order = {}, {}
	end

	return cache
end

return M

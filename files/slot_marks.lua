-- Decides which cards of a wand get a MARK drawn on them, besides brackets.
--
-- Brackets say which cards a spell pulled in.  Three more things are worth seeing
-- on the slot row itself, and none is a grouping:
--
--   underline   a modifier chain: the modifiers and the card they modify are
--               drawn as one unit, so "which card does Damage Plus feed?" is
--               answered by a coloured line rather than by counting brackets.
--   strike      a card that was drawn but never fired: a depleted spell, a card
--               a failed "If ..." threw away.
--   copied      a card whose body another card re-ran: what Alpha, Gamma, Tau,
--               Omega, Double Spell... copied.  A small dot above the card, one
--               per copier, so "which spell is this Greek letter copying?" is
--               answered on the wand itself.  Only wands with a copier get any.
--
-- This module is pure -- slots in, columns out, no Gui and no pixels -- exactly
-- like the bracket planner, so it is tested without the game.  What each mark
-- LOOKS like (colour, thickness, offset) belongs to grouping_overlay.lua.
--
-- Public API
--   M.collect(sim, cols, rows) -> { mark... }
--     sim   result of wand_structure.simulate
--     cols  deck slot (1-based) -> displayed slot column (0-based)
--     rows  deck slot -> displayed slot row (0-based)
--   mark = { kind = "underline", ca, cb, row }   columns ca..cb on one row
--        | { kind = "strike", col, row }
--        | { kind = "copied", col, row, n }   n copiers re-ran this card

local M = {}

local function underline_of(expr, cols, rows)
	local lo, hi
	for _, slot in ipairs(expr.marked) do
		if cols[slot] then
			if lo == nil or slot < lo then lo = slot end
			if hi == nil or slot > hi then hi = slot end
		end
	end
	if lo == nil or lo == hi then return nil end
	-- A wand box wraps its slot row; a line cannot follow the wrap, and a chain
	-- is never split across rows in practice, so draw nothing rather than lie.
	if (rows[lo] or 0) ~= (rows[hi] or 0) then return nil end
	return { kind = "underline", ca = cols[lo], cb = cols[hi], row = rows[lo] or 0 }
end

-- Tally which slots were copied, by how many copiers.  A copy of the copier
-- itself (Alpha as the first card copies Alpha) says nothing about another card
-- and is not counted.
local function tally_copies(expr, tally)
	-- the copier's own slot: where it was drawn, or -- for a copy that itself
	-- copies -- the slot of the card whose body is running
	local own = expr.head or (expr.recast and expr.sources and expr.sources[1]) or nil
	for _, child in ipairs(expr.children or {}) do
		if child.recast then
			for _, slot in ipairs(child.sources or {}) do
				if slot ~= own then tally[slot] = (tally[slot] or 0) + (child.count or 1) end
			end
		end
	end
end

local function collect_expression(expr, cols, rows, out, tally)
	tally_copies(expr, tally)
	if expr.marked then
		local mark = underline_of(expr, cols, rows)
		if mark then out[#out + 1] = mark end
	end
	for _, slot in ipairs(expr.skipped or {}) do
		if cols[slot] then
			out[#out + 1] = { kind = "strike", col = cols[slot], row = rows[slot] or 0 }
		end
	end
	for _, child in ipairs(expr.children or {}) do
		collect_expression(child, cols, rows, out, tally)
	end
end

function M.collect(sim, cols, rows)
	local out, tally = {}, {}
	for _, cast in ipairs(sim.casts or {}) do
		for _, expr in ipairs(cast.nodes) do collect_expression(expr, cols, rows, out, tally) end
		for _, expr in ipairs(cast.always) do collect_expression(expr, cols, rows, out, tally) end
		for _, slot in ipairs(cast.spent or {}) do
			if cols[slot] then
				out[#out + 1] = { kind = "strike", col = cols[slot], row = rows[slot] or 0 }
			end
		end
	end
	local slots = {}
	for slot in pairs(tally) do slots[#slots + 1] = slot end
	table.sort(slots)
	for _, slot in ipairs(slots) do
		if cols[slot] then
			out[#out + 1] = { kind = "copied", col = cols[slot], row = rows[slot] or 0, n = tally[slot] }
		end
	end
	return out
end

return M

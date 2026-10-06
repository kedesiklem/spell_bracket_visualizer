-- Decides which cards of a wand get a MARK drawn on them, besides brackets.
--
-- Brackets say which cards a spell pulled in.  Two more things are worth seeing
-- on the slot row itself, and neither is a grouping:
--
--   underline   a modifier chain: the modifiers and the card they modify are
--               drawn as one unit, so "which card does Damage Plus feed?" is
--               answered by a coloured line rather than by counting brackets.
--   strike      a card that was drawn but never fired: a depleted spell, a card
--               a failed "If ..." threw away.
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

local function collect_expression(expr, cols, rows, out)
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
		collect_expression(child, cols, rows, out)
	end
end

function M.collect(sim, cols, rows)
	local out = {}
	for _, cast in ipairs(sim.casts or {}) do
		for _, expr in ipairs(cast.nodes) do collect_expression(expr, cols, rows, out) end
		for _, slot in ipairs(cast.spent or {}) do
			if cols[slot] then
				out[#out + 1] = { kind = "strike", col = cols[slot], row = rows[slot] or 0 }
			end
		end
	end
	return out
end

return M

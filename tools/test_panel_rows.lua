#!/usr/bin/env lua5.4
-- Validates the wand-structure panel's ROW CLAMP against the REAL
-- files/grouping_overlay.lua, by stubbing the game's Gui API and recording
-- what draw_panel actually draws.
--
--     lua tools/test_panel_rows.lua        (any Lua 5.1+ / LuaJIT)
--
-- What's at stake: a structure too long for the screen folds its tail into one
-- "... +N more" line. The "?" legend ("depends on game state when cast") is
-- appended LAST, so a naive tail-cut drops the legend while the "?" marks it
-- explains stay on screen above it -- unexplained. Rows may set sticky=true to
-- be held back from the cut and re-appended after it; the "+N more" count then
-- has to be over the CONTENT rows only, or it silently misreports how much was
-- hidden. Both halves are pure arithmetic, and both are off-by-one bait.

local here = arg[0]:match("^(.*)[/\\]") or "."
local MOD = here .. "/.."

-- ---- stub the game environment, then load the REAL overlay ------------------

function dofile_once(path)
	local rel = path:match("^mods/spell_bracket_visualizer/(.*)$")
	assert(rel, "unexpected dofile_once path: " .. tostring(path))
	return dofile(MOD .. "/" .. rel)
end

local drawn -- { texts = { {x, y, text, scale}, ... } }
function GuiZSet() end
function GuiColorSetForNextWidget() end
function GuiImageNinePiece() end
function GuiText(gui, x, y, text, scale)
	drawn.texts[#drawn.texts + 1] = { x = x, y = y, text = text, scale = scale }
end
-- Pixel-like font: linear in scale, so faithful_scale stays inert and the
-- clamp is exercised on its own rather than through the font-compat path.
function GuiGetTextDimensions(gui, text, scale)
	scale = scale or 1
	return 6 * #text * scale, 9 * scale
end

local overlay = dofile(MOD .. "/files/grouping_overlay.lua")
local T = assert(overlay._test, "grouping_overlay.lua did not export _test")

-- ---- tiny check harness (same conventions as the other tools/) -------------

local failures = 0
local function eq(what, got, want)
	if got == want then
		print("PASS " .. what)
	else
		failures = failures + 1
		print("FAIL " .. what)
		print("    expect " .. tostring(want))
		print("    got    " .. tostring(got))
	end
end

local TITLE = "Wand structure  (1/cast)"
local LEGEND = "? = depends on game state when cast"
local BRACKET_LEGEND = "[ ] = spells this card pulls from the wand"
local GREY = { 0.6, 0.6, 0.6 }

local function same_color(a, b)
	return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- Drive the real draw_panel and return just the row labels it drew (the title
-- and the "|" nesting spines are not rows).
local function render(rows, sh)
	drawn = { texts = {} }
	local anchor = { boxes = { { top = 48, right = 400 } }, sel = 1 }
	T.draw_panel(nil, rows, TITLE, 640, sh or 360, anchor, 1.0)
	local labels = {}
	for _, t in ipairs(drawn.texts) do
		if t.text ~= TITLE and t.text ~= "|" then labels[#labels + 1] = t.text end
	end
	return labels
end

local function content_rows(n)
	local rows = {}
	for i = 1, n do
		rows[i] = { bars = {}, label = "spell " .. i, color = GREY }
	end
	return rows
end

local function with_legend(rows)
	rows[#rows + 1] = { bars = {}, label = LEGEND, color = GREY, sticky = true }
	return rows
end

local function count_more(labels)
	local n, text = 0, nil
	for _, l in ipairs(labels) do
		if l:match("^%.%.%. %+%d+ more$") then n = n + 1; text = l end
	end
	return n, text and tonumber(text:match("%+(%d+)")) or nil
end

-- ---- 1. short structure: nothing is cut, the legend sits last ---------------

local labels = render(with_legend(content_rows(3)), 360)
eq("short: every row drawn", #labels, 4)
eq("short: legend is last", labels[#labels], LEGEND)
eq("short: no '+N more' line", (count_more(labels)), 0)

-- ---- 2. long structure WITH the sticky legend -------------------------------
--
-- The legend must survive the cut and stay last, and the "+N more" count must
-- describe the CONTENT rows hidden -- not count the legend as content.

labels = render(with_legend(content_rows(200)), 360)
local n_more, hidden = count_more(labels)
eq("clamped: exactly one '+N more' line", n_more, 1)
eq("clamped: legend survives the cut", labels[#labels], LEGEND)

local shown = 0
for _, l in ipairs(labels) do
	if l ~= LEGEND and not l:match("^%.%.%. %+%d+ more$") then shown = shown + 1 end
end
eq("clamped: hidden count accounts for every content row", shown + hidden, 200)
eq("clamped: rows drawn are a prefix (first content row kept)", labels[1], "spell 1")
eq("clamped: '+N more' sits directly above the legend",
	labels[#labels - 1]:match("^%.%.%. %+%d+ more$") ~= nil, true)

-- ---- 3. long structure with NO sticky row (pre-existing behaviour) ----------
--
-- Regression guard: the sticky branch must not perturb the plain tail-cut.

labels = render(content_rows(200), 360)
n_more, hidden = count_more(labels)
eq("no-legend: exactly one '+N more' line", n_more, 1)
eq("no-legend: '+N more' is last", labels[#labels]:match("^%.%.%. %+%d+ more$") ~= nil, true)

shown = 0
for _, l in ipairs(labels) do
	if not l:match("^%.%.%. %+%d+ more$") then shown = shown + 1 end
end
eq("no-legend: hidden count accounts for every content row", shown + hidden, 200)

-- The legend is paid for out of the row budget, NOT added on top of it: the
-- clamped panel is the same height either way (it is clamped to the screen --
-- growing it would put a row off the bottom edge, which is the whole point of
-- the clamp). What the legend costs is one CONTENT row.
local with_l = render(with_legend(content_rows(200)), 360)
local without_l = render(content_rows(200), 360)
eq("legend does not grow the clamped panel", #with_l, #without_l)

local function content_shown(labels)
	local n = 0
	for _, l in ipairs(labels) do
		if l ~= LEGEND and not l:match("^%.%.%. %+%d+ more$") then n = n + 1 end
	end
	return n
end
eq("legend displaces exactly one content row",
	content_shown(with_l), content_shown(without_l) - 1)

-- ---- 4. two sticky footnotes both survive the clamp ------------------------
--
-- Track C's named "?" footnote and Track B's "[ ] = ..." legend are BOTH
-- sticky now (sim_rows can emit up to two trailing sticky rows). Both must
-- survive the "... +N more" cut, in order, and the count must still be over
-- the CONTENT rows only -- two sticky rows now cost two lines of the budget.

local function with_two_stickies(rows)
	rows[#rows + 1] = { bars = {}, label = LEGEND, color = GREY, sticky = true }
	rows[#rows + 1] = { bars = {}, label = BRACKET_LEGEND, color = GREY, sticky = true }
	return rows
end

-- The bracket legend is long enough that draw_panel's per-label width budget
-- (fit_label) can truncate it with a trailing "..." -- unrelated to the row
-- CLAMP this test is about -- so these checks match it by its stable prefix
-- rather than requiring the exact untruncated string.
labels = render(with_two_stickies(content_rows(200)), 360)
n_more, hidden = count_more(labels)
eq("two-sticky: exactly one '+N more' line", n_more, 1)
eq("two-sticky: footnote survives the cut", labels[#labels - 1], LEGEND)
eq("two-sticky: bracket legend survives the cut and stays last",
	labels[#labels]:match("^%[ %]") ~= nil, true)

shown = 0
for _, l in ipairs(labels) do
	if l ~= LEGEND and not l:match("^%[ %]") and not l:match("^%.%.%. %+%d+ more$") then
		shown = shown + 1
	end
end
eq("two-sticky: hidden count accounts for every content row", shown + hidden, 200)

-- ---- 4b. new row kinds: re-casts, skipped cards, an engine that failed -------

do
	local function labels_of(sim)
		local out = {}
		for _, r in ipairs(T.sim_rows(sim, { spells_per_cast = 1 }, {})) do
			out[#out + 1] = r.label
		end
		return out
	end
	local recast = { kind = "leaf", id = "LIGHT_BULLET", atype = "PROJECTILE", modifiers = {},
		recast = true, count = 3 }
	local divide = { kind = "leaf", id = "DIVIDE_3", atype = "DRAW_MANY", modifiers = {},
		children = { recast } }
	local labels = labels_of({ casts = { { nodes = { divide }, mana = 0 } }, wrapped = false })
	local found
	for _, l in ipairs(labels) do if l:find("again:", 1, true) then found = l end end
	eq("recast row: marked, with its count", found and found:find("x3", 1, true) ~= nil, true)

	local skipper = { kind = "leaf", id = "IF_ENEMY", atype = "OTHER", modifiers = {},
		skipped = { 2, 3 } }
	labels = labels_of({ casts = { { nodes = { skipper }, mana = 0 } }, wrapped = false })
	found = nil
	for _, l in ipairs(labels) do if l:find("skips 2 spells", 1, true) then found = l end end
	eq("skipped cards: the row says how many", found ~= nil, true)

	labels = labels_of({ casts = {}, error = "boom" })
	eq("engine failure: one row naming the reason",
		#labels == 1 and labels[1]:find("boom", 1, true) ~= nil, true)
end

-- ---- 5. T1.4 -- the named "?" footnote + the always-on bracket legend -----

-- Regression (found in-game, v1.4.0 first run): a wand whose only offender was
-- not an "If"/random card hid its brackets and drew the ? glyph, but the panel
-- never said why. The footnote must appear whenever the engine reported an
-- uncertain card, and that card's own row must carry the "?".
do
	local node = { kind = "leaf", id = "ALPHA", atype = "OTHER", modifiers = {},
		uncertain_ids = { ALPHA = true } }
	local sim = { casts = { { nodes = { node }, wrapped = false, mana = 40 } }, wrapped = false }
	local rows = T.sim_rows(sim, { spells_per_cast = 1 }, {}, { "ALPHA" })
	local footnote, alpha_row
	for _, r in ipairs(rows) do
		if r.label:match("^%?%s*=") then footnote = r end
		if r.label:find("Alpha", 1, true) and not r.label:match("^%?") then alpha_row = r end
	end
	eq("alpha-only: footnote present", footnote ~= nil, true)
	eq("alpha-only: footnote names Alpha", footnote and footnote.label:find("Alpha", 1, true) ~= nil, true)
	eq("alpha-only: the Alpha row is marked ?", alpha_row and alpha_row.label:find("Alpha?", 1, true) ~= nil, true)
end


do
	local node = { kind = "leaf", id = "IF_ENEMY", atype = "OTHER", modifiers = {} }
	local sim = { casts = { { nodes = { node }, wrapped = false, mana = 0 } }, wrapped = false }
	local cfg = { spells_per_cast = 1 }
	local rows = T.sim_rows(sim, cfg, {}, { "ALPHA" })

	local footnote, legend
	for _, r in ipairs(rows) do
		if r.label:match("^%?%s*=") then footnote = r end
		if r.label == BRACKET_LEGEND then legend = r end
	end

	eq("uncertain footnote: present", footnote ~= nil, true)
	eq("uncertain footnote: names Alpha", footnote and footnote.label:find("Alpha", 1, true) ~= nil, true)
	eq("uncertain footnote: sticky", footnote and footnote.sticky, true)

	eq("bracket legend: present", legend ~= nil, true)
	eq("bracket legend: sticky", legend and legend.sticky, true)
end

-- ---- 6. T1.9 -- per-cast mana in the header, vs. mana_max ------------------

local function leaf(id)
	return { kind = "leaf", id = id, atype = "PROJECTILE", modifiers = {} }
end

local function find_header(rows)
	for _, r in ipairs(rows) do
		if r.header then return r end
	end
end

local function find_row(rows, label)
	for _, r in ipairs(rows) do
		if r.label == label then return r end
	end
end

local MANA_FOOTNOTE = "mana = cost of this cast; > max means part of it is discarded"

do
	-- Overflow: mana_max = 150, the cast costs 210.
	local sim = { casts = { { nodes = { leaf("LIGHT_BULLET") }, wrapped = false, mana = 210 } },
		wrapped = false }
	local cfg = { spells_per_cast = 1, mana_max = 150 }
	local rows = T.sim_rows(sim, cfg, {})
	local header = find_header(rows)
	eq("mana overflow: header shown", header ~= nil, true)
	eq("mana overflow: header text", header and header.label, "cast 1  mana 210  > max 150")
	eq("mana overflow: header uses WRAP_COLOR", same_color(header and header.color, T.WRAP_COLOR), true)
	eq("mana overflow: footnote present", find_row(rows, MANA_FOOTNOTE) ~= nil, true)
end

do
	-- No overflow: mana_max = 300, the same 210-mana cast.
	local sim = { casts = { { nodes = { leaf("LIGHT_BULLET") }, wrapped = false, mana = 210 } },
		wrapped = false }
	local cfg = { spells_per_cast = 1, mana_max = 300 }
	local rows = T.sim_rows(sim, cfg, {})
	local has_max = false
	for _, r in ipairs(rows) do
		if r.label:find("> max", 1, true) then has_max = true end
	end
	eq("mana no overflow: no '> max' anywhere", has_max, false)
	eq("mana no overflow: footnote absent", find_row(rows, MANA_FOOTNOTE), nil)
end

-- ---- 7. T1.7 -- an empty, all-depleted cast gets a header saying so --------
--
-- A cast whose every draw hit a depleted card has nodes = {} and a non-empty
-- `spent` (files/wand_structure.lua's header) -- a real cast that emptied part
-- of the deck without firing anything. Even as the wand's ONLY cast (so none
-- of sim_rows' other header triggers -- multiple casts, a wrap, mana overflow
-- -- apply), it must still get a header, or the panel would render nothing at
-- all for a cast that did happen.

do
	local sim = { casts = { { nodes = {}, spent = { 3 }, mana = 0 } }, wrapped = false }
	local cfg = { spells_per_cast = 1 }
	local rows = T.sim_rows(sim, cfg, {})
	local header = find_header(rows)
	eq("empty cast: header shown even as the only cast", header ~= nil, true)
	eq("empty cast: header says no spells left",
		header and header.label:find("no spells left", 1, true) ~= nil, true)
	eq("empty cast: header still carries the mana suffix",
		header and header.label:find("mana 0", 1, true) ~= nil, true)
end

do
	-- A normal cast alongside an empty/depleted one: the tree for the normal
	-- cast must still render, and only the empty cast's header changes.
	local sim = { casts = {
		{ nodes = { leaf("LIGHT_BULLET") }, spent = nil, mana = 10 },
		{ nodes = {}, spent = { 5 }, mana = 0 },
	}, wrapped = false }
	local cfg = { spells_per_cast = 1 }
	local rows = T.sim_rows(sim, cfg, {})
	local headers = {}
	for _, r in ipairs(rows) do if r.header then headers[#headers + 1] = r end end
	eq("mixed casts: two headers", #headers, 2)
	eq("mixed casts: cast 1 header is plain", headers[1].label, "cast 1  mana 10")
	eq("mixed casts: cast 2 header says no spells left",
		headers[2].label:find("no spells left", 1, true) ~= nil, true)
end

-- ---- 8. T1.10c -- RESET's panel text: cleared count + the wrap header -------
--
-- RESET always wraps (cast.wrapped = true, since the engine restores the
-- discard pile to the deck right after). The row must say how many spells it
-- cleared (or that there was nothing left), the cleared slots must NOT appear
-- as their own rows (they never executed), and the header must explain that
-- THIS wrap is a RESET, not a normal run-off-the-end wrap.

local function reset_node(cleared)
	return { kind = "reset", id = "RESET", atype = "UTILITY", modifiers = {},
		cleared = cleared, first = 2, last = 4, head = 2 }
end

do
	local sim = { casts = { { nodes = { reset_node({ 3, 4 }) }, wrapped = true, mana = 20 } },
		wrapped = true }
	local cfg = { spells_per_cast = 1 }
	local rows = T.sim_rows(sim, cfg, {})

	local reset_row
	for _, r in ipairs(rows) do
		if r.label:find("Reset", 1, true) and not r.header then reset_row = r end
	end
	eq("reset: row present", reset_row ~= nil, true)
	eq("reset: row says how many it clears",
		reset_row and reset_row.label:find("(clears 2 spells)", 1, true) ~= nil, true)

	local header = find_header(rows)
	eq("reset: header shown (single wrapped cast)", header ~= nil, true)
	eq("reset: header names RESET as the reason for the wrap",
		header and header.label:find("RESET restores the wand", 1, true) ~= nil, true)
	eq("reset: header keeps WRAP_COLOR", same_color(header and header.color, T.WRAP_COLOR), true)

	local slot_rows = 0
	for _, r in ipairs(rows) do
		if r.label:find("^%s*3%f[%A]") or r.label:find("^%s*4%f[%A]") then slot_rows = slot_rows + 1 end
	end
	eq("reset: no child rows for the cleared slots", slot_rows, 0)
end

do
	-- cleared = {}: RESET was the last card, nothing left to clear.
	local sim = { casts = { { nodes = { reset_node({}) }, wrapped = true, mana = 20 } },
		wrapped = true }
	local cfg = { spells_per_cast = 1 }
	local rows = T.sim_rows(sim, cfg, {})

	local reset_row
	for _, r in ipairs(rows) do
		if r.label:find("Reset", 1, true) and not r.header then reset_row = r end
	end
	eq("reset (empty): row present", reset_row ~= nil, true)
	eq("reset (empty): row says nothing left to clear",
		reset_row and reset_row.label:find("(nothing left to clear)", 1, true) ~= nil, true)
end

-- ---- 6. long rows wrap instead of being cut; tall structures scroll ----------

do
	-- pixel-like font stub: 6 * scale px per char
	local long = "Light Bullet Trigger Spitter Damage Plus Heavy Spread Bouncing"
	local wrapped = T.wrap_label(nil, long, 1.0, 120)
	eq("wrap: a long label becomes several lines", #wrapped > 1, true)
	local rebuilt = {}
	for _, l in ipairs(wrapped) do rebuilt[#rebuilt + 1] = (l:gsub("^%s+", "")) end
	eq("wrap: no word is lost", table.concat(rebuilt, " "), long)
	local fits = true
	for _, l in ipairs(wrapped) do if #l * 6 > 120 then fits = false end end
	eq("wrap: every line fits the width", fits, true)
	eq("wrap: a short label is left alone", T.wrap_label(nil, "short", 1.0, 120)[1], "short")

	local anchor = { boxes = { { top = 48, right = 400 } }, sel = 1 }
	drawn = { texts = {} }
	T.draw_panel(nil, { { bars = {}, label = long, color = GREY } }, TITLE, 640, 360,
		anchor, 1.0, { wrap = true })
	local all = {}
	for _, t in ipairs(drawn.texts) do
		if t.text ~= TITLE and t.text ~= "|" then all[#all + 1] = (t.text:gsub("^%s+", "")) end
	end
	eq("panel wrap: nothing truncated with '...'", table.concat(all, " "):find("...", 1, true), nil)
	eq("panel wrap: full text readable", table.concat(all, " "), long)

	local function page(scroll)
		local view = { scroll = scroll }
		drawn = { texts = {} }
		T.draw_panel(nil, content_rows(200), TITLE, 640, 360, anchor, 1.0, view)
		local labels = {}
		for _, t in ipairs(drawn.texts) do
			if t.text ~= TITLE and t.text ~= "|" then labels[#labels + 1] = t.text end
		end
		return labels, view.scroll
	end
	eq("scroll: first page starts at spell 1", page(0)[1], "spell 1")
	local mid = page(10)
	eq("scroll: scrolled page starts with the 'above' row", mid[1], "^ 10 above")
	eq("scroll: then spell 11", mid[2], "spell 11")
	local bottom, clamped = page(10000)
	eq("scroll: clamped to the last page", clamped < 10000, true)
	local last_content
	for _, l in ipairs(bottom) do if l:match("^spell %d+$") then last_content = l end end
	eq("scroll: the last spell is reachable", last_content, "spell 200")
	eq("scroll: the hint is shown", bottom[#bottom], "PgUp/PgDn: scroll")
end

-- ---- 7. hover tooltip and click-to-open for a row cut with "..." -------------

do
	local long = "Light Bullet Trigger Spitter Damage Plus Heavy Spread Bouncing Burst"
	local anchor = { boxes = { { top = 48, right = 400 } }, sel = 1 }
	local function draw(opts)
		drawn = { texts = {} }
		T.draw_panel(nil, { { bars = {}, label = long, color = GREY } }, TITLE, 640, 360,
			anchor, 1.0, opts)
		return drawn.texts
	end
	local function row_pos(texts)
		for _, t in ipairs(texts) do
			if t.text ~= TITLE and t.text:sub(-3) == "..." then return t.x, t.y end
		end
	end
	local function has_full(texts)
		local joined = {}
		for _, t in ipairs(texts) do joined[#joined + 1] = (t.text:gsub("^%s+", "")) end
		return table.concat(joined, " "):find(long, 1, true) ~= nil
	end

	local view = {}
	local x, y = row_pos(draw(view))
	eq("tooltip: the row is cut short without a pointer", x ~= nil, true)
	eq("tooltip: ...and the full text is not shown", has_full(draw(view)), false)

	view.mouse = { x = x + 5, y = y + 2, click = false }
	eq("tooltip: hovering the cut row shows its full text", has_full(draw(view)), true)

	view.mouse = { x = 5, y = 5, click = false }
	eq("tooltip: no tooltip when the pointer is elsewhere", has_full(draw(view)), false)

	view.mouse = { x = x + 5, y = y + 2, click = true }
	draw(view)
	view.mouse = nil
	local opened = draw(view)
	eq("click: the row opens in place, wrapped in full", has_full(opened) and not row_pos(opened), true)

	-- clicking an opened row closes it again
	local ox, oy
	for _, t in ipairs(opened) do
		if t.text ~= TITLE then ox, oy = t.x, t.y; break end
	end
	view.mouse = { x = ox + 5, y = oy + 2, click = true }
	draw(view)
	view.mouse = nil
	eq("click: clicking it again closes it", row_pos(draw(view)) ~= nil, true)
end

print("")
print(failures .. " failure(s)")
os.exit(failures == 0 and 0 or 1)

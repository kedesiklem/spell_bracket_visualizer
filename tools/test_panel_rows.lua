#!/usr/bin/env lua5.4
-- Validates the wand-structure panel's LAYOUT against the REAL
-- files/grouping_overlay.lua, by stubbing the game's Gui API and recording what
-- draw_panel actually draws.
--
--     lua tools/test_panel_rows.lua        (any Lua 5.1+ / LuaJIT)
--
-- What's at stake: a structure too long for the screen SCROLLS instead of being
-- folded.  The "?" legend ("depends on game state when cast") is appended LAST
-- and explains marks that stay on screen, so rows may set sticky=true to stay
-- put under the scrolling part -- otherwise a scroll would hide the legend while
-- the marks it explains remain visible.  The panel keeps a fixed, comfortable
-- width whatever the wand next to it looks like, can be hidden down to a tab,
-- and keeps its tooltip / click-to-wrap for long rows.

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
function GuiImage() end
function GuiImageNinePiece(gui, id, x, y, w, h)
	if id == 90210 then drawn.box = { x = x, y = y, w = w, h = h } end
end
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

-- Drive the real draw_panel and return just the row labels it drew (the title,
-- its "[-]" button and the "|" nesting spines are not rows).
local CHROME = { ["|"] = true, ["[-]"] = true }
local function is_row(t) return t.text ~= TITLE and not CHROME[t.text] end

local function render(rows, sh, view, right)
	drawn = { texts = {} }
	local anchor = { boxes = { { top = 48, right = right or 400 } }, sel = 1 }
	T.draw_panel(nil, rows, TITLE, 640, sh or 360, anchor, 1.0, view)
	local labels = {}
	for _, t in ipairs(drawn.texts) do
		if is_row(t) then labels[#labels + 1] = t.text end
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

local HINT = "PgUp/PgDn: scroll   Home: hide"
local function spells_in(labels)
	local out = {}
	for _, l in ipairs(labels) do
		if l:match("^spell %d+$") then out[#out + 1] = tonumber(l:match("%d+")) end
	end
	return out
end

-- ---- 1. short structure: nothing scrolls, the legend sits last ---------------

local labels = render(with_legend(content_rows(3)), 360)
eq("short: every row drawn", #labels, 4)
eq("short: legend is last", labels[#labels], LEGEND)
eq("short: no scroll hint", labels[#labels] ~= HINT, true)

-- ---- 2. long structure: it scrolls, the legend stays under it ----------------

labels = render(with_legend(content_rows(200)), 360, { scroll = 0 })
eq("long: the first page starts at spell 1", labels[1], "spell 1")
eq("long: the legend stays on screen", labels[#labels - 1], LEGEND)
eq("long: the key hint closes the panel", labels[#labels], HINT)
local folded = false
for _, l in ipairs(labels) do if l:match("more$") or l:match("above$") then folded = true end end
eq("long: no '+N more' / 'N above' folding rows any more", folded, false)

-- every content row can be reached, and the legend is on every page
local reached, legend_always = {}, true
local view = { scroll = 0 }
for _ = 1, 200 do
	labels = render(with_legend(content_rows(200)), 360, view)
	for _, n in ipairs(spells_in(labels)) do reached[n] = true end
	if labels[#labels - 1] ~= LEGEND then legend_always = false end
	view.scroll = view.scroll + 5
end
local count = 0
for _ in pairs(reached) do count = count + 1 end
eq("long: every spell is reachable by scrolling", count, 200)
eq("long: the legend is on every page", legend_always, true)

-- The legend is paid for out of the visible rows, not added on top: the panel is
-- the same height either way (it is clamped to the screen).
local with_l = render(with_legend(content_rows(200)), 360, { scroll = 0 })
local without_l = render(content_rows(200), 360, { scroll = 0 })
eq("legend does not grow the panel", #with_l, #without_l)
eq("legend displaces exactly one content row",
	#spells_in(with_l), #spells_in(without_l) - 1)

-- ---- 3. two sticky footnotes both stay ------------------------------------------
--
-- Track C's named "?" footnote and Track B's "[ ] = ..." legend are BOTH sticky
-- (sim_rows can emit up to two trailing sticky rows): both stay, in order, under
-- the scrolling part.  The bracket legend is long enough that the per-label
-- width budget can cut it with "...", so it is matched by its stable prefix.

local function with_two_stickies(rows)
	rows[#rows + 1] = { bars = {}, label = LEGEND, color = GREY, sticky = true }
	rows[#rows + 1] = { bars = {}, label = BRACKET_LEGEND, color = GREY, sticky = true }
	return rows
end

labels = render(with_two_stickies(content_rows(200)), 360, { scroll = 0 })
eq("two-sticky: footnote stays", labels[#labels - 2], LEGEND)
eq("two-sticky: bracket legend stays, just above the hint",
	labels[#labels - 1]:match("^%[ %]") ~= nil, true)
eq("two-sticky: the hint is last", labels[#labels], HINT)

-- ---- 3b. size: fixed, comfortable, independent of the wand ----------------------

do
	local function box_for(right, scale, sw)
		drawn = { texts = {} }
		local anchor = { boxes = { { top = 48, right = right } }, sel = 1 }
		T.draw_panel(nil, content_rows(3), TITLE, sw or 640, 360, anchor, scale or 0.6)
		return drawn.box
	end
	local narrow, wide = box_for(100), box_for(600)
	eq("size: the same width next to a small and a huge wand", narrow.w, wide.w)
	eq("size: comfortably wide (at least 180 GUI)", narrow.w >= 180, true)
	eq("size: never the whole screen", narrow.w <= 640 * 0.45 + 0.001, true)
	eq("size: grows with the text size", box_for(100, 1.0).w >= box_for(100, 0.5).w, true)
	eq("size: right-aligned to the screen edge",
		math.abs((narrow.x + narrow.w) - (640 - 3 + 4)) < 1.5 or narrow.x + narrow.w <= 640, true)

	-- the width does not move while scrolling or when rows change
	local v = { scroll = 0 }
	render(content_rows(200), 360, v)
	local w1 = drawn.box.w
	v.scroll = 40
	render(content_rows(200), 360, v)
	eq("size: the width does not jump while scrolling", drawn.box.w, w1)
end

-- ---- 3c. hide / show ------------------------------------------------------------

do
	local anchor = { boxes = { { top = 48, right = 400 } }, sel = 1 }
	local function draw(view)
		drawn = { texts = {} }
		T.draw_panel(nil, content_rows(3), TITLE, 640, 360, anchor, 1.0, view)
		return drawn.texts
	end
	local view = { hidden = true }
	local texts = draw(view)
	eq("hidden: only the tab is drawn", #texts, 1)
	eq("hidden: the tab names the panel and offers to show it",
		texts[1].text, "[+] " .. TITLE)

	view.mouse = { x = texts[1].x + 3, y = texts[1].y + 2, click = true }
	draw(view)
	eq("hidden: a click on the tab shows the panel again", view.hidden, false)

	-- title click hides; the same click must not bring it straight back
	view.mouse = nil
	texts = draw(view)
	local tx, ty
	for _, t in ipairs(texts) do if t.text == TITLE then tx, ty = t.x, t.y end end
	view.mouse = { x = tx + 3, y = ty + 2, click = true }
	draw(view)
	eq("title: a click on the title hides the panel", view.hidden, true)
	view.mouse = nil
	eq("title: ...and it stays hidden on the next frame", #draw(view), 1)
end

-- ---- 3d. the scroll bar -----------------------------------------------------------

do
	local view = { scroll = 0 }
	render(content_rows(200), 360, view)
	local box = drawn.box
	-- a click near the bottom of the bar jumps most of the way down
	local bar_x = box.x + box.w - 4 - 2 + 1
	local line_h = 9 * 1.0 + 2
	view.mouse = { x = bar_x, y = box.y + 4 + line_h + 2 + (box.h - 2 * line_h) * 0.9, click = true }
	render(content_rows(200), 360, view)
	eq("scroll bar: a click far down jumps down the structure", view.scroll > 100, true)
	view.mouse = nil
	local before = view.scroll
	render(content_rows(200), 360, view)
	eq("scroll bar: the position is kept between frames", view.scroll, before)
end

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

	local function page(scroll)
		local v = { scroll = scroll }
		local got = render(content_rows(200), 360, v)
		return got, v.scroll
	end
	eq("scroll: first page starts at spell 1", page(0)[1], "spell 1")
	eq("scroll: scrolled page starts at spell 11", page(10)[1], "spell 11")
	local bottom, clamped = page(10000)
	eq("scroll: clamped to the last page", clamped < 10000, true)
	local last_content
	for _, l in ipairs(bottom) do if l:match("^spell %d+$") then last_content = l end end
	eq("scroll: the last spell is reachable", last_content, "spell 200")
	eq("scroll: the hint is shown", bottom[#bottom], HINT)
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
		if is_row(t) then ox, oy = t.x, t.y; break end
	end
	view.mouse = { x = ox + 5, y = oy + 2, click = true }
	draw(view)
	view.mouse = nil
	eq("click: clicking it again closes it", row_pos(draw(view)) ~= nil, true)
end

-- ---- cards that need more than a name: Divide By, copies, triggers -----------
--
-- The adapter's fields (wand_structure.lua) turned into words.  Nodes are built
-- by hand: these tests are about the wording, not about what the engine did.
do
	local function labels(node)
		node.modifiers = node.modifiers or {}
		node.children = node.children or {}
		local sim = { casts = { { nodes = { node }, wrapped = false, mana = 0 } }, wrapped = false }
		local out = {}
		for _, r in ipairs(T.sim_rows(sim, { spells_per_cast = 1 }, {})) do
			if not r.sticky then out[#out + 1] = r.label end
		end
		return out
	end

	local row = labels({ kind = "leaf", id = "LIGHT_BULLET", atype = "PROJECTILE",
		modifiers = { "DIVIDE_4", "DIVIDE_4", "DIVIDE_4" }, runs = 64 })[1]
	eq("divide chain: identical Divide By cards fold, the exact run count follows",
		row, "[Divide 4 x3] Light Bullet  x64")

	row = labels({ kind = "leaf", id = "LIGHT_BULLET", atype = "PROJECTILE",
		modifiers = { "DIVIDE_2", "DAMAGE", "DAMAGE" }, link_runs = { [2] = 2 } })[1]
	eq("a modifier a Divide By re-ran counts every run", row, "[Divide 2, Damage x3] Light Bullet")

	row = labels({ kind = "multicast", id = "BURST_2", atype = "DRAW_MANY", group = 2,
		modifiers = { "DIVIDE_2" }, runs = 2, silent_runs = 1 })[1]
	eq("a target that draws says how many of its runs drew nothing",
		row, "[Divide 2] Burst 2  x2 (1 draw nothing)")

	row = labels({ kind = "leaf", id = "DIVIDE_2", atype = "OTHER", dangling = true,
		divides_nothing = true })[1]
	eq("a Divide By with nothing after it", row, "Divide 2  (nothing to repeat)")

	row = labels({ kind = "leaf", id = "ALPHA", atype = "OTHER", children = {
		{ kind = "leaf", id = "LIGHT_BULLET", atype = "PROJECTILE", recast = true,
			count = 2, sources = { 1, 3 }, modifiers = {}, children = {} } } })[2]
	eq("a Greek copy names the slots it copied",
		row, "again: Light Bullet  x2  (copies slots 1, 3)")

	local failed = labels({ kind = "leaf", id = "ADD_TRIGGER", atype = "OTHER",
		trigger_failed = "no_target",
		swept = { { id = "DAMAGE", slot = 2, effect = "applied", consumed = false } } })
	eq("failed trigger: the head says why", failed[1],
		"Add Trigger  (fails: no spell after it to attach to)")
	eq("failed trigger: what it stepped over is still in the wand", failed[2],
		"stepped over, kept in the wand: Damage (applied)")

	local ok = labels({ kind = "trigger", id = "LIGHT_BULLET", atype = "PROJECTILE",
		trigger = "timer", trigger_frames = 20, payload = 1,
		modifiers = { "ADD_TIMER", "BURST_2", "DAMAGE" },
		swept = { { id = "BURST_2", slot = 2, effect = "ignored", consumed = true },
			{ id = "DAMAGE", slot = 3, effect = "depleted", consumed = true } },
		children = { { kind = "leaf", id = "BOMB", atype = "PROJECTILE", modifiers = {}, children = {} } } })
	eq("trigger: what was discarded with the target, and what it did",
		ok[2], "stepped over, discarded: Burst 2 (no effect), Damage (no charges, no effect)")
	eq("timer trigger: when the payload fires", ok[3], "after 0.33s:")
	eq("trigger: the payload follows", ok[4], "Bomb")

	eq("expiration trigger: says so",
		labels({ kind = "trigger", id = "LIGHT_BULLET", atype = "PROJECTILE", trigger = "death",
			children = { { kind = "leaf", id = "BOMB", atype = "PROJECTILE", modifiers = {}, children = {} } } })[2],
		"on expiration:")

	eq("trigger with nothing to carry fires plain",
		labels({ kind = "leaf", id = "LIGHT_BULLET", atype = "PROJECTILE", no_payload = true,
			modifiers = { "ADD_TRIGGER" } })[1],
		"[Add Trigger] Light Bullet  (no spell left to carry: fires plain)")
end

print("")
print(failures .. " failure(s)")
os.exit(failures == 0 and 0 or 1)

dofile("data/scripts/lib/mod_settings.lua") -- see this file for documentation on the settings API

local mod_id = "spell_bracket_visualizer"
mod_settings_version = 2
mod_settings = {
	{
		id = "show_grouping",
		ui_name = "Wand Structure Panel",
		ui_description = "While the inventory is open, show a Lisp-style tree of the\nactive wand's cast structure: what fires together each cast\n(multicasts, triggers, modifiers) and when the wand WRAPS.",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "panel_text_size",
		ui_name = "Wand Structure Panel: Text Size",
		ui_description = "Text size for the wand structure panel.\nSmaller fits more rows before the panel has to scroll.\nWith a font mod (e.g. Better Font) or a language with a\nsmooth font, the game ignores the smaller sizes -- the panel\ndetects that and switches itself to Large automatically.",
		value_default = "small",
		values = { { "tiny", "Tiny" }, { "small", "Small" }, { "medium", "Medium" }, { "large", "Large" } },
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "compact_panel",
		ui_name = "Wand Structure Panel: Compact Text",
		ui_description = "Say it in fewer characters: D10 for Divide by 10, draw 2 for Double\nspell, x3 for a repeat count, * for a re-cast, @3 for 'copied slot 3', (! no target)\nfor a failed Add Trigger... A one-line key appears under the\nstructure when a symbol is on screen.",
		value_default = false,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "show_legend",
		ui_name = "Wand Structure Panel: Legend",
		ui_description = "Show the explanatory lines at the bottom of the panel (what [ ],\n? and the mana line mean, and the key to the compact text's\nsymbols). Off by default: warnings about uncertain spells stay.",
		value_default = false,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "show_slot_brackets",
		ui_name = "Slot Brackets",
		ui_description = "Rainbow nesting brackets on the spell cards in the wand UI,\nlike nested code brackets: each group's span, and wand\nwrapping in orange.",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "show_slot_marks",
		ui_name = "Slot Marks (underline / strike / copy dots)",
		ui_description = "Underlines a modifier chain (the modifiers and the card they\nmodify) in the wand UI, and strikes through cards that are\ndrawn but never fire (depleted spells, cards a failed IF threw\naway). A small dot above a card means a Greek letter (or Double\nSpell...) copied it, one dot per kind of copier, each in its own colour.",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "ignore_depleted_spells",
		ui_name = "Ignore Depleted Spells",
		ui_description = "Spells with 0 charges left can't fire. When on (default), the\nwand groups and WRAPS the way the game actually does: a\ndepleted spell is skipped and retried past, so it draws no\nbracket. Turn off to pretend every card fires, depleted or not.",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "uncertain_brackets",
		ui_name = "Uncertain Wands: Slot Brackets",
		ui_description = "A wand holding a spell whose effect depended on a guess (an\nIF spell reading the world, a random draw, an engine call the\nmod can't model) draws no slot brackets, and shows a small dim\n'?' at the end of the row instead. Hide keeps that rule. Show\ndraws the brackets anyway, with '?' marks in the panel, for\nplayers who want the approximation and know what it is.",
		value_default = "hide",
		values = { { "hide", "Hide (default)" }, { "show", "Show anyway" } },
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "show_debug",
		ui_name = "Debug Info (for bug reports)",
		ui_description = "Show a small box (top-right) with your screen/GUI size and\nthe held wand's stats, plus magenta guide-lines on each wand box.\nIf the brackets or panel look wrong, turn this on, open your\nwand, and send the author a screenshot -- it shows your\nresolution, wand size, and where the mod thinks each row is.",
		value_default = false,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	-- The heavy "Calibration Overlay" HUD (debug_boxes: rulers, mouse probes,
	-- plumb lines) was removed for the Workshop release; that code lives in git
	-- history. Re-add it if the box geometry ever drifts after a game update.
	-- The lightweight show_debug box above is the user-facing one.
}

function ModSettingsUpdate( init_scope )
	mod_settings_update( mod_id, mod_settings, init_scope )
end

function ModSettingsGuiCount()
	return mod_settings_gui_count( mod_id, mod_settings )
end

function ModSettingsGui( gui, in_main_menu )
	mod_settings_gui( mod_id, mod_settings, gui, in_main_menu )
end

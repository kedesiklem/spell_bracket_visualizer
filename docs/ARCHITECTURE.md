# Architecture

This document explains how the mod decides what to draw, and which file owns
which decision. If you only want to use the mod, the README is enough.

## The one idea: run the game's own cast code

Earlier versions of this mod carried a hand-written simulator: a table saying
how many cards each spell draws, plus a re-implementation of the engine's draw
rules. Every spell that behaved differently (the Greek letters, Divide By,
Add Trigger, RESET) needed its own special case, and every special case was a
guess about the engine.

The mod now does what [WandDBG](https://github.com/kaliuresis/WandDBG) does:
it **runs the game's real `gun.lua`** over a copy of the wand, inside a
sandbox, and records what happened. Nothing about the draw rules is
re-implemented here, so when the engine does something surprising (Alpha as the
first card copies itself until the recursion limit; Divide By re-runs its
target several times) the panel shows exactly that.

> Credit: the sandboxed-evaluation approach and the fake-world stand-ins in
> `engine_stubs.lua` follow kaliuresis' WandDBG (`files/debugger.lua`). The game
> files themselves belong to Nolla Games and are read from the player's own
> install at runtime; none are shipped with the mod.

## What a bracket means

> A bracket encloses exactly the cards the engine **removed from the deck**
> while executing the bracket's head card.

The tracer therefore never asks "how many cards does this spell draw?". It
watches `table.remove` on the deck and attributes each removal to the card
whose body was running at that moment. A multicast's bracket is whatever it
pulled out; a trigger's is its payload; a modifier's is the card it modified.
RESET replaces the whole deck table, so its bracket is "everything it cleared".
A card a spell merely *re-casts* (Divide By, Alpha) stays in the deck, so it is
shown as a re-cast child (`again: ... xN`), not as part of a bracket.

## Data flow

```
 wand in the inventory
        |  grouping_overlay.read_deck / read_config
        v
 { tokens, always, spells_per_cast, uses, shuffle }
        |  wand_sim_cache  (skip the work if the wand has not changed)
        v
 wand_structure.simulate(engine, wand)
        |  engine.run(wand)            -> raw recording (a tree of nodes)
        |  re-shape                    -> expressions, spans, flags
        v
 { casts = { { nodes = { expression... }, mana, wrapped, ... } } }
        |
        v
 grouping_overlay: panel rows + slot-bracket glyphs
```

## Files and their single responsibility

### Engine layer (`files/engine/`) - "what does the game do?"

| File | Responsibility |
| --- | --- |
| `engine.lua` | The only entry point: wires the four pieces below and exposes `run`, `knows`, `name_key`, `action_type`. |
| `game_env.lua` | The sandbox: compiles `gun.lua` and every spell into a private environment, with a whitelist of pure Lua functions and no path to the real global table. |
| `engine_stubs.lua` | Stand-ins for the Noita API that spell bodies call: no-ops, a fake player/world for the reads that steer drawing, a deterministic RNG, and a report of everything that had to be guessed. |
| `cast_tracer.lua` | Hooks around `gun.lua` that record each cast as a tree of nodes (spans of removed slots, wraps, cleared decks, uncertainty). Pure observation; it changes nothing. |
| `wand_runner.lua` | The protocol for operating `gun.lua` from outside (load deck, start shot, play always-casts, draw, reload), repeated until the wand recharges. |
| `lua_compat.lua` | The two places LuaJIT (the game) and Lua 5.3+ (offline tools) differ. |

### Presentation-independent logic (`files/`)

| File | Responsibility |
| --- | --- |
| `wand_structure.lua` | Re-shapes the raw recording into the expression tree the overlay draws: folds modifiers into their head, groups multicasts, detects the Add Trigger scan, folds identical re-casts, computes slot spans. It decides nothing about game rules. Its header documents the output shape. |
| `wand_sim_cache.lua` | Memoises simulations keyed by the wand's contents, so the engine runs once per change rather than once per frame. |

### Overlay (`files/`) - "how is it drawn?"

| File | Responsibility |
| --- | --- |
| `grouping_overlay.lua` | Reads the live wand, builds the engine lazily on the first frame (after every mod appended its spells), and draws the panel and the slot brackets. |
| `wand_sprite_meta.lua` | Generated table of wand sprite sizes for the box-layout model. |

### Tools (`tools/`) - not shipped in the release zip

| File | Responsibility |
| --- | --- |
| `test_support.lua` | Loader and engine factory shared by every offline test. |
| `test_wand_structure.lua` | Expression-shape tests against the real engine. |
| `test_slot_delims.lua`, `test_panel_rows.lua`, `test_font_compat.lua` | Bracket planner, panel row clamp, font-safety layout. |
| `preview_wand.lua` | Print any wand's brackets and expression tree in the terminal. |
| `extract_gun.py` | Copy `gun.lua` and friends out of the player's `data.wak` into the git-ignored `.gun_ref/`. |

## Uncertainty

The sandbox's world is fake (no enemies nearby, full health, a fixed random
sequence). A card whose body read game state, drew a random number, or called
an engine function the sandbox does not model is marked **uncertain**: its name
gets a `?` in the panel, and the wand's slot brackets are hidden by default
(setting: *Uncertain Wands*). Everything else is exactly what the engine does.

## Running the tests

```
python3 tools/extract_gun.py            # once: needs your Noita install
texlua tools/test_wand_structure.lua    # or any Lua 5.1+ / LuaJIT
texlua tools/test_slot_delims.lua
texlua tools/test_panel_rows.lua
```

`.gun_ref/` holds Nolla's game files: it is git-ignored and never ships.

## Not verified outside the game

The offline tests cannot exercise `ModTextFileGetContent` (how the mod reads
`gun.lua` in game), the `setfenv` path of `lua_compat.lua`, or the engine's
per-frame cost on a large inventory. These need a play-test.

# Advanced scenarios plan — modded spells, Greeks, Add Trigger, mana

> **Historical document.** This plan describes the hand-written simulator and
> `structure_meta.lua`, both since replaced by running the game's own `gun.lua`
> (see `ARCHITECTURE.md`). It is kept for the reasoning behind the
> hedge-in-text, never-lie-in-brackets policy, which still holds.

Response to the Workshop thread of Sep 2–3 (KoObEy's five points, Night's
"false results" report). The mod's own pitch has been "a teaching tool for
early-game wrapping"; this plan is what it takes to stop leaning on that and
to be *correct or explicitly silent* on every wand instead.

Everything here builds on what already exists: `wand_structure.lua` is a real
deck simulator, `structure_meta.lua` carries per-card draw facts, and the
`?` marking + shuffle-wand suppression already embody the right instinct
(hedge in text, never lie in brackets). Nothing gets rewritten; the simulator
grows a handful of node kinds, the metadata gets a second (runtime) source, and
a confidence policy decides when the slot row stays blank.

**On the engine facts in this document.** An earlier draft tagged them
**verified** or **VERIFY**, the latter meaning "from memory of `gun_actions.lua`
/ `gun.lua`, confirm before coding". Every one of them has since been read
directly from `.gun_ref/`, extracted by `tools/extract_gun.py` (§0.1), and the
tags are gone. Several of the remembered facts were wrong in ways that changed
the design — Add Trigger's consumption width (§4 D1), Divide's repeat semantics
(D2), which Greeks force-draw at all (D3), the `reflecting` safety premise
(§3 A2), and always-cast mana (§5). Where that happened, the correction records
the original guess beside it, because the gap between the two is the argument
for the differential harness.

---

## 0. The feedback, mapped

The thread runs Aug 22 – Sep 3 and contains two different criticisms, not one.
A **method** objection (UserK, endorsed by KoObEy) came first: the mod guesses
at rules it could simply run. A **results** objection followed (Night, then
KoObEy's five numbered points): here is where the guess is wrong. The method
objection is listed first because answering it is what makes everything else
verifiable — and because the answer has changed since the Aug 26 reply.

| # | Who | Date | Point | Where it lands |
|---|-----|------|-------|----------------|
| — | UserK | Aug 22 | hook into the game's gun system and simulate with the game's own code instead of guessing; "would also likely play nicer with mods" | §0.1 — **position reversed** |
| — | KoObEy | Aug 23 | "I agree with UserK, that running the game code to get the actual results would be the better approach"; "As is, this mod shows false results" | §0.1 |
| — | Night | Sep 2 | modded modifiers and multicasts register as projectile spells, so wands show several casts where only one exists | Track A1 — v1.4.0 |
| 1 | KoObEy | Sep 3 | a wand holding an OTHER-type spell that is not a note should get **no brackets at all** — "particularly for Divides, Greeks and Add Triggers" | Track C, with a stated departure — §0.2 |
| 2 | KoObEy | Sep 3 | identify what modded spells draw the way the game builds tooltips: empty shot state, execute the spell, read the shot state back | Track A1 (partial) v1.4.0; Track A2 (full) v1.5.0 |
| 3 | KoObEy | Sep 3 | proper 0-charges logic — "pretty easy", "used in a lot of practical wands" | **not actually done** — §0.3 |
| 4 | KoObEy | Sep 3 | Greeks and complex spells need a clear stated definition of what a bracket means; his four candidate readings diverge | Track B + D3 |
| 5 | KoObEy | Sep 3 | mana: sum cost per cast, compare against max mana, warn | Track E1 |

The release-gating set is KoObEy's own:

> "With some form of my suggestions **1-3** included, I would fully retract my
> criticism and end up recommending this mod."

1, 2 and 3 are conditions; 4 and 5 he volunteered as improvements. §6 slices on
that basis. An earlier draft of this plan shipped 1, 3, 4 and 5 first and held
2 back — precisely the wrong subset to lead with.

### 0.1 The method objection — reversing the Aug 26 answer

The Aug 26 reply said: *"I'm choosing to not hook into the games code since this
mod is mostly intended as a teaching tool ... I am intentionally not trying to
simulate the entire cast of every spell."* That defended two things at once:
keeping the mod a lightweight panel, which is still right, and guessing at the
draw rules, which is not. They are separable, and this plan separates them.

What changed: `tools/extract_gun.py` pulls `gun.lua`, `gun_actions.lua` and
their dependencies out of `data.wak` into a gitignored `.gun_ref/`, and
`tools/gun_harness.lua` runs **Noita's own cast code** over a deck outside the
game (branch `harness/gun-differential`, commit 8263221). The simulator can now
be diffed against the real rules, deck by deck, as a test.

That adopts the substance of UserK's suggestion in the form that fits an
overlay mod:

- **Not** hooking the live gun system while the player is casting. That is Wand
  DBG's job, it risks perturbing real cast state, and it would turn a panel into
  a heavyweight dependency.
- **Yes** running the game's real code as a **differential oracle** offline, so
  what ships provably agrees with the engine on every deck the harness covers,
  and its disagreements are known rather than discovered by players.

This is also why the rest of this document could be corrected before any of it
was written: the engine facts below are now read from `.gun_ref/` instead of
remembered. Several that this plan asserted from memory were wrong — §4 D1, D2
and D3, and §3's `reflecting` premise — and D5's open question is answered.

Lead the thread post with this. "I now run your code against mine" is a
stronger answer to "this shows false results" than any feature in this plan.

Harness part 2 has since landed: `tools/test_gun_differential.lua` compares
per-cast **consumption**, not the play trace, and also checks per-cast mana
(`cast.mana` vs. `gun.lua`'s own spend, §5) — it is the merge gate for every
simulator change in this plan. It currently carries 44 differential cases (41
structural, 3 mana) and reports `0 divergences, 0 unsupported, 1 known`; the
one known divergence is TAU's copy-live unpredictability (it indirectly
triggers a forced draw through the card it copies), which §4 D3 records —
the divergence is expected under D3's tier and is resolved there by keeping
ALPHA/GAMMA/TAU `approximate`, not by modeling class-1 copy-live exactly
(that stays v1.5.0 work).

### 0.2 Point 1 — where this plan departs, and on what evidence

KoObEy named three families: *"particularly for Divides, Greeks and Add
Triggers."* Track C hides brackets for **Greeks** and agrees with him there. It
does **not** hide them for Divides and Add Triggers. That disagreement should be
stated plainly rather than presented as compliance.

The reason is that both are deterministic once modeled correctly — but this
plan's first draft modeled both *incorrectly*, so the departure is only earned
once §4 D1 and D2 land and the harness confirms them:

- **Add Trigger** is not "consumes the next card". It scans forward past
  MODIFIER / PASSIVE / OTHER / DRAW_MANY cards, executes each intervening
  MODIFIER body inline under `dont_draw_actions`, then consumes **all** of them
  plus the projectile (`gun_actions.lua:9313`). Deterministic, but a
  variable-width prefix.
- **Divide** reads `deck[iter]`, suppresses the draws of its *first* invocation,
  and consumes `iter_max` cards only at the outermost level
  (`gun_actions.lua:10063`). Deterministic, but not "repeat N times".

**The gate:** each family keeps the `exact` tier only while the differential
harness agrees with the simulator on its test decks. If the harness disagrees
and cannot be reconciled, the family drops to `approximate` and its brackets
hide themselves under the default policy — KoObEy's rule applying
automatically, by evidence rather than by argument. That is the honest version
of "we think we can do better than hiding these".

Greeks are a different case, and he is simply right about them: §4 D3 shows they
are two incompatible groups rather than one.

### 0.3 Point 3 — conceded; it is not done

The earlier claim here ("shipped in 1.3.0, ask KoObEy to retest") does not
survive checking. `ignore_depleted_spells` does default to **on**, so there is
nothing for him to switch. But two real gaps remain, and they are plausibly the
"currently incorrect edge cases" he meant:

1. **Greek wands ignore the setting by default.** `greek_keeps_depleted` also
   defaults on, and `grouping_overlay.lua:162` computes
   `apply_filter = ignore_depleted and not (greek and greek_keeps)`. So on any
   wand holding a Greek spell the 0-charge filter is off entirely. His point 3
   ("a lot of practical wands") and his point 4 (Greeks) intersect exactly here,
   and the intersection is unhandled.
2. **A depleted card at the end of the deck eats a draw instead of wrapping.**
   `draw_actions` (`gun.lua:299`) does **retry** past a depleted card — the repo
   comment gets that right and no `spent` node kind is needed — but the retry
   loop is `while #deck > 0` and never reaches the reload path, so the iteration
   is silently lost rather than wrapping the wand. The same path handles
   insufficient mana, so Track E inherits the answer.

Both land in v1.4.0, and the reply concedes the point instead of asking him to
retest.

---

## 1. Track B — the definition (do this first; everything else hangs on it)

KoObEy's four readings of "the bracket around spell X contains Y":

1. Y was **drawn** during X's execution
2. Y was **executed** during X's execution
3. Y shares X's **shot state**
4. Y is **no longer in the deck** after X's execution

They coincide on ordinary wands and split exactly on the spells this plan
is about: a Greek *executes* a card it never *draws* (2 but not 1/4); Divide
By and Add Trigger *remove* a card they never `draw_actions()` (4 but not 1);
a trigger payload is *drawn and removed* but runs in its **own** shot state
(1, 4 but not 3); a depleted card is drawn and removed but never executed
(1, 4 but not 2).

The mod is a deck-stream visualizer, so the only definition it can honor
without simulating combat is **#4, consumption**:

> **A bracket encloses exactly the cards the engine removed from the deck
> while executing the bracket's head card. A cast bracket encloses the
> cards removed from the deck during one cast. A card a spell re-casts by
> reference (Alpha, Omega, …) is not removed, so it is never inside a
> bracket — the panel names it as a copy instead.**

Consequences, all of which are *features* of picking one definition:

- Trigger payloads stay nested (they are consumed by the trigger's forced
  draw). The bracket says "consumed here", not "fires now" — the panel's
  `trig` wording already carries the timing.
- Divide By and Add Trigger stay prefixes, but neither consumes just "the next
  card": Divide charges `iter_max` cards at the outermost level (§4 D2) and Add
  Trigger swallows its whole forward scan (§4 D1). The bracket width is
  computed, not assumed.
- Greek spells get **no bracket to the card they copy**. What they consume
  besides that varies by class and is often *nothing at all*: ALPHA / GAMMA /
  TAU let the copied body draw for real, while OMEGA / PHI / MU / SIGMA / ZETA
  run it under `dont_draw_actions` so it consumes nothing, and only MU / SIGMA /
  ZETA force-draw a card of their own (§4 D3). Since the definition would give
  OMEGA and PHI a visibly empty bracket, all eight hide their brackets by
  default and the panel names the copy in text instead.
- RESET's bracket encloses the entire remaining wand — it moves all of `hand`
  and `deck` to `discarded`, and then hands the whole discard pile back, so the
  cast wraps (§4 D6). That is the definition working, not an edge case.
- The definition goes three places: `README.md` "How it works", the
  Workshop description ("What a bracket means"), and a one-line legend the
  panel can show (`[ ] = spells this card pulls from the wand`), reusing the
  sticky-footnote mechanism from the `?` legend.

Deliverable: text only, plus `docs/GROUPING_DESIGN.md` gets the definition
as its opening paragraph. Ship in the same release as Track C.

---

## 2. Track C — confidence tiers and the "no brackets" policy

> **Status: implemented.** `gen_structure_meta.py`'s `OVERRIDES` table emits
> `tier="approximate"` for IF_ELSE / IF_ENEMY / IF_HALF / IF_HP / IF_PROJECTILE,
> DRAW_RANDOM / DRAW_RANDOM_X3 / DRAW_3_RANDOM / RANDOM_SPELL /
> RANDOM_MODIFIER, and ALPHA / GAMMA / TAU / OMEGA / PHI / MU / SIGMA, and
> `tier="unknown"` for ZETA, matching this section's table exactly.
> `wand_structure.lua` has `M.tier(rec)` and `M.wand_tier(ids, meta)`, and
> `grouping_overlay.lua` stamps `wd.tier` / `wd.tier_ids` on every wand and
> checks it in `draw_box_brackets` next to the shuffle check. The
> `uncertain_brackets` setting (values `hide`/`show`, default `hide`) is live;
> Hide draws the dim `?` glyph at the end of the slot row, `sim_rows` extends
> the `?` footnote into a named list of offending ids, and the Debug Info box
> prints `tier=%s (%s)` with the offenders. The rest of this section is the
> design that produced the shipped tier table.

Every card in a wand gets a **tier**, derived from its metadata record — never
from `ACTION_TYPE` alone (KoObEy's "OTHER that is not a note" is really "OTHER
whose body does something the simulator can't follow"; the notes are
structurally trivial leaves and should keep their brackets).

Tiers below are assigned from the bodies as read in `.gun_ref/`, not from type:

| tier | meaning | vanilla members |
|------|---------|-----------------|
| **exact** | the body's deck effects are fully captured by the record and are deterministic | every PROJECTILE / STATIC_PROJECTILE / MATERIAL leaf; every draws=1 MODIFIER / PASSIVE / UTILITY; every DRAW_MANY; trigger projectiles; KANTELE_* / OCARINA_* notes; `IF_END` (draws 1); **RESET** (consumes the entire remaining deck **and** hand — §4 D6); any OTHER/UTILITY whose body has no deck effect, now confirmed to include **ALL_SPELLS** (entity load only), CESSATION, SUMMON_PORTAL, X_RAY, TEMPORARY_WALL |
| **exact, harness-gated** | deterministic, but only after the corrected model lands and `test_gun_differential.lua` agrees — otherwise demoted to *approximate* automatically (§0.2) | DIVIDE_2 / _3 / _4 / _10 (D2); ADD_TRIGGER / ADD_TIMER / ADD_DEATH_TRIGGER (D1) |
| **approximate** | modeled, but position- or state-dependent: shown with `?` | ALPHA / GAMMA / TAU (copy live, D3 class 1); OMEGA / PHI / MU / SIGMA (copy suppressed, D3 class 2); `IF_ENEMY`, `IF_HP`, `IF_PROJECTILE` (branch on world state); `IF_HALF` (alternates on a persistent global — predictable in *pairs* but not from a single frame, D4) |
| **unknown** | no usable record | **ZETA** (reads the player's *other* wands and seeds RNG from position + frame number — unknowable statically, D3 class 3); any modded spell the probe could not classify, or a probe error; any vanilla id absent from `structure_meta.lua` (see below) |

**The 422/490 gap is not a gap.** A raw grep of `gun_actions.lua` finds **490**
ids while `structure_meta.lua` carries **422**, which looks like 68 spells the
generator drops. It is not: all 68 sit inside `--[[ … ]]` block comments in the
game's own source (`ACID`, `BEE`, `BAAB_*`, `BUILDING_*`, the `*_LEGACY`
entries), and `gen_structure_meta.py` strips block comments before parsing. They
do not exist at runtime, so vanilla coverage is **422 of 422 — complete**, and
no wand can hold one. Anything the tier logic sees as *unknown* is therefore
genuinely modded, which is what makes the Hide policy safe to default on.

Policy (new setting, `uncertain_brackets`, enum):

- **Hide (default)** — a wand containing any *unknown* card, or any
  *approximate* card, draws **no slot brackets**. A small dim `?` glyph at the
  right end of the slot row says why the row is blank (so "no brackets" reads as
  *uncertain*, not *broken*). The panel still draws the tree with `?` marks and
  the footnote names the spells responsible:
  `? = Alpha, Unknown Modded Spell: structure uncertain`.
- **Show** — brackets drawn anyway, `?` marks in the panel as today. For players
  who want the approximation and know what it is.

This is KoObEy's point 1 generalized so it also covers mods (Night's case) and
future unknowns without a hand-maintained exception list. It is **not** point 1
verbatim: he asked for Divides and Add Triggers to be hidden too, and they are
not — see §0.2 for the departure and the harness gate that keeps it honest.
The shuffle-wand suppression stays a separate, absolute rule.

Implementation notes:

- `wand_structure.lua`: `M.tier(meta_record)` (pure) and `M.wand_tier(ids, meta)`
  → `"exact" | "approximate" | "unknown"` with the offending ids. The
  harness-gated tier is not a fourth runtime value — it resolves to `exact` or
  `approximate` at generation time, from whether the differential suite passed.
  Tested in `tools/test_wand_structure.lua`.
- `grouping_overlay.lua`: `collect_wand_boxes` stamps `wd.tier`;
  `draw_box_brackets` checks it next to the shuffle check; `sim_rows` extends the
  existing `any_dynamic` footnote into a named list.
- Debug Info box: print the wand's tier and the offending ids.

---

## 3. Track A — runtime spell metadata (the modded-spell fix)

Today `meta_for()` returns `{ type = "OTHER" }` for any id not in
`structure_meta.lua`, so a modded modifier is a leaf that ends its cast and a
modded multicast gathers nothing — exactly Night's "multiple casts when there is
only one". Two layers fix it; the second is KoObEy's suggestion.

### A1 — read the game's live `actions` table (cheap, do first)

> **Status: implemented.** `files/runtime_meta.lua` loads `gun_actions.lua`
> lazily (after `gun_enums.lua`) inside a `pcall`, builds
> `runtime_meta[id] = {type, name, mana, rp}` per id, and merges it beneath
> `structure_meta.lua` in `meta_for`'s fallback chain; the type-fallback table
> below is what it emits for an id with no generated record. Any failure
> leaves `M.runtime` empty, `M.status = "failed: ..."`, and `M.merged()`
> degrades to plain `structure_meta` — `M.status_line()` reports this on the
> Debug Info box. Tested offline against `.gun_ref/` in
> `tools/test_runtime_meta.lua`, which also confirmed the finding below that
> loading `gun_actions.lua` needs no other file-scope global beyond
> `gun_enums.lua`'s `ACTION_TYPE_*` constants and the file's own two
> `dofile_once` deps — so nothing else has to be stubbed for A1 to work. A2
> (the probe), A3 (probe-vs-meta regression) and A4 (settings/debug) remain
> planned for v1.5.0.

Every spell the game knows, including every spell other mods appended via
`ModLuaFileAppend("data/scripts/gun/gun_actions.lua", …)`, is an entry in the
global `actions` table — confirmed a plain global assignment at
`gun_actions.lua:4`, produced by
`dofile_once("data/scripts/gun/gun_actions.lua")` (after `gun_enums.lua` for the
`ACTION_TYPE_*` constants). Load it lazily on the first `M.update()` (all mods
have finished appending by then), inside the usual `pcall`, and build
`runtime_meta[id] = { type, name, mana, max_uses, related_projectiles ~= nil }`.

Merge order for `meta_for(meta, id)` — note the real signature is
`(meta, id)` and it is file-local in `wand_structure.lua:89`, so this becomes a
module-level merge rather than a change to that function's arity:
**probe result (A2) > structure_meta.lua > type-only fallback from A1 >
`{type="OTHER"}`**. The type-only fallback:

| runtime `type` | assumed record | tier |
|----------------|----------------|------|
| MODIFIER, PASSIVE | `draws=1` | approximate (until probed) |
| DRAW_MANY | unknown count | unknown |
| PROJECTILE / STATIC_PROJECTILE / MATERIAL | leaf | approximate (could be a trigger) |
| UTILITY / OTHER | leaf | unknown |

A1 alone already turns most modded modifiers from "cast boundary" into "prefix",
which is the bulk of Night's complaint. The `name` field also gives modded
spells localized panel labels for free, and `mana` feeds Track E — with the
caveat from §5 that a `nil` mana means `ACTION_MANA_DRAIN_DEFAULT` (10), not
zero.

`structure_meta.lua` stays: it is the offline test fixture and the fallback when
the runtime read fails, and the generator should start emitting `mana=` so the
mana tests run without the game.

### A2 — the probe: execute an unknown spell in a stub shot state

**Scope has narrowed.** The probe was designed because there was no way to run
the real code. There is now (§0.1), and for vanilla spells the differential
harness is strictly better evidence. A2's remaining job is the one the harness
cannot do: classifying **modded** spells at runtime, whose bodies are not in
`data.wak`. Everything below is scoped to that.

**The original safety argument was wrong and needs replacing.** This plan
claimed every action body wraps its world side effects in
`if not reflecting then … end`. It does not: `reflecting` appears **twice in
490 vanilla actions** (`gun_actions.lua:10757` in `IF_HALF`, and `:11095`).
The protection actually lives in `gun.lua`'s wrappers — `add_projectile`,
`add_projectile_trigger_*` all return early under `reflecting` — not in a
convention the bodies follow. So a modded body called with `reflecting = true`
is **not** thereby harmless, and the real safety comes from our own stubbing of
every engine global. Say that honestly in the design doc; it changes the risk
assessment, not the approach.

Two consequences worth recording:

- `draw_action` itself begins `if reflecting then return end`
  (`gun.lua:236`). So the *real* engine draws nothing during a reflecting pass.
  The harness must therefore run with `reflecting = false`, and the probe's
  `reflecting = true` only makes sense because the probe supplies its own
  `draw_actions` stub rather than gun.lua's.
- `IF_HALF` branches on `reflecting` and takes the no-skip path when it is set,
  so the probe sees exactly one of its two behaviors. Any modded spell that
  copies that idiom has the same blind spot. Record it as
  `dynamic = "reflect-blind"` rather than pretending the record is complete.

**Another mod may already have wrapped every `action` function.** Spell Lab
(Workshop 2297568811) appends this to `gun_actions.lua`:

```lua
for k,v in pairs( actions ) do
    local original_function = v.action
    v.action = function(...)
        if not reflecting then action_called( v ) end
        current_draw_depth = ( current_draw_depth or 0 ) + 1
        local result = original_function(...)
        current_draw_depth = current_draw_depth - 1
        return result
    end
end
```

So `actions[i].action` is not necessarily the body the game shipped — the probe
may be calling a chain of other mods' wrappers, and A1's runtime read sees the
wrapped table too. Spell Lab's wrapper is benign (it honors `reflecting`, and
`action_called` is a no-op unless Spell Lab's UI is open), and it is a useful
existence proof that this pattern is in the wild. But the probe must not assume
it holds the vanilla body: `current_draw_depth` is a global another mod expects
to balance, and a wrapper that does not honor `reflecting` would fire real side
effects during a probe. Sandbox the globals a wrapper might touch, and record
in the probe result whether the body was wrapped (compare `#actions` against the
vanilla 422 and, where cheap, check whether the function is the one loaded from
`.gun_ref/`).

Also confirms the A1 load timing is standard practice: Advanced Spell Inventory
(3267869519) does `dofile_once("data/scripts/gun/gun_actions.lua")` with the
comment *"Do this here so mods have enough time to do their gun_actions.lua mod
appends"* — the same reason `runtime_meta.load()` waits for the first update.

The sandbox (`files/action_probe.lua`, pure Lua, no game API so it runs under
`lua5.1`/`5.4` in the tools):

- **Globals the body sees** (via `setfenv` where available, otherwise a plain
  global swap guarded by "only if `draw_actions == nil` in this VM", §7):
  `deck`, `hand`, `discarded` (stub cards), `c` and `shot_effects` (tables with
  an `__index` returning `0` for unknown fields), `reflecting = true`,
  `recursion_level = 0`, `dont_draw_actions = false`, `mana = 1e9`,
  `current_reload_time`, the `ACTION_TYPE_*` constants, the Lua stdlib, and
  every uppercase-initial global (engine API) replaced by a stub.
- **Engine stubs must not blanket-return `0`.** `0` is truthy in Lua, so a
  uniform `return 0` makes every engine predicate take its true branch. The live
  example is in the Add Trigger body: `ActionUsesRemainingChanged` returning `0`
  makes `if not reduce_uses` unreachable. Stub returns are per-function:
  `false` for predicates (`EntityHasTag`, `HasFlagPersistent`, `GameHasFlagRun`),
  `nil` or `{}` for lookups (`EntityGetInRadiusWithTag`, `EntityGetAllChildren`),
  `0` only for genuine numerics (`GameGetFrameNum`, `GetUpdatedEntityID`),
  `0, 0` for `EntityGetTransform`, `""` for `GlobalsGetValue`. Anything
  unlisted returns `nil` and is logged, so the gaps are visible.
- **Stubbed gun.lua functions, each recording**: `draw_actions(n, forced)`
  (records `n`; `n == #deck` at call time ⇒ `-1`; pops `n` stub cards to `hand`;
  honors `dont_draw_actions`, which several vanilla bodies set — see §4 D2/D3 —
  and which a modded body may copy), `draw_shot` / `create_shot` and the three
  `add_projectile_trigger_*` (record `{ trigger = kind, payload = n }`, do
  **not** recurse), `add_projectile`, `check_recursion` (mirror the real one:
  `-1` past `recursion_limit = 2` for `recursive` cards, else `rec + 1`),
  `move_discarded_to_deck`, `order_deck`, `set_current_action`,
  `register_action`, `play_action`, `Reflection_*`.
- **Stub cards** are 16 dummies
  `{ id = "__PROBE_k", type = PROJECTILE, deck_index = k, uses_remaining = -1,
  related_projectiles = {"__probe.xml", 1}, action = <records "recast k"> }`.
  Their `action` recording is what detects a Greek-style re-cast by reference;
  the deck shrinking *without* a `draw_actions` call is what detects direct
  consumption (Divide, Add Trigger, RESET, and any modded look-alike).
  `related_projectiles` must be present or the Add Trigger family silently takes
  its no-op path. Run the probe with `deck[1].type` set to each of PROJECTILE /
  MODIFIER / OTHER in turn so type-conditional bodies are seen every way.
- **Determinism**: run 3× with different `SetRandomSeed`; a differing record ⇒
  `dynamic = "random"`. Guard: the `draw_actions` stub errors after 64 calls.
- **Any error** ⇒ the id is cached as `unknown` and never probed again this
  session. Everything runs from `OnWorldPostUpdate` while the inventory is open,
  never inside a cast, and never touches real gun state (§7 confirms the mod's
  VM does not hold `gun.lua`).

Record produced, superset of today's fields:

```lua
{ type, name, mana,
  draws = n | -1,            -- forced draws (draw_actions)
  consumes = n | "scan" | "rest",  -- removed from the deck with no forced draw:
                             --   n      fixed count (Divide's iter_max case)
                             --   scan   variable-width forward scan (Add Trigger)
                             --   rest   the entire remaining deck (RESET)
  consumes_skip = { types },  -- for "scan": types stepped over and swallowed
  repeats = n,               -- times the consumed card's body was invoked
  repeats_first_silent = true,-- first invocation runs under dont_draw_actions
  recasts = { "hand[1]" | "discarded[1]" | "deck[#deck]" | "all" | … },
  recasts_silent = true,      -- the copied body runs under dont_draw_actions
  trigger = kind, payload = n,
  dynamic = "random" | "reflect-blind" | nil }
```

`chains()` / `is_multicast()` in `wand_structure.lua` keep working on the same
`draws` / `chain` / `payload` fields; the rest are new and drive D1–D3.

### A3 — the probe as a regression test for the vanilla table

`tools/extract_gun.py` already writes `gun_actions.lua` to `.gun_ref/` (§0.1 —
do *not* build the `dump_gun_actions.py` this plan originally proposed);
`tools/probe_actions.lua` loads it with `action_probe.lua` and prints a record
per id; `tools/test_probe_vs_meta.lua` diffs that against `structure_meta.lua`.
The probe must strip `--[[ … ]]` block comments before walking the file, exactly
as `gen_structure_meta.py` does: 68 of the 490 `id =` matches in
`gun_actions.lua` are commented-out actions that do not exist at runtime (§2).
Skip that and the first diff is 68 lines of phantom spells.

Every disagreement is either a regex miss in the generator (ADD_TRIGGER, §4 D1,
is the known one) or a probe bug — both worth knowing before the probe is
trusted on other people's spells. Note that agreement between probe and
generator proves only that two *guesses* match; the differential harness is what
proves either matches the engine. Once all three agree, the generator can be
replaced by the probe (`gen_structure_meta.py` → thin wrapper), and the Python
cross-check mirror `test_wand_structure.py` has been retired in favor of
`tools/test_gun_differential.lua`.

### A4 — settings and debug

- `probe_modded_spells` (default on): A2 on/off. With it off, A1's type-only
  fallback applies and those wands are *approximate* → no brackets under the
  default policy.
- Debug Info box: for the held wand, one line per card:
  `id  tier  src=meta|runtime|probe  draws/consumes/payload`. That is the
  screenshot that makes a modded-spell bug report actionable.

---

## 4. Track D — specific vanilla spells

Every body in this section has now been read in `.gun_ref/`; line references are
to `gun_actions.lua` and `gun.lua` as extracted by `tools/extract_gun.py`. The
**VERIFY** tags are gone — where an earlier draft of this plan guessed, the
guess is recorded alongside the correction, because the shape of the mistake is
the reason the harness exists.

### D1 — Add Trigger / Add Timer / Add Death Trigger (**FIXED**)

> **Status: implemented.** `gen_structure_meta.py` now emits `scan=true` for the
> three cards and `rp=N` (the `related_projectiles` count) for the 212 cards
> that can carry a trigger; `wand_structure.lua` grows a scan branch; 11 cases
> cover it in `tools/test_wand_structure.lua` and the Python mirror. All eleven
> wands were run through Noita's real `gun.lua` with `tools/gun_harness.lua`
> and agree with it on what each expression consumes. The rest of this section
> is the reasoning that produced the fix.

`structure_meta.lua:15-17` records the three as `trigger=…, payload=1` with no
`draws`, so the simulator makes the Add Trigger card a trigger head whose
payload is the **next** card: `ADD_TRIGGER, SPARK, BOMB` renders
`(ADD_TRIGGER SPARK) BOMB`. That is wrong, and the real body
(`gun_actions.lua:9313`, and structurally identical at `ADD_TIMER` and
`ADD_DEATH_TRIGGER`) is wrong in a more interesting way than this plan first
guessed.

*The earlier guess was:* peek `deck[1]`; if it is a projectile with
`related_projectiles`, consume that one card and open a 1-card payload;
otherwise do nothing. **What it actually does:**

1. **Forward scan.** Starting at `deck[1]`, step forward while the card is
   MODIFIER / PASSIVE / OTHER / DRAW_MANY, counting into `how_many`.
2. **Modifiers are applied in passing.** Each stepped-over MODIFIER has its
   `data.action()` invoked inline under `dont_draw_actions = true` — so it
   modifies the trigger projectile *and* its own forced draw is suppressed.
   Cards whose id is one of the three Add Trigger spells, and depleted cards,
   are skipped without being executed but are still counted.
3. **Consumption is variable-width.** If the card the scan lands on has
   `related_projectiles`, the body consumes **all `how_many` cards** —
   `for i=1,how_many do table.insert(discarded, deck[1]); table.remove(deck,1) end`
   — the stepped-over modifiers included. Not one card.
4. **Payload count is not 1.** `count = data.related_projectiles[2] or 1`, and
   the body loops `for i=1,count do add_projectile_trigger_hit_world(target, 1) end`.
   A spell whose `related_projectiles` declares 3 opens three 1-card payloads,
   so the forced draw is `count`, not 1. `ADD_TIMER` calls
   `add_projectile_trigger_timer(target, 20, 1)` (20-frame delay);
   `ADD_DEATH_TRIGGER` calls `add_projectile_trigger_death(target, 1)`.
5. **The `valid` fallback.** Before spawning, the body scans the *remaining*
   deck for any PROJECTILE / STATIC_PROJECTILE / MATERIAL / UTILITY. If it finds
   none, `valid` is false and it runs `data.action()` under `dont_draw_actions`
   instead — i.e. **it casts the projectile plainly, with no trigger at all**,
   having already consumed the cards. So "a trailing Add Trigger does nothing
   and cannot wrap" is false: it consumes, it fires, it just does not trigger.

So `ADD_TRIGGER, DAMAGE, SPARK, BOMB` is `(ADD_TRIGGER→DAMAGE SPARK (BOMB))`:
Damage and Spark both consumed by the scan, Bomb drawn as the payload.

Metadata, as shipped: the three cards get `trigger="…", scan=true` (and lose the
bogus `payload=1`); every card with `related_projectiles` gets `rp=N`, which is
both "can carry a trigger" and the payload count. The simulator's scan branch
walks the deck with the same type predicate, removes the scan directly (no
`draw()`, so it can never wrap), makes the target the expression head with the
whole scan as its modifier prefix, and then either opens `rp` payloads or — when
the `valid` check finds nothing projectile-ish left — emits a plain leaf.

One engine behavior the model deliberately does not show: when the scan runs off
the end of the deck it consumes nothing, but the modifiers it stepped over have
*already had their bodies run*, and they are then drawn and run a second time.
The harness confirms it (`{ADD_TRIGGER DAMAGE* DAMAGE}`). That is shot state,
not deck consumption, so under the Track B definition no bracket says it.

Tests: the three-card and four-card cases above; Add Trigger before a lone
modifier (scan runs off the end, consumes nothing); trailing Add Trigger (the
`valid` fallback, plain cast); a `related_projectiles[2] > 1` spell (multiple
payloads); Add Trigger followed by Add Trigger (second one counted, not
executed); payload wraps.

### D2 — Divide By

*The earlier guess was:* Divide consumes the next card and invokes its body
`repeats` times, each invocation drawing fresh cards, so
`DIVIDE_2, BURST_2, A, B, C, D` is `(DIVIDE_2 (BURST_2 A B) (BURST_2 C D))`.
**That example is wrong on both counts.** The real body
(`gun_actions.lua:10063`):

- **Reads `deck[iter]`, not `deck[1]`.** `iter = iteration or 1`, where
  `iteration` is passed down by an enclosing Divide. Nested Divides therefore
  read progressively deeper into the deck.
- **The first invocation is silent.** The loop is
  `for i=1,count do if i == 1 then dont_draw_actions = true end;
  data.action(rec, iter+1); dont_draw_actions = false end`. So invocation 1
  runs with draws suppressed and gathers **nothing**; only invocations 2..count
  draw. The example above is `(DIVIDE_2 (BURST_2) (BURST_2 A B))` — one
  populated group, not two.
- **Counts degrade with depth.** `DIVIDE_2` count 2, dropping to 1 at
  `iter >= 5`; `DIVIDE_3` count 3, dropping at `iter >= 4`; `DIVIDE_4` count 4,
  dropping at `iter >= 4`; `DIVIDE_10` count 10, dropping at `iter >= 3`.
- **Consumption happens once, at the outermost level, and is not 1 card.**
  Guarded by `if (iter == 1)`, the body removes `iter_max` cards to `discarded`,
  where `iter_max` is the deepest `iteration` any nested Divide reported back
  (each returns `iter_max`). `DIVIDE_2, DIVIDE_2, SPARK` consumes 2.
- Answering the old §7 question: the consumed cards go to **`discarded`**, not
  `hand`.

Metadata: `repeats = count`, `repeats_first_silent = true`,
`repeats_decay_at = iter`, `consumes = "iter_max"`. Simulator: `parse_expr`
tracks an `iter` depth, invokes the consumed card's body `count` times with the
first invocation collecting no children, and charges `iter_max` cards to the
outermost Divide only.

Tests: the corrected example; divide → trigger; divide → divide (consumption of
2, and the depth-degraded count); divide → multicast at wand end (wrap inside a
non-first repeat); DIVIDE_10 at depth 3.

### D3 — the Greeks: three classes, not one

> **Status: partially implemented.** The generator bug this section blamed for
> ALPHA / GAMMA / TAU's chaining is fixed: `gen_structure_meta.py`'s
> draws-regex used to read the commented-out `--draw_actions( 1, true )` line
> in those three bodies as live; comments are stripped before the regex runs
> now, so all three carry no `draws` and are leaves in `structure_meta.lua`,
> confirmed by `tools/test_gun_differential.lua`'s three "does not chain"
> cases. What is **not** done is modeling class 1's copy-live consumption
> itself — what ALPHA/GAMMA/TAU indirectly draw through the card they copy —
> which stays v1.5.0 work and is the one KNOWN divergence the differential
> harness reports (§0.1; the TAU case above).

This plan treated the eight as a uniform family that copies a card by reference
and force-draws one card afterwards. Neither half of that is generally true.
The `draw_actions(1, true)` call this plan attributed to "most of them" is
**commented out in the game's source** for three of them, and four others
suppress the copied body's draws entirely.

| Greek | reads | copied body draws? | own force-draw | refunds copied mana |
|-------|-------|--------------------|----------------|---------------------|
| ALPHA | `discarded[1]` → `hand[1]` → `deck[1]` | **yes, live** | none (`--draw_actions( 1, true )`) | no |
| GAMMA | `deck[#deck]` → `hand[#hand]` | **yes, live** | none (commented out) | no |
| TAU | `deck[1]` and `deck[2]` | **yes, live** | none (commented out) | no |
| OMEGA | every card in `discarded`, `hand`, `deck` | no — `dont_draw_actions` | none | yes |
| PHI | as OMEGA, type-filtered | no — `dont_draw_actions` | none | yes |
| MU | as OMEGA, type-filtered | no — `dont_draw_actions` | `draw_actions(1, true)` | yes |
| SIGMA | as OMEGA, type-filtered | no — `dont_draw_actions` | `draw_actions(1, true)` | yes |
| ZETA | a random spell from the player's **other quick-inventory wands** | no — `dont_draw_actions` | `draw_actions(1, true)` | no |

Three corrections that change the design:

1. **ALPHA reads `discarded[1]`, not `hand[1]`.** This plan had it as "the first
   card drawn this cast". It is the first card *discarded* — which, because
   `discarded` accumulates across casts until a reload, is usually the wand's
   first card of the current cycle, and is empty only on the very first draw.
   The fallback chain to `hand[1]` then `deck[1]` matters on that first cast.
2. **Class 1 (ALPHA / GAMMA / TAU) is the only class where the copied body's
   forced draws are real consumption.** This plan's worked example — `Alpha ⇒
   copy of Double Spell` then two consumed cards — is correct here and *only*
   here.
3. **Class 2 (OMEGA / PHI / MU / SIGMA) and ZETA consume nothing through the
   copy.** `dont_draw_actions = true` wraps every `data.action()` call, and
   `draw_actions` is a no-op while it is set (`gun.lua:300`). So an Omega on a
   wand full of multicasts draws nothing at all from them. Under the Track B
   consumption definition, OMEGA and PHI consume **nothing whatsoever** — their
   bracket would be empty — while MU, SIGMA and ZETA consume exactly the one
   card of their own trailing `draw_actions(1, true)`.

An empty bracket is a worse lie than no bracket, so this is an independent
argument for KoObEy's position on Greeks specifically: **all eight stay
`approximate` or `unknown` and hide their brackets by default**, and the panel
names the copy in text (`Alpha ⇒ copy of Light Bullet`) without drawing bars.
ZETA is `unknown` outright — it reads entities off the player's other wands and
seeds `SetRandomSeed` from position plus `GameGetFrameNum()`, so it is not a
function of the wand at all.

One shared fact for all eight: `check_recursion` (`gun.lua`) returns `-1` once a
`recursive` card is nested past `recursion_limit = 2`, at which point the copy
silently does not happen. The simulator should model the same cutoff rather than
recursing freely.

### D4 — IF_* requirement spells

Now read rather than assumed. `IF_END` is a plain `draws=1` card and is
**exact**. The branching four scan the deck for their matching `IF_END` /
`IF_ELSE` and remove the skipped span, so they do have real deck effects:

- `IF_ENEMY` counts `homing_target` entities within radius 240 (skips when
  fewer than 15), `IF_HP` and `IF_PROJECTILE` similarly read world state —
  genuinely runtime, so **approximate**.
- `IF_HALF` is different and worth noting: it toggles a persistent global
  (`GUN_ACTION_IF_HALF_STATUS`) and alternates every cast. It is fully
  deterministic *as an alternation* but not determinable from a single frame,
  and it is one of only two vanilla bodies that reads `reflecting` — so the
  probe is structurally blind to one of its branches (§3 A2). **approximate**,
  flagged `dynamic = "reflect-blind"`.

Simulating both branches and greying the skipped span remains a later option,
not in this plan.

### D5 — depleted cards and the retry rule (KoObEy point 3) — resolved

> **Status: implemented.** `wand_structure.lua`'s `simulate` takes `opts.uses`
> (slot → `uses_remaining`) and `draw()` retries past a depleted card exactly
> as `gun.lua` does, with the retry able to fire only on the first attempt of
> each draw — a later retry cannot wrap. A depleted card lands in `cast.spent`
> rather than being pre-filtered, and `sim_rows` gives a cast whose every draw
> hit a depleted card (`#cast.nodes == 0` but `#cast.spent > 0`) its own
> `-- no spells left (depleted)` header so the panel doesn't read as
> "nothing happened". `greek_keeps_depleted` is kept in `settings.lua` as a
> visible no-op — its description now says "No longer does anything ... This
> option will be removed in the next release" — because `read_deck` no longer
> pre-filters by Greek wand at all; the actual removal is deferred to v1.5.0.
> Six `uses=` cases in `tools/test_gun_differential.lua` confirm the model
> against `gun.lua` itself: a depleted modifier retried past, a multicast
> retrying past one and still gathering 2, a depleted *last* card losing its
> draw without wrapping (both a root draw and a forced draw onto it), the same
> on a Greek wand (TAU — the one KNOWN divergence, §0.1/§4 D3), and RESET
> clearing a depleted card exactly like a live one. The rest of this section
> is the reasoning that produced the fix.

The open question was whether `draw_actions(N)` **retries** after a depleted
card or **counts it** toward N. `gun.lua:299-322` answers it: **retry.** When
`draw_action` returns false, the caller enters `while #deck > 0 do if
draw_action(...) then break end end` and keeps drawing until one succeeds. So
`BURST_2, DEPLETED, A, B` gathers A and B; the repo comment is right, the
shipped `card_fires` filter models it correctly, and the speculative `spent`
node kind is **not needed**. Drop it.

Two things the resolution turned up that *are* needed, and that §0.3 concedes to
KoObEy:

- **The retry loop cannot wrap.** It is guarded on `#deck > 0` and never reaches
  the `instant_reload_if_empty` path that `draw_action` uses for a normal empty
  deck. If the deck empties during retry, the iteration is silently lost — the
  wand does **not** wrap for it. A depleted card near the end of the deck
  therefore eats a draw. The simulator currently filters depleted cards out
  entirely and so cannot express this; it needs to keep them as a consumed blank
  *for the purpose of the draw count at deck end* while still not rendering them
  as fired.
- **`greek_keeps_depleted` disables the whole filter on Greek wands** by default
  (`grouping_overlay.lua:162`). Given D3 — Greeks read `discarded`, `hand` and
  `deck` by position — the setting's rationale is sound, but "off by default on
  exactly the wands point 3 is about" is not. With D3's per-class model in place
  the filter can stay on for classes that do not read by index, and the setting
  narrows to ALPHA / GAMMA / TAU.

The same `draw_action` path handles insufficient mana, so §5 inherits both
answers.

### D6 — RESET (**FIXED**)

> **Status: implemented.** `wand_structure.lua` gives RESET `consumes = "rest"`
> in the metadata and a node kind `reset` carrying the emptied slots as
> `cleared` (printed `RESET:clears[3,4]`); the restore is modeled as a WRAP.
> Seven cases in `tools/test_gun_differential.lua` run it against Noita's own
> `gun.lua` and agree on every one (commit fd92a41, merged at 83bbccc). The
> rest of this section is the reasoning that produced the fix.

`RESET` (`gun_actions.lua:10439`) was listed as "unchecked" in the tier table.
It is checked now, and it is not a leaf: it moves **every** card from `hand`
and from `deck` into `discarded` and empties both, plus
`current_reload_time -= 25`. Under the Track B definition its bracket encloses
the entire remaining wand — but the cast does **not** end there for want of
cards, which is what an earlier draft of this section guessed. The tail of the
body is the part that surprises:

```lua
if ( force_stop_draws == false ) then
    force_stop_draws = true
    move_discarded_to_deck()
    order_deck()
end
```

So the deck does not stay empty: it comes straight back **full**, holding
everything discarded so far this recharge cycle (including RESET itself and
everything it just cleared), restored in slot order. The cast then continues
drawing from the wand's own start — a wrap — and `force_stop_draws` latches
true for the rest of the cast, so a *second* RESET in the same cast restores
nothing (the deck really does stay empty that time) and also blocks
`draw_action`'s own reload path, so a later draw that empties the deck is
**lost**, not wrapped.

The harness confirms this on `BURST_2, RESET, SPITTER, BOMB` @ 1 spell/cast:
BURST_2's first child is RESET, whose restore refills the deck, so the
multicast's **second** child is drawn from slot 1 and finds BURST_2 again —
whose own draw hits RESET again. That second RESET restores nothing
(`force_stop_draws` is already set), and the inner multicast's second child is
lost for good, uncounted and unwrapped. The engine's own trace reads
`BURST_2 >RESET ~>BURST_2 ~>>RESET`.

One more consequence: a RESET cast's consumed slot set **nets out**. A card
the cast drew and RESET then handed straight back to the deck was not, on
balance, removed from it — the engine's own deck diff agrees, and
`cast.slots` is computed the same way (touched-this-cast minus still-in-the-
deck). And because the restore is a wrap in every sense the mod means (later
draws really are wrapped-in cards from the wand's start), a RESET cast is
rendered exactly like any other wrapping cast — same `W` marker, same
recharge-cycle-ends-here rule.

That is deterministic and cheap to model — `consumes = "rest"`, tier **exact**
— and it is a striking bracket to draw, which is an argument for shipping it
rather than hiding it.

`ALL_SPELLS`, also previously unchecked, loads an entity and touches
`c.fire_rate_wait` / `current_reload_time` only. No deck effect: **exact** leaf.

---

## 5. Track E — mana

The engine rule is now read rather than assumed (`gun.lua:236-287`). Mana is a
single global for the whole cast, seeded by `_start_shot(current_mana)` and
handed back at the end. `draw_action` charges each card **as it is drawn**:

```lua
local action_mana_required = action.mana or ACTION_MANA_DRAIN_DEFAULT  -- 10
if action_mana_required > mana then
    OnNotEnoughManaForAction(); table.insert(discarded, action); return false
end
mana = mana - action_mana_required
```

So an unaffordable card is drawn, discarded unexecuted, and `draw_actions`
**retries** for it — the identical path to the depleted case in D5, including
the inability to wrap when the deck empties mid-retry. KoObEy's "lacking mana
discards the spell and allows later wrapping" is right about the discard; the
"later wrapping" is subtler, because the retry itself consumes an extra card
and, at the end of the deck, silently loses the draw instead of wrapping.

Four corrections to this plan's original E1 sketch, all of which change the
arithmetic:

1. **`nil` mana is 10, not 0.** `ACTION_MANA_DRAIN_DEFAULT = 10` (`gun.lua:5`).
   A modded spell that omits `mana` costs 10, and the generator must emit the
   default explicitly rather than leaving the field absent.
2. **Always-cast spells are free — exclude them from the sum.** This plan said
   to add "the always-cast cards" to each cast's total. They never pass through
   `draw_action`: `_play_permanent_card` (`gun.lua:575`) calls `play_action`
   directly, so no mana is deducted. It calls `handle_mana_addition` first,
   which means an always-cast **Add Mana** (negative `mana`) still *adds* to the
   pool. So always-cast contributes zero or a credit, never a cost.
3. **Trigger payloads share the cast's pool.** `draw_shot` swaps the shot state
   `c` but leaves `mana` global (`gun.lua:307-318`), and the payload is drawn
   during the cast, not at hit time. So a per-*cast* total that includes payload
   cards is the correct unit — which is what KoObEy proposed and what the panel
   already groups by.
4. **OMEGA / PHI / MU / SIGMA refund what they copy.** Each saves
   `local mana_ = mana` before its copy loop and restores `mana = mana_` after,
   so the copied spells' costs vanish. ALPHA / GAMMA / TAU / ZETA do not.
   Since all eight hide their brackets by default (D3), this only matters for
   the mana row — which should show the Greek's own cost and not the copies'.
5. **RESET's cleared cards and the Add Trigger scan's swept-up cards are free**
   (§4 D1, §4 D6). Neither ever passes through `draw_action` — RESET's clear
   and the scan's forward walk both remove cards from the deck by a direct
   `table.remove`, not a draw — and `draw_action` is the only place `mana` is
   ever decremented, so none of those cards cost anything. A depleted card is
   free for the same structural reason from a different angle: `draw_action`
   discards it and returns before reaching the `mana = mana - cost` line, so it
   too is billed nothing (§4 D5). `wand_structure.lua`'s cast-loop mana sum
   excludes all three card classes (`spent`, `cleared`, `scanned`) from the
   total; `tools/gun_harness.lua` exposes `cast.mana_spent` from the engine's
   own `mana` global so the exclusion is checked against `gun.lua` itself, not
   just reasoned about.

### E1 — per-cast mana total vs. max mana (ship with 1.4)

> **Status: implemented.** `wand_structure.lua`'s cast loop sums `cast.mana`
> over every card the cast drew (`meta_for(meta, cd.id).mana or MANA_DEFAULT`),
> excluding the three free-card classes: `spent` (a depleted card, discarded
> unplayed, §4 D5), `cleared` (RESET's direct removal, §4 D6) and `scanned`
> (the Add Trigger scan's forward sweep, §4 D1) — none of the three ever pass
> through `draw_action`, so none are billed. `grouping_overlay.lua` reads
> `mana_max` off the wand's `AbilityComponent` directly (not inside
> `gun_config`, next to it), defaulting to 0 meaning "no threshold". The cast
> header gains `mana N` and, when `cast.mana > mana_max`, `> max N` in the
> warning color; the sticky footnote and Debug Info box carry the same rule.
> `tools/test_gun_differential.lua`'s three `mana_spent` cases check
> `cast.mana` against `gun.lua`'s own `mana` global for exactly the scanned-
> and cleared-card exclusions, and pass.

`mana` per card from A1's runtime table (vanilla fallback: emit `mana=` in
`structure_meta.lua`, defaulting absent values to 10). `simulate` already knows
which cards each cast consumed; sum over them, excluding always-cast cards and
Greek-copied cards per the corrections above, and store `cast.mana`. Wand
`mana_max` from `AbilityComponent` (`mana_max`, `mana_charge_speed`, current
`mana`, all next to `gun_config`).

Panel: the cast header gains `  mana 210` and, when `cast.mana > mana_max`,
turns warning-colored with `> max 150` — a cast costing more than the wand can
ever hold never fires as drawn. Footnote: `mana = cost of this cast; > max means
part of it will be discarded`. Debug box: per-cast totals plus the wand's mana
fields.

This is exactly KoObEy's middle ground: always true as a statement, never
pretending to know the current pool.

### E2 — optional "assume full mana" discard simulation (later)

Setting off by default. Simulate each cast with the pool at `mana_max` (not the
live `mana`, which flickers as it regenerates): the first card whose cost
exceeds the remaining pool is discarded blank, the retry pulls a replacement,
later cheaper cards may still fire, and the resulting shifts are drawn with `?`.
D5's answer applies unchanged — retry, not count, and no wrap if the deck
empties during the retry.

---

## 6. Release slicing

Sliced against KoObEy's retraction condition (1-3), not against what is easiest
to build. Every simulator change in both releases lands with a differential
harness case (§0.1) as well as unit tests — that gating is what turns the Track
C tiers into claims rather than hopes.

**v1.4.0 — "checked against the game"** — answers 1, 2 (partially) and 3, and
throws in 4 and 5:

- ~~**Track B** — the consumption definition, stated in `README.md`, the
  Workshop description, and the panel legend.~~ **done** *(point 4)*
- ~~**Track C** — tiers, `uncertain_brackets`, the `?` slot glyph, the named
  footnote.~~ **done** *(point 1, with §0.2's departure — see §2's status)*
- ~~**A1** — read the live `actions` table so modded modifiers stop reading as
  projectiles and modded multicasts group correctly.~~ **done** (see §3 A1's
  status). This is Night's fix, and it is "some form of" point 2 arriving *in*
  the gating release rather than after it.
- **D1** — ~~Add Trigger, corrected~~ **done** (see §4 D1): forward scan,
  variable-width consumption, inline modifier application,
  `payload = related_projectiles[2] or 1`, and the `valid` fallback where it
  casts the projectile plainly with no trigger at all. Cross-checked against the
  real `gun.lua`, which is the first thing the harness has paid for.
- ~~**D5** — the two 0-charge gaps from §0.3: Greek wands honoring the filter,
  and the lost draw at deck end.~~ **done** *(point 3 — see §4 D5's status)*
- ~~**E1** — per-cast mana total vs. `mana_max`, warning-colored when over.~~
  **done** *(point 5 — see §5 E1's status)*
- ~~**Harness part 2** — decks in, real `gun.lua` results out, diffed against
  `wand_structure.lua`, as `tools/test_gun_differential.lua`.~~ **done** — this
  is what D1 and the Track C tiers are justified by, so it landed first (§0.1).

Extra items landed beyond this list, all gated by the same harness: **D6**
RESET, including the wrap-restore correction the differential harness found
past what this plan's D6 originally guessed (§4 D6); the retirement of the
Python mirror of `wand_structure.lua` in favor of the differential harness as
the cross-check (commit fb9a68f); the differential suite's `MAGIC_SHOT`
placeholder replaced with `SPITTER`, a real Noita action id the engine can
actually deck (`tools/test_gun_differential.lua`'s header); and
`RANDOM_MODIFIER`'s chaining, previously unmodeled, now `draws=1,
tier="approximate"` (§2's status, and the note in `gen_structure_meta.py`'s
`OVERRIDES`).

What is left of v1.4.0 is T1.12's release text (the Workshop/README writeup of
everything above) and the in-game checks under §7 — nothing in this plan's own
list remains unimplemented.

**v1.5.0 — "modded spells"** — completes point 2:

- **A2** the probe · **A3** probe-vs-meta regression · **A4** settings and debug.
- **D2** Divide, corrected: `deck[iter]`, first-invocation draw suppression,
  `iter_max` consumption at the outermost level only.
- **D3** the Greeks, corrected — two classes, not one. ALPHA / GAMMA / TAU copy
  by reference with their own `draw_actions(1, true)` **commented out in the
  game's source**, and let the copied body draw for real. OMEGA / MU / PHI /
  SIGMA wrap the copied body in `dont_draw_actions`, so it consumes nothing;
  only MU and SIGMA force-draw a card of their own. Under the Track B definition
  several Greeks therefore consume *nothing at all* and would get an empty
  bracket — which is an independent argument for keeping them hidden by default
  even after they are modeled.
- Ask Night for their mod list and test against those spells specifically.

**Later**: E2, D4, and the prefix-vs-definition question raised on the first
1.4.0 run — `Divide By 2, Spark Bolt` draws no bracket at all, because
"modifiers sit outside the parens" and "a one-node cast gets no cast
bracket" both fire, yet the definition in §1 says Divide consumed the card
next to it and so has something to enclose. Options and the affected docs
are written up in `docs/GROUPING_DESIGN.md` under "Open question: prefixes
vs. the definition". Not decided; deliberately not touched before release.

Two scope changes that fall out of the engine reading:

- **A2 is now optional rather than load-bearing.** The probe was designed
  because there was no way to run the real code. There is now. For vanilla
  spells the harness is strictly better evidence, so A2's remaining job is
  narrow and honest: classifying *modded* spells at runtime, where `.gun_ref/`
  cannot help because the spell is not in `data.wak`. §3's safety argument needs
  rewriting too — `reflecting` appears **twice in 490 vanilla actions**, so it is
  `gun.lua`'s wrappers and our own global stubbing that make the probe safe, not
  a convention the bodies follow.
- **§7 mostly collapses.** Its item-1 sub-questions are answered from `.gun_ref/`
  and folded into §4 and §5. What still needs the running game: `setfenv`
  availability under the mod's API restrictions, whether
  `dofile_once("data/scripts/gun/gun_actions.lua")` from `OnWorldPostUpdate`
  returns other mods' appended spells, and the `AbilityComponent` mana fields.

Test discipline stays as it is, plus the harness: every simulator change lands
with cases in `tools/test_wand_structure.lua` (Lua 5.1-compatible, run under
whatever `lua` the machine has — there is none in the remote environment, so the
suite runs locally), slot-row behavior in `tools/test_slot_delims.lua`, a
differential case in `tools/test_gun_differential.lua` wherever the rule came
from `.gun_ref/`, and `tools/preview_wand.lua` gains `--tier` and `--mana` flags
so a reported wand can be reproduced from its spell list without the game.

---

## 7. Verification list

> **In-game results, 2026-09-08 (first 1.4.0 run, vanilla + Tinker With Wands
> Everywhere).** Confirmed: `runtime actions: 422 loaded (ok)` — the live
> `actions` read works in the mod's VM; `mana_max=2221 charge=1104` readable
> off `AbilityComponent`; Add Trigger wand groups as one cast with the prefix
> outside (`Add Trigger, Damage Plus, Spark Bolt, Bomb`); a 0-charge Bomb as
> that trigger's payload loses the draw and does **not** wrap — matches the
> real gun.lua, now pinned as a case; `Double Spell, Thunder Charge ×2` shows
> `mana 240 > max 212` in orange with the mana footnote. Two in-game bugs found
> and fixed the same session: the footnote naming the uncertain spell was gated
> on `any_dynamic` (Alpha never triggered it), and the `?` marker sat on top of
> the last card (now a `? uncertain` tag in the box header band).
> **Not yet seen in-game:** RESET (not offered by the spell-lab picker), the
> relocated `? uncertain` tag, a modded spell (needs a Workshop spell mod), and
> the Better Font pass on the new panel rows. **Open call:** whether a trigger
> whose payload draw hit a depleted card should still bracket the spent slot
> (today it draws nothing; a `(payload depleted)` panel note is the cheap
> alternative).

Most of what this section originally listed is done. `tools/extract_gun.py`
already puts `gun.lua` and `gun_actions.lua` in `.gun_ref/` (§0.1), and every
question under the old item 1 has been answered and folded into §2, §4 and §5:

| old question | answer | where |
|--------------|--------|-------|
| ADD_TRIGGER / ADD_TIMER / ADD_DEATH_TRIGGER bodies | forward scan, variable-width consumption, `count` payloads, plain-cast fallback | §4 D1 |
| DIVIDE_* repeat counts; consumed card to `discarded` or `hand` | 2/3/4/10 with depth decay; first invocation silent; `iter_max` cards to **`discarded`** | §4 D2 |
| the eight Greeks: which pile and index, which force-draw | three classes; three have their force-draw commented out; four suppress the copied body | §4 D3 |
| RESET, ALL_SPELLS, SUMMON_PORTAL, CESSATION deck effects | RESET consumes the entire deck **and** hand; ALL_SPELLS and the rest are leaves | §4 D6, §2 |
| `draw_actions` depleted / insufficient-mana handling: retry or count | **retry**, and the retry loop cannot wrap | §4 D5, §5 |
| the `reflecting` tooltip pass and its globals | `draw_action` returns early under `reflecting`; only 2 of 490 bodies read it | §3 A2 |

What genuinely still needs the running game, and gates only the A2 probe in
v1.5.0 — not anything in v1.4.0:

1. In this mod's VM: is `setfenv` available under
   `request_no_api_restrictions="0"`? Is `draw_actions` nil (i.e. the mod's Lua
   state does not share `gun.lua`'s globals)? Does
   `dofile_once("data/scripts/gun/gun_actions.lua")` from `OnWorldPostUpdate`
   return a table including another mod's appended spells? (Test with any
   spell-adding mod from the Workshop.)
2. Are `mana_max` / `mana_charge_speed` / `mana` readable on the wand's
   `AbilityComponent` with `ComponentGetValue2` (expected yes; same component as
   `gun_config`)? This gates E1's warning threshold, so check it early.
   **Status: still needs the in-game check.** `grouping_overlay.lua` reads
   `mana_max` via `pcall(ComponentGetValue2, ab, "mana_max")` and defaults to 0
   (no threshold) if that fails, so E1 (§5) degrades safely either way — but
   whether the real read succeeds in a running game, rather than just failing
   closed, has not been confirmed.
3. Does `.gun_ref/` survive a Noita update, or does `extract_gun.py` need a
   version guard? The harness silently testing against stale rules would be the
   one failure mode worse than not having it.

---

## 8. Thread post — the promised discussion, before release

Per the Sep 3 reply (*"I'll make a post after I have a sense of things but
before releasing anything to have a discussion"*), this goes up **before** 1.4.0
ships and asks for disagreement rather than announcing a changelog. Light BBCode
so it renders in a Steam discussion. Text below the rule is the post itself.

---

Alright — I dove in, and I owe a couple of you a correction before anything else.

[b]On running the game's code (UserK, and KoObEy agreeing)[/b]

I said I wasn't going to do this. I was wrong to bundle two separate things
together: keeping this mod a lightweight panel, and guessing at the draw rules
myself. I kept the first and dropped the second. The mod's test suite now pulls
Noita's own gun.lua and gun_actions.lua out of data.wak and runs the real cast
code outside the game, so my simulator gets diffed against the actual engine,
deck by deck, every time I change it. I'm still not hooking the live gun system
while you're casting — that's Wand DBG's job and I don't want to touch real cast
state — but "does my answer match the game's answer" is something I check now
instead of assert.

It immediately turned up things I had flat wrong. Three, all fixed in this
release:

[list]
[*]Alpha, Gamma and Tau were chaining onto the next spell. They don't. Their own
draw call is commented out in the game's source, and the script that builds my
spell table was reading the commented-out line. That bug has been in every
release so far.
[*]Add Trigger doesn't take the next card as its payload. It scans forward over
modifiers, consumes that whole run plus the projectile, and the payload size
comes from the projectile itself. "Add Trigger, Damage Plus, Spark Bolt, Bomb"
was drawing as two casts. It's one.
[*]A spell with 0 charges at the end of the deck doesn't wrap the wand. The
retry that skips past it can't reload.
[/list]

[b]What a bracket means (KoObEy #4)[/b]

This is the important one, and I'd like you to argue with the answer before I
ship it. Of your four readings I'm taking the fourth — no longer in the deck
after the first spell executed — because this mod is a deck-stream visualizer
and consumption is the only one of the four it can honestly claim to track.

[quote]A bracket encloses exactly the cards the engine removed from the deck
while executing the bracket's head card. A card a spell re-casts by reference
(Alpha, Omega, ...) is never inside a bracket — the panel names it as a copy
instead.[/quote]

The consequences are load-bearing, so worth saying out loud: trigger payloads
stay nested, because they're consumed by the forced draw even though they fire
later; Divide By and Add Trigger are prefixes; Greeks get no bracket at all
around the spell they copy. Reset's bracket is the entire rest of the wand,
because that is exactly what it removes. If you think a different one of the
four is the better teaching choice, now is the time to say so.

[b]0 charges (KoObEy #3)[/b]

You were right, and my first pass at this concluded it was already handled. It
wasn't, in two places: on any wand carrying a Greek the depleted-spell handling
silently switched itself off, and a depleted spell at the very end of the deck
ate a draw instead of wrapping. The mod now does what the engine does — skip it,
draw the next one, and don't wrap if the deck runs out mid-retry.

[b]No brackets on OTHER-type spells (KoObEy #1)[/b]

Adopting it. Every spell carries a confidence tier now, and a wand holding
anything the mod can't follow exactly draws no slot brackets at all — with a
small "? uncertain" tag saying the row is blank because it's uncertain, not
broken, and a footnote in the panel naming the spells responsible.

Where I differ from you is Add Trigger, and half of Divide By. Having actually
read both bodies I can follow Add Trigger exactly, so it keeps its brackets.
Divide splits: in front of a plain projectile the model matches the engine, so
those keep their brackets; in front of a multicast, a trigger or a modifier it
doesn't — the game re-invokes the divided spell and draws fresh cards each time
— so those wands hide. I only found that boundary by testing it against the real
code, which is the point. The exemption has to keep earning itself, and where it
stopped earning it, the brackets went away.

[b]Modded spells (Night, KoObEy #2)[/b]

Night, your diagnosis was exact: the mod had no idea what modded spells were and
defaulted them to projectiles, which is why one cast rendered as several. The
first half ships now — the mod reads the game's live spell table, which includes
everything other mods appended, so modded modifiers and multicasts get their
real types. How many cards a modded spell actually draws still isn't known, so
those wands are marked uncertain and hide their brackets rather than guess. Next
release does KoObEy's tooltip trick properly: running an unknown spell in an
empty shot state and recording what it does to the deck. If you tell me which
spell mods you play with, I'll test against those specifically.

[b]Mana (KoObEy #5)[/b]

Taking the middle ground you suggested — each cast's cost summed and compared
against the wand's max mana, with the cast highlighted when it can never afford
itself. Not simulating the live pool; it flickers as it regenerates, and I'd
rather show something always-true than something usually-true.

That covers 1-3, plus 4 and 5. Happy to argue about any of it before it goes
out, particularly the bracket definition, since everything else hangs off it.

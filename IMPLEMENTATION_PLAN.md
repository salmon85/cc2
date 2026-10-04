# Colonial Conquest II — Implementation Plan

Autonomous implementation of a Godot 4 / GDScript (strict static typing) modernization of
*Colonial Conquest II*: turn-based 4X space strategy with authoritative headless server,
deterministic turn resolution, data-driven `.tres` entity definitions, and a retro-terminal
GUI client.

Verification loop: every task below is followed by a headless Godot CLI run that must exit
`0` with **no** script errors or warnings before the item is marked complete.

```
GODOT=~/.local/godot/godot
$GODOT --headless --quit-after 2 --path .          # project validation
$GODOT --headless --path . -s res://tests/test_*.gd # per-system verification
```

---

## Phase 1 — Project Setup & CLI Routing

- [x] 1.1 `project.godot` — Godot 4 project, strict static typing, autoloads, main scene, display
- [x] 1.2 `src/core/enums.gd` — global enums (planet class, tech field, ship role, order type…)
- [x] 1.3 `src/core/rng_service.gd` — deterministic seeded RNG wrapper (server-authoritative)
- [x] 1.4 `src/core/cli.gd` — command-line parser: `--server`, `--client`, `--ip`, `--port`, `--seed`
- [x] 1.5 `src/app.gd` + `src/app.tscn` — bootstrap node routing mode → server / client / single-player
- [x] 1.6 `src/net/peer_transport.gd` — thin transport interface (loopback / ENet)
- [x] 1.7 Verification: `tests/test_cli.gd` — 49 checks, arg parsing matrix + routing decision table
- [x] 1.8 Verification: `tests/test_transport.gd` (24 checks), `tests/test_app.gd` (19 checks)

Phase 1 verified. Two findings fixed by the loop: `PackedStringArray([...])` is not a
constant expression (engine flags are a plain `Array[String]`), and unknown engine flags
must be distinguished from typos, so `CLI.ENGINE_FLAGS` suppresses warnings for real
passthrough args.

## Phase 2 — Core Data Resources

- [x] 2.1 `src/data/planet_type_data.gd` + 6 `.tres` (Terrestrial/Desert/Ice/Volcanic/Gas/Barren)
- [x] 2.2 `src/data/ship_hull_data.gd` + 6 `.tres` (Scout/Colony/Transport/Corvette/Cruiser/Dreadnought)
- [x] 2.3 `src/data/tech_node_data.gd` + 16 tech `.tres` (4 fields × 4 tiers, dependency-sorted)
- [x] 2.4 `src/data/building_data.gd` + 9 `.tres` (mine/farm/factory/shield/battery/garrison/shipyard/station/terraformer)
- [x] 2.5 `src/data/defs.gd` — resource registry loader with typed access + validation
- [x] 2.6 `src/game/planet_state.gd`, `src/game/system_state.gd`, `src/game/fleet_state.gd`
- [x] 2.7 `src/game/faction_state.gd`, `src/game/galaxy_state.gd` (JSON-serializable authoritative graph)
- [x] 2.8 Verification: `tests/test_defs.gd` — 156 checks, every `.tres` loads + validates clean
- [x] 2.9 Verification: `tests/test_state.gd` — 84 checks, JSON round-trip is a verified fixed point

Phase 2 verified. The loop caught eight real defects: `Defs` resolved script paths under
`res://data/` instead of `res://src/data/` (so *nothing* loaded); `FactionState.tech_effect`
referenced its own initializer in its body; the transport's `.tres` was cheaper than the
colony ship's, breaking the hull cost ladder; `PlanetState.ship_queue` and
`FactionState.research_allocation` were typed arrays that JSON returns untyped, so a
round-trip aborted mid-load; `FleetState.cargo_load()` let a negative manifest *inflate*
free capacity; and all three `fingerprint()` methods emitted `StringName` keys in memory
but plain strings after JSON, so identical states hashed differently. Fixes: definitions
are re-resolved from ids via `rebind_definitions()` rather than serialised, fingerprints
normalise keys to sorted plain strings, and `validate()` now *returns* its issues so tests
can assert on them (Godot does not deliver `push_error` to GDScript in 4.7).

`tools/verify.sh` runs the whole loop: import pass (refreshes the global `class_name`
cache), then every `tests/test_*.gd`, with an allowlist of *expected* guard errors so a
deliberately-exercised `push_error` path does not mask a genuinely new failure.

## Phase 3 — Galaxy Generation

- [x] 3.1 `src/gen/galaxy_generator.gd` — best-candidate star placement in a skewed disk, 30–100 systems
- [x] 3.2 Warp lane graph: nearest-neighbour pass guarantees connectivity, extra short lanes for routing depth
- [x] 3.3 Planet rolls per system (1–6 bodies), class by weighted habitability distribution, orbit falloff
- [x] 3.4 Homeworld selection with minimum separation, faction seeding (1 human + N AI)
- [x] 3.5 Starting colonies (3 farms / 2 mines / 1 garrison), one tier-1 tech per field, scout+colony fleet
- [x] 3.6 Verification: `tests/test_galaxy_gen.gd` — 531 checks: invariants, determinism, JSON round-trip

Phase 3 verified. Three real bugs: `pick_weighted` was called on a bare `RandomNumberGenerator`
(it lives on the `RNGService` wrapper), which silently rolled a null class index and left
homeworlds with nothing colonisable — the generator now owns its weighted draw on the
authoritative stream; the 30-entry proper-noun pool could not name a 100-system map, so
names now shuffle deterministically and fall back to unique catalogue designations; and
`Array.shuffle()` would have drawn from Godot's *global* RNG, quietly breaking the
determinism guarantee, so every shuffle is an explicit Fisher-Yates over the seeded stream.

## Phase 4 — Turn Resolver

- [x] 4.1 `src/game/order.gd` — order types & queued order container
- [x] 4.2 `src/turn/movement.gd` — fleet travel by drive tech, arrivals, intercept detection
- [x] 4.3 `src/turn/combat.gd` — space combat: volleys → beams → PD → dogfight → retreat
- [x] 4.4 `src/turn/invasion.gd` — bombardment → surface batteries → ground assault
- [x] 4.5 `src/turn/colony_sim.gd` — pop growth, food/starvation, factories, mines, tax, morale
- [x] 4.6 `src/turn/research.gd` — TP aggregation into 4 sliders, tech unlocks
- [x] 4.7 `src/turn/fow.gd` — sensor ranges, visible systems/fleets, planet survey
- [x] 4.8 `src/turn/turn_resolver.gd` — orchestrate the 5 stages in order, emit news log
- [x] 4.9 Verification: `tests/test_turn_engine.gd` — 427 checks: 20-turn soak, economy conservation, determinism
- [x] 4.10 Verification: `tests/test_determinism_replay.gd` — 419 checks: save/load round-trips, long-soak replay

### Defects the self-verification loop caught in Phase 4

Every item below was found by a headless test, not by reading the code:

- **`Enums` had no `class_name`.** Every subsystem referred to `OrderType` /
  `CombatOutcome` as bare identifiers, which only compiled because nothing had ever
  loaded `turn_resolver.gd`. Added `class_name Enums` and qualified all uses.
- **`research.gd` never parsed.** `Array[StringName]()` is not a valid constructor.
  The import pass missed it because nothing referenced the class. Fixed to
  `var completed: Array[StringName] = []`, and every turn-stage file is now
  individually `load()`ed by a probe test so an unreferenced file cannot hide again.
- **`galaxy.factions` is an `Array`, not a `Dictionary`** — `.keys()`/`.values()` in the
  resolver were wrong. `fleets` *is* a dictionary; the two are easy to conflate.
- **`Order.from_dict` accepted any integer type**, so a malformed or hostile packet
  became an order silently resolving to `OrderType.NONE`. Now range-checked.
- **`turn_resolver.gd` granted buildings immediately** instead of queueing them, and
  called `.append()` on `building_queue`, which is a `Dictionary` keyed by id → count.
- **`json_state.rng_state` lost precision.** JSON has no 64-bit integer, so a raw RNG
  state round-tripped through a double and diverged. Now written as a decimal string.
- **`FactionState.tech_points` was a `PackedFloat32Array`.** Research accumulates every
  turn, and 32-bit floats lose precision fast enough to break save/load determinism.
  Now `PackedFloat64Array` throughout.
- **`str(key)` is not stable across `StringName` → `String`.** Every `fingerprint()`
  rendered keys with `str()`, so a planet hashed differently before and after a save.
  Added `src/core/key_text.gd` and routed all four fingerprint/serialisation sites
  through it.
- **`GalaxyGenerator.generate` never called `bind_tech`.** Every faction started with an
  empty tech cache and read *all* tech bonuses as zero until the game was saved and
  reloaded — a fresh galaxy genuinely played differently from a loaded one. This was
  the root cause of the determinism failure.
- **`colony_sim.gd` gated the food-stock update on `food_produced > 0`.** A colony with
  no farms therefore ate from its reserve forever and could never starve. The reserve
  now moves by the net every turn regardless of sign.
- **`colony_sim.gd` returned early for zero-habitability worlds**, skipping mining, tax
  and construction entirely. Split out `_economy_and_upkeep` and `_terraform`.
- **`InvasionStage.resolve_all` required ≥2 fleets in a system**, so an undefended
  colony — the most common invasion target — could never be taken.
- **`FowStage.redact` never emitted a `visible` key**, leaving a client unable to tell a
  hidden system from an empty one.
- **Every building had `max_per_colony = 0`** (unlimited), which made overbuilding a
  free strategy and the treasury floor unreachable in practice. Caps added and enforced.
---

# Phase 5: Client GUI and Presentation Layer

The presentation layer is built around a single seam, `SessionController`, which owns the
`GalaxyState`, the `OrderQueue` and the seeded RNG. Panels never touch the galaxy directly:
they call controller methods, which either mutate the state or return a rejection *and*
emit `action_rejected` with a reason. That discipline is what makes the GUI testable
headlessly — every assertion in the suite drives a real widget and reads real state.

## Delivered

- [x] 5.1 `src/ui/cc2_theme.gd` — retro-Amiga palette, `StyleBoxFlat` factories, and a
      complete `Theme` (Label, Panel, Button in all states, HSlider, OptionButton,
      ItemList, RichTextLabel, ScrollContainer). The slider grabber is drawn in code as a
      10x10 `ImageTexture`, so there is **no binary asset dependency**.
- [x] 5.2 `src/ui/format.gd` — readout formatting (thousands separators, signed
      values, percentages, BBCode-coloured surplus/deficit, label/value field alignment).
- [x] 5.3 `src/client/session_controller.gd` — the UI/sim seam: selection, move/build/
      tax/research orders, and `end_turn()`, which submits staged orders to the same
      `TurnResolver` the dedicated server runs.
- [x] 5.4 `src/client/galaxy_map.gd` — `SubViewport` + `Camera2D`; cursor-anchored wheel
      zoom with clamping, middle/right-drag pan, WASD/arrow/edge keys, hover highlight.
- [x] 5.5 `src/client/galaxy_map_view.gd` — `_draw()`: stars coloured by spectral class,
      owner rings in faction colour, warp lanes, fleet diamonds, dashed warp vectors with
      direction arrowheads, travel progress, and the staged-order line. Fog renders
      unsurveyed systems as anonymous hollow markers.
- [x] 5.6 `src/client/inspector_panel.gd` — system survey + planet class, habitability,
      population, food balance/stock, farms/mines/factories/shields/batteries/garrisons,
      shipyard progress, stores, and the in-build queue.
- [x] 5.7 `src/client/macro_panel.gd` — tax slider, four normalised research-allocation
      sliders, colony + build selectors, and a live readout of the staged orders.
- [x] 5.8 `src/client/fleet_panel.gd` — fleet registry, selection, full combat readout,
      and the STAGE MOVE order-mode toggle.
- [x] 5.9 `src/client/top_bar.gd` — Stardate, Imperial Treasury, Net/Turn, Research, and
      the End Turn button.
- [x] 5.10 `src/client/game_client.gd` + `scenes/client/GameClient.tscn` — three-column
      frame (inspector + fleet / map / macro + log) under the HUD. The scene file holds
      only the root so the tree cannot desynchronise from the types the panels expect.
- [x] 5.11 `src/app.gd` — attaches the client to SINGLE_PLAYER and CLIENT. DEDICATED_SERVER
      stays headless, so `--server` still runs in CI alongside the GUI build.
- [x] 5.12 `tests/test_gui_integration.gd` — 135 checks. Instantiation, scene-tree
      integrity, panel node accessors, theme is non-default, every signal edge is
      connected, map hit-testing and zoom clamping, fleet order accept/reject, macro
      controls emitting real Phase 4 orders, **End Turn advancing the stardate by exactly
      1**, five consecutive turns advancing by 5, and save/load determinism *through* the
      GUI. Nodes are freed explicitly before `quit()` so the exit is leak-free.

## Verification

| Check | Result |
| --- | --- |
| `tools/verify.sh` (9 suites) | ALL GREEN — 1844 checks, 0 failed |
| `godot --headless --editor --quit` | rc=0, no parser errors |
| `--server` / `--single` / `--client` | all boot rc=0; the latter two attach the client |
| Rendered frame at 1024x576, 1280x720, 1600x900 | layout intact at every resolution |

## Defects the self-verification loop caught in Phase 5

- **`OptionButton` has no `find_metadata`.** The build selector called it on every
  refresh, so the macro panel threw on the first turn. Replaced with an explicit scan
  over `get_item_metadata`.
- **`ItemList` has no `selected` property.** Both the fleet list and the inspector's body
  list read it; the correct accessor is `get_selected_items`.
- **`ItemList.select()` on an empty list** raised an out-of-bounds error whenever the
  inspector redrew for an unsurveyed system. Now guarded.
- **A freshly generated galaxy was completely dark.** Visibility was only ever computed
  at the *end* of a turn, so a new player could not see even their own homeworld and the
  client opened on an empty map. `GalaxyGenerator.generate` now seeds each faction's
  sensor picture.
- **Fog of war was instantaneous, not cumulative.** `update_visibility` rebuilt the set
  from scratch each turn, so a scout moving on retroactively blinded the systems it had
  surveyed. Visibility now accumulates — knowledge is only ever gained.
- **`Defs` never called `load_all()` on its own**, despite documenting that it loads at
  startup. Nothing else did it either, so a real boot generated a galaxy from an empty
  registry. Added `_ready()`.
- **`SessionController.attach` called `rebind_definitions()` with no argument**, falling
  back to an autoload lookup that fails outside a full boot — every planet then reported
  an unknown type.
- **`GameClient.start()` dereferenced panels before `_ready()` had built them.** Callers
  naturally call `start()` right after `add_child()`; the binding is now deferred.
- **`_wire()` ran twice and double-connected every signal.** `Signal` is a value type, so
  a per-edge `is_connected` guard on a copied signal always reports false. An explicit
  `_wired` flag is the reliable guard.
- **`_sync_viewport` assigned `size` to a full-rect-anchored control**, emitting a layout
  warning on every pass. The anchors already track the viewport, so the assignment was
  removed rather than deferred.
- **`get_tree()` on a node not yet in the tree** returns null and logs an engine error.
  `app.gd` uses `Engine.get_main_loop()` instead, which is safe during `SceneTree._initialize`.
- **`GalaxyState` had no `visible_systems` entry for a new game** and `App._attach_client`
  hard-referenced the `Defs` autoload, breaking the routing test in its bare `-s` context.
  Both resolved to by-name lookups.

---

## Final Gate

- [x] F.1 Full headless suite green
- [x] F.2 `godot --headless --editor --quit` import + no parser errors
- [x] F.3 Determinism replay: same seed + same orders ⇒ byte-identical state hash

## Out of Scope (Phase 6+)

Phase 6 ENet multiplayer transport, Phase 7 AI faction brain. The GUI is already
written against `SessionController`, so Phase 6 replaces that class's internals with
a network authority and leaves the panels untouched.
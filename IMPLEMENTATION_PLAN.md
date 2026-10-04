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
- [x] 5.12 `tests/test_gui_integration.gd` — 154 checks. Instantiation, scene-tree
      integrity, panel node accessors, theme is non-default, every signal edge is
      connected, map hit-testing and zoom clamping, fleet order accept/reject, macro
      controls emitting real Phase 4 orders, **End Turn advancing the stardate by exactly
      1**, five consecutive turns advancing by 5, and save/load determinism *through* the
      GUI. Nodes are freed explicitly before `quit()` so the exit is leak-free.

## Verification

| Check | Result |
| --- | --- |
| `tools/verify.sh` (9 suites) | ALL GREEN — 1863 checks, 0 failed |
| `godot --headless --editor --quit` | rc=0, no parser errors |
| `--server` / `--single` / `--client` | all boot rc=0; the latter two attach the client |
| Rendered frame at 1024x576, 1280x720, 1600x900 | layout intact at every resolution |

## Phase 5 follow-up: runtime UI defects found by playing the client

Reported from a running window, not from the test suite — all three passed every headless
assertion while being visibly wrong. Each now has a regression check.

- **BBCode leaked into the HUD.** `NET / TURN` is sign-coloured, so `Format.signed_colored`
  returns `[color=…]+0.0[/color]`, but `_cell()` built a plain `Label`, which prints the
  tags literally. Added `_cell_bbcode()` and a `RichTextLabel` with `bbcode_enabled`.
- **The galaxy map rendered as a black rectangle.** Two independent causes:
  1. `frame_galaxy()` ran inside `bind()`, before the container had laid the map out, so
     `get_rect().size` was zero and the fit collapsed to `0.0` — which `clampf` pinned to
     `MIN_ZOOM` (0.35). The whole ±120 galaxy then rendered about 42px across. Framing now
     defers until `resized` reports a real area, and fits the *widest* system from the
     chosen centre rather than the galaxy disk, since centring on home pushes far-side
     systems past the disk radius.
  2. Fog of war reveals 1 of 40 systems on turn one (sensor ranges are 2–3 parsecs against a
     240-parsec-wide galaxy), and unsurveyed systems drew as a 5px alpha-0.30 ring — about
     1.75px on screen. Widened and brightened to named constants; known stars still read
     far brighter, and unsurveyed ones still carry no class colour or ownership.
  The SubViewport is now hosted by a `SubViewportContainer` with `stretch = true` — a bare
  SubViewport under a Control renders to a target nothing presents.
- **"REFUSED: select one of your colonies first" spammed the log.** The build dropdown was
  a *request* that queued against whatever the controller had selected, which was usually a
  system or an uncolonised body the player had clicked. `_on_build_selected` now adopts the
  colony named by the selector above it. Separately, `_refresh_colonies()` was writing
  `select_planet` on every `state_changed` — that runs in response to `select_planet`, so it
  recursed and stomped the player's real choice. Selection is now established only where the
  player actually chose something.

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

## Phase 5 follow-up 2: the sliders moved the galaxy map

Reported as "moving these moves the space map upwards like I dragged it, but I didn't".

- **The staged-orders readout sized itself to its text.** `MacroPanel._queue_label` had
  `fit_content = true`, so its height tracked the number of staged orders. Every slider step
  stages a `SET_TAX`/`SET_RESEARCH` order, so dragging one made the label taller, which grew
  the right column's minimum, which grew the row, which resized the `SIZE_EXPAND_FILL` map
  beside it — and the map's `resized` handler re-framed the camera. Measured at a 700px
  window: twelve slider steps took the map from 641 to 747px tall and the camera from zoom
  1.257 to 1.464. The readout is now a fixed-height scrolling box, like the event log.
- **The map never framed itself on a normal boot.** `frame_galaxy()` was deferred to
  `resized`, but `resized` does not fire when a Control's *rect* changes — only its `size` —
  so after `bind()` the fit was never re-triggered and the map sat unframed at zoom 1.0
  centred on the origin. `bind()` now defers the fit with `call_deferred` instead. This was
  masked during development because the screenshot harness set `custom_minimum_size` on the
  client, which forced a real resize.

Regression coverage: `macro: sliders leave the map alone` stages 24 orders by dragging the
tax slider and asserts the readout's peak height never exceeds its cap, and that neither the
map's size nor the camera's position or zoom moved. Reverting the fix makes the readout
reach 560px and the check fails.

## Final Gate

- [x] F.1 Full headless suite green
- [x] F.2 `godot --headless --editor --quit` import + no parser errors
- [x] F.3 Determinism replay: same seed + same orders ⇒ byte-identical state hash

## Out of Scope (Phase 7+)

Phase 7 AI faction brain. The GUI is already written against `SessionController`, so
Phase 6 replaced that class's internals with a network authority and left the panels
untouched.

---

# Phase 6: ENet Multiplayer Transport & Dedicated Server

## Delivered

- **`src/net/network_manager.gd`** — the peer owner. `host_game(port, max_players)` and
  `join_game(address, port)` build an `ENetMultiplayerPeer` and install it on a private
  `MultiplayerAPI` branch. Handles `peer_connected`, `peer_disconnected`,
  `connected_to_server`, `connection_failed` and `server_disconnected`. Tracks each peer
  against an empire slot; `free_slot()` never hands out slot 0's rival for a joiner by
  accident (scan starts at 1 because the server itself is peer 1).
- **`src/net/turn_sync_server.gd`** / **`src/net/turn_sync_client.gd`** — the authoritative
  and client roles, plus **`src/net/turn_sync_peer.gd`**, which holds the actual RPC surface.
- **`src/core/cli.gd`** — `--server`, `--port=<int>` (default 7777), `--slots=<int>`
  (default 2, clamped to 1..8). The dedicated server constructs no Viewport or Control.
- **`tests/test_enet_sync.gd`** — 110 checks, including a live 1-server/2-client run on
  loopback.

## Three engine constraints that decided the design

Each was found by probing the engine, not by reading docs, and each broke the obvious
implementation silently.

1. **Two RPC classes at one node path do not work.** Godot checksums a node's `@rpc` method
   set and requires every peer addressing that path to match. `TurnSyncServer` and
   `TurnSyncClient` have different methods, so the literal two-file split produced
   `The rpc node checksum failed` and dropped *every* RPC with no other symptom. Resolved
   with one shared script carrying the superset of methods, and runtime role guards
   (`_is_authority()`) keeping the two roles apart.
2. **RPC paths are sent branch-relative but resolved tree-relative.** Unnamed nodes get
   per-instance placeholders (`@Node@8`), so an endpoint created with `Node.new()` +
   `set_script()` resolves to a different path on each peer. `NetworkManager` names it
   (`SYNC_NODE_NAME`) and builds it through one factory so both sides agree.
3. **The branch root must be the `NetworkManager` itself.** Holding the branch on a child
   node scopes only that node's descendants; the manager and its direct `TurnSync` child
   fell through to the tree default and both saw unique id 1, so every send hit
   `RPC 'x' on yourself is not allowed by selected mode`. Re-parenting the manager into a
   holder fixes identity but renames the subtree and re-breaks (2).

## Properties proven rather than asserted

- **Networked == offline.** `tests/test_enet_sync.gd` resolves the same two orders twice —
  once locally through `TurnResolver` with no transport, once over a real ENet socket —
  and requires identical state hashes. This is what makes single-player and multiplayer
  the same game rather than two code paths that merely look alike.
- **Cross-process.** `godot --headless --path . --server --port=7979 --slots=3 --seed=42`
  logs `dedicated server ready: 0.0.0.0:7979, 3 slots, seed 42, 50 systems, stardate 1`,
  and two separate OS processes dial in and are assigned empires 0 and 1.

## Defects the self-verification loop caught in Phase 6

- **Both RPC directions were dead for most of the build** — from (1) and (3) above. The
  integration test passed its early scenarios because they exercised the local paths; only
  the parity scenario sent a real packet and surfaced it.
- **`resolve_if_ready()` cleared `_pending`, so a wait loop on `submitted_count()` never
  terminated.** Checking the resolution flag before the count fixed the hang.
- **`free()` on a subtree the ENet driver still referenced aborted the process** with
  `Object is locked and can't be freed`. `dispose()` now uses `queue_free()`.
- **GDScript getter-only properties return a copy**, so the first attempt at exposing
  pending orders as a property silently discarded writes. Replaced with `stage_orders()`.
- **`broadcast()` logged `Condition "!is_inside_tree()" is true`** when a server was
  resolved before being added to the tree. The resolution is still correct; only the wire
  hop is skipped. Same class of trap as the guard in `TurnSyncClient.submit_turn()`.

## Regression coverage for the ordering rule

Orders are applied in *slot* order, never arrival order, or a replay would not reproduce
its own hash. The first version of this test was **structurally insensitive**: it used two
`SET_TAX` orders on *different* factions, and since each order is applied independently to
its own faction, the result was identical either way — the test passed with the fix
reverted. It now drives two orders that both target empire 0, where `SET_TAX` is
last-write-wins, so application order is observable. Reverting to arrival order yields
`tax_rate 0.1` instead of `0.8` and a different state hash.

## Defects the client-connection work found

Wiring `--client` to actually dial surfaced four problems, all of which had the
server sitting there looking healthy:

- **`--server` never resolved a turn.** Nothing called `resolve_if_ready()`; the
  role existed but no driver polled it. Added `App._process`.
- **Turn 1 could never resolve with `--slots=2`.** `begin()` was seeded with every
  advertised slot, so the server waited on a second player who may never connect.
  The wait set now starts empty and is rebuilt from who actually joined.
- **`--slots` could exceed `--factions`,** seating a player in an empire with no
  faction behind it. Clamped to the faction count, with a warning.
- **The joining client could not adopt the server's galaxy into the running GUI**
  without re-binding, because the panels hold the `GalaxyState` object. `from_dict`
  mutates in place, so refreshing via `state_changed` is enough.

## Verification

- `tools/verify.sh`: **10 suites, 2023 checks, 0 failed, ALL GREEN**, exit 0.
- `test_enet_sync` alone: 130 checks, including a real join/welcome/submit/resolve
  conversation over a socket.
- `test_gui_integration` alone: 173 checks, including the networked End Turn path.
- Both new GUI checks were confirmed to fail when their fix is reverted.

## Manual session

`godot --headless --path . --server --port=7777 --slots=2 --seed=42` plus two
`godot --path . --client --ip=127.0.0.1 --port=7777` windows: each client prints
`joined as empire N`, and pressing End Turn in both advances them together. See
`help.md`.
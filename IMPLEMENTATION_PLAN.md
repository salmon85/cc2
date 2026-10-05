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

## Out of Scope

The AI faction *brain*. The GUI is already written against `SessionController`, so
Phase 6 replaced that class's internals with a network authority and left the panels
untouched.

> Phase 7 delivered the session lifecycle instead. An AI seat now exists — a dropped
> client's empire stops holding the turn open and is handed to the AI after its grace
> period — but nothing plays it yet. The brain remains out of scope; see the Phase 7
> section at the end of this file.

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

# Phase 7: Session Lifecycle & Multiplayer Lobby

## Delivered

- **`src/net/session_lobby.gd`** (`SessionLobby`) — slot assignment, ready flags,
  grace periods, and the match-start decision, as pure bookkeeping. Deliberately *not*
  folded into `TurnSyncServer`: a lobby whose rules can only be exercised through a
  live socket cannot be tested at all, and these are exactly the rules most likely to
  be wrong.
- **Slot assignment.** Each peer takes the lowest free slot; a full lobby refuses rather
  than overlapping. A slot is a faction id, so two players sharing one would file orders
  into each other's treasury.
- **Ready flags**, per peer and retractable, with a latching start so a caller polling
  every frame cannot announce two matches.
- **Grace periods.** A departing peer's slot is *held*, not deleted: it stops holding the
  turn open at once, but stays claimed so a reconnecting player gets their own empire
  back rather than a stranger's. On expiry the empire passes to the AI.
- **`--ready` / `--auto-ready`** — a headless client has no lobby UI to click, so this
  is how it is ever counted.
- **A **READY** button in the top bar** — the GUI equivalent, and the control that makes
  `--client` usable at all now that a match waits for its players.
- **`tests/test_session_lifecycle.gd`** — 139 checks: the rules as pure functions, the
  CLI surface, a real join/ready/start conversation over loopback, a client dropped
  mid-turn, and the real `--server` + `--client` command lines driven through `App`.

## The two waits, which are easy to conflate

Starting waits for every *configured* slot. Each *turn* waits only for *connected*
players. `turn_slots()` returning `occupied_slots()` rather than `claimed_slots()` is
the whole anti-stall property: the resolver can only wait for someone who can answer,
so a departed — or AI-held — empire must never hold the turn open. This is asserted
directly, and confirmed to fail when the rule is reverted.

## Properties proven rather than asserted

- A match does **not** start on connect alone, nor with one of two players ready.
- Both clients hold a galaxy whose hash is byte-identical to the server's, and were given
  *different* empires.
- A client dropped mid-turn does not stall the resolver: its order is on the wire, it
  never submits, and the turn still resolves.
- The abandoned empire is held for exactly its grace period, is not AI-managed during it,
  and passes to the AI on expiry — while still not holding the turn open.
- `--slots=2` with one ready client does not start; a second `--client --ready` does.

## Defects the self-verification loop caught in Phase 7

1. **A disconnect instantly stole the player's empire.** `remove_active_slot()` called
   `mark_ai_managed()` on its way through, which cancelled the grace period the lobby had
   *just* started — so every disconnect was an immediate hand-over, and a player about to
   reconnect lost their empire to the AI. The AI decision belongs to the lobby, on grace
   expiry, and only there.
2. **The GUI had no way to ready up.** The ready gate went in with no control behind it,
   which silently broke the documented manual workflow: two GUI clients would sit in the
   lobby forever. Found by *running* the Quick Start from `help.md` and watching it hang,
   not by any test. The READY button and `--ready` are the two faces of the same feature
   for the two kinds of client.
3. **The 30s grace period is not shorter than the disconnect it is compensating for.**
   Verified by killing a client and timing it: ENet takes roughly 30 seconds to conclude a
   peer is gone, which is why the grace period is what it is. Documented rather than
   "fixed" — the lag is the transport's.

## Verification

- `tools/verify.sh`: **11 suites, 2173 checks, 0 failed, ALL GREEN**, exit 0.
- `test_session_lifecycle` alone: 139 checks.
- `test_gui_integration` alone: 184 checks, including 11 on the READY button.
- Every new test was confirmed to fail with its fix reverted: the anti-stall rule (2),
  the grace/AI ordering (3), the match-start gate (6), `--ready` being ignored (2), the
  ready button's visibility (2) and its toggle (1).

## Manual session

`--server --port=7777 --slots=2 --seed=42` plus two `--client` windows: both press
**READY** in the top bar, the server prints `match started`, and End Turn advances them
together. Headless clients substitute `--ready` for the button. See `help.md`.

## Still out of scope

The AI empire is a *seat*, not a mind: its slot stops holding the turn open and it is
marked AI-managed, but nothing yet plays it. An AI faction brain remains future work, as
does lobby re-admission (a player returning after their grace expires has expired).


# Bug Fixes & Interface Improvements

## Bug 1: stardates never advanced and ships never moved

**Root cause.** `TurnSyncPeer.apply_snapshot()` built a fresh `GalaxyState` from the
payload and assigned `galaxy = incoming`. The `SessionController` — and through it every
panel, the map, and the fleet views — still held the *original* object. After a turn
resolved, the sync peer's copy was correct and the interface's copy was one turn stale,
forever.

Proven before fixing, with a four-line script:

```
attached:  controller galaxy id = -9223371997143104011   turn=0
resolved:  sync galaxy id      = -9223371997075995143   turn=1
           controller id       = -9223371997143104011   turn=0
           SAME OBJECT?        = false
```

**Fix.** `from_dict()` already mutates in place, so the snapshot is now deserialised into
the *live* galaxy. After the fix the same script reports `SAME OBJECT? true` and the
controller reads `turn=1`.

**A second defect in the same function.** The old code adopted the payload *before*
checking its hash, so a mismatched snapshot replaced the client's state and only then
reported the desync — the one thing the hash exists to prevent. The payload is now built
into a scratch object, verified, and only then applied.

## Bug 2: one player quitting ended everyone's game

**Root cause.** ENet reports *every* peer on the connection, so a client sees other
players come and go. `NetworkManager._on_peer_disconnected()` had no `is_host` guard —
unlike `_on_peer_connected()` right above it — and emitted `peer_left` regardless. On a
client, `App._on_client_server_gone()` handles that signal by calling `get_tree().quit(1)`.
So any player closing their window ended the session for every other player.

**Fix.** Split the two events. A host still emits `peer_left` (it owns the seats). A
client emits the new `peer_departed`, which `App` handles by logging
`another player left (peer N); their empire is held by the server` to the event log and
doing nothing else. `peer_left` on a client now means only what it should: this session's
authority is gone, and it genuinely cannot continue.

Verified with two real clients: killing one leaves the other running, playing, and
holding its state.

## Improvement 1: fog of war on ownership

`_draw_systems()` now draws an owner ring only where the player is entitled to know the
owner — their own system, or one with a fleet actually parked in it. A fleet merely
sailing there does not count: it reveals the origin now and the destination on arrival,
which is what a real player would know. Unowned systems always render neutral, so empty
space reads as empty rather than as redacted.

## Improvement 2: the READY button shows the lobby tally

`SessionLobby.ready_count()` counts only *occupied* seats, so a departed player and an
AI-managed empire both contribute nothing. The server broadcasts it over a new
`rpc_lobby_ready_count`, on arrival and on every change. The button reads `Ready 1/2` —
green while unready, red once pressed.

The count is authoritative rather than each client counting its own flags, because two
windows disagreeing about who is ready makes the lobby look broken. The button also never
shows a count below the local pressed state, which would otherwise read `Ready 0/2` for
the frame between pressing and hearing back.

Colour is not the only signal: roughly one man in twelve cannot reliably separate these
two hues, so the wording carries the state on its own.

## Defects the loop caught in this round

Three of my own test fixtures were wrong before any product code was: a lambda capturing
a local by value, an index into a list after removal, and a readiness assertion that
re-flagged a departed peer. Worth recording because each produced a *plausible* failure
rather than an obvious one — the fixture was the thing under suspicion, not the code.

One product question surfaced from a failing test and was resolved by reading the code
rather than by changing it: `set_ready()` still accepts a departed peer, because their
entry is retained for reclaim. That is harmless — an unoccupied seat is not in
`occupied_slots()`, so a stale flag can never reach the tally or the start gate — and it
is now asserted rather than left to chance.

## Verification

- `tools/verify.sh`: **11 suites, 2212 checks, 0 failed, ALL GREEN**, exit 0.
- `test_gui_integration`: 207 checks (was 184), including the resolution-reaches-panels
  and peer-departure regressions.
- `test_session_lifecycle`: 155 checks (was 139), including the ready tally.
- Each new test confirmed to fail with its fix reverted: object replacement (3), the
  missing `is_host` guard (2), the ungated owner ring (1), the ready tally counting
  unoccupied and AI seats (2).
- The ownership test asserts that `_draw_systems()` *consults* the rule, not just that
  the rule behaves — the first version of that test passed happily while the drawing
  path ignored the rule entirely.

---

# Round 7: multiplayer lobby, galaxy generation, and Fog of War defects

Three reported defects, each diagnosed by driving the real engine rather than by reading
the source, and each with a root cause that the source alone did not make obvious.

## Defect 1: the READY button never received the tally

`TurnSyncServer._broadcast_ready_count()` called

```gdscript
rpc_lobby_ready_count(lobby.ready_count(), lobby.total_slots)
```

as a **bare local call**. In Godot a bare call invokes the method in-process only; `.rpc()`
is what puts it on the wire. So the server dutifully applied the new count to *itself* and
sent nothing. Every other RPC in that file already carried `.rpc()` or `.rpc_id()`, which
is exactly why the omission survived review: the line reads correctly and does the wrong
thing. The late-joiner path in `send_welcome()` was already correct and is retained.

The regression test drives two real clients over real ENet with a real `SessionLobby` and
asserts that the peer which *did not toggle* is told the new count — that client is the
one whose button was silently going stale.

## Defect 2: `--slots=4` seated two players

Two problems, not one:

1. `--factions` defaults to 2 and nothing tied it to `--slots`, so `--slots=4` asked the
   generator for a two-empire galaxy and then silently shrank itself back to two seats.
2. `GalaxyGenerator` clamped the empire count to `count / 5`. On the 30-system minimum
   map that ceiling is 6, so even `--factions=8` yielded six — the same bug one layer
   down, invisible from the CLI.

`CC2CLI.reconcile_slot_empires()` now raises `faction_count` to `slots` (and sizes the
system count to match) whenever `--factions` was *not* given explicitly; an operator who
writes `--slots=8 --factions=2` is running a two-human game and is honoured. The
generator's clamp is now against `MAX_SYSTEMS` rather than a spacing heuristic, because a
crowded homeworld is merely cramped while a missing empire is a missing player.

Probed before the fix: `ask-8-in-30-systems -> 6`, versus `ask-8 systems=50 -> 8`.

## Defect 3: colony and fleet markers leaked through the fog

The map's owner ring was already correctly gated (`ring-leaks=0` on a fresh galaxy), so the
reported "squares and markers" were somewhere else. Four real leaks:

- **`InspectorPanel._body_caption()`** drew an `x` beside every foreign `colonized` body.
- **`InspectorPanel._refresh_system()`** printed `OWNER` in the owning faction's colour
  for any visible system — a free, always-accurate roster of every empire's holdings.
- **`InspectorPanel._refresh_planet()`** then spelled out a rival colony's entire economy:
  population, farm/mine/shield counts, reserves, build queue.
- **`GalaxyMapView._draw_fleets()`** had no visibility check whatsoever. Every star was
  hidden and every owner ring suppressed, while a diamond was still drawn on the map for
  every fleet of every empire, anywhere on the board. The fog was on the background and
  off the foreground.

The map was the only place the ownership rule lived, which is precisely how the map could
be clean while the inspector reported the same system two panels to the right. The rule is
now `SessionController.knows_owner_of()` — *own empire, or own fleet parked in orbit* —
and every renderer consults that one function.

`FowStage.redact()` remains unused on the network path: `build_payload()` ships the raw
galaxy, so client-side gating is the only protection. Left as-is deliberately — it is the
cheaper of the two, and moving redaction to the server would be a bandwidth change nobody
asked for.

### A fourth bug the new test found

`_refresh_bodies()` cached on the system index alone, so a body that changed owner or
colony status kept its old caption until the player left and returned. A world settled by
somebody else was still drawn with the player's own `*` beside it. The cache key now
includes what the rows would actually say.

## Verification

- `tools/verify.sh`: **11 suites, 0 failed, ALL GREEN**, exit 0.
- `test_galaxy_gen`: 609 checks (was ~530) — every requested faction count in 1..8 across
  30/50/100 systems, and every empire asserted to hold a homeworld, a colony and a fleet.
- `test_cli`: 78 checks (was 62) — every slot count in 1..8 is backed by enough empires.
- `test_enet_sync`: 150 checks — the new two-client lobby scenario.
- `test_gui_integration`: 233 checks (was 207).
- The Defect 3 fixture is **constructed**, not searched for: a single-player galaxy has
  one empire, so a rival colony would never appear naturally and the behavioural half of
  the test would silently never run.

# Round 8: one system, planet-scale map, and a lobby that counts players

Seven reported problems, but four of them turned out to be one problem wearing different
clothes: the map had *systems* where it needed *planets*. Everything below is arranged by
that insight rather than by the order it was reported in.

## Defect 1: the ready gate counted seats, not players

`--slots=4` with two people connected deadlocked the turn. The gate compared a ready
*count* against a *capacity*, so an under-filled table could never advance — the game was
structurally unplayable at any slot count above the number of humans who actually turned up.

The distinction that was missing is that `--slots` is **capacity** and the gate needs
**attendance**. `LobbyState.player_count()` is now the denominator: it tracks joins and
leaves, so a player dropping mid-game immediately raises the ratio for everyone else
rather than stranding them. `help.md` now says so in the `--slots` row itself.

## A second lobby bug the new test found

`send_welcome()` broadcast the ready tally to the *newcomer only* (`rpc_id`). The client
who was already seated never learned the denominator had grown, so it sat on a stale
fraction until its next turn sync. `send_welcome` now calls `_broadcast_ready_count()` —
an actual broadcast — because growing the table is exactly the event every seated client
needs to hear about. This is the second time "the message was correct, it just went to the
wrong people" has been a real bug in this transport.

## Defect 2: the misaligned black box

The screenshot's box was the panel's background rect, drawn at a different size than the
text it framed. Removed rather than realigned: it was decoration, and removing it also
satisfies the font-size reduction without a second layout constant to keep in sync. Ready
state is now carried by colour alone (green unready / red ready).

## Defect 3: END TURN and ORDERS, both removed

Two buttons removed rather than hidden. END TURN became `map.end_turn_requested`, fired
automatically once every connected player is ready — the button was the only thing
between the player and the transition they wanted anyway. ORDERS and its counter are gone
with it: orders are applied at turn commit regardless, so the counter was reporting the
result of a decision the player could not influence.

## Defect 4: the map becomes one system

This is the structural change everything else follows from. `GalaxyGenerator` now places
**one** star at the origin with `strategic_value = 1.0` and populates it with planets on
sqrt-spaced orbit rings (`GALAXY_RADIUS * lerpf(0.06, 0.94, sqrt(t))` — square root
spreads rings by *area*, so they don't bunch toward the star). `--systems=N` is retained
as the CLI surface everyone already uses but now means **planets in the one system**.

Every subsystem that asked "which system" had to ask "which planet" instead — movement,
invasion, FoW, the inspector, and the renderer. Two of those conversions found real bugs,
which is the argument for doing the conversion by hand rather than by search-and-replace:

- **`_homeworld_of` walked `faction.systems`.** With one system, every empire's index
  resolved to the same entry, so *every* empire's homeworld came back as planet 0. It now
  scans `galaxy.planets` for a colonized planet it owns — the systems index is not a
  meaningful proxy for "where this empire is" when there is exactly one system.
- **`knows_owner_of` and `_planet_detail_known` over-revealed.** Both gated on "own fleet
  in this *system*", which with one system means any ship anywhere reveals every rival's
  holdings and full economy. Both now narrow to a fleet **parked on that specific world**.
  This is a Fog-of-War regression the restructure introduced; it is called out here
  because "the system-level check is now trivially true" is not a thing anyone would
  notice by reading the diff.

## Defect 5: 50x scale needs four constants, not one

The system is 50x larger, so every distance was re-tuned: `GameDB.BASE_MOVEMENT` 50→2500,
`MAX_MOVEMENT` 600, and the three sensor ranges. Two more live where the units are read —
`ShipHullData.SPEED_SCALE` and `FleetState.HULL_SCALE`, both 50.0.

This is the one change in the round most likely to have broken something silently, and it
did: with only the `GameDB` constants scaled, fleets computed 76.0/turn against a 5973-unit
crossing and never visibly moved. Movement clamps to the *hull* speed cap, not the base
value, so `FleetState.base_speed()` must scale the hull figure at the one point every
consumer reads. Missing any one of the four constants produces a working-looking game
that does nothing.

## Defect 6: the seed governs layout, the homeworld does not

Determinism tests force a distinction that is easy to blur. The `home_rng` stream is drawn
separately from the layout stream, so **the same seed always produces the same map** while
**the starting planet is redrawn on every game** — which is what was asked for, and what
`test_determinism_replay` now asserts in both directions (same seed → same layout
fingerprint, different runs → different opening fingerprint).

## Defects the self-verification loop caught in Round 8

Three of these are worth recording because none of them were visible by reading the diff.

**A dead call that aborted the test driver forever.** `_lobby.mark_ready(slot, true)` was
never a real method — the lobby has `set_ready(peer_id, ready)`, keyed by *peer*. The call
raised every frame, which aborted `_process` *before* its final `return false`, so the
stage never advanced and the suite spun until it was killed rather than failing. Two
lessons: a suite that hangs is reporting a crash inside its own driver, and the dead
`_teardown(); _finish(); return true` sitting after that `return false` meant the abort
had nowhere visible to go. Both removed.

**Two assertions that pinned the bug this round was meant to fix.** The old pure-rule
tests asserted `not everyone_ready()` for a lobby where the only remaining player *was*
ready — i.e. they asserted the `--slots=4`-with-two-players deadlock was correct. Under the
new gate that is true, so the tests failed. They were rewritten to assert the property that
actually matters: the departed player's flag cannot reach the tally, and an AI-managed seat
contributes nothing and stays off the turn loop. Notably `not everyone_ready()` was never
the interesting property even before — the AI seat was already excluded from `occupied_slots()`,
so it never held the gate open in the first place.

**A one-frame race read as a desync.** The server resolves turn 2 on the same frame the
lobby latches, so the four "client holds the server's galaxy" assertions ran while that
resolution was still on the wire and compared turn 1 against turn 2. Waiting for the
clients to catch up — polled *across frames*, because ENet is pumped by the main loop and a
tight in-frame loop would burn 400 iterations without one packet arriving — makes them
pass. Note what this is not: it is not a fixed desync. The hash matched as soon as the
packet landed, and the clients were correctly behind rather than wrong.

## Verification

- `tools/verify.sh`: **11 suites, 1815 checks, 0 failed, ALL GREEN**, exit 0.
  (`test_app` 17, `test_cli` 78, `test_defs` 156, `test_determinism_replay` 199,
  `test_enet_sync` 152, `test_galaxy_gen` 321, `test_gui_integration` 238,
  `test_session_lifecycle` 158, `test_state` 84, `test_transport` 24,
  `test_turn_engine` 388.)
- `test_galaxy_gen`: 321 checks — adds `_test_homeworld_is_random`, which pins both halves
  of Defect 6 rather than just asserting "something varies".
- `test_turn_engine`: 388 checks — `_unowned_planet(g, skip)` exists because the old
  fixtures colonised `g.systems[0].planet_indices[0]`, which is now faction 0's randomly
  drawn homeworld already sitting at its population cap. A test that "grows a colony" by
  re-colonising someone's homeworld passes for the wrong reason.


# Round 9: map presentation, map-size tiers, and the ready reset

## Deliverable 1 & 3: the field went black, and gained a frame

The concentric orbit rings are gone, and so is the grid that was hiding behind them. They
were doing each other's job: at sixty-four circles over a field fifty times wider than the
old disk, the rings read as a bullseye behind every object rather than as the orbits they
were meant to depict, and the grid existed to stop that reading as void. With both removed
the markers are the only thing on screen, which is the point.

The field is now pure black rather than the theme's green-cast `BG`. The green carried
into the planet colours by simultaneous contrast — a white planet on green reads as mint —
so making the backdrop true black also made the planet palette do what it says.

The bounds indicator is a **rectangle**, not a circle around the star. The playable area is
the square the generator lays planets inside, and a circle would cut off the corners a
maximum-inclination planet actually occupies — telling a player that corner is out of
bounds when it is not.

## Deliverable 2: five map sizes, and the scaling that makes them playable

`--map-size=<tier>` picks `tiny`/`small`/`medium`/`large`/`extreme`, quoted as multiples of
the **original 120-parsec disk** so `tiny` is that disk exactly rather than an
approximation of it. `large` is the default: at 50x a new player's first turns are spent
watching a ship cross the screen.

The span is now a property of the *galaxy* (`GalaxyState.map_radius`, serialised) rather
than a constant. It has to be: two sessions on one machine may run `tiny` and `extreme`
simultaneously, and a client told only planet positions would otherwise infer the radius
from how far apart they are.

**The substantive part is that a bigger map must not mean a slower game.** Fleet speed and
sensor reach are quoted at the `extreme` span and scaled by `radius / GALAXY_RADIUS`, so a
ship crosses a `tiny` map in as many turns as it takes to cross an `extreme` one.
`test_turn_engine` asserts this as a ratio rather than an exact figure — it walks a scout
from the innermost world to the outermost on every tier and requires the turn counts to sit
within a factor of four of each other. Without the scaling the span grows fifty-fold and
the turn count grows with it, which is the failure that would not have shown up in any
assertion about distance.

## Deliverable 4: the zoom bounds are deliberately asymmetric

This is the one place where the obvious implementation is wrong in both directions.

**The floor scales with the map, and sits far below the fit.** `frame_galaxy` computes the
zoom that fits the whole system; a floor set near that value clamps the fit and leaves the
far side off screen — the exact defect this control was rewritten to fix last round. The
first attempt at this (floor at `0.5/6000`) did exactly that and the GUI test caught it:
`test_gui_integration` reported the opening zoom pinned to the minimum. It is now
`0.01/6000` — a runaway guard, not a framing constraint.

**The ceiling does *not* scale with the map.** Markers are drawn at a fixed size in galaxy
units, so what decides whether a planet is clickable is how many *pixels* it covers, and
that is a function of zoom alone. Scaling the ceiling with the radius would give a `tiny`
map a ceiling of 0.06 — at which a planet is a third of a pixel — making the small map the
one map you cannot zoom in on.

## Deliverable 5: ready flags are per-turn

A ready flag belonged to the turn it was raised for and was never cleared. Two consequences,
both bad: the *next* turn's lobby looked satisfied before anyone committed to it, and the
button read "already ready" to a player who had done nothing — the one lobby state that
cannot recover on its own.

Cleared in three places, because the state is genuinely held in three: the server clears
each peer's flag in the lobby; the client clears its local mirror in `receive_resolution`;
and the top bar stops inflating the tally from the stale local flag while the client's
resolution is still in flight. All three were needed — a client that clears its mirror but
receives a stale tally shows a wrong number, and one that receives a fresh tally while
keeping its own flag draws the button red for a turn nobody committed to.

## Deliverable 6: names are a fog leak of their own

The name is a free fact about a world the player has never visited, it is stable across
turns, and it is the identifier a player reuses to refer to a place. A map of named rivals'
worlds is a map somebody has already scouted.

`SessionController.knows_name_of()` requires ownership or a fleet parked on *that*
world — deliberately stricter than the economy gate, which also accepts `surveyed`. A
survey records what a world *is*, not what somebody named it; letting surveys through would
re-expose every name the moment a scout's sweep lit up a neighbouring orbit. Both the map
label and the inspector heading consult the one function, so a world cannot be nameless on
the map and named in the panel beside it.

## A bug the tier tests found immediately

`radius_for_tier("enormous")` returned 120 instead of the default. The lookup was
`SIZE_TIERS.get(key, DEFAULT_TIER)` — but `SIZE_TIERS` maps *name to scale*, so the
default it substituted was the string `"large"`, and `float("large")` is `0.0`. Every
unknown tier silently produced a degenerate map instead of falling back. Caught by the
first assertion in the new tier block.

## Verification

- `tools/verify.sh`: **11 suites, 1905 checks, 0 failed, ALL GREEN**, exit 0.
- `test_galaxy_gen`: 343 (was 321) — the tier table, `tiny` being exactly the 120-parsec
  disk, `map_radius` surviving a save, and a pre-`map_radius` save falling back rather than
  collapsing every orbit onto the star.
- `test_turn_engine`: 410 (was 388) — the cross-tier travel comparison.
- `test_enet_sync`: 166 (was 152) — a networked scenario that readies both players, resolves
  the turn, and asserts both the server's flags and each client's local flag are cleared.
- `test_cli`: 104 (was 78) — every tier, the space-separated form, and the unknown-tier
  fallback warning.
- `test_gui_integration`: 250 (was 238) — name fog in both the map and the inspector, the
  black field, and the bounds frame enclosing every planet.

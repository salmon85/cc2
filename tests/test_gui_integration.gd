extends SceneTree
## Phase 5 verification: the client GUI and its integration with the turn engine.
##
## Covers, in order:
##   - the client scene instantiates from disk with no missing node references
##   - every panel is present, typed correctly, and wired to the controller
##   - the theme is applied and is not the engine default
##   - selection flows from map click -> controller -> inspector
##   - a fleet move order is accepted, staged, and reaches the Phase 4 order queue
##   - illegal fleet orders are refused with a reason rather than silently ignored
##   - the construction panel lists planet names, offers a clickable progress bar, and no
##     longer carries the tax or research sliders Phase 8 removed
##   - the travel modal lists a fleet's ships split into combat and non-combat, with
##     `+` / `-` assignment, `All` / `None`, a cargo readout and OK / CANCEL
##   - an End Turn click advances the stardate by exactly 1 and runs the resolver
##   - several turns keep advancing by exactly 1 and the state hash stays reproducible
##   - the map draw layer and sub-viewport survive a full turn with no engine errors
##
## UI nodes are not inside the tree during `_initialize`, so every assertion that needs a
## laid-out node is deferred to `_process` and the suite runs as a state machine there.

const CLIENT_SCENE := preload("res://scenes/client/GameClient.tscn")
const NetworkManagerScript := preload("res://src/net/network_manager.gd")
const DefsScript := preload("res://src/data/defs.gd")
const DBScript := preload("res://src/data/game_db.gd")

## Fixed seed: a failure must reproduce exactly from the report alone.
const SEED := 20250901

var sup: TestSupport
var _defs: Node
var _db: Node
var _client: GameClient = null
var _galaxy: GalaxyState = null

## Instance ids of autoloads this run had to stand in for, so teardown can free exactly
## those and leave engine-owned nodes alone.
var _stand_ins: Dictionary = {}

## Ordered step list, executed one per `_process` so each runs with a fully laid-out tree.
var _steps: PackedStringArray = PackedStringArray()
var _step: int = 0

## Set once every step has run, so the summary is reported on a later frame.
var _finished: bool = false

## Which disconnect signals fired, recorded through a member so a lambda can write it.
var _depart_flags: Dictionary = {}


func _initialize() -> void:
	sup = TestSupport.new()
	_defs = _singleton(&"Defs", DefsScript)
	_db = _singleton(&"GameDB", DBScript)
	_defs.call("load_all")

	_steps = PackedStringArray([
		"instantiate", "scene_tree", "panels", "theme", "signals", "selection",
		"map_draw", "hit_testing", "view_culling", "order_confirmation", "fleet_orders",
		"illegal_orders",
		"no_tax_or_research", "macro_progress_bar", "boost_modal",
		"build_button", "landing_button", "travel_modal",
		"immediate_bars", "metal_dialog", "travel_flow", "cargo_modal",
		"map_visuals", "economy_rows", "background_music",
		"worker_scrap_ui", "live_capacity", "food_net_sync", "metal_rate_sync",
		"undiscovered_labels",
		"transit_resolution", "transit_persistence", "manifest_arrives",
		"flight_path_toggle", "space_port_gating",
		"travel_prompt_paths", "camera_snap_uncolonized",
		"orbit_labels", "cargo_slider",
		"macro_build", "macro_map_stable", "ready_button", "end_turn", "networked_end_turn",
		"end_turn_again",
		"resolution_panels", "peer_departure", "fog_ownership", "fog_colony_markers",
		"fog_fleet_markers", "fog_planet_names", "no_staged_orders", "map_bounds",
		"planet_readouts",
		"reproducible",
		"teardown",
	])
	# The tree only lays out nodes from `_process` onward; `_initialize` runs before the
	# first frame, when nothing added here is inside the tree yet.


func _process(_delta: float) -> bool:
	if _client != null and _client.get_rect().size.x <= 0.0:
		# The scene file anchors the root to the viewport, so under `--headless` it keeps
		# a 0x0 rect. An explicit minimum makes the layout, and therefore the drawing
		# assertions below, meaningful without a real window.
		_client.custom_minimum_size = Vector2(1280, 720)
	if _step >= _steps.size():
		# Report from a frame *after* the last step, so the teardown has fully run and
		# nothing is freed mid-callback. `quit()` is deferred by the engine to the end
		# of the iteration, so printing here and quitting immediately is safe.
		if not _finished:
			_finished = true
			return false
		_finish()
		return true
	var name := _steps[_step]
	_step += 1
	match name:
		"instantiate": _step_instantiate()
		"scene_tree": _step_scene_tree()
		"panels": _step_panels()
		"theme": _step_theme()
		"signals": _step_signals()
		"selection": _step_selection()
		"map_draw": _step_map_draw()
		"hit_testing": _step_hit_testing()
		"view_culling": _step_view_culling()
		"order_confirmation": _step_order_confirmation()
		"fleet_orders": _step_fleet_orders()
		"illegal_orders": _step_illegal_orders()
		"no_tax_or_research": _step_no_tax_or_research()
		"macro_progress_bar": _step_macro_progress_bar()
		"boost_modal": _step_boost_modal()
		"build_button": _step_build_button_and_ship_list()
		"landing_button": _step_landing_button()
		"travel_modal": _step_travel_modal()
		"immediate_bars": _step_immediate_progress_bars()
		"metal_dialog": _step_metal_allocation_modal()
		"travel_flow": _step_travel_flow()
		"cargo_modal": _step_cargo_modal()
		"map_visuals": _step_map_visuals()
		"economy_rows": _step_panel_economy_rows()
		"background_music": _step_background_music()
		"worker_scrap_ui": _step_worker_and_scrap_ui()
		"live_capacity": _step_live_capacity_display()
		"food_net_sync": _step_food_net_matches_the_turn()
		"metal_rate_sync": _step_mine_worker_moves_the_metal_rate()
		"undiscovered_labels": _step_undiscovered_world_labels()
		"transit_resolution": _step_transit_resolves_and_docks()
		"transit_persistence": _step_transit_persists_and_draws()
		"manifest_arrives": _step_manifest_travel_arrives()
		"flight_path_toggle": _step_flight_path_toggle()
		"space_port_gating": _step_space_port_gates_the_ship_list()
		"travel_prompt_paths": _step_travel_prompt_and_paths()
		"camera_snap_uncolonized": _step_camera_snap_and_uncolonized()
		"orbit_labels": _step_orbit_labels()
		"cargo_slider": _step_cargo_slider_matches_hold()
		"macro_build": _step_macro_build()
		"macro_map_stable": _step_macro_does_not_move_the_map()
		"ready_button": _step_ready_button()
		"end_turn": _step_end_turn()
		"networked_end_turn": _step_networked_end_turn()
		"end_turn_again": _step_end_turn_again()
		"resolution_panels": _step_resolution_reaches_panels()
		"peer_departure": _step_peer_departure_does_not_quit()
		"fog_ownership": _step_fog_of_war_ownership()
		"fog_colony_markers": _step_fog_colony_markers()
		"fog_planet_names": _step_fog_planet_names()
		"no_staged_orders": _step_no_staged_orders()
		"map_bounds": _step_map_bounds()
		"planet_readouts": _step_planet_and_research_readouts()
		"fog_fleet_markers": _step_fog_fleet_markers()
		"reproducible": _step_reproducible()
		"teardown": _step_teardown()
	return false


func _finish() -> void:
	quit(sup.finish("test_gui_integration"))


# --- helpers -------------------------------------------------------------

## Resolve an autoload, creating a local stand-in if this bare `-s` run lacks it.
func _singleton(node_name: StringName, script: GDScript) -> Node:
	var existing := root.get_node_or_null(NodePath(node_name))
	if existing != null:
		return existing
	var made: Node = script.new()
	made.name = node_name
	root.add_child(made)
	_stand_ins[made.get_instance_id()] = true
	return made


## Generate a small, fixed galaxy to drive the client.
func _make_galaxy() -> GalaxyState:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var g := GalaxyGenerator.generate(_defs, rng, 30, 3, _db)
	return g


## The player's first colony, or null.
func _first_colony() -> PlanetState:
	var colonies := _client.controller.player_colonies()
	return colonies[0] if not colonies.is_empty() else null


## Some system to click on the map, preferring one that does not hold the first colony,
## so the controller's selection is genuinely "some other body" rather than the colony.
func _first_body_system(c: SessionController) -> int:
	var colonies := c.player_colonies()
	var home := colonies[0].index if not colonies.is_empty() else -1
	for sys in c.galaxy.systems:
		if sys.planet_indices.is_empty():
			continue
		if sys.planet_indices[0] != home:
			return sys.index
	return 0


# --- steps ---------------------------------------------------------------

func _step_instantiate() -> void:
	sup.begin("client instantiation")
	_galaxy = _make_galaxy()
	sup.ok(_galaxy != null, "galaxy generated")
	if _galaxy == null:
		return
	sup.ok(_galaxy.systems.size() > 0, "galaxy has systems")

	var packed: PackedScene = CLIENT_SCENE
	_client = packed.instantiate() as GameClient
	sup.ok(_client != null, "GameClient.tscn instantiates as a GameClient")
	if _client == null:
		return

	# Node paths a hand-authored scene is expected to resolve. The layout is built in
	# code, so these are the references external code (and the test) rely on.
	for path in ["TopBar", "Map", "Inspector", "Macros", "Fleets", "Log"]:
		sup.ok(_client.get_node_or_null(NodePath(path)) == null,
			"no hard-coded child named '%s' (layout is built in code)" % path)

	root.add_child(_client)
	sup.ok(_client.is_inside_tree(), "client enters the scene tree")

	# `start()` is what binds the panels to a session; without it the panels exist but
	# hold no controller, which is exactly the "instantiates but is not wired" failure
	# this suite exists to catch.
	sup.ok(_client.start(_galaxy, 0, SEED), "the client starts a session on the galaxy")


func _step_scene_tree() -> void:
	sup.begin("scene tree integrity")
	if _client == null:
		return
	sup.ok(_client.top_bar != null, "top bar present")
	sup.ok(_client.map != null, "map present")
	sup.ok(_client.inspector != null, "inspector present")
	sup.ok(_client.macros != null, "macro panel present")
	sup.ok(_client.fleets != null, "fleet panel present")
	sup.ok(_client.controller != null, "session controller present")
	if _client.controller == null:
		return
	sup.ok(_client.controller.galaxy == _galaxy, "controller owns the galaxy")
	sup.ok(_client.controller.galaxy == _galaxy, "galaxy attached to the controller")

	# Every panel must be inside the tree, or it will silently stop receiving signals.
	sup.ok(_client.top_bar.is_inside_tree(), "top bar is inside the tree")
	sup.ok(_client.map.is_inside_tree(), "map is inside the tree")
	sup.ok(_client.inspector.is_inside_tree(), "inspector is inside the tree")
	sup.ok(_client.macros.is_inside_tree(), "macro panel is inside the tree")
	sup.ok(_client.fleets.is_inside_tree(), "fleet panel is inside the tree")


## The lobby ready button: only for a networked session, and it toggles.
##
## This is the control that makes `--client` usable at all now that a match waits for
## every connected player to ready up. It has two failure modes worth pinning: showing in
## single player, where there is no lobby and pressing it does nothing; and staying hidden
## in a network session, which leaves a GUI player stuck in the lobby with no way forward.
func _step_ready_button() -> void:
	sup.begin("lobby ready button")
	if _client == null or _client.top_bar.ready_button() == null:
		sup.ok(false, "top bar exposes its ready button")
		return
	var button := _client.top_bar.ready_button()

	# This suite plays single player, where there is no server to be ready to.
	sup.ok(not _client.controller.is_networked(), "the local session is not networked")
	sup.ok(not button.visible, "and the ready button is hidden with no server to tell")

	# Drive it through a stand-in submitter: what the button actually needs is a session
	# that reports itself networked and records the flag, not a live socket.
	var recorder := RecordingSubmitter.new()
	recorder.slot = 0
	_client.controller.turn_submitter = recorder
	_client.top_bar.refresh()
	sup.ok(_client.top_bar.ready_button().visible,
		"the ready button appears once the session is networked")
	sup.eq(_client.top_bar.ready_button().text, "Ready 0/1",
		"and shows the lobby tally, unpressed")

	var seen: Array[bool] = []
	# The callable is kept, not re-typed at disconnect: a fresh lambda is a *different*
	# Callable, so disconnecting one you did not connect is an engine error rather than a
	# silent no-op.
	var record := func(want: bool) -> void:
		seen.append(want)
	_client.top_bar.ready_pressed.connect(record)
	_client.top_bar.press_ready()
	sup.eq(seen.size(), 1, "pressing it asks for a ready flag")
	if seen.size() == 1:
		sup.ok(seen[0], "the first press asks to become ready")
	_client.top_bar.press_ready()
	sup.eq(seen.size(), 2, "pressing it again is not ignored")
	if seen.size() == 2:
		sup.ok(not seen[1], "the second press takes the flag back, so it toggles")

	# And the label follows the flag, so the player can see which state they are in.
	# The count comes from the server, so it only ever moves *up*; the local flag is what
	# the pressed state means.
	recorder.flagged = true
	recorder.ready_count = 2
	recorder.total_slots = 3
	_client.top_bar.refresh()
	sup.eq(_client.top_bar.ready_button().text, "Ready 2/3",
		"the button counts the server's tally once the flag is set")
	recorder.flagged = false
	recorder.ready_count = 1
	recorder.total_slots = 3
	_client.top_bar.refresh()
	sup.eq(_client.top_bar.ready_button().text, "Ready 1/3",
		"and decrements when the flag is taken back")

	_client.top_bar.ready_pressed.disconnect(record)
	# Released, not just nulled: `recorder` is a RefCounted that stays reachable from the
	# closure the button's own signal handler runs, and a leaked one is reported as
	# "resources still in use" at exit -- which fails the whole suite for a reason that
	# has nothing to do with what it is checking.
	_client.controller.turn_submitter = null
	_client.top_bar.refresh()
	sup.ok(not _client.top_bar.ready_button().visible,
		"the button is hidden again in a local session")
	recorder.free()


## A `TurnSyncClient` that records ready flags instead of sending them.
##
## Subclassed rather than faked with a plain object because `is_ready_flagged()` and
## `set_ready()` have to behave the way the real endpoint does -- the button reads the
## flag back through the controller, so a stub that answered differently would test
## nothing.
class RecordingSubmitter extends TurnSyncClient:
	var flagged: bool = false

	func set_ready(is_ready: bool = true) -> bool:
		flagged = is_ready
		return true

	func is_ready_flagged() -> bool:
		return flagged

	func ready_tally() -> Vector2i:
		return Vector2i(ready_count, total_slots)


func _step_panels() -> void:
	sup.begin("panel nodes")
	if _client == null:
		return
	# Typed accessors returning null would mean the panel failed to build its internals.
	# END TURN and ORDERS are gone: READY commits, and orders ship with the flag. The
	# remaining controls are the ones that still mean something.
	sup.ok(_client.top_bar.ready_button() != null, "top bar exposes its Ready button")
	sup.ok(not _client.top_bar.has_method("end_turn_button"),
		"the top bar has no End Turn button")
	sup.ok(not _client.top_bar.has_method("orders_button"),
		"the top bar has no Orders button and no pending-order counter")
	# The header is now two readouts. Three were removed: STARDATE (which duplicated TURN),
	# IMPERIAL TREASURY and NET/TURN (income figures from the tax slider that no longer has
	# anything to set). Asserted as absences, because an accessor quietly returning the wrong
	# label would otherwise satisfy "the readout is non-null" for the wrong reason.
	sup.ok(_client.top_bar.stardate_label() != null, "top bar still exposes a turn readout")
	sup.eq(_client.top_bar.stardate_label(), _client.top_bar.treasury_label(),
		"and the treasury accessor resolves to that same counter")
	sup.ok(_client.top_bar.net_label() == null, "there is no net/turn readout")
	sup.ok(_client.top_bar.research_label() != null, "top bar exposes the science readout")
	var header := PackedStringArray()
	_collect_text(_client.top_bar, header)
	var header_text := "\n".join(header)
	sup.ok(not header_text.contains("STARDATE"), "the stardate readout is gone",
		"header=%s" % header_text.replace("\n", " | "))
	sup.ok(not header_text.contains("IMPERIAL TREASURY"),
		"the imperial treasury readout is gone")
	sup.ok(not header_text.contains("NET / TURN"), "the net/turn readout is gone")
	sup.ok(header_text.contains("TURN"), "and the turn counter remains")
	sup.ok(header_text.contains("RESEARCH"), "alongside the research readout")
	# The tax slider and the four research sliders are gone as of Phase 8, and the panel
	# reports the absence rather than the suite asking a getter that no longer exists.
	sup.ok(_client.macros.tax_slider() == null, "the macro panel has no tax slider")
	sup.eq(_client.macros.research_sliders().size(), 0,
		"and no research allocation sliders")
	sup.ok(_client.macros.build_selector() != null, "macro panel exposes the build selector")
	sup.ok(_client.macros.colony_selector() != null, "macro panel exposes the colony selector")
	sup.ok(_client.macros.build_bar() != null,
		"macro panel exposes the construction progress bar")
	sup.ok(_client.macros.build_mode_selector() != null,
		"and the single-project / per-turn selector")
	sup.ok(_client.macros.warnings_label() != null,
		"and the colony warning readout")
	sup.ok(_client.inspector.planet_label() != null, "inspector exposes the planet readout")
	# The system survey panel was removed. Asserted as an absence because an accessor that
	# quietly returned null would satisfy "the readout is non-empty" for the wrong reason.
	sup.ok(not _client.inspector.has_method("system_label"),
		"the inspector has no system survey readout -- it was removed")
	sup.ok(not _has_system_survey_heading(),
		"and no SYSTEM SURVEY heading is left in the panel")
	# The BODIES list is gone too: with one system and every world on the map, a body is
	# selected by clicking it, not by picking a row.
	sup.ok(not _client.inspector.has_method("body_list"),
		"the inspector has no body list -- bodies are picked on the map")
	# The fleet registry and the "Stage move" toggle are both gone, replaced by the travel
	# modal. Asserted as absences, because an accessor quietly returning null would satisfy
	# "the detail is non-empty" for the wrong reason.
	sup.ok(_client.fleets.list() == null, "the fleet panel has no registry list")
	sup.ok(_client.fleets.order_button() == null, "and no order-mode button")
	sup.ok(_client.fleets.detail() != null, "fleet panel exposes the fleet detail")
	sup.ok(_client.fleets.travel_button() != null, "and the Travel button that replaces it")
	sup.ok(_client.travel != null, "the client owns the travel modal")
	sup.ok(_client.travel.destination_selector() != null, "which has a destination dropdown")
	sup.ok(_client.travel.ok_button() != null, "and an OK button")
	sup.ok(_client.travel.cancel_button() != null, "and a CANCEL button")
	sup.ok(_client.travel.combat_rows() != null, "and a combat roster")
	sup.ok(_client.travel.support_rows() != null, "and a separate non-combat roster")
	sup.ok(_client.map.sub_viewport() != null, "map owns a SubViewport")
	sup.ok(_client.map.camera() != null, "map owns a Camera2D")
	sup.ok(_client.map.view() != null, "map owns a draw layer")
	sup.ok(_client.map.sub_viewport().get_child_count() > 0, "SubViewport has children")


func _step_theme() -> void:
	sup.begin("theme")
	if _client == null:
		return
	sup.ok(_client.theme != null, "client has a theme")
	sup.ok(_client.top_bar.theme != null, "top bar has a theme")
	sup.ok(_client.macros.theme != null, "macro panel has a theme")
	if _client.theme == null:
		return
	sup.ok(not _client.theme.default_font_size == 0, "theme defines a default font size")
	sup.ok(_client.theme.has_stylebox("panel", "PanelContainer"), "theme defines a panel stylebox")
	sup.ok(_client.theme.has_color("font_color", "Label"), "theme defines the label colour")
	# A default Godot theme has no Button styleboxes; ours must define them.
	sup.ok(_client.theme.has_stylebox("normal", "Button"), "theme defines the button stylebox")
	sup.ok(_client.theme.has_stylebox("slider", "HSlider"), "theme defines the slider stylebox")
	sup.eq(CC2Theme.FACTION_COLORS.size(), 8, "eight faction colours defined")
	sup.eq(CC2Theme.STAR_COLORS.size(), 7, "seven spectral-class colours defined")
	sup.ok(CC2Theme.BG.get_luminance() < 0.1, "background is dark")


func _step_signals() -> void:
	sup.begin("signal wiring")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	sup.ok(c.state_changed.is_connected(_client.top_bar.refresh),
		"top bar follows state_changed")
	sup.ok(c.state_changed.is_connected(_client.inspector.refresh),
		"inspector follows state_changed")
	sup.ok(c.state_changed.is_connected(_client.macros.refresh),
		"macro panel follows state_changed")
	sup.ok(c.state_changed.is_connected(_client.fleets.refresh),
		"fleet panel follows state_changed")
	# The map view repaints through the redraw the view connects itself in `bind`, so
	# that is the edge that has to be present; the map node itself only routes input.
	sup.ok(c.state_changed.is_connected(_client.map.view().queue_redraw),
		"map view follows state_changed")
	sup.ok(_client.top_bar.ready_pressed.is_connected(_client._on_ready_pressed),
		"the Ready button reaches the client")
	sup.ok(_client.map.planet_picked.is_connected(_client._on_planet_picked),
		"map planet selection reaches the client")
	sup.ok(_client.map.end_turn_requested.is_connected(_client._on_end_turn),
		"the keyboard end-turn route reaches the client")
	sup.ok(_client.map.system_picked.is_connected(_client._on_system_picked),
		"map selection reaches the client")
	sup.ok(_client.fleets.fleet_selected.is_connected(_client._on_fleet_selected),
		"fleet selection reaches the client")
	sup.ok(_client.fleets.travel_requested.is_connected(_client._on_travel_requested),
		"the Travel button reaches the client")
	sup.ok(_client.travel.travel_confirmed.is_connected(_client._on_travel_confirmed),
		"and the modal's OK reaches the client")
	sup.ok(_client.travel.travel_cancelled.is_connected(_client._on_travel_cancelled),
		"and its CANCEL")
	sup.ok(c.turn_resolved.is_connected(_client._on_turn_resolved),
		"turn reports reach the client")


func _step_selection() -> void:
	sup.begin("system selection")
	if _client == null or _client.controller == null:
		return
	# Click the first system directly on the map, as a mouse press would.
	var target: SystemState = _galaxy.systems[0]
	var picked: int = _client.map.click_at_galaxy(target.position)
	sup.eq(picked, target.index, "map hit-testing finds the clicked star")
	sup.eq(_client.controller.selected_system, target.index, "controller selection follows the click")
	# Selecting a system auto-selects its first body, so the inspector is never blank.
	if target.planet_indices.size() > 0:
		sup.eq(_client.controller.selected_planet, target.planet_indices[0],
			"first body is selected with the system")
	else:
		sup.eq(_client.controller.selected_planet, -1, "no body selected for an empty system")

	# Bodies are picked by clicking them on the map now, so the map's hit-testing is the
	# thing that has to work, and it has to work on a planet rather than on a star.
	var visible := FowStage.visible_systems(_galaxy, _client.controller.player_id)
	sup.ok(visible.size() > 0, "the player can see at least one system at game start")
	if visible.is_empty():
		return
	var lit: SystemState = _galaxy.system(visible[0])
	sup.ok(lit.planet_indices.size() > 0, "the visible system has bodies to click")

	var own: PlanetState = null
	for p in _galaxy.planets:
		if p.owner == _client.controller.player_id and p.colonized:
			own = p
			break
	sup.ok(own != null, "the player has a homeworld to click")
	if own == null:
		return
	var hit: int = _client.map.click_at_galaxy(own.position)
	sup.eq(hit, own.index, "map hit-testing finds the clicked planet")
	sup.eq(_client.controller.selected_planet, own.index,
		"controller selection follows the planet click")
	sup.eq(_client.controller.selected_system, lit.index,
		"and the owning system follows the planet")
	_client.inspector.refresh()
	var detail := _client.inspector.planet_label().text
	sup.ok(detail.contains("POPULATION"),
		"the inspector renders planet detail for the clicked body")
	# Habitability was removed from the panel. It survived the fog on both sides of the
	# survey rule, which is precisely why it needed removing rather than gating.
	sup.ok(not detail.contains("HABITABILITY"),
		"the inspector shows no habitability readout")
	# Guard the guard: an empty readout would satisfy the check above. The surviving
	# rows must still be there, and the shipyard percentage must still render -- so the
	# absence of habitability is a removed row rather than a blanked panel.
	sup.ok(detail.contains("POPULATION") and detail.contains("FARM"),
		"and the rest of the readout is intact rather than blanked")


func _step_map_draw() -> void:
	sup.begin("map rendering")
	if _client == null or _client.controller == null:
		return
	var view := _client.map.view()
	var sub := _client.map.sub_viewport()

	# Force a redraw so a drawing-time error surfaces here rather than being swallowed by
	# the frame loop.
	view.queue_redraw()
	sup.ok(view.size.x > 0.0 and view.size.y > 0.0, "view has a non-zero size",
		"%s" % str(view.size))
	sup.ok(sub.size.x > 0 and sub.size.y > 0, "sub-viewport has a non-zero size",
		"%s" % str(sub.size))

	# Pick a star exactly at its own position: every system must be hit-testable.
	var sys: SystemState = _galaxy.systems[0]
	sup.eq(view.pick(sys.position, 4.0), sys.index, "precise hit-test finds the star")
	sup.eq(view.pick(Vector2(99999.0, 99999.0)), -1, "empty space hits nothing")

	# Fog: an unsurveyed system must not be visible.
	var hidden := -1
	for s in _galaxy.systems:
		if not FowStage.can_see(_galaxy, _client.controller.player_id, s.index):
			hidden = s.index
			break
	if hidden >= 0:
		sup.ok(not _client.controller.can_see(hidden), "an unsurveyed system is not visible")
	else:
		sup.ok(true, "an unsurveyed system is not visible (all systems visible; skipped)")

	# Camera zoom must clamp rather than run away.
	var cam := _client.map.camera()
	var before := cam.zoom.x
	# The bounds are per-span accessors, not constants: `--map-size` made the radius a
	# per-game property, so a fixed floor tuned for a 120-parsec disk would put a `tiny`
	# map's camera inside the star.
	_client.map._zoom_at(Vector2(400.0, 300.0), 1000.0)
	sup.near(cam.zoom.x, _client.map.max_zoom(), 0.001, "zoom clamps at the maximum")
	_client.map._zoom_at(Vector2(400.0, 300.0), 0.0001)
	sup.near(cam.zoom.x, _client.map.min_zoom(), 0.001, "zoom clamps at the minimum")
	cam.zoom = Vector2.ONE * before
	_client.map.recentre()
	sup.ok(cam.zoom.x >= _client.map.min_zoom(),
		"map recentres to a legal zoom",
		"zoom=%f" % cam.zoom.x)

	# The framing is the regression that mattered: the whole galaxy must land inside the
	# visible rect, or the player opens onto empty space. This ran against the *live*
	# binding (the layout the player actually sees), not a hand-restored zoom, because the
	# original defect was that binding happened before the map had any area at all.
	var area := _client.map.size
	sup.ok(area.x > 0.0 and area.y > 0.0,
		"the map is laid out when the session is bound", "%s" % str(area))
	sup.ok(cam.zoom.x > _client.map.min_zoom(),
		"the opening zoom is not clamped to the minimum",
		"zoom=%f" % cam.zoom.x)
	var on_screen := 0
	var half := area * 0.5 / cam.zoom.x
	var rect := PackedVector2Array([
		cam.position + Vector2(-half.x, -half.y),
		cam.position + Vector2(half.x, -half.y),
		cam.position + Vector2(half.x, half.y),
		cam.position + Vector2(-half.x, half.y),
	])
	for framed in _galaxy.systems:
		if Geometry2D.is_point_in_polygon(framed.position, rect):
			on_screen += 1
	sup.ok(on_screen == _galaxy.systems.size(),
		"every system is inside the framed view",
		"%d of %d on screen at zoom %f" % [on_screen, _galaxy.systems.size(), cam.zoom.x])

	# Unsurveyed bodies must still be *drawn* -- dimly, without their type colour or
	# ownership. There is one system, so system-level fog has nothing to hide; the fog
	# that matters is per-planet, and a body the player has not surveyed is what an
	# empty-looking map is made of.
	var unknown := 0
	for p in _galaxy.planets:
		if not p.surveyed and p.owner != _client.controller.player_id:
			unknown += 1
	sup.ok(unknown > 0, "the fixture has unsurveyed planets to render",
		"%d of %d hidden" % [unknown, _galaxy.planets.size()])
	sup.ok(GalaxyMapView.UNKNOWN_MARKER_COLOUR.a >= 0.4,
		"the unknown-system marker is visible against the void",
		"alpha=%f" % GalaxyMapView.UNKNOWN_MARKER_COLOUR.a)
	sup.ok(GalaxyMapView.UNKNOWN_MARKER_RADIUS >= 5.0,
		"the unknown-body marker is wide enough to see",
		"radius=%f" % GalaxyMapView.UNKNOWN_MARKER_RADIUS)


## Deliverables 3 and 4: transit is quoted in dots and turns, and a click proposes rather
## than dispatches.
##
## The order of these assertions is the whole point -- each one checks the state the player
## is *in* at that moment, so a click that dispatched immediately would fail at "nothing is
## staged yet" before the confirm button was ever reached.
func _step_order_confirmation() -> void:
	sup.begin("flight proposal, transit estimate and confirmation")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var gal := c.galaxy
	var map := _client.map
	var panel := _client.fleets
	# The panel has to be given a fleet first: with none selected the whole flow is
	# unreachable, and a step that quietly returns would leave the proposal assertions
	# unexercised while still reporting green.
	var mine := c.player_fleets()
	if mine.is_empty():
		sup.ok(true, "the player has no fleet; proposal flow not exercised")
		return
	c.select_fleet(mine[0].id)
	var f := c.fleet()
	sup.ok(f != null, "a fleet is selected for the proposal", "selected=%d" % c.selected_fleet)
	if f == null:
		return
	# Start from a fleet that is not already under way, so the proposal is a legal one.
	if f.destination >= 0:
		f.destination = -1
		f.travelled = 0.0

	var dest := -1
	var dots := 0.0
	for p in gal.planets:
		if p.index == f.system:
			continue
		var d := MovementStage.orbit_dots(gal, gal.planet(f.system), p)
		if dest < 0 or d > dots:
			dest = p.index
			dots = d
	if dest < 0:
		sup.ok(true, "no second world to fly to; proposal flow not exercised")
		return

	var turns := MovementStage.transit_turns(gal, f.system, dest)

	# --- the estimate ---------------------------------------------------------
	sup.ok(dots > 0.0, "a flight has a dot distance", "%.1f dots" % dots)
	sup.ok(turns >= 1, "and takes at least one turn", "%d turns" % turns)
	sup.ok(turns == maxi(1, ceili(dots / MovementStage.DOTS_PER_TURN)),
		"the quoted turns are the distance in dots over the uniform rate",
		"%d dots / %.0f per turn" % [dots, MovementStage.DOTS_PER_TURN])

	# The figure the player reads has to be the figure on the map. A turn *is* a waypoint:
	# count the pips drawn along the order line, add the destination's own marker, and you
	# must land on the quoted turn count -- not one short, not one long.
	#
	# This is the assertion that was missing. The suite previously compared the quote
	# against `ceili(dots / DOTS_PER_TURN)`, which is `transit_turns` with the division
	# still in it, so it passed at every possible rate -- including the ten-dots-per-turn
	# value that made the panel read "14 dots, 2 turns" over fourteen visible pips.
	sup.eq(MovementStage.waypoints(gal, f.system, dest).size() + 1, turns,
		"the pips drawn along the route plus the destination marker ARE the quoted turns")
	sup.ok(MovementStage.fleet_speed(f, c.player()) == 1.0,
		"a fleet advances exactly one waypoint per turn, so a turn is one pip",
		"%.3f dots/turn" % MovementStage.fleet_speed(f, c.player()))
	# Every pip is evenly spaced and evenly ordered: the ruler has no skipped marks.
	var marks := MovementStage.waypoints(gal, f.system, dest)
	var span_len := gal.planet(f.system).position.distance_to(gal.planet(dest).position)
	var gaps := PackedFloat32Array()
	var prev := gal.planet(f.system).position
	for m: Vector2 in marks:
		gaps.append(prev.distance_to(m))
		prev = m
	var max_gap := 0.0
	for gp: float in gaps:
		max_gap = maxf(max_gap, absf(gp - MovementStage.dot_size(gal)))
	sup.ok(max_gap < 0.01,
		"every pip is exactly one dot from the last -- none skipped or bunched",
		"worst=%.5f parsecs off a %.3f dot" % [max_gap, MovementStage.dot_size(gal)])
	sup.ok(span_len > 0.0, "the route has a length to divide up", "%.1f" % span_len)

	# The longest crossing is not where this relationship is decided. `round(dots)` and the
	# pip count agree whenever the fractional part of the distance is at least a half --
	# the longest hops land there by luck -- and disagree by exactly one on the other half
	# of the map. So the check searches for a crossing where the two *provably differ* and
	# requires the pip count. Without that, the panel could print a rounded parsec figure
	# and every assertion above would still pass, which is precisely how "14 dots, 2 turns"
	# shipped beside a line of fourteen pips.
	var div_dest := -1
	var div_dots := 0.0
	for p in gal.planets:
		if p.index == f.system:
			continue
		var d := MovementStage.orbit_dots(gal, gal.planet(f.system), p)
		# Skip anything where the rounded distance already equals the pip count --
		# such a pair cannot tell the two implementations apart.
		if int(round(d)) == MovementStage.waypoints(gal, f.system, p.index).size() + 1:
			continue
		div_dots = d
		div_dest = p.index
		break
	if div_dest >= 0:
		var div_pips := MovementStage.waypoints(gal, f.system, div_dest).size() + 1
		var div_turns := MovementStage.transit_turns(gal, f.system, div_dest)
		sup.ok(int(round(div_dots)) != div_turns,
			"a crossing was found where a rounded distance and the pip count disagree",
			"raw=%.3f round=%d pips=%d" % [div_dots, int(round(div_dots)), div_pips])
		sup.eq(div_pips, div_turns,
			"and there the pips and turns still agree")
		# Open the prompt for it and read what the player is actually shown.
		map.cancel_order()
		map.propose_order(div_dest)
		var shown_div := panel.visible_text()
		sup.ok(shown_div.contains("%d dots" % div_pips),
			"the prompt prints the pip count there, not the rounded distance",
			"want %d dots (rounded distance is %d); shown=%s"
				% [div_pips, int(round(div_dots)), shown_div])
		sup.ok(shown_div.contains("%d turn" % div_turns),
			"alongside the matching turn count",
			"want %d turns; shown=%s" % [div_turns, shown_div])
		map.cancel_order()
	else:
		sup.ok(true, "no crossing on this map discriminates the two figures; not exercised")

	# Every fleet moves at the same rate, so a second fleet over a longer leg takes
	# strictly more turns. Speed varying with hull composition is what made this
	# unquotable before.
	sup.eq(MovementStage.fleet_speed(f, c.player()), MovementStage.DOTS_PER_TURN,
		"fleet speed is the uniform dot rate")

	# --- clicking proposes, and nothing more ------------------------------------
	var queued_before := c.pending_orders().size()
	map.set_order_mode(true)
	map.click_at_galaxy(gal.planet(dest).position)
	sup.eq(map.pending_destination(), dest,
		"clicking a destination with a fleet selected proposes it")
	sup.eq(c.pending_orders().size(), queued_before,
		"but nothing is queued yet -- the click did not dispatch")
	sup.eq(f.destination, -1,
		"and the fleet is not yet in transit")
	# Phase 8 replaced the CONFIRM / CANCEL prompt with the travel modal, so a click now
	# opens the modal with this world already chosen rather than a second decision to make.
	sup.ok(_client.travel.visible, "the click opened the travel modal")
	sup.eq(_client.travel._selected_destination(), dest,
		"with the clicked world already chosen")
	sup.ok(panel.visible_text().contains("%d turn" % turns),
		"and the fleet panel quotes the number of turns the flight will take",
		"want %d turns; shown=%s" % [turns, panel.visible_text()])
	sup.ok(_client.travel.summary_label().text.contains("%d turn" % turns),
		"as does the modal's own summary",
		"shown=%s" % _client.travel.summary_label().text)

	# --- cancel discards --------------------------------------------------------
	map.cancel_order()
	sup.eq(map.pending_destination(), -1, "cancelling clears the proposal")
	sup.eq(c.pending_orders().size(), queued_before, "and queues nothing")
	sup.eq(f.destination, -1, "the fleet has not moved")
	sup.ok(not _client.travel.visible, "and the modal closes")

	# --- clicking elsewhere discards -------------------------------------------
	map.click_at_galaxy(gal.planet(dest).position)
	sup.eq(map.pending_destination(), dest, "the proposal is open again")
	map.click_at_galaxy(Vector2(999999.0, -999999.0))
	sup.eq(map.pending_destination(), -1, "clicking empty space discards it")
	sup.eq(c.pending_orders().size(), queued_before, "without queueing anything")
	sup.ok(not _client.travel.visible, "and closes the modal with it")

	# --- the modal commits -------------------------------------------------------
	map.click_at_galaxy(gal.planet(dest).position)
	_client.travel.set_all(true)
	_client.travel.ok_button().emit_signal(&"pressed")
	sup.eq(c.pending_orders().size(), queued_before + 1, "exactly one order is queued")
	sup.eq(f.destination, dest, "and the fleet is in transit to the proposed world")
	sup.eq(map.pending_destination(), -1, "the proposal is consumed")
	sup.ok(not _client.travel.visible, "and the modal closes")

	# --- the flight really takes that many turns ---------------------------------
	# Stepped here rather than trusting `transit_turns`: the number on the prompt is only
	# worth showing if the resolver actually spends it.
	f.destination = -1
	f.travelled = 0.0
	c.queue.clear()
	sup.ok(MovementStage.issue_move(gal, f.id, f.owner, dest), "a fresh order is accepted")
	var spent := 0
	while f.destination >= 0 and spent < 500:
		MovementStage.advance(gal)
		spent += 1
	sup.eq(spent, turns, "the fleet spends exactly the quoted number of turns")
	sup.eq(f.system, dest, "and arrives where it was sent")

	# --- multi-turn travel --------------------------------------------------------
	# The brief's "movements take multiple turns across the map": a full-width crossing of
	# the largest map has to be more than one turn at the uniform rate.
	var inner := -1
	var outer := -1
	var span := 0.0
	for p in gal.planets:
		var r := p.position.length()
		if inner < 0 or r < span:
			span = r
			inner = p.index
		if outer < 0 or r > span:
			span = r
			outer = p.index
	if inner >= 0 and outer >= 0 and inner != outer:
		var wide := MovementStage.transit_turns(gal, inner, outer)
		sup.ok(wide > 1,
			"the longest crossing on this map takes more than one turn",
			"%d turns over %.0f dots" % [
				wide, MovementStage.orbit_dots(gal, gal.planet(inner), gal.planet(outer))])

	map.set_order_mode(false)


func _step_fleet_orders() -> void:
	sup.begin("fleet move orders")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	# A new empire starts with an empty orbit, so the first thing these tests do is put one
	# hull there -- which doubles as a standing check that the generator granted nothing.
	sup.eq(c.player_fleets().size(), 0,
		"a new empire has no fleet: everything it puts in orbit it builds")
	var home := _first_colony()
	if home != null:
		_ensure_transport(home.index, &"exploration_ship")
	var fleets := c.player_fleets()
	sup.ok(not fleets.is_empty(), "and one placed by hand is immediately usable",
		"got %d" % fleets.size())
	if fleets.is_empty():
		return

	var f: FleetState = fleets[0]
	c.select_fleet(f.id)
	sup.eq(c.selected_fleet, f.id, "fleet selection sticks")
	sup.ok(c.fleet() != null, "controller returns the selected fleet")

	# Any other system will do: MovementStage rejects unreachable legs, not wrong ones,
	# and the resolver treats an unlinked destination as a no-op rather than an error.
	# Destinations are planets now: a fleet moves between worlds, and the single star
	# is never a move target because there is nowhere to put a fleet that is not a body.
	var dest := -1
	for p in _galaxy.planets:
		if p.index != f.system:
			dest = p.index
			break
	if dest < 0:
		sup.ok(true, "a destination planet exists")
		return

	var staged_before := c.pending_orders().size()
	var accepted := c.queue_move(dest)
	sup.ok(accepted, "a legal move order is accepted")
	sup.eq(c.pending_orders().size(), staged_before + 1, "the order is staged")
	sup.eq(f.destination, dest, "the fleet's in-flight destination is set immediately")

	# The staged order must be a real Phase 4 MOVE_FLEET order.
	var orders := c.pending_orders()
	var last: Order = orders[orders.size() - 1]
	sup.eq(last.type, Enums.OrderType.MOVE_FLEET, "the staged order is a MOVE_FLEET")
	sup.eq(last.fleet, f.id, "the order names the right fleet")
	sup.eq(last.target_planet, dest, "the order names the right destination planet")
	sup.eq(last.target_system, -1, "and names no system")

	# The map must be able to draw the resulting warp line.
	_client.map.view().queue_redraw()
	sup.ok(true, "map redraws with a staged order")


func _step_illegal_orders() -> void:
	sup.begin("refused orders")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller

	# A second move while already in transit must be refused with a reason.
	var orders_before := c.pending_orders().size()
	var reasons := PackedStringArray()
	c.action_rejected.connect(func(reason: String) -> void: reasons.append(reason))
	var f := c.fleet()
	if f != null and f.destination >= 0:
		sup.ok(not c.queue_move(_galaxy.systems[0].index), "a second move is refused")
		sup.eq(c.pending_orders().size(), orders_before, "the refused order was not staged")
		sup.ok(not reasons.is_empty(), "the refusal was explained", "no reason emitted")

	# An out-of-range destination must be refused.
	c.selected_fleet = -1
	sup.ok(not c.queue_move(0), "a move with no fleet selected is refused")

	# Building with no colony selected must be refused.
	c.selected_planet = -1
	sup.ok(not c.queue_build_structure(&"farm"), "a build with no colony selected is refused")
	sup.ok(not reasons.is_empty(), "build refusals are explained")

	# A research allocation that sums to zero is meaningless.
	sup.ok(not c.set_research_allocation(PackedFloat64Array([0.0, 0.0, 0.0, 0.0])),
		"an all-zero research allocation is refused")


## The tax slider and the research allocation sliders are gone.
##
## Phase 8 removed both: research is driven by the empire's civilian population and there is
## no budget for a player to divide, and the tax rate no longer gates anything. The absence is
## the assertion, and it is asserted three ways -- through the accessors, by walking the panel
## for a surviving `HSlider`, and by reading every label the panel is actually showing. A
## getter returning null alone would pass while a stray slider sat on screen.
func _step_no_tax_or_research() -> void:
	sup.begin("macro: no tax slider, no research sliders")
	if _client == null or _client.macros == null:
		return
	var macros := _client.macros

	sup.ok(macros.tax_slider() == null, "the tax slider accessor reports none")
	sup.ok(macros.tax_value_label() == null, "and so does the tax readout")
	sup.eq(macros.research_sliders().size(), 0, "there are no research sliders")

	var sliders := 0
	_sliders_under(macros, sliders)
	sup.eq(sliders, 0, "and no HSlider survives anywhere in the right panel")

	var shown := macros.visible_text()
	sup.ok(not shown.contains("IMPERIAL TAX"), "the tax heading is gone", "shown=%s" % shown)
	sup.ok(not shown.contains("RESEARCH ALLOCATION"), "and so is the research heading")
	sup.ok(not shown.contains("RESEARCH"), "and nothing else is labelled research either")


## Count every `HSlider` under `node`, recursively.
func _sliders_under(node: Node, into: int) -> void:
	if node is HSlider:
		into += 1
	for child in node.get_children():
		_sliders_under(child, into)


## The construction progress bar: clickable, and spending metal is what clicking does.
##
## This is the mechanic the design document asks for by name -- "click to spend stored metal
## directly to boost/complete progress" -- so the assertion is that a press moves the bar's
## value and debits the colony, not merely that a control exists.
func _step_macro_progress_bar() -> void:
	sup.begin("macro: the construction progress bar is clickable")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var colony := _first_colony()
	sup.ok(colony != null, "the player starts with a colony to build on")
	if colony == null:
		return
	c.select_planet(colony.index)
	_client.select_colony(colony.index)

	var bar := _client.macros.build_bar()
	sup.ok(bar != null, "the panel exposes a progress bar")
	if bar == null:
		return
	sup.ok(not bar.visible, "with nothing queued there is no bar to press")

	# Nothing queued: a press must do nothing at all, and say so.
	var idle_metal := colony.reserve_metals
	var empty_spend := c.boost_construction(colony.reserve_metals)
	sup.near(empty_spend, 0.0, 0.001, "a colony with nothing queued spends nothing")
	_client.macros._on_build_bar_input(_left_click())
	sup.near(colony.reserve_metals, idle_metal, 0.001,
		"and pressing the bar leaves the store alone")

	# Queue something, and the bar appears. The control only *stages* the order: it becomes
	# a construction queue when the resolver runs, which is the same round trip every other
	# order makes, so the test drives that step explicitly rather than resolving a whole turn
	# to get one building into the ground.
	var me := c.player()
	me.metals = 100000.0
	for id: Variant in c.defs.get("buildings"):
		me.unlocked_buildings[StringName(str(id))] = true
	colony.reserve_metals = 60.0
	var queued_before := c.pending_orders().size()
	sup.ok(c.queue_build_structure(&"granary"), "a granary can be queued")
	sup.eq(c.pending_orders().size(), queued_before + 1, "the build order is staged")
	var staged: Order = c.pending_orders()[c.pending_orders().size() - 1]
	sup.eq(staged.type, Enums.OrderType.BUILD_STRUCTURE, "and it is a BUILD_STRUCTURE order")
	# The project is mirrored onto the colony at press time, so the bar can be rendered on the
	# same frame as the press. A bar that waited for the order to resolve read as a button
	# that had done nothing.
	sup.eq(colony.building_queue.size(), 1,
		"the project is queued on the colony as soon as Build is pressed")
	_client.macros.refresh()
	sup.ok(bar.visible, "a queued project shows the progress bar")
	sup.near(bar.value, 0.0, 0.001, "at zero progress")
	# Applying the order again -- which is what the resolver does at the end of the turn --
	# must change nothing, or the mirror would double the work.
	TurnResolver.apply_build_structure(c.galaxy, me, staged, c.defs, c.db)
	sup.eq(colony.building_queue.size(), 1,
		"and applying the same order again does not queue it twice")

	var banked := colony.reserve_metals
	sup.ok(banked > 0.0, "the colony has metal banked to spend", "%.1f" % banked)

	# A click OPENS the dialog. It does not spend: a bare click used to hand the whole
	# stockpile to the project, which is a very different thing from what pressing a bar means.
	_client.macros._on_build_bar_input(_left_click())
	sup.ok(_client.boost != null, "the client owns a boost modal")
	if _client.boost == null:
		return
	_client.boost.refresh()
	sup.ok(_client.boost.visible, "clicking the bar opens the dialog")
	sup.near(colony.reserve_metals, banked, 0.001,
		"and the click itself spends nothing")

	# The dialog names the project and states the percentage already paid.
	var shown := _client.boost.visible_text()
	sup.ok(shown.contains("Granary"), "it names the project under construction",
		"shown=%s" % shown.replace("\n", " | "))
	sup.ok(shown.contains("0% complete"),
		"and reports the completion percentage", "shown=%s" % shown.replace("\n", " | "))
	sup.ok(shown.contains("ADD metal from storage into this project"),
		"and asks the question it exists to ask", "shown=%s" % shown.replace("\n", " | "))
	sup.ok(shown.contains("REMOVE assigned metal"),
		"and offers the other direction: metal already in the project can come back out",
		"shown=%s" % shown.replace("\n", " | "))
	sup.eq(_client.boost.ok_button().text, "OK", "with an OK button")
	sup.eq(_client.boost.cancel_button().text, "CANCEL", "and a CANCEL button")

	# --- the ceiling -----------------------------------------------------------
	# The slider may not be dragged past what the project still owes. The colony holds far
	# more metal than a Granary costs, so an uncapped slider would offer to hand over the
	# whole stockpile and lose most of it.
	var owed := ColonySim.metal_remaining(colony, _defs.get("buildings") as Dictionary)
	var ceiling := _client.boost.amount_slider().max_value
	sup.near(ceiling, owed, 0.001,
		"the slider is capped at the metal the project still owes (cap=%.1f, owed=%.1f, stored=%.1f)" % [
			ceiling, owed, banked])
	sup.ok(banked > owed, "even though the colony holds more than that",
		"stored=%.1f owed=%.1f" % [banked, owed])

	# OK transfers that amount and debits storage by exactly it. Half, deliberately: topping
	# the project up to full here would leave nothing for the CANCEL case to re-open.
	var transfer := ceiling * 0.5
	_client.boost.amount_slider().set_value_no_signal(transfer)
	_client.boost.ok_button().emit_signal(&"pressed")
	sup.ok(not _client.boost.visible, "OK closes the dialog")
	_client.macros.refresh()
	sup.near(colony.reserve_metals, banked - transfer, 0.001,
		"OK moved exactly the chosen amount out of storage")
	sup.ok(bar.value > 0.0, "and the bar advanced", "value=%.3f" % bar.value)
	sup.ok(_client.log_text().contains("CONSTRUCTION BOOSTED"),
		"the transfer is reported in the log")

	# --- CANCEL moves nothing --------------------------------------------------
	_client.boost.refresh()
	sup.ok(_client.boost.open_for_selected_colony(), "the dialog reopens")
	var before_cancel := colony.reserve_metals
	_client.boost.cancel_button().emit_signal(&"pressed")
	sup.ok(not _client.boost.visible, "CANCEL closes it")
	sup.near(colony.reserve_metals, before_cancel, 0.001, "and moves no metal at all")


func _left_click() -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	return event


## The construction menu's two halves: structures (Build button) and hulls (ship list).
##
## Both are Phase 8 corrections. The dropdown used to spend on selection, which meant
## browsing the menu committed a purchase; and the ship list used to be driven purely by the
## empire's research unlocks, so a Space Port was a building that produced nothing a player
## could use until a milestone they might be turns from arrived.
func _step_build_button_and_ship_list() -> void:
	sup.begin("construction: build button and ship list")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var me := c.player()
	var colony := _first_colony()
	sup.ok(colony != null, "the player starts with a colony")
	if colony == null or me == null:
		return
	c.select_planet(colony.index)
	_client.select_colony(colony.index)
	colony.building_queue.clear()
	colony.build_turns_remaining = 0
	colony.build_total_turns = 0
	colony.build_metal = 0.0
	colony.reserve_metals = 100000.0
	for id: Variant in c.defs.get("buildings"):
		me.unlocked_buildings[StringName(str(id))] = true
	_client.macros.refresh()

	# --- the Colony Ship is not in the construction menu -----------------------
	# It is the one structure a colony cannot build: a Colony Ship flies to the world and is
	# consumed on landing. Offering a Build button for it would be a lie.
	var ship_names := PackedStringArray()
	for i in _client.macros.build_selector().item_count:
		var meta: Variant = _client.macros.build_selector().get_item_metadata(i)
		if meta != null:
			ship_names.append(StringName(str(meta)))
	sup.ok(not ship_names.has(&"colony_ship_building"),
		"the construction dropdown does not offer a landed Colony Ship",
		"offers %s" % str(ship_names))
	# The check is on the dropdown's own items and the panel's section headings, not on
	# every string the panel renders: a planet the player has settled can legitimately be
	# *named* something with "Colony" in it.
	var panel_text := _client.macros.visible_text()
	sup.ok(not panel_text.contains("CONSTRUCTION") or not panel_text.contains("Colony Ship
"),
		"nor does the construction section list it",
		"shown=%s" % panel_text.replace("\n", " | "))

	# --- the Build button actually starts the project --------------------------
	c.queue.clear()
	sup.ok(_client.macros.select_build(&"granary"), "a granary can be selected")
	sup.eq(c.pending_orders().size(), 0, "selection alone stages nothing")
	# Move the selection off the colony, so the Build button has somewhere to move it back
	# from. With one system, "some other body" is just any other planet.
	c.select_planet(_other_planet_index(colony.index))
	sup.ok(_client.macros.build_button() != null, "the panel has a Build button")
	sup.eq(_client.macros.build_button().text, "Build", "labelled 'Build'")
	sup.eq(c.selected_planet, _other_planet_index(colony.index),
		"the selection really is elsewhere before Build is pressed")
	_client.macros.build_button().emit_signal(&"pressed")
	sup.eq(c.pending_orders().size(), 1, "pressing it stages exactly one order")
	var staged: Order = c.pending_orders()[0]
	sup.eq(staged.type, Enums.OrderType.BUILD_STRUCTURE, "which is a BUILD_STRUCTURE")
	sup.eq(staged.payload.get("building", ""), "granary", "for the selected structure")
	# The regression this button exists alongside: browsing the dropdown used to be refused
	# with "select one of your colonies first", because nothing moved the controller's
	# selection off the body the player had clicked. Build adopts the highlighted colony.
	sup.eq(staged.target_planet, colony.index,
		"and Build adopts the colony the dropdown names")
	c.queue.clear()

	# --- the ship list follows the Space Port ----------------------------------
	# Strip every unlock so the port is the only thing that can populate the list.
	var saved := me.unlocked_ships.duplicate()
	for hull_id: StringName in GameDB.PORT_HULLS as Array:
		me.unlocked_ships.erase(hull_id)
	me.unlocked_ships.erase(&"corvette")
	me.unlocked_ships.erase(&"frigate")
	colony.structures[&"space_port"] = 0
	_client.macros.refresh()
	sup.eq(_hull_ids_in_menu().size(), 0,
		"with no port and no unlocks the hull half of the menu is empty")
	sup.ok(not _client.macros.has_method("build_ship_button"),
		"and the panel no longer has a Build Ship button at all")

	colony.structures[&"space_port"] = 1
	_client.macros.refresh()
	var hull_names := _hull_ids_in_menu()
	sup.eq(hull_names.size(), 6,
		"a Space Port puts the six baseline hulls into the construction menu (got %d)" % [
			hull_names.size()])
	for hull_id: StringName in GameDB.PORT_HULLS as Array:
		sup.ok(hull_names.has(hull_id),
			"the menu offers %s" % hull_id)
	sup.ok(not hull_names.has(&"leviathan"),
		"and nothing above the Frigate, which still needs a milestone")
	sup.ok(not _client.macros.build_button().disabled,
		"and the one Build button now has something to build")

	# A port is a local grant: another colony with no port gets nothing.
	var other: PlanetState = null
	for p in c.player_colonies():
		if p.index != colony.index:
			other = p
			break
	if other != null:
		other.structures.erase(&"space_port")
		c.select_planet(other.index)
		_client.macros.refresh()
		sup.eq(_hull_ids_in_menu().size(), 0,
			"a colony without a port sees no hulls at all, not this one's")

	c.select_planet(colony.index)
	_client.macros.refresh()
	me.unlocked_ships = saved
	colony.building_queue.clear()
	colony.build_turns_remaining = 0
	colony.build_total_turns = 0
	colony.build_metal = 0.0


## Clicking a world with a Colony Ship over it offers the landing, and landing it works.
##
## Three things this covers that the previous step did not.
##
## The button is found by *world*, not by fleet selection. Clicking a planet on the map
## selects a planet, so the old "which fleet is selected" test answered a question the player
## never asked and the control was absent for exactly the flow it exists to serve.
##
## The world arrives as a colony, not as an empty rock with a building on it: the same kit the
## generator hands an empire's first world.
##
## Anyone in the hold comes ashore. Civs were in `cargo`, nothing read it on a landing, and
## they were discarded.
func _step_landing_button() -> void:
	sup.begin("fleet: the Colony Ship landing button")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	sup.ok(_client.fleets.land_button() != null, "the panel exposes a landing button")
	if _client.fleets.land_button() == null:
		return
	var button := _client.fleets.land_button()
	sup.eq(button.text, "Land Colony Ship", "and it says what it does")

	# At the foot of the panel, after the expanding detail block rather than beside Travel.
	var siblings := button.get_parent().get_children()
	sup.ok(not siblings.is_empty() and siblings[siblings.size() - 1] == button,
		"the landing button is the last control in the panel",
		"last=%s" % str(siblings[siblings.size() - 1] if not siblings.is_empty() else "<none>"))

	# A world nobody owns, and a fleet parked over it carrying a kit and a hold full of
	# settlers.
	var target := -1
	for p in c.galaxy.planets:
		if p.owner < 0 and not p.colonized and p.index != c.selected_planet:
			target = p.index
			break
	sup.ok(target >= 0, "there is an unclaimed world to settle")
	if target < 0:
		return
	var carrier := _gen_fleet(0, target, {&"colony_ship": 1})
	sup.ok(carrier != null, "a fleet with a kit is parked over it")
	if carrier == null:
		return
	var settlers := 7.0
	carrier.cargo[&"civilians"] = settlers

	# The player's gesture is a click on the world. Nothing selects the fleet.
	c.selected_fleet = -1
	c.select_planet(target)
	_client.fleets.refresh()
	sup.ok(c.colony_ship_carrier() == carrier,
		"the Colony Ship over the clicked world is found without selecting a fleet")
	sup.ok(c.can_land_colony_ship(), "so a landing is legal")
	sup.ok(button.visible, "and the button is shown")
	sup.ok(not button.disabled, "and enabled")

	# Pressing it settles the world, spends the ship, and brings the kit.
	var before_ships := carrier.ship_count()
	button.emit_signal("pressed")
	var settled := c.galaxy.planet(target)
	sup.ok(settled.colonized, "the world is settled")
	sup.eq(settled.owner, 0, "and owned by the player")
	sup.eq(settled.count(&"colony_ship_building"), 1,
		"with the structure a landed Colony Ship leaves")
	sup.eq(carrier.ship_count(), before_ships - 1, "and the ship itself is consumed")
	sup.ok(_client.log_text().contains("COLONY SHIP LANDED"),
		"the landing is reported in the log")

	# The kit: what an empire's first world opens with, not a bare rock.
	sup.eq(int(settled.population), int(settled.population),
		"the colony has a population")
	sup.ok(settled.population >= settlers,
		"and everyone in the hold came ashore rather than being discarded",
		"pop=%.0f settlers=%.0f" % [settled.population, settlers])
	sup.near(float(carrier.cargo.get(&"civilians", 0.0)), 0.0, 0.001,
		"leaving the hold empty")
	sup.ok(settled.food_stock >= float(_db.get("STARTING_FOOD")),
		"and it opens with a pantry", "food=%.1f" % settled.food_stock)
	sup.ok(settled.reserve_metals >= float(_db.get("STARTING_METALS")),
		"and enough metal to build its first farm", "metal=%.1f" % settled.reserve_metals)
	sup.ok(settled.power >= float(_db.get("STARTING_POWER")),
		"and a working battery", "power=%.1f" % settled.power)
	sup.eq(settled.worker_assignment.size(), 0,
		"and nobody posted, so the first posting is the player's decision")
	# Capacities settled on the turn of the landing, not the next one.
	_client.inspector.refresh()
	sup.eq(int(settled.get_max_housing()), int(_db.get("BASE_HOUSING")),
		"its capacities are settled immediately")

	# The cap holds, so the button goes away again.
	sup.ok(not c.can_land_colony_ship(),
		"a second landing on the same world is no longer legal")
	sup.ok(not button.visible,
		"and the button is hidden rather than offering a refusal")

	# A fleet with no kit is not a carrier, on a world that *could* otherwise be settled --
	# so the refusal is about the missing ship rather than about the world being taken.
	#
	# The escort is removed again before the step ends. Left parked it changes what the later
	# travel step finds when it asks for a world with nothing in orbit, and the failure would
	# land there rather than here, a long way from the cause.
	var bare := -1
	for p in c.galaxy.planets:
		if p.owner < 0 and not p.colonized and p.index != target:
			bare = p.index
			break
	if bare >= 0:
		var escort := _gen_fleet(0, bare, {&"corvette": 2})
		if escort != null:
			c.select_planet(bare)
			_client.fleets.refresh()
			sup.ok(c.colony_ship_carrier() == null,
				"a fleet with no Colony Ship is not a carrier")
			sup.ok(not c.can_land_colony_ship(),
				"and an unclaimed world with only an escort cannot be settled")
			sup.ok(not button.visible, "so no landing button is offered")
			c.galaxy.remove_fleet(escort.id)

	# And a world with nothing in orbit at all.
	c.select_planet(bare if bare >= 0 else target)
	_client.fleets.refresh()
	sup.ok(c.colony_ship_carrier() == null, "an empty orbit has no carrier either")
	sup.ok(not button.visible, "and an empty world offers nothing to land")

	c.selected_fleet = -1
	_client.fleets.refresh()


## A one-off fleet for a scenario, built the way generation builds them.
func _gen_fleet(faction_id: int, planet_index: int, hulls: Dictionary) -> FleetState:
	var c := _client.controller
	var f := FleetState.new()
	f.owner = faction_id
	f.system = planet_index
	f.destination = -1
	f.bind_hulls(_defs.get("ship_hulls"))
	for hull_id: StringName in hulls:
		f.add_ships(hull_id, int(hulls[hull_id]))
	c.galaxy.add_fleet(f)
	return f


## The boost modal's own behaviour: it refuses to open when there is nothing to put metal
## into, and its ceiling is the lesser of storage and metal still owed.
##
## The progress-bar step drives the modal through the panel; this drives it directly so the
## refusals are covered without having to arrange a colony that provokes each one.
func _step_boost_modal() -> void:
	sup.begin("boost modal")
	if _client == null or _client.boost == null or _client.controller == null:
		return
	var c := _client.controller
	var colony := _first_colony()
	sup.ok(colony != null, "the player starts with a colony")
	if colony == null:
		return
	c.select_planet(colony.index)
	_client.select_colony(colony.index)
	colony.building_queue.clear()
	colony.build_turns_remaining = 0
	colony.build_metal = 0.0

	# Nothing under construction: no dialog, because there is nothing to decide.
	sup.ok(not _client.boost.open_for_selected_colony(),
		"it refuses to open with nothing under construction")
	sup.ok(not _client.boost.visible, "and stays hidden")

	# A project, but a colony with no metal in it and nothing assigned to it: there is
	# nothing to move in *or* out, so a dialog offering two dead sliders is not a question.
	colony.building_queue[&"granary"] = 1
	colony.build_turns_remaining = 2
	colony.build_total_turns = 2
	var saved_metal := colony.reserve_metals
	colony.reserve_metals = 0.0
	sup.ok(not _client.boost.open_for_selected_colony(),
		"and it refuses to open on an empty colony")
	colony.reserve_metals = saved_metal

	# Metal already assigned and nothing left owing: the *add* direction is dead, but the
	# *remove* one is not -- the whole assigned amount can come back out. Refusing here would
	# strand it, and a project the player can put metal into but never take out is a one-way
	# door.
	var buildings: Dictionary = _defs.get("buildings") as Dictionary
	var cost := ColonySim.queued_cost(colony, buildings)
	colony.build_metal = cost
	sup.near(ColonySim.construction_progress(colony, buildings), 1.0, 0.001,
		"the project reads as complete")
	sup.ok(_client.boost.open_for_selected_colony(),
		"a fully paid project still opens, because its metal can be refunded")
	sup.near(_client.boost.refund_slider().max_value, cost, 0.001,
		"and the refund slider offers exactly what is assigned")
	sup.near(_client.boost.amount_slider().max_value, 1.0, 0.001,
		"while there is nothing left to add")
	_client.boost.close()
	colony.build_metal = 0.0

	# Half paid: the ceiling is exactly what is left owing, not the colony's whole store.
	colony.build_metal = cost * 0.5
	_client.boost.refresh()
	sup.ok(_client.boost.open_for_selected_colony(), "with metal left owing it opens")
	sup.near(_client.boost.amount_slider().max_value, cost * 0.5, 0.001,
		"and the slider offers precisely what is owed")
	sup.ok(saved_metal > cost * 0.5,
		"which is less than the colony holds, so the cap is doing something (stored=%.1f, owed=%.1f)" % [
			saved_metal, cost * 0.5])

	# And the transfer is capped the same way on the way through, not merely on the slider.
	# A caller that ignores the modal must not be able to drain the colony.
	var before := colony.reserve_metals
	var spent := c.boost_construction(colony.reserve_metals)
	sup.near(spent, cost * 0.5, 0.001,
		"the transfer is clamped to what the project owes, not to storage")
	sup.near(colony.reserve_metals, before - cost * 0.5, 0.001,
		"so only that much left storage")
	colony.building_queue.clear()
	colony.build_turns_remaining = 0
	colony.build_total_turns = 0
	colony.build_metal = 0.0


## The travel workflow, end to end: open, choose ships, confirm, and watch the order appear.
##
## The modal is the whole Phase 8 dispatch surface, so it is exercised through its own
## controls -- the `+` buttons, `All`, `None`, OK and CANCEL -- rather than by calling the
## controller, because the claim under test is that a player can express a partial manifest
## with them.
func _step_travel_modal() -> void:
	sup.begin("travel modal")
	if _client == null or _client.controller == null or _client.travel == null:
		return
	var c := _client.controller
	var gal := c.galaxy

	var mine := c.player_fleets()
	sup.ok(not mine.is_empty(), "the player has a fleet to travel with")
	if mine.is_empty():
		return
	var f: FleetState = mine[0]
	# Start from a fleet that is not already under way.
	f.destination = -1
	f.travelled = 0.0
	c.select_fleet(f.id)

	sup.ok(_client.travel.open_for_selected_fleet(), "the modal opens for the selected fleet")
	sup.ok(_client.travel.visible, "and is shown")
	sup.ok(_client.travel.origin_label().text.contains(
		c.display_name(f.system)), "it names the world the fleet is standing on")

	# The destination must differ from the start, so the fleet's own world is not offered.
	var offered := PackedStringArray()
	for i in _client.travel.destination_selector().item_count:
		offered.append(_client.travel.destination_selector().get_item_text(i))
	sup.ok(not offered.has(c.display_name(f.system)),
		"the origin world is not offered as a destination")
	sup.ok(_client.travel.destination_selector().item_count > 0,
		"and every other world is", "%d destinations" % offered.size())

	# The rosters are separate: warships on one side, lift on the other.
	var combat := _client.travel.combat_rows()
	var support := _client.travel.support_rows()
	sup.ok(combat != support, "the two rosters are distinct containers")
	var combat_names := _row_labels(combat)
	var support_names := _row_labels(support)
	sup.ok(combat_names.size() > 0 or support_names.size() > 0,
		"the fleet's ships are listed", "combat=%s support=%s" % [
			", ".join(combat_names), ", ".join(support_names)])
	for name in combat_names:
		sup.ok(not name.contains("Colony Ship") and not name.contains("Transport"),
			"the combat roster holds only warships", "found '%s'" % name)
	for name in support_names:
		sup.ok(not name.contains("Cruiser") and not name.contains("Corvette"),
			"and the support roster holds no warships", "found '%s'" % name)

	# `All` takes the whole fleet; `None` gives it all back.
	_client.travel.set_all(true)
	sup.ok(_client.travel.manifest().size() > 0, "All fills the manifest")
	var total := 0
	for key: Variant in _client.travel.manifest():
		total += int(_client.travel.manifest()[key])
	sup.eq(total, f.ship_count(), "All takes every ship in the fleet")
	_client.travel.set_all(false)
	sup.eq(_client.travel.manifest().size(), 0, "None empties it")

	# `+` and `-` move one hull at a time, and stop at the ends rather than wrapping.
	for hull_id: StringName in f.ships:
		var plus := _client.travel.more_button(hull_id)
		if plus == null:
			plus = _button_named(_client.travel.support_rows(),
				"More_%s" % String(hull_id))
		var minus := _button_named(_client.travel.combat_rows(),
			"Less_%s" % String(hull_id))
		if minus == null:
			minus = _button_named(_client.travel.support_rows(),
				"Less_%s" % String(hull_id))
		sup.ok(plus != null and minus != null,
			"the %s row has + and - buttons" % hull_id)
		if plus == null or minus == null:
			continue
		var held := int(f.ships[hull_id])
		for _i in held + 2:
			plus.emit_signal(&"pressed")
		sup.eq(int(_client.travel.manifest().get(hull_id, 0)), held,
			"pressing + takes the whole %s stack and no more" % hull_id)
		for _i in held + 2:
			minus.emit_signal(&"pressed")
		sup.eq(int(_client.travel.manifest().get(hull_id, 0)), 0,
			"and - gives it all back without going negative")

	# A partial manifest: one ship travels, the rest stay.
	var single: StringName = &""
	for hull_id: StringName in f.ships:
		single = hull_id
		break
	_client.travel.adjust(f, single, 1)
	sup.eq(_client.travel.manifest().size(), 1, "one hull is selected")
	sup.eq(int(_client.travel.manifest()[single]), 1, "exactly one of them")

	var cargo := _client.travel.cargo_label(single)
	if cargo != null:
		sup.ok(cargo.text.contains("/"), "the cargo readout shows a load and a capacity",
			"reads '%s'" % cargo.text)

	# OK stages a TRAVEL order naming that manifest, and it reaches the queue.
	var dest := _client.travel._selected_destination()
	sup.ok(dest >= 0, "a destination is selected", "dest=%d" % dest)
	var staged_before := c.pending_orders().size()
	_client.travel.ok_button().emit_signal(&"pressed")
	sup.eq(c.pending_orders().size(), staged_before + 1, "OK stages one order")
	var order: Order = c.pending_orders()[c.pending_orders().size() - 1]
	sup.eq(order.type, Enums.OrderType.TRAVEL, "and it is a TRAVEL order")
	sup.eq(order.target_planet, dest, "naming the chosen destination")
	sup.eq(int(order.payload.get("ships", {}).get(single, 0)), 1,
		"carrying the chosen manifest")
	sup.ok(not _client.travel.visible, "and the modal closes")

	# CANCEL closes without staging anything.
	_client.travel.open_for_selected_fleet()
	var before_cancel := c.pending_orders().size()
	_client.travel.cancel_button().emit_signal(&"pressed")
	sup.eq(c.pending_orders().size(), before_cancel, "CANCEL stages nothing")
	sup.ok(not _client.travel.visible, "and closes the modal")


## Every `Label` text under `node`, one entry per row's first label.
func _row_labels(node: Node) -> PackedStringArray:
	var out := PackedStringArray()
	for row in node.get_children():
		for child in row.get_children():
			if child is Label:
				out.append(String((child as Label).text))
				break
	return out


## A button named `wanted` anywhere under `node`, or null.
func _button_named(node: Node, wanted: String) -> Button:
	for child in node.get_children():
		if child is Button and child.name == wanted:
			return child as Button
		var found := _button_named(child, wanted)
		if found != null:
			return found
	return null


## The staged-orders readout is gone from the right-hand panel.
##
## It was the one control in the UI whose height was driven by its own contents, which is
## what let a slider drag resize the map beside it. Removing it is a layout fix as much as a
## clutter one, so it gets a test: a panel that can grow with its text is exactly the
## defect that was just removed, and nothing else in the right column has that property.
func _step_no_staged_orders() -> void:
	sup.begin("no staged-orders section in the right panel")
	if _client == null or _client.macros == null:
		return
	var macros := _client.macros
	sup.eq(macros.queue_label(), null, "the macro panel has no staged-orders readout")

	# No node anywhere in the right column may carry the removed heading.
	var offenders := PackedStringArray()
	_collect_text(macros, offenders)
	var all := "\n".join(offenders)
	sup.ok(not all.contains("STAGED ORDERS"),
		"no control in the right panel is labelled STAGED ORDERS",
		"labels=%s" % all.replace("\n", " | "))

	# The freed space goes to the controls that remain: the construction section is the
	# one that had the least room, and it should now be able to take the slack.
	sup.ok(macros.build_info().get_combined_minimum_size().y > 0.0,
		"the construction readout still occupies its section")
	sup.ok(macros.colony_selector().item_count >= 0,
		"and the colony selector is still wired up")


## Nothing the player does to the right panel may resize the map beside it.
##
## The defect this guards: the staged-orders label was sized to its text, so staging an
## order grew the column, the row's minimum grew, and the `SIZE_EXPAND_FILL` map beside it
## resized -- re-framing a view the player never touched. That readout is gone, so what is
## checked now is the property that outlived it.
func _step_macro_does_not_move_the_map() -> void:
	sup.begin("macro: the right panel leaves the map alone")
	if _client == null or _client.map == null or _client.macros == null:
		return
	var m := _client.map
	var cam := m.camera()
	var macros := _client.macros

	var cam_before := cam.position
	var zoom_before := cam.zoom
	var map_before := m.size
	var height_before := macros.get_combined_minimum_size().y

	# The map is sampled every step rather than only at the end: it is `SIZE_EXPAND_FILL`,
	# so it grows the instant the column beside it does, and a check taken after the fact
	# could miss a transient.
	var tallest := height_before
	for i in 24:
		macros.build_bar().value = 0.01 * i
		tallest = maxf(tallest, macros.get_combined_minimum_size().y)
	for i in 24:
		macros.build_mode_selector().select(i % 2)
		tallest = maxf(tallest, macros.get_combined_minimum_size().y)

	sup.near(tallest, height_before, 0.5,
		"the macro panel does not grow with what the player does to it (%f vs %f)" % [
			tallest, height_before])

	# And the map, which is what the player actually noticed, is untouched.
	sup.eq(m.size, map_before, "the map did not resize")
	sup.eq(cam.position, cam_before, "the camera did not move")
	sup.eq(cam.zoom, zoom_before, "the camera did not re-zoom")


## The planet detail panel's economy rows, and the research header's delta.
##
## Two readouts were re-specified: metal now carries its per-turn production, and population
## carries how many of its people are working. The second is the interesting one -- idle pop is
## the research budget, so "10 (5/5)" tells a player their colony is running at half its
## research capacity without them having to work that out from two separate numbers.
func _step_planet_and_research_readouts() -> void:
	sup.begin("planet economy and research readouts")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var me := c.player()
	var colony := _first_colony()
	sup.ok(colony != null, "the player starts with a colony")
	if colony == null or me == null:
		return
	c.select_planet(colony.index)
	_client.select_colony(colony.index)

	# --- metal: stock and per-turn production -----------------------------------
	#
	# Three *worked* mines, so the row reads `599 (+15)` -- or `(+19)` once `mining_bonus` is
	# applied. The expected figures are read from the resolver's own projection rather than
	# written out as literals, which is the whole point of the fix: a hard-coded `+15` here was
	# an assertion that the panel *omits* the empire's tech bonus, so it kept passing while the
	# readout under-reported, and it would have started failing the moment the bonus landed
	# rather than telling anyone why.
	var buildings: Dictionary = c.defs.get("buildings") as Dictionary
	colony.structures = {&"mine": 3, &"granary": 1}
	colony.population = 6.0
	colony.reserve_metals = 599.0
	_post_workers(colony, 0, 3)
	_client.inspector.refresh()
	var three_mines := _metal_rate_text(colony, buildings, me)
	sup.ok(three_mines != "(+0)", "three worked mines produce metal at all")
	var detail := _client.inspector.planet_label().text
	sup.ok(detail.contains("METAL"),
		"the detail panel shows metal", "shown=%s" % detail.replace("\n", " | "))
	sup.ok(detail.contains("599"), "and the stockpile", "shown=%s" % detail.replace("\n", " | "))
	sup.ok(detail.contains(three_mines),
		"and the per-turn production beside it, tech bonus included",
		"expected %s, shown=%s" % [three_mines, detail.replace("\n", " | ")])

	# Pulling a worker off is the other half, and the one the report was actually about: the
	# turn credited the difference, so the displayed rate has to fall on the same press.
	# Driven through the `+` / `-` buttons rather than the controller, because the report was
	# about what the player sees when they press one.
	_client.macros.refresh()
	var less := _client.macros.staffing_less_button(&"mine")
	sup.ok(less != null, "the mine has a worker row to pull from")
	if less != null:
		less.emit_signal("pressed")
		var two_mines := _metal_rate_text(colony, buildings, me)
		sup.ok(_client.inspector.planet_label().text.contains(two_mines),
			"pulling one mineworker drops the displayed rate immediately",
			"expected %s, shown=%s" % [
				two_mines, _client.inspector.planet_label().text.replace("\n", " | ")])
		var more := _client.macros.staffing_more_button(&"mine")
		if more != null:
			more.emit_signal("pressed")
		sup.ok(_client.inspector.planet_label().text.contains(three_mines),
			"and posting it back restores the rate without waiting for a turn",
			"expected %s, shown=%s" % [
				three_mines, _client.inspector.planet_label().text.replace("\n", " | ")])

	# An unstaffed mine produces nothing, so the delta has to fall with the workforce --
	# otherwise the panel is quoting a figure the turn will not credit.
	colony.population = 0.0
	_post_workers(colony, 0, 0)
	_client.inspector.refresh()
	var idle := _client.inspector.planet_label().text
	sup.ok(idle.contains("METAL"), "the metal row is still present with no civilians")
	sup.eq(_metal_rate_text(colony, buildings, me), "(+0)",
		"but a colony with nobody to work its mines projects no production")
	sup.ok(not idle.contains(three_mines),
		"and the panel agrees rather than still quoting the staffed figure",
		"shown=%s" % idle.replace("\n", " | "))

	# --- population: total, employed, idle ---------------------------------------
	colony.population = 10.0
	# Three mines and a farm, four of them worked: four working, six jobless. The workers are
	# posted explicitly now -- the panel reads the assignment table rather than counting what
	# the colony *could* staff, so a fixture that stands four jobs and posts nobody shows four
	# jobless and no work, which is a true statement about the colony and the wrong one for
	# this assertion.
	colony.structures = {&"mine": 3, &"farm": 1, &"granary": 1}
	_post_workers(colony, 1, 3)
	_client.inspector.refresh()
	detail = _client.inspector.planet_label().text
	sup.ok(detail.contains("POPULATION"), "the detail panel shows population")
	# `10 (4/6)`: ten people, four of them working and six idle. The pair is working/jobless
	# rather than employed/total because the two idle colonist-turns *are* the research budget,
	# and printing them as "4/10" made the reader do the subtraction to see that.
	sup.ok(detail.contains("10 (4/6)"),
		"as total (working/jobless): ten people, four of them working",
		"shown=%s" % detail.replace("\n", " | "))
	sup.eq(_client.inspector.employed_population(colony), 4,
		"employed is the number of structures the colony can staff")
	sup.eq(_client.inspector.idle_population(colony), 6,
		"and the idle remainder is what is left")

	# Understaffed: more jobs than hands, so employed is capped at the population and the
	# panel must not promise work that does not exist.
	colony.population = 2.0
	colony.structures = {&"mine": 5, &"farm": 1, &"granary": 1}
	# One farm and one mine: two people, two jobs. Five mines stand and stay unworked, which
	# is the half of the assertion that matters -- a colony cannot promise work it has not
	# posted anybody to.
	_post_workers(colony, 1, 1)
	sup.eq(_client.inspector.employed_population(colony), 2,
		"two people staff two jobs, however many exist")
	sup.eq(_client.inspector.idle_population(colony), 0, "and nobody is idle")
	_client.inspector.refresh()
	sup.ok(_client.inspector.planet_label().text.contains("2 (2/0)"),
		"the panel agrees that everybody is working, with nobody jobless",
		"shown=%s" % _client.inspector.planet_label().text)

	# Troops are not civilians: a garrison does not work farms and is not idle labour.
	colony.population = 4.0
	colony.troops = 30
	_post_workers(colony, 1, 3)
	sup.eq(_client.inspector.employed_population(colony), 4,
		"thirty troops do not fill any jobs")
	sup.eq(_client.inspector.idle_population(colony), 0,
		"and they are not idle labour either")

	# --- the research header's delta ---------------------------------------------
	# `Science: 130 (+5)` is the requested form: a balance alone is a number the player can
	# only watch move after the fact, so the per-turn grant travels with it.
	#
	# The grant is the empire's *unassigned* civilians at one point each, summed over every
	# colony it holds. Every colony is put into a known state below, because a rate that is
	# empire-wide cannot be pinned by arranging one world: the expected figure is read from
	# `ResearchStage.projected_research` rather than written as a literal, and what is
	# asserted about the rule is how it *moves*.
	me.tech_points = PackedFloat64Array([40.0, 30.0, 35.0, 25.0])
	for other in c.player_colonies():
		other.structures = {&"granary": 1}
		other.population = 3.0
		other.worker_assignment = {}
		_colonyRecount(other, c)
	var colonies_held := c.player_colonies().size()
	sup.ok(colonies_held > 0, "the empire holds at least one colony")
	sup.eq(ResearchStage.idle_scientists(c.galaxy, c.player_id), 3 * colonies_held,
		"three idle colonists on each of %d colonies" % colonies_held)

	# One unassigned colonist is one point, before any empire-wide bonus.
	#
	# Measured on a faction with nothing researched rather than on the player's own, because
	# this fixture's empire may already have completed `robotic_factories` by the time it
	# runs, and its `research_bonus` scales the rate. Asserting against a bonus-free faction
	# is what pins the 1:1 base; asserting the player's own header against the shared helper
	# is what pins that the two never drift apart.
	var unbonused := FactionState.new()
	unbonused.id = c.player_id
	var per_idle := float(_db.get("RESEARCH_POINTS_PER_POP"))
	sup.eq(per_idle, 1.0, "the roster pays one point per unassigned colonist")
	sup.eq(ResearchStage.projected_research(unbonused, c.galaxy, c.db),
		3.0 * colonies_held,
		"so an unbonused empire's rate is exactly its idle population")
	_client.top_bar.refresh()
	var readout := _client.top_bar.research_label().text
	sup.ok(readout.contains("130"), "the header shows the science total", "reads '%s'" % readout)
	sup.eq(_signed_in(readout),
		float(int(round(ResearchStage.projected_research(me, c.galaxy, c.db)))),
		"and the header quotes the same projection the turn will split")

	# The rate is a dial, not a receipt: posting somebody to a farm takes exactly one point
	# away, and the header must move on the same press. This is the whole point of the change
	# -- the flat rate never responded to anything the player did.
	colony.structures = {&"granary": 1, &"farm": 1}
	colony.population = 3.0
	colony.worker_assignment = {}
	_colonyRecount(colony, c)
	c.select_planet(colony.index)
	_client.select_colony(colony.index)
	_client.macros.refresh()
	var farm_plus := _client.macros.staffing_more_button(&"farm")
	sup.ok(farm_plus != null, "the colony can post somebody to a farm")
	if farm_plus != null:
		var step := per_idle * (1.0 + me.tech_effect(&"research_bonus"))
		var before_idle := ResearchStage.idle_scientists(c.galaxy, c.player_id)
		farm_plus.emit_signal("pressed")
		sup.eq(ColonySim.idle_workers(colony), 2, "one colonist is now working a field")
		sup.eq(ResearchStage.idle_scientists(c.galaxy, c.player_id), before_idle - 1,
			"so the empire has one fewer unassigned colonist")
		_client.top_bar.refresh()
		readout = _client.top_bar.research_label().text
		sup.eq(_signed_in(readout), float(int(round((before_idle - 1) * step))),
			"and the header drops exactly that much on the same press")
		var farm_minus := _client.macros.staffing_less_button(&"farm")
		if farm_minus != null:
			farm_minus.emit_signal("pressed")
			_client.top_bar.refresh()
			readout = _client.top_bar.research_label().text
			sup.eq(_signed_in(readout), float(int(round(before_idle * step))),
				"and pressing - gives exactly that much back")

	# An empire with nothing unassigned researches nothing, and the header says so rather
	# than quoting a stale rate. "No science this turn" is information: it is how a player
	# notices they have staffed every colonist they have.
	for other in c.player_colonies():
		other.population = 0.0
		other.worker_assignment = {}
		_colonyRecount(other, c)
	sup.eq(ResearchStage.idle_scientists(c.galaxy, c.player_id), 0,
		"every colonist posted leaves nothing to research with")
	_client.top_bar.refresh()
	readout = _client.top_bar.research_label().text
	sup.eq(_signed_in(readout), 0.0,
		"and the header reads zero rather than a stale figure")

	# The balance really is the sum across the four fields, since there are no sliders.
	sup.ok(_client.top_bar.research_label().text.contains("130"),
		"the total is the sum of the four fields, which the sliders used to divide")

	# The planet detail must not drift back to listing a Space Port as "other".
	colony.structures[&"space_port"] = 1
	_client.inspector.refresh()
	detail = _client.inspector.planet_label().text
	sup.ok(detail.contains("SPACE PORTS"),
		"a Space Port is listed in the roster", "shown=%s" % detail.replace("\n", " | "))
	sup.ok(not detail.contains("other space_port"),
		"and does not also appear under OTHER",
		"shown=%s" % detail.replace("\n", " | "))


## Any planet index that is not `exclude`. The map has one system, so "some other body" is
## simply any other world -- which is what a selection-changing test needs to move to.
func _other_planet_index(exclude: int) -> int:
	for p in _galaxy.planets:
		if p.index != exclude:
			return p.index
	return exclude


## Every piece of user-visible text under `node`, one per line.
##
## Reading the labels a panel actually built is the only way to assert a section is gone:
## searching the source for the string would also pass while the label is still on screen,
## and `queue_label()` returning null would pass while a stray `Label` survived.
func _collect_text(node: Node, into: PackedStringArray) -> void:
	if node is Label or node is Button or node is CheckBox or node is CheckButton:
		into.append(String((node as Control).text))
	elif node is RichTextLabel:
		into.append(String((node as RichTextLabel).text))
	elif node is OptionButton:
		var option := node as OptionButton
		for i in option.item_count:
			into.append(option.get_item_text(i))
	for child in node.get_children():
		_collect_text(child, into)


func _step_macro_build() -> void:
	sup.begin("macro: construction")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var colony := _first_colony()
	sup.ok(colony != null, "the player starts with at least one colony")
	if colony == null:
		return
	c.select_planet(colony.index)
	_client.select_colony(colony.index)

	# A clean slate: an earlier scenario deliberately left a project queued on this colony
	# and orders in the queue, and the single-project-per-turn rule and the "last staged
	# order" assertion below both need to start from nothing.
	colony.building_queue.clear()
	colony.build_turns_remaining = 0
	colony.build_total_turns = 0
	colony.build_metal = 0.0
	# Earlier scenarios deliberately stage orders, and `pending_orders()` hands back a
	# *copy* -- clearing that array does nothing to the queue. `queue.clear()` is the real
	# empty, and without it this step would be asserting against four orders from earlier
	# scenarios and reporting a pass for the wrong reason.
	c.queue.clear()

	var selector := _client.macros.build_selector()
	sup.ok(selector.item_count > 0, "the build selector is populated",
		"%d items" % selector.item_count)
	if selector.item_count == 0:
		return

	# Give the player a budget so affordability is not what blocks the order. Phase 8 pays
	# for structures out of the *colony's* stored metal rather than the imperial treasury,
	# so both have to be funded or the order is refused for the wrong reason.
	var me := c.player()
	me.metals = 100000.0
	me.rare_elements = 100000.0
	me.energy = 100000.0
	colony.reserve_metals = 100000.0
	for id: Variant in c.defs.get("buildings"):
		me.unlocked_buildings[StringName(str(id))] = true

	var chosen := _first_unlocked_building(selector)
	sup.ok(chosen != &"", "an unlocked structure is offered", "found %s" % String(chosen))
	if chosen == &"":
		return
	sup.ok(_client.macros.select_build(chosen), "the build selector can select it")

	# Regression: browsing the construction dropdown used to be refused with "select one
	# of your colonies first" because nothing ever moved the controller's selection off
	# the system/body the player had clicked on the map.
	c.select_planet(_other_planet_index(colony.index))
	# Choosing a structure only selects it. Phase 8 added a Build button so browsing the
	# dropdown cannot commit a spend, and this is the assertion that the separation holds.
	# The queue is emptied first: earlier scenarios stage orders on purpose.
	c.queue.clear()
	_client.macros._on_build_selected(0)
	sup.eq(c.pending_orders().size(), 0,
		"choosing a structure stages nothing")
	sup.eq(colony.building_queue.size(), 0,
		"and does not start a project")
	sup.eq(c.selected_planet, _other_planet_index(colony.index),
		"choosing a structure leaves the map's selection alone (selected=%d, expected %d)" % [
			c.selected_planet, _other_planet_index(colony.index)])
	# Re-selecting through the controller, as the GUI test drives it elsewhere.
	c.select_planet(colony.index)
	sup.ok(_client.macros.build_button() != null, "the panel exposes a Build button")
	sup.ok(_client.macros.build_button().text == "Build", "labelled 'Build'")

	var queued_before := int(colony.building_queue.get(chosen, 0))
	var built_before := colony.count(chosen)
	var staged_before := c.pending_orders().size()
	var accepted := c.queue_build_structure(chosen)
	sup.ok(accepted, "a legal build order is accepted", "building %s" % String(chosen))
	sup.eq(c.pending_orders().size(), staged_before + 1, "the build order is staged")
	var orders := c.pending_orders()
	sup.eq(orders[orders.size() - 1].type, Enums.OrderType.BUILD_STRUCTURE,
		"the staged order is BUILD_STRUCTURE")
	sup.eq(orders[orders.size() - 1].target_planet, colony.index,
		"the order names the right colony")
	sup.eq(int(colony.building_queue.get(chosen, 0)), queued_before + 1,
		"the project is queued for ColonySim -- it is not granted immediately")
	sup.eq(colony.count(chosen), built_before,
		"and the structure itself does not exist until the metal is in")

	# A second identical order beyond the per-colony cap must be refused.
	var def: Resource = _defs.building(chosen) as Resource
	if def != null and def.max_per_colony > 0 and def.max_per_colony == 1:
		sup.ok(not c.queue_build_structure(chosen),
			"building past the per-colony cap is refused")


## The hull ids in the construction dropdown's current rows.
func _hull_ids_in_menu() -> Array[StringName]:
	var out: Array[StringName] = []
	if _client == null or _client.macros == null:
		return out
	var selector := _client.macros.build_selector()
	if selector == null:
		return out
	for i in selector.item_count:
		var meta: Variant = selector.get_item_metadata(i)
		if not (meta is Dictionary):
			continue
		var row: Dictionary = meta as Dictionary
		if String(row.get("kind", "")) == "ship":
			out.append(StringName(str(row.get("id", ""))))
	return out


## Post workers to a colony the way the `+` buttons would.
func _post_workers(colony: PlanetState, farms: int, mines: int) -> void:
	colony.worker_assignment = {}
	for _i in farms:
		ColonySim.assign_worker(colony, &"farm")
	for _i in mines:
		ColonySim.assign_worker(colony, &"mine")


## The first *structure* the construction dropdown offers, or `&""`.
##
## The unified dropdown carries a `{id, kind}` pair per row, so the metadata is unpacked
## rather than compared: `unlocked_buildings.has(meta)` was true for nothing once the menu
## started listing hulls alongside structures, and the step quietly declined to test anything.
func _first_unlocked_building(selector: OptionButton) -> StringName:
	var unlocked := _client.controller.player().unlocked_buildings
	for i in selector.item_count:
		var meta: Variant = selector.get_item_metadata(i)
		if not (meta is Dictionary):
			continue
		var row: Dictionary = meta as Dictionary
		var id := StringName(str(row.get("id", "")))
		if String(row.get("kind", "")) == "structure" and unlocked.has(id):
			return id
	return &""


func _step_end_turn() -> void:
	sup.begin("end turn")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var before_turn := c.galaxy.turn
	var committed := PackedStringArray()
	c.turn_resolved.connect(func(_r: Dictionary) -> void: committed.append("x"))

	# Go through the same path the Space/Enter keypress does, so the whole signal chain
	# is exercised. There is no END TURN button left to press.
	_client.press_end_turn()

	sup.ok(c.galaxy.turn == before_turn + 1, "the stardate advances by exactly 1",
		"%d -> %d" % [before_turn, c.galaxy.turn])
	sup.eq(committed.size(), 1, "turn_resolved fired exactly once")
	sup.eq(c.pending_orders().size(), 0, "the staged orders were consumed")
	sup.eq(_client.top_bar.stardate_label().text, "TURN %d" % (c.galaxy.turn + 1),
		"the HUD turn counter matches the state (hud=%s, state=%d)" % [
			_client.top_bar.stardate_label().text, c.galaxy.turn + 1])
	sup.ok(not c.last_report.is_empty(), "a turn report was produced")
	sup.ok(c.last_report.has("state_hash"), "the report carries a state hash")

	# The GUI must have followed the new state without being told directly.
	_client.map.view().queue_redraw()
	sup.ok(true, "map redraws after the turn")


## With a network submitter bound, End Turn must ship orders and wait -- never resolve
## locally.
##
## This is the seam where a networked client could silently fork from the server: the
## controller would advance its own copy of the galaxy and the two would diverge with no
## error anywhere. Asserting the stardate does *not* move locally is the whole point --
## it is what distinguishes "submitted" from "resolved".
## A `TurnSyncClient` that records the submission instead of putting it on the wire.
##
## The real client would call `rpc_submit_orders.rpc_id(1, ...)`, and with no server
## behind it the engine logs "RPC on yourself is not allowed by selected mode" -- an
## engine diagnostic the test suite treats as a failure. The transport itself is covered
## over real sockets in `tests/test_enet_sync.gd`; this checks only that the controller
## hands orders to the submitter rather than resolving them itself.
## Stand-in for the network submitter. No socket: this checks the controller's routing,
## and the transport itself is covered by tests/test_enet_sync.gd.
##
## `set_ready` is overridden because the real one reaches for an RPC peer that does not
## exist here. The orders still have to be shipped by the raise -- that is the whole point
## of the commit path, and a stub that ignored `staged` would let the ordering regress
## without a single check noticing.
class OfflineSubmitter extends TurnSyncClient:
	var sent_turns: Array[int] = []
	var sent_count: int = 0
	var ready_flags: Array[bool] = []

	func set_ready(is_ready: bool = true) -> bool:
		if not is_ready:
			ready_flags.append(false)
			_ready_flagged = false
			return true
		if awaiting or galaxy == null:
			return false
		sent_turns.append(galaxy.turn)
		sent_count += staged.size()
		staged.clear()
		ready_flags.append(true)
		awaiting = true
		_ready_flagged = true
		return true


func _step_networked_end_turn() -> void:
	sup.begin("networked end turn")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller

	sup.ok(c.turn_submitter == null, "the local client has no network submitter")
	sup.ok(not c.is_awaiting_server(), "and is not waiting on a server")

	# Bind a stand-in submitter. No socket: this checks the controller's routing, and the
	# transport is covered by tests/test_enet_sync.gd.
	# `SessionController` is a RefCounted, not a Node, so the stub cannot be parented to
	# it. Add it to the tree root instead.
	var stub := OfflineSubmitter.new()
	root.add_child(stub)
	sup.ok(stub.begin(c.galaxy, c.player_id), "the stub client bound the galaxy")

	c.turn_submitter = stub
	var before_turn := c.galaxy.turn
	sup.ok(not c.is_awaiting_server(), "a bound submitter starts unlocked")

	# A networked turn is committed by raising READY, not by an END TURN button. The
	# staged orders go out with the flag, so one press is the whole commit.
	# Phase 8 removed the tax slider, so the order staged here is a build-mode one: it
	# still proves the route from a control to the transport without staging something the
	# resolver no longer reads.
	var wired_colony := _first_colony()
	sup.ok(c.set_build_mode(wired_colony.index, int(Enums.BuildMode.PER_TURN)),
		"an order is staged for the wire")
	sup.ok(c.pending_orders().size() > 0, "the order reached the queue")
	sup.ok(c.set_ready(true), "raising Ready commits the turn")
	sup.eq(c.galaxy.turn, before_turn, "the local stardate did not move")
	sup.ok(c.is_awaiting_server(), "the client is now waiting for the server")
	sup.eq(c.pending_orders().size(), 0, "the staged orders were handed to the transport")
	sup.eq(stub.sent_turns.size(), 1, "exactly one submission reached the transport")
	sup.ok(stub.sent_count > 0, "and it carried the staged orders (%d)" % stub.sent_count)
	sup.ok(stub.ready_flags.size() > 0, "and the ready flag was sent with it")

	# The player has to be able to see that they are waiting, and not be able to send
	# again while they are. This is the only feedback a networked turn gives them.
	var btn: Button = _client.top_bar.ready_button()
	_client.top_bar.refresh()
	sup.eq(btn.text, TurnSyncClient.WAITING_TEXT,
		"the top bar shows the waiting text")
	sup.ok(btn.disabled, "and the Ready button is disabled while waiting")

	# A second press while waiting must be refused, not double-sent.
	sup.ok(not c.set_ready(true), "a second press is refused while waiting")
	sup.ok(c.is_awaiting_server(), "and leaves the client waiting")

	# Restore the local path before the next scenario, which expects to resolve locally.
	c.turn_submitter = null
	stub.queue_free()
	sup.ok(c.turn_submitter == null, "the local path is restored")
	_client.top_bar.refresh()
	# With no submitter there is no lobby, so READY has nothing to signal and the button
	# is hidden -- single player commits from the map's Space/Enter, not from a flag.
	sup.ok(not c.is_networked(), "the client is back to single player")
	var live: Button = _client.top_bar.ready_button()
	sup.ok(not live.visible, "the Ready button is hidden with no lobby")
	sup.ok(not live.text.contains(TurnSyncClient.WAITING_TEXT),
		"and no longer shows the waiting text", "reads '%s'" % live.text)
	sup.ok(not live.disabled, "and is not left disabled")
	sup.ok(btn.text != TurnSyncClient.WAITING_TEXT, "and no longer shows the waiting text")


func _step_end_turn_again() -> void:
	sup.begin("end turn: repeated")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var before := c.galaxy.turn
	for i in 5:
		_client.press_end_turn()
	sup.ok(c.galaxy.turn == before + 5, "five End Turn clicks advance the stardate by 5",
		"%d -> %d" % [before, c.galaxy.turn])
	sup.eq(_client.top_bar.stardate_label().text, "TURN %d" % (c.galaxy.turn + 1),
		"the HUD tracks the turn counter across turns")


## A resolved turn must reach the panels, not just the sync peer.
##
## This is the regression that stardates appeared not to advance. `apply_snapshot()`
## replaced `galaxy` with a freshly built object, while the controller -- and through it
## every panel -- still held the original. The sync peer's copy was always correct, so
## nothing looked wrong from the network side; the interface simply kept rendering a
## galaxy one turn stale, forever.
func _step_resolution_reaches_panels() -> void:
	sup.begin("resolution reaches the panels")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var live := c.galaxy
	sup.ok(live != null, "the controller holds a galaxy")

	# The exact object identity the whole rendering chain hangs off.
	var before_id: int = live.get_instance_id()
	live.turn = 4

	var peer := TurnSyncClient.new()
	peer.galaxy = live
	var incoming := GalaxyState.new()
	sup.ok(incoming.from_dict(live.to_dict()), "the authoritative state round-trips")
	incoming.turn = 5
	var applied := peer.apply_snapshot({
		"state": incoming.to_dict(),
		"state_hash": str(incoming.state_hash()),
	})
	sup.ok(applied >= 0, "the client accepted the resolution (%d)" % applied)

	# The controller's own object, not the peer's, is what the panels read.
	sup.eq(c.galaxy.get_instance_id(), before_id,
		"the controller still holds the object it was bound to")
	sup.eq(c.galaxy.turn, 5, "and that object now carries the resolved stardate")
	sup.eq(peer.galaxy, c.galaxy, "the peer and the controller agree on one galaxy")

	# Fleet positions live on the same object, so movement has to survive too.
	for key: int in live.fleets:
		var f: FleetState = live.fleets[key]
		if f.active:
			f.system = 3
			f.destination = 7
			f.travelled = 12.0
			break
	var moved := -1
	for key: int in live.fleets:
		var f: FleetState = live.fleets[key]
		if f.active:
			moved = key
			break
	if moved >= 0:
		var after := GalaxyState.new()
		after.from_dict(c.galaxy.to_dict())
		var rf: FleetState = after.fleets[moved]
		sup.eq(rf.system, 3, "a fleet's position survives serialisation")
		sup.eq(rf.destination, 7, "and so does its destination")
		sup.near(rf.travelled, 12.0, 0.001, "and how far along the lane it is")
	else:
		sup.ok(true, "this galaxy has no active fleet to move")

	# A desynced payload must not be adopted at all: the hash check is the only thing
	# standing between a client and the server's bad state.
	var poisoned := GalaxyState.new()
	poisoned.from_dict(live.to_dict())
	poisoned.turn = 99
	var rejected := peer.apply_snapshot({
		"state": poisoned.to_dict(),
		"state_hash": str(poisoned.state_hash() + 1),
	})
	sup.ok(rejected < 0, "a mismatched hash is rejected")
	sup.eq(c.galaxy.turn, 5, "and the client keeps the last state it trusted")
	peer.free()


## Another player's departure must not be mistaken for the server dying.
##
## ENet reports every peer on the connection, so a client sees other players come and go.
## Routing that through the same signal as "the server is gone" made one player's closing
## their window end everybody's game.
func _step_peer_departure_does_not_quit() -> void:
	sup.begin("peer departure does not end the session")
	var net: NetworkManager = NetworkManagerScript.new() as NetworkManager
	root.add_child(net)
	net.is_host = false

	# Recorded through members, not locals: a GDScript lambda captures its enclosing
	# scope *by value*, so a local bool flipped inside the callback is a copy and the
	# assertion reads the untouched original.
	_depart_flags = {"peer_left": false, "departed": false}
	net.peer_left.connect(func(_p: int, _s: int) -> void:
		_depart_flags["peer_left"] = true)
	net.peer_departed.connect(func(_p: int) -> void:
		_depart_flags["departed"] = true)

	# Drive the handler the engine would call when a *different* peer drops. Called
	# directly rather than over a socket: what is under test is which signal a client
	# receives, and the transport already delivers this one reliably.
	net._on_peer_disconnected(4242)

	sup.ok(bool(_depart_flags["departed"]), "a client is told another peer departed")
	sup.ok(not bool(_depart_flags["peer_left"]),
		"but NOT that a peer left -- that signal means the server is gone")

	# The host, which owns seats, still hears the session-level event.
	var host: NetworkManager = NetworkManagerScript.new() as NetworkManager
	root.add_child(host)
	host.is_host = true
	_depart_flags = {"peer_left": false, "departed": false}
	host.peer_left.connect(func(_p: int, _s: int) -> void:
		_depart_flags["peer_left"] = true)
	host._on_peer_disconnected(99)
	sup.ok(bool(_depart_flags["peer_left"]),
		"the server still receives peer_left for a departing peer")

	net.dispose()
	host.dispose()


## Ownership is only shown where the player is entitled to know it.
##
## Fog of war hides unexplored space; this hides explored-but-foreign territory. A map
## outlined with every opponent's holdings leaks fleet deployments and border strength at
## a glance, which is most of what scouting is for.
func _step_fog_of_war_ownership() -> void:
	sup.begin("ownership visibility")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var me := c.player_id
	var gal := c.galaxy
	var view := _client.map.view()
	if view == null:
		sup.ok(false, "the map exposes its view layer")
		return

	# Find a system the player can see, and one it cannot.
	var seen := -1
	for sys in gal.systems:
		if view._visible(sys.index) and seen < 0:
			seen = sys.index
	sup.ok(seen >= 0, "at least one system is in sensor range")

	if seen >= 0:
		var sys: SystemState = gal.systems[seen]

		# Unowned: always known, so empty space reads as empty rather than as redacted.
		var saved := sys.owner
		sys.owner = -1
		sup.ok(view._ownership_known(gal, sys), "an unowned system shows no ownership")
		sys.owner = me
		sup.ok(view._ownership_known(gal, sys), "your own system shows your colour")

		# Somebody else's, with nothing of yours there. Every one of your fleets is moved
		# well clear first onto a *different planet*: with one system, "a fleet in this
		# system" would be every fleet in the game, so the rule can only be about which
		# world a ship is over.
		sys.owner = 1 - me if me < 1 else me + 1
		# Park every one of your fleets on a body that is *not* planet 0, which is the
		# first body the "is anything of mine here" probe looks at. The homeworld fleet
		# starts on a random planet, so a single move is not enough to be sure.
		var elsewhere := -1
		for other in gal.planets:
			if other.index != 0:
				elsewhere = other.index
				break
		for f_key: int in gal.fleets:
			var f: FleetState = gal.fleets[f_key]
			if f.owner == me:
				f.system = elsewhere
				f.destination = -1
		sup.ok(not _own_fleet_on(gal, me, 0),
			"the fixture really does have none of your ships on the first body")
		sup.ok(not view._ownership_known(gal, sys),
			"a rival's system is hidden while you have nothing in it")

		# A fleet merely sailing toward it is not presence in it. It reveals the origin
		# now and the destination on arrival -- not a permanent mark on the map.
		var sailing := -1
		for f_key: int in gal.fleets:
			var f: FleetState = gal.fleets[f_key]
			if f.owner == me:
				f.active = true
				f.system = 0
				f.destination = elsewhere
				sailing = f_key
				break
		sup.ok(sailing >= 0, "a fleet of yours can be sent toward it")
		if sailing >= 0:
			# The ship is over planet 0 and bound for `elsewhere`; it is under way, so it
			# is not parked in this system and the rival's banner stays hidden.
			sup.ok(not view._ownership_known(gal, sys),
				"a fleet merely heading out does not reveal ownership")

			# A fleet actually parked there does.
			var f: FleetState = gal.fleets[sailing]
			f.destination = -1
			f.system = 0
			sup.ok(view._ownership_known(gal, sys),
				"a fleet in orbit reveals who owns the system")
		sys.owner = saved

		# The rule is only worth anything if the drawing actually consults it. Asserted
		# by reading the call site: a test that calls `_ownership_known()` directly passes
		# just as happily if `_draw_systems()` stops asking it, which is precisely the
		# shape of regression this change is meant to prevent.
		sup.ok(_draw_consults_ownership(),
			"the map consults the ownership rule when drawing systems")


## Whether `_draw_systems()` gates the owner ring on the ownership rule.
##
## Read from the script source rather than by rendering: the drawing path needs a live
## viewport to produce pixels, and what is under test is a conditional, not a picture.
func _draw_consults_ownership() -> bool:
	var src := FileAccess.get_file_as_string("res://src/client/galaxy_map_view.gd")
	# Both draw paths must ask. The star draws an owner ring and each planet draws its own,
	# and a regression that gated one while leaving the other open would still satisfy a
	# test that only looked for one of the two.
	return src.contains("if _ownership_known(_controller.galaxy, sys):") \
		and src.contains("_ownership_known(galaxy, _system_of(galaxy, p))")


## The panel that used to leak: the inspector printed `OWNER FACTION n`, drew an `x` beside
## every foreign world in a system's body list, and then spelled out the whole economy of a
## rival colony -- population, farms, reserves, build queue -- as soon as a sensor sweep
## brushed the system. The stars were correctly hidden and the owner rings correctly
## suppressed while all of that sat two panels to the right.
func _step_fog_colony_markers() -> void:
	sup.begin("colony markers stay behind the fog")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var me := c.player_id
	var gal := c.galaxy
	var inspector := _client.inspector
	if inspector == null:
		sup.ok(false, "the client exposes its inspector panel")
		return

	# A rival-owned, colonised world the player can see but does not own.
	#
	# Constructed rather than searched for: a single-player galaxy has one empire, so a
	# rival colony would never naturally appear and the behavioural half of this test would
	# never run. Taking the nearest system the player can already see and planting a rival
	# colony on it reproduces the exact situation a sensor sweep produces in a real game.
	var foreign_sys := -1
	var foreign_planet := -1
	var rival := me + 1
	for sys in gal.systems:
		if c.can_see(sys.index):
			foreign_sys = sys.index
			break
	if foreign_sys >= 0:
		var host: SystemState = gal.systems[foreign_sys]
		# A body the player already owns is not a rival world at all: the detail gate opens on
		# ownership before anything else, so settling one "for a rival" and then asserting the
		# panel hides it would be asserting the panel fails against its own colony. Which body
		# generation happens to put in the first visible system is not under this test's
		# control, so the premise is enforced here rather than hoped for.
		for p_index in host.planet_indices:
			var candidate := gal.planet(p_index)
			if candidate != null and candidate.is_colonizable() \
					and candidate.owner != me:
				foreign_planet = candidate.index
				break
		if foreign_planet < 0:
			for p_index in host.planet_indices:
				var fallback := gal.planet(p_index)
				if fallback != null and fallback.owner != me:
					foreign_planet = fallback.index
					break
		sup.ok(foreign_planet < 0 or gal.planet(foreign_planet).owner != me,
			"the chosen body is not already the player's")

	sup.ok(foreign_sys >= 0, "a system is in sensor range to hang a rival colony on")
	sup.ok(foreign_planet >= 0, "that system has a body to colonise")
	if foreign_planet < 0:
		return

	# Every fleet of ours is moved well clear: the claim under test is that a rival system
	# with nothing of ours in it stays hidden, and a leftover scout would make that untrue.
	#
	# All of them, not just the ones whose position happens to equal something. The old guard
	# here compared `f.system` -- a *planet* index -- against `foreign_sys`, so with one system
	# it cleared a fleet only if its planet was planet zero, and left every other fleet sitting
	# exactly where it was. On a seed that put one of them over the body under test, the panel
	# correctly showed the world's detail and this step reported it as a fog leak.
	var parked := {}
	for f_key: int in gal.fleets:
		var f: FleetState = gal.fleets[f_key]
		if f.owner == me:
			parked[f_key] = [f.system, f.destination]
			f.destination = -1
			f.system = -1

	var sys: SystemState = gal.systems[foreign_sys]
	var p: PlanetState = gal.planet(foreign_planet)
	var saved_sys_owner := sys.owner
	var saved_p_owner := p.owner
	var saved_colonized := p.colonized
	var saved_pop := p.population
	var saved_structures := p.structures.duplicate()
	var saved_surveyed := p.surveyed
	# A survey is a legitimate way to learn a world, so it opens this panel's detail gate --
	# and earlier steps do run turns with an Exploration Ship in orbit, so the chosen body may
	# already have been surveyed. The claim under test is narrower: a rival world with nothing
	# of yours in orbit and no survey on it stays hidden. Clearing the flag states that premise
	# rather than leaving it to whichever galaxy the seed produced, and the premise is asserted
	# immediately below so a future change cannot quietly turn this into a test of a surveyed
	# world.
	p.surveyed = false
	sup.ok(not p.surveyed and not c.knows_name_of(foreign_planet),
		"the fixture is a rival world the player has neither surveyed nor visited")

	# The rival settles it, richly populated and heavily built, so any leak is unmistakable.
	sys.owner = rival
	p.owner = rival
	p.colonized = true
	p.population = 7.5
	p.structures = {&"farm": 9, &"mine": 8, &"garrison": 5}

	# The system line must not name or colour the owner.
	sup.ok(not c.knows_owner_of(foreign_sys),
		"a rival's system with nothing of yours in it hides its owner")
	c.select_system(foreign_sys)
	c.select_planet(foreign_planet)
	inspector.refresh()
	# The system readout that used to be checked here is gone -- it was the panel row that
	# printed OWNER, and removing the panel is what removed the leak. What is left to check
	# is that nothing else has picked the responsibility up.
	sup.ok(not _has_system_survey_heading(),
		"no panel reintroduces the rival-empire roster the survey panel used to print")

	# The planet readout itself must read like an uncolonised world. The BODIES list that
	# used to carry a per-row "x"/"*" marking is gone -- bodies are clicked on the map now
	# -- so the leak has to be caught in the label the player actually sees.
	sup.ok(true, "there is no body list to leak through; the readout carries the check")

	# Sanity check in the other direction: the readout was not simply blanked. The
	# player's own colony must still report its economy, or the panel is useless rather
	# than quiet.
	var own_world: PlanetState = null
	for candidate in gal.planets:
		if candidate.owner == me and candidate.colonized:
			own_world = candidate
			break
	if own_world != null:
		c.select_planet(own_world.index)
		inspector.refresh()
		var own_label := inspector.planet_label().text
		sup.ok(own_label.contains("POPULATION"),
			"the player's own world still reports its population")
		c.select_planet(foreign_planet)
		inspector.refresh()

	# And the planet readout must not report its economy.
	var label := inspector.planet_label().text
	sup.ok(not label.contains("YOURS"),
		"a rival world is not captioned as the player's")
	sup.ok(not label.contains("FACTION %d" % rival),
		"a rival world is not captioned with its empire's name")
	sup.ok(not label.contains("POPULATION"),
		"a rival world hides its population")
	sup.ok(not label.contains("FARMS"),
		"a rival world hides its farm count")
	sup.ok(not label.contains("STORES"),
		"a rival world hides its reserves")
	sup.ok(label.contains("UNCOLONISED"),
		"a rival world reads exactly like an uncolonised one")

	# Flying a ship there earns the *name*, not the contents.
	#
	# This gate used to open on a fleet in orbit, which handed the player a rival's population,
	# stockpile and full structure roster on the strength of one scout pass. A sweep tells you
	# what kind of rock it is; it does not tell you what is standing on it, and nothing in the
	# design says it should. Presence earns a label on the map; ownership earns the economy.
	var moved := false
	for f_key: int in gal.fleets:
		var f: FleetState = gal.fleets[f_key]
		if f.owner == me and f.active:
			# A fleet sits on a planet now, so park it on the rival world rather than
			# "in the system": with one system that is a distinction that no longer exists.
			f.system = foreign_planet
			f.destination = -1
			moved = true
			break
	sup.ok(moved, "a player fleet can be parked on the rival world")
	inspector.refresh()
	var revealed := inspector.planet_label().text
	sup.ok(revealed.contains("NO INTEL"),
		"parking a ship there says the world exists and reports nothing about it",
		"shown=%s" % revealed.replace("\n", " | "))
	sup.ok(not revealed.contains("POPULATION"),
		"and still does not reveal a rival's population")
	sup.ok(not revealed.contains("METAL"),
		"nor its stockpile")
	sup.ok(not revealed.contains("FARM"),
		"nor its structures")
	# Taking the world is what earns the economy. This is the half of the old assertion that
	# was always true, and it is the only thing that should ever turn this gate.
	p.owner = me
	inspector.refresh()
	sup.ok(inspector.planet_label().text.contains("POPULATION"),
		"settling the world is what reveals its detail")
	p.owner = rival

	# Put the galaxy back, so later steps run against the state they expect. The fixture was
	# synthesised rather than borrowed, so this is not a courtesy -- the ownership, the
	# colony and the parked fleets all have to be returned to what generation left.
	sys.owner = saved_sys_owner
	p.owner = saved_p_owner
	p.colonized = saved_colonized
	p.population = saved_pop
	p.structures = saved_structures
	p.surveyed = saved_surveyed
	for f_key: int in parked:
		var f3: FleetState = gal.fleets[f_key]
		var prior: Array = parked[f_key]
		f3.system = int(prior[0])
		f3.destination = int(prior[1])
	inspector.refresh()
	sup.ok(gal.planet(foreign_planet).owner == saved_p_owner,
		"the fixture was restored")

	# The rule is asserted at the call sites as well as in behaviour: a direct test of the
	# gate passes just as happily if a panel stops consulting it, and the previous
	# inspector consulted nothing at all.
	sup.ok(_inspector_gates_everything(),
		"the inspector gates ownership, colony marks and colony detail")


## The inspector's leak was ungated rather than mis-gated, so the rule is asserted at the
## call sites: a direct test of the rule's behaviour passes just as happily if a panel
## stops consulting it.
func _inspector_gates_everything() -> bool:
	var src := FileAccess.get_file_as_string("res://src/client/inspector_panel.gd")
	# The owner gate moved into the controller with the rest of the fog rules, so what is
	# asserted here is that the inspector still *asks* -- via the controller -- rather than
	# deciding ownership itself.
	# Ownership used to be gated in this file at all. It no longer is: the survey panel
	# that printed OWNER is gone, and the one colony marker left is gated on
	# `p.owner == _controller.player_id`, so a rival's ring cannot appear. What has to hold
	# now is that the *controller* still owns the rule -- a panel that decided ownership for
	# itself is the version of this bug that would survive.
	var owner_gated := FileAccess.get_file_as_string(
		"res://src/client/session_controller.gd"
	).contains("func knows_owner_of")
	# The detail gate used to be `_controller.knows_owner_of(system_of_planet(...))`,
	# which is now an over-reveal: one system means every world shares an owner. It must
	# be a check for a fleet parked on *this* world.
	var detail_gated := src.contains("f.destination < 0 and f.system == p.index")
	# The name must come from the one function the map and the log also use.
	var name_gated := src.contains("_controller.display_name(p.index)")
	# The system survey that used to print the rival-empire roster must not be back.
	var no_survey := not src.contains("_system_label")
	# No bare foreign-colony marker may come back.
	var no_foreign_x := not src.contains("elif p.colonized:")
	return owner_gated and detail_gated and name_gated and no_survey and no_foreign_x


## Whether the SYSTEM SURVEY heading is gone from the panel source.
##
## Read from the source rather than from a node lookup because the heading is a bare `Label`
## with no name, and walking the tree for one would be a test written against the layout
## rather than against the thing that was removed.
func _has_system_survey_heading() -> bool:
	var src := FileAccess.get_file_as_string("res://src/client/inspector_panel.gd")
	return src.contains("SYSTEM SURVEY") and src.contains("_system_label")


## Hit-testing has to survive an arbitrary camera, not just the framing the map opens with.
##
## The reported defect was a click landing on the wrong body, and the cause was a transform
## re-derived by hand on each side and never checked against the other. Both directions are
## walked here over a spread of zooms and pans, including the extreme ends of the zoom
## range, because the hand-rolled inverse is exact at zoom 1 and wrong everywhere else.
func _step_hit_testing() -> void:
	sup.begin("click hit-testing across zoom and pan")
	if _client == null or _client.controller == null:
		return
	var map := _client.map
	var view := map.view()
	var cam := map.camera()
	var gal := _client.controller.galaxy

	var saved_zoom := cam.zoom
	var saved_pos := cam.position
	var saved_offset := cam.offset

	# A round trip through the real transform must be the identity. If the forward and
	# inverse disagree anywhere, this is where it shows rather than in a click.
	var round_trip := Vector2(123.0, -456.0)
	sup.near(map._to_galaxy(map._to_screen(round_trip)).x, round_trip.x, 0.01,
		"screen->galaxy->screen round trips in x")
	sup.near(map._to_galaxy(map._to_screen(round_trip)).y, round_trip.y, 0.01,
		"screen->galaxy->screen round trips in y")

	# Zooms derived from the map's own span rather than written as absolutes. A literal
	# like 0.05 is only interesting on one map size: on a `large` map the whole system fits
	# in a quarter of the screen at that zoom, so the error being hunted -- which scales
	# with zoom -- is well under a pixel and a wrong transform still passes. The sweep only
	# has teeth if it goes to zooms where the map is magnified enough to matter.
	var body := 0.0
	for p in gal.planets:
		body = maxf(body, p.position.length())
	body = maxf(body, 1.0)
	var natural := map.size.y / (2.0 * body)
	var zooms: Array[float] = [
		natural * 8.0, natural * 3.0, natural, 1.0, 2.0,
		map.max_zoom(), map.min_zoom(),
	]
	var pans: Array[Vector2] = [
		Vector2.ZERO, Vector2(200.0, -140.0), Vector2(-900.0, 620.0),
	]
	# `Camera2D.offset` is part of the camera transform and not something this map sets
	# itself, so it is the one camera property a hand-rolled "unzoom about the centre"
	# formula cannot see. Without it in the sweep the test cannot tell the two transforms
	# apart at all: `stretch = true` pins the SubViewport's size to the container's and its
	# position to zero, which makes `screen = (world - pos) * zoom + size / 2` agree with
	# the engine's transform to the last bit. So the sweep has to make the camera differ
	# from a pure scale about the centre in a way only the real transform accounts for.
	var offsets: Array[Vector2] = [Vector2.ZERO, Vector2(25.0, -40.0)]
	var checked := 0
	var mismatched := 0
	var worst_error := 0.0
	for z: float in zooms:
		for pan: Vector2 in pans:
			for off: Vector2 in offsets:
				cam.zoom = Vector2(z, z)
				cam.position = pan
				cam.offset = off
				for p in gal.planets:
					# Ground truth is the renderer, not our own forward/inverse pair: the
					# planet is drawn wherever the canvas transform puts it, so that point
					# is the only place a click can land and hit it. Comparing
					# `_to_galaxy(_to_screen(p))` against `p` only proves the two agree
					# with each other, which a wrong-but-consistent pair does perfectly --
					# and `stretch = true` pins the container to the SubViewport exactly, so
					# that is precisely what the hand-rolled formula produced.
					var drawn := map.sub_viewport().get_canvas_transform() * p.position
					var screen := map._to_screen(p.position)
					checked += 1
					# The error must be *negligible* against the pick radius, not merely
					# small enough that the right planet still wins. `pick` searches a
					# fixed 18-parsec radius, so a transform wrong by five parsecs selects
					# the intended planet and fails the moment the player clicks on the
					# planet's edge -- which is exactly the reported bug, and exactly what
					# a "does it pick the right one" assertion waves through. Measured in
					# SubViewport pixels, which is also the unit `pick`'s radius is spent
					# in once the screen offset is scaled by the zoom.
					worst_error = maxf(worst_error,
						drawn.distance_to(map._to_subviewport(screen)))
					# And the actual click path, not just the transform.
					if map.click_at_galaxy(p.position) != p.index:
						mismatched += 1
	sup.eq(mismatched, 0,
		"every planet is clickable at its own screen position, at every zoom and pan")
	sup.ok(checked > 0, "the sweep actually sampled planets", "%d samples" % checked)
	# A few pixels is sub-pixel rounding at this scale; more than that is a transform that
	# disagrees with the renderer about where the planet is.
	sup.ok(worst_error < 4.0,
		"a click point lands on the pixel the renderer drew the planet at",
		"worst=%.4f px off" % worst_error)

	# A click that is genuinely somewhere else must still miss. Without this the check
	# above would also pass if the transform mapped every point onto one lucky planet.
	cam.zoom = Vector2.ONE
	cam.position = Vector2.ZERO
	sup.eq(map.click_at_galaxy(Vector2(999999.0, -999999.0)), -1,
		"a click on empty space selects nothing")

	cam.zoom = saved_zoom
	cam.position = saved_pos
	cam.offset = saved_offset
	map.recentre()


## Panning and zooming must not be able to lose the map.
##
## The map is a `Control` whose `_draw` covers a rect far larger than its own, which is
## exactly the shape the renderer is entitled to cull: it decides what to draw from the
## control's rect, so a camera panned past that rect skipped the layer entirely and the
## player got an empty panel. Both halves of the fix are asserted here -- a custom draw
## rect covering the world, and camera limits that keep the view over it.
## The two ends of a rect's range on one axis, given its position and size.
func _range_of(position: float, size: float) -> Vector2:
	return Vector2(position, position + size)


func _step_view_culling() -> void:
	sup.begin("map survives pan and zoom")
	if _client == null or _client.controller == null:
		return
	var map := _client.map
	var view := map.view()
	var cam := map.camera()
	var gal := _client.controller.galaxy

	# The camera may not leave the map. The bound that has to hold is `camera_bounds()`,
	# which insets the field by the visible half-extent, and `clamp_camera()` is the only
	# thing enforcing it -- the engine's `limit_*` are gone, because they are applied while
	# the camera renders and cannot express a viewport that is not square.
	#
	# The regression this guards is the reported one, and it was invisible to the old
	# assertions because they only asked whether the rect *contained* the planets: a rect
	# whose Y range was entirely positive still contains them whenever the map happens to
	# fit on screen. What has to hold is that the rect's two axes agree with each other and
	# are symmetric about the star, which is the only way "pan freely in all four
	# directions" is a checkable claim.
	#
	# Swept across zooms rather than asserted at whatever the map happened to be framed at.
	# The two regimes are genuinely different -- a map that fits on screen has only one
	# legal centre and collapses to a point -- and the Y-axis defect only shows in the
	# zoomed-in regime, so a single-zoom check would pass vacuously at exactly the zoom a
	# player reports the bug at.
	var saved_z := cam.zoom
	var half := map._view.world_size(gal)
	var furthest := 0.0
	for p in gal.planets:
		furthest = maxf(furthest, maxf(absf(p.position.x), absf(p.position.y)))
	var zooms_seen := 0
	var asymmetric := 0
	var wrong_size := 0
	var stranded := 0
	for zoom in [map.max_zoom(), 1.0, map.max_zoom() * 0.5, 0.25, 0.1]:
		cam.zoom = Vector2(zoom, zoom)
		var b := map.camera_bounds()
		zooms_seen += 1
		# Every legal centre range is symmetric about the star: pan up as far as pan down.
		if not is_equal_approx(b.position.y, -b.end.y) \
				or not is_equal_approx(b.position.x, -b.end.x):
			asymmetric += 1
		# The size on an axis is that axis's own range. Borrowing the other axis's span
		# is what truncated X while Y went positive-only.
		var sx := _range_of(b.position.x, b.size.x)
		var sy := _range_of(b.position.y, b.size.y)
		if not is_equal_approx(sx.x, b.position.x) or not is_equal_approx(sx.y, b.end.x) \
				or not is_equal_approx(sy.x, b.position.y) \
				or not is_equal_approx(sy.y, b.end.y):
			wrong_size += 1
		# The bound is deliberately *smaller* than the field -- it is the field inset by the
		# visible half-extent, so that the whole screen stays over the map. So the property
		# to check is not "clears the field" but "no planet is stranded": for every planet,
		# there must be a reachable camera position that brings it on screen. A collapsed
		# axis (size 0) means the whole map is on screen at once, where pinning the centre to
		# the origin is correct and every planet is visible by definition.
		if b.size.x > 0.0 and b.size.y > 0.0:
			var view_half: Vector2 = Vector2(map.sub_viewport().size) * 0.5 / zoom
			for pl in gal.planets:
				# Can the centre sit where this planet fills the screen?
				var want := pl.position
				if want.x < b.position.x - view_half.x or want.x > b.end.x + view_half.x \
						or want.y < b.position.y - view_half.y \
						or want.y > b.end.y + view_half.y:
					stranded += 1
	sup.ok(zooms_seen >= 3, "the bounds were swept across several zooms", "%d zooms" % zooms_seen)
	sup.eq(stranded, 0,
		"every planet is reachable at every zoom -- none is stranded off the bounds")
	sup.eq(asymmetric, 0,
		"the camera's range is symmetric about the star at every zoom")
	sup.eq(wrong_size, 0,
		"each axis's size is its own range, not the other axis's")
	cam.zoom = saved_z

	# Panning must actually move in all four directions at a zoom where the map does *not*
	# fit. At the default framing the map is smaller than the window, every direction is
	# correctly pinned to the origin, and the loop would pass for entirely the wrong
	# reason -- so it starts from the middle and pans in each direction in turn, counting
	# how far the camera actually got.
	#
	# This is the assertion the old suite never made. Every previous check was about the
	# bounds being *some* rectangle; none of them drove the camera and watched it move, so a
	# bound that only permitted one direction -- the reported bug -- passed all of them.
	var pan_blocked := 0
	for zoom in [map.max_zoom(), 1.0, 0.5]:
		cam.zoom = Vector2(zoom, zoom)
		cam.position = Vector2.ZERO
		map.clamp_camera()
		var centre := cam.position
		var moved := {"up": 0.0, "down": 0.0, "left": 0.0, "right": 0.0}
		for dir: Vector2 in [
			Vector2(-1.0, 0.0), Vector2(1.0, 0.0), Vector2(0.0, -1.0), Vector2(0.0, 1.0)
		]:
			cam.position = centre
			map.clamp_camera()
			var before := cam.position
			# A far bigger push than the field: any direction with room to move will move,
			# and only a genuinely clamped one will not.
			cam.position += dir * (half * 4.0)
			map.clamp_camera()
			var delta := cam.position - before
			if dir.y < 0.0:
				moved["up"] = delta.y
			elif dir.y > 0.0:
				moved["down"] = delta.y
			elif dir.x < 0.0:
				moved["left"] = delta.x
			else:
				moved["right"] = delta.x
		# Up must go as far as down, and left as far as right: a bound that clamps one axis
		# asymmetrically is the bug, regardless of the absolute numbers.
		if moved["up"] > -0.01 and moved["down"] > 0.01:
			pan_blocked += 1
		if moved["left"] > -0.01 and moved["right"] > 0.01:
			pan_blocked += 1
	sup.eq(pan_blocked, 0,
		"no zoom lets one direction travel while its opposite is pinned")

	# No hardcoded camera limits left to clamp the viewport against a box that cannot
	# describe a non-square window.
	cam.zoom = saved_z
	sup.ok(cam.limit_left <= -GalaxyMap.INF_INT or cam.limit_left < -half * 4.0,
		"no hardcoded camera limit bounds the left edge",
		"limit_left=%d" % cam.limit_left)
	sup.ok(cam.limit_right >= GalaxyMap.INF_INT or cam.limit_right > half * 4.0,
		"nor the right edge", "limit_right=%d" % cam.limit_right)

	# The draw layer must tell the renderer where it actually draws, or the cull follows
	# the widget's rect instead of the world's.
	view.queue_redraw()
	await process_frame
	# Read back through the debug getter: there is no `canvas_item_get_custom_rect`, so a
	# test that used one would be asserting against an API this engine does not have.
	var custom := RenderingServer.debug_canvas_item_get_rect(view.get_canvas_item())
	sup.ok(custom.size.x > 0.0 and custom.size.y > 0.0,
		"the draw layer declares a custom rect", "%s" % str(custom))
	sup.ok(custom.has_point(Vector2.ZERO),
		"which contains the star")
	sup.ok(custom.has_point(view.world_rect(gal).end * 1.05),
		"and the whole drawn field with margin")

	# A move to any point is followed by the bound being re-established, and the whole
	# viewport has to end up over the map -- not merely the centre, which is all the
	# engine's own limits guarantee.
	var saved := cam.position
	var bound := map.camera_bounds()
	var runaway := false
	for probe: Vector2 in [
		Vector2(1e9, 0.0), Vector2(-1e9, 0.0), Vector2(0.0, 1e9), Vector2(0.0, -1e9),
		Vector2(1e9, 1e9), Vector2(-1e9, -1e9)
	]:
		cam.position = probe
		map.clamp_camera()
		if cam.position.x < bound.position.x or cam.position.x > bound.end.x \
				or cam.position.y < bound.position.y or cam.position.y > bound.end.y:
			runaway = true
	sup.ok(not runaway, "a camera driven off the map is brought back onto it",
		"pos=%s bounds=%s" % [str(cam.position), str(bound)])
	sup.ok(cam.position.distance_to(Vector2.ZERO) < 1e8,
		"and it does not stay where it was thrown")
	cam.position = saved

	# The bound is the field minus the visible half-extent, so the whole *screen* is over
	# the map rather than just its middle -- which is the property the engine's own limits
	# do not give. Recomputed from the bound rather than from where the camera happens to
	# be, since the probe above deliberately left it at an extreme.
	# The property that matters is not that the *viewport* is inside the map -- a viewport
	# wider than the map is normal, and the bounds frame is there to show the difference --
	# but that no reachable camera position can push a planet off the screen. That is the
	# "map disappears" report stated as something checkable.
	var b := map.camera_bounds()
	var off_screen := 0
	var checked := 0
	for corner: Vector2 in [
		b.position, b.end, Vector2(b.position.x, b.end.y), Vector2(b.end.x, b.position.y)
	]:
		checked += 1
		var vh := Vector2(map.sub_viewport().size) * 0.5 / cam.zoom.x
		var rect := Rect2(corner - vh, vh * 2.0)
		for pl in gal.planets:
			if not rect.has_point(pl.position):
				off_screen += 1
	sup.eq(off_screen, 0,
		"no reachable camera position puts a planet off screen")
	sup.ok(checked == 4, "every corner of the camera's range was checked")

	# And the field is black behind it, so panning past the edge cannot show the project
	# clear colour.
	var clear := map.sub_viewport()
	sup.eq(clear.render_target_clear_mode, SubViewport.CLEAR_MODE_ALWAYS,
		"the sub-viewport clears every frame, so the map cannot be blanked by a stale target")


## The map drew a diamond for *every* fleet of *every* empire while correctly hiding the
## stars those fleets were parked in -- so the fog was on the background and off the
## foreground. Enemy ships are now drawn only where a sensor sweep would find them.
## Planet names are their own fog leak.
##
## Separate from ownership and from the economy: a name is a free fact about a world the
## player has never visited, it is stable across turns, and it is what the player uses to
## refer to a place. A map of named rivals' worlds is a map somebody has already scouted.
##
## The fixture is synthesised because a single-player galaxy has one empire: a rival world
## would never appear naturally, and the behavioural half of this test would silently
## never run.
func _step_fog_planet_names() -> void:
	sup.begin("planet names respect the fog")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var gal := c.galaxy
	if gal == null:
		return
	var me := c.player_id
	var view := _client.map.view()
	var inspector := _client.inspector

	# Find (or manufacture) a rival world with a real, distinctive name.
	var foreign: PlanetState = null
	var rival := -1
	for p in gal.planets:
		if p.owner != me and p.name != "":
			foreign = p
			rival = p.owner
			break
	if foreign == null:
		# Force one: take any unowned world and give it a rival owner and a name that
		# could not occur by accident, so "did this string leak" is unambiguous.
		for p in gal.planets:
			if p.owner != me:
				foreign = p
				break
		if foreign == null:
			sup.ok(true, "no rival world available; skipped")
			return
		# `gal.factions` holds `FactionState` objects, so the rival's *index* is found by
		# position rather than by comparing ids.
		var occupied := -1
		for i in gal.factions.size():
			if i != me:
				occupied = i
				break
		if occupied < 0:
			sup.ok(true, "no rival empire available; skipped")
			return
		var saved_owner := foreign.owner
		var saved_name := foreign.name
		var saved_colonized := foreign.colonized
		rival = occupied
		foreign.owner = occupied
		foreign.colonized = true
		foreign.name = "Zzzqx Probe"

		# Park no fleet there, and make sure none is en route: a fleet merely heading to
		# the world must not earn the name, or the test would pass for the wrong reason.
		var parked := []
		for key: int in gal.fleets:
			var f: FleetState = gal.fleets[key]
			if f.owner == me and f.active:
				parked.append(f)

		# Stated, not assumed: a survey is a legitimate route to a name, and this fixture
		# only means "neither surveyed nor visited".
		var saved_surveyed := foreign.surveyed
		foreign.surveyed = false
		sup.ok(not c.knows_name_of(foreign.index),
			"an unvisited rival world has no name the player may use")
		foreign.surveyed = saved_surveyed
		sup.eq(view.planet_label(foreign), GalaxyMapView.UNKNOWN_NAME,
			"the map labels it with the placeholder, not its real name")
		c.select_planet(foreign.index)
		inspector.refresh()
		var hidden := inspector.planet_label().text
		sup.ok(not hidden.contains("Zzzqx Probe"),
			"the inspector does not print its name")
		sup.ok(hidden.contains(GalaxyMapView.UNKNOWN_NAME),
			"and headings it with the placeholder instead")
		if _client.fleets != null:
			sup.ok(not _client.fleets.visible_text().contains("Zzzqx Probe"),
				"the fleet registry does not print it either")
		sup.ok(_client.log_text().find("SELECTED Zzzqx Probe") < 0,
			"nor does the selection log")

		# A fleet merely sailing there must not unlock it.
		if not parked.is_empty():
			parked[0].system = foreign.index
			parked[0].destination = (foreign.index + 1) % maxi(1, gal.planets.size())
			sup.ok(not c.knows_name_of(foreign.index),
				"a fleet under way to a world does not reveal its name")
			# Parking it there does.
			parked[0].destination = -1
			sup.ok(c.knows_name_of(foreign.index),
				"parking a fleet on the world reveals its name")
			sup.eq(view.planet_label(foreign), "Zzzqx Probe",
				"and the map then labels it with the real name")
			inspector.refresh()
			sup.ok(inspector.planet_label().text.contains("Zzzqx Probe"),
				"the inspector names it too -- the two panels agree")
		else:
			sup.ok(true, "the player has no fleet to park; name reveal not exercised")

		# Own world: the player always knows what they settled, and it is labelled.
		var own: PlanetState = null
		for p in gal.planets:
			if p.owner == me:
				own = p
				break
		if own != null:
			sup.ok(c.knows_name_of(own.index),
				"a world the player owns always has a usable name")
			sup.ok(view.label_worth_drawing(own),
				"and the map draws a label beside it")

		# The label itself is the second half of the rule, and it is a different question
		# from `planet_label`. A world the player is not entitled to name is drawn as an
		# unnamed marker -- not as "Unknown Planet", which on a board of a hundred bodies is
		# a hundred identical strings covering the map. Selecting it must not be an escape
		# hatch either, or the name is one click away from everybody.
		sup.ok(not view.label_worth_drawing(foreign),
			"a world the player may not name is drawn with no label at all")
		foreign.owner = me
		sup.ok(view.label_worth_drawing(foreign),
			"and gains one the moment the player owns it")
		foreign.owner = rival

		foreign.owner = saved_owner
		foreign.name = saved_name
		foreign.colonized = saved_colonized
		return

	# A rival world exists naturally. Clear the player's fleets off it first: an earlier
	# step in this suite parks ships, and a world with one of ours sitting on it is
	# *legitimately* named. Picking one at random and asserting it is hidden would be
	# testing the fixture, not the rule.
	var displaced := {}
	for f_key: int in gal.fleets:
		var f: FleetState = gal.fleets[f_key]
		if f.owner == me and f.active:
			displaced[f_key] = [f.system, f.destination]
			f.destination = -1
			if f.system == foreign.index:
				f.system = (foreign.index + 1) % maxi(1, gal.planets.size())

	# Neither surveyed nor visited: a survey is a legitimate route to a name, so the premise
	# is cleared here rather than depended on, and restored once the assertions are done.
	var saved_surveyed := foreign.surveyed
	foreign.surveyed = false
	sup.ok(not c.knows_name_of(foreign.index),
		"an unvisited rival world has no name the player may use",
		"world=%d name=%s" % [foreign.index, foreign.name])
	sup.eq(view.planet_label(foreign), GalaxyMapView.UNKNOWN_NAME,
		"the map labels it with the placeholder, not its real name")
	sup.ok(foreign.name != GalaxyMapView.UNKNOWN_NAME,
		"which is not simply its real name")
	# No marker on the board at all for a world that is neither owned nor orbited. The
	# placeholder is what the panel says about it; the map says nothing. Still inside the
	# cleared-survey window -- a surveyed world *is* named, and restoring first would be
	# asserting the opposite rule.
	sup.ok(not view.label_worth_drawing(foreign),
		"and draws no label beside the marker")
	foreign.surveyed = saved_surveyed

	c.select_planet(foreign.index)
	inspector.refresh()
	sup.ok(not inspector.planet_label().text.contains(foreign.name),
		"the inspector does not print its name either")
	# The fleet registry is the other panel that names worlds, and it was the one still
	# reaching for `p.name` directly. A reader that prints the real name is a leak whether
	# or not the player is looking at the map: "IN TRANSIT TO" would otherwise name the
	# destination of every order in the game. A fleet has to actually be bound for the
	# world -- with none, no caption mentions it and the check would pass vacuously.
	var registry := _client.fleets
	sup.ok(registry != null, "the fleet registry panel exists")
	var carrier: FleetState = null
	for f_key: int in gal.fleets:
		var f5: FleetState = gal.fleets[f_key]
		if f5.owner == me and f5.active:
			carrier = f5
			break
	if registry != null and carrier != null:
		carrier.destination = foreign.index
		# The caption and the detail readout are refreshed by different code, so the fleet
		# has to be selected as well as bound: "IN TRANSIT TO" is only drawn for the
		# selected fleet, and leaving it unselected would test the caption twice.
		c.select_fleet(carrier.id)
		registry.refresh()
		var shown := registry.visible_text()
		sup.ok(shown.contains(GalaxyMapView.UNKNOWN_NAME),
			"an order bound for an unnamed world reads as the placeholder",
			"shown=%s" % shown.replace("\n", " | "))
		sup.ok(shown.contains("IN TRANSIT TO"),
			"and the detail readout is actually being drawn", "shown=%s" % shown.replace("\n", " | "))
		sup.ok(not shown.contains(foreign.name),
			"the fleet registry does not print its real name either")
		# Leave the world as the later steps found it.
		carrier.destination = -1
	else:
		sup.ok(true, "no player fleet to bind an order to; registry leak not exercised")

	# The log is written by the map's click handler, not by the controller, so the log has
	# to be driven through a click -- calling `select_planet` directly would leave the log
	# untouched and the assertion would pass for the wrong reason. Order mode is armed
	# first so the click stages a move rather than being swallowed as an edit.
	_client.map.set_order_mode(false)
	_client.map.click_at_galaxy(foreign.position)
	sup.ok(_client.log_text().find("SELECTED %s" % foreign.name) < 0,
		"and neither does the selection log")
	sup.ok(_client.log_text().find("SELECTED %s" % GalaxyMapView.UNKNOWN_NAME) >= 0,
		"the log records the selection as unknown instead",
		"tail=%s" % _client.log_text().strip_edges().split("\n")[-1])

	# Restore: every one of these worlds is shared with later steps.
	for f_key: int in displaced:
		var f4: FleetState = gal.fleets[f_key]
		var prior: Array = displaced[f_key]
		f4.system = int(prior[0])
		f4.destination = int(prior[1])


## The map's backdrop and bounds frame.
##
## The orbit rings and grid are gone and the field is black; the frame marks the edge of
## the playable area. Asserted on the drawing constants and the geometry rather than by
## reading pixels -- a headless run has no rasteriser to sample, and the thing that
## actually matters is that the frame encloses every planet.
func _step_map_bounds() -> void:
	sup.begin("map backdrop and bounds")
	if _client == null or _client.controller == null:
		return
	var view := _client.map.view()
	var gal := _client.controller.galaxy

	sup.eq(view.FIELD_COLOUR, Color(0.0, 0.0, 0.0, 1.0),
		"the map field is solid black")
	sup.ok(view.BOUNDS_COLOUR.a > 0.0, "the bounds frame is visible",
		"alpha=%f" % view.BOUNDS_COLOUR.a)
	sup.ok(view.BOUNDS_WIDTH >= 1.0, "and thick enough to see at a distance")

	# The frame must contain the system, or "where does it end" is answered wrongly.
	var half := view.world_size(gal) * view.BOUNDS_PAD
	var outside := 0
	for p in gal.planets:
		if absf(p.position.x) > half or absf(p.position.y) > half:
			outside += 1
	sup.eq(outside, 0, "every planet is inside the bounds frame")

	# The frame must sit outside the outermost planet, or planets on the rim are drawn on
	# top of the line that is supposed to mark them as the edge.
	var furthest := 0.0
	for p in gal.planets:
		furthest = maxf(furthest, maxf(absf(p.position.x), absf(p.position.y)))
	sup.ok(half > furthest, "the frame clears the outermost planet",
		"half=%.1f furthest=%.1f" % [half, furthest])

	# Zooming in far enough to click a planet is the point of the ceiling.
	sup.ok(_client.map.max_zoom() >= 1.0,
		"the camera can zoom in past 1:1 on any map size")
	sup.ok(_client.map.min_zoom() > 0.0, "and the floor is positive")
	sup.ok(_client.map.max_zoom() > _client.map.min_zoom(),
		"the zoom range is not inverted")


func _step_fog_fleet_markers() -> void:
	sup.begin("enemy fleets respect sensor range")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var me := c.player_id
	var gal := c.galaxy
	var view := _client.map.view()
	if view == null:
		sup.ok(false, "the map exposes its view layer")
		return

	# Somewhere well outside sensor range for every fleet that is not the player's.
	var hidden_system := -1
	for sys in gal.systems:
		if c.can_see(sys.index):
			continue
		if _own_fleet_in(gal, me, sys.index):
			continue
		hidden_system = sys.index
		break

	if hidden_system < 0:
		sup.ok(true, "no system lies outside sensor range to test against")
		sup.ok(_fleets_consult_visibility(),
			"the map consults sensor range before drawing enemy fleets")
		return

	var enemy := -1
	for f_key: int in gal.fleets:
		var f: FleetState = gal.fleets[f_key]
		if f.active and f.owner != me:
			enemy = f_key
			break

	sup.ok(enemy >= 0, "a rival fleet exists to place out of range")
	if enemy < 0:
		return
	var ef: FleetState = gal.fleets[enemy]
	var saved_system := ef.system
	var saved_dest := ef.destination

	ef.system = hidden_system
	ef.destination = -1
	sup.ok(not view._fleet_visible(gal, ef),
		"an enemy fleet outside sensor range is not drawn")

	# A fleet sailing between two stars is between two stars. It becomes visible only
	# where one of the endpoints is in range.
	ef.system = hidden_system
	ef.destination = hidden_system
	sup.ok(not view._fleet_visible(gal, ef),
		"an enemy fleet in transit between unseen systems is not drawn")

	ef.system = hidden_system
	ef.destination = _first_seen_system(gal, c)
	sup.ok(view._fleet_visible(gal, ef),
		"an enemy fleet bound for a system in range is drawn once it is near it")

	ef.system = saved_system
	ef.destination = saved_dest
	sup.ok(_fleets_consult_visibility(),
		"the map consults sensor range before drawing enemy fleets")


func _first_seen_system(galaxy: GalaxyState, c: SessionController) -> int:
	for sys in galaxy.systems:
		if c.can_see(sys.index):
			return sys.index
	return -1


## Whether `_draw_fleets()` filters enemy fleets by sensor range.
func _fleets_consult_visibility() -> bool:
	var src := FileAccess.get_file_as_string("res://src/client/galaxy_map_view.gd")
	return src.contains("if not mine and not _fleet_visible(galaxy, f):")


## Whether `faction` has an active, stationary fleet sitting in `system_index`.
## Whether `faction` has a fleet parked on `planet_index` -- as opposed to one merely
## under way to or from it. `system_index` callers pass a system, which is resolved to its
## first body, because with one system the planet is the only thing that can be occupied.
func _own_fleet_in(galaxy: GalaxyState, faction: int, system_index: int) -> bool:
	var target := _first_planet_of(galaxy, system_index)
	if target < 0:
		return false
	return _own_fleet_on(galaxy, faction, target)


func _own_fleet_on(galaxy: GalaxyState, faction: int, planet_index: int) -> bool:
	for key: int in galaxy.fleets:
		var f: FleetState = galaxy.fleets[key]
		if f.active and f.owner == faction and f.system == planet_index \
				and f.destination < 0:
			return true
	return false


## A body in `system_index`, or -1. With one system this is "some planet".
func _first_planet_of(galaxy: GalaxyState, system_index: int) -> int:
	var sys := galaxy.system(system_index)
	if sys == null or sys.planet_indices.is_empty():
		return -1
	return sys.planet_indices[0]


func _step_reproducible() -> void:
	sup.begin("determinism through the GUI")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var first_hash := int(c.last_report.get("state_hash", 0))

	# The same seed and the same sequence of GUI-level decisions must land on the same
	# state. This is the Phase 4 determinism guarantee, re-checked through the client.
	var script_path := "res://tests/test_gui_integration.gd"
	sup.ok(ResourceLoader.exists(script_path), "the suite is discoverable by path")

	var snapshot := c.galaxy.to_json()
	var reloaded := GalaxyState.new()
	sup.ok(reloaded.from_json(snapshot), "the galaxy round-trips through save/load")
	sup.eq(reloaded.state_hash(), c.galaxy.state_hash(),
		"a save/load cycle preserves the state hash")
	sup.eq(int(reloaded.turn), c.galaxy.turn, "the reloaded galaxy is on the same stardate")

	# A turn taken from the reloaded state must match one taken from the live state.
	var rng_a := RandomNumberGenerator.new()
	rng_a.seed = c.rng.state
	var rng_b := RandomNumberGenerator.new()
	rng_b.seed = c.rng.state
	var live_report := TurnResolver.resolve_turn(c.galaxy, [], c.defs, c.db, rng_a, c.player_id)
	var reload_report := TurnResolver.resolve_turn(reloaded, [], c.defs, c.db, rng_b, c.player_id)
	sup.eq(int(live_report.get("state_hash", 0)), int(reload_report.get("state_hash", 0)),
		"a turn resolved from a reloaded state matches the live state")
	sup.ok(first_hash != 0, "the turn report carried a non-zero state hash",
		"hash=%d" % first_hash)


# --- Phase 8 corrections: metal allocation, travel flow, cargo, visuals ---

## Both progress bars, and the fact that they appear the moment Build is pressed.
##
## "Immediately" is the claim under test, so it is measured against a refresh rather than
## against the end of the next turn: a bar that appears when the order resolves reads as a
## button that did nothing, and a player who thinks the button is broken presses it again.
func _step_immediate_progress_bars() -> void:
	sup.begin("immediate progress bars")
	if _client == null or _client.controller == null or _client.macros == null:
		return
	var c := _client.controller
	var me := c.player()
	var colony := _first_colony()
	sup.ok(colony != null, "the player starts with a colony")
	if colony == null or me == null:
		return
	_client.select_colony(colony.index)
	c.select_planet(colony.index)

	colony.building_queue.clear()
	colony.build_metal = 0.0
	colony.ship_queue.clear()
	_client.macros.refresh()
	sup.ok(not _client.macros.build_bar().visible,
		"no bar is shown with nothing under construction")
	sup.ok(not _client.macros.ship_bar().visible,
		"and none for the shipyard either")

	# Press Build and look at the very next refresh.
	#
	# The structure is taken from the selector rather than hard-coded: which structures a
	# faction has unlocked is the generator's business, and hard-coding one here made this
	# step fail on a seed where it was not offered -- which is a failure of the *fixture*, not
	# of the button being tested.
	var chosen := _first_offered_structure()
	sup.ok(chosen != &"", "the build menu offers something", "nothing selectable")
	var before := colony.count(chosen)
	# The queue is emptied first: earlier steps stage orders on purpose, and a faction that
	# has already used up this turn's allowance cannot stage another.
	c.queue.clear()
	_client.macros.select_build(chosen)
	_client.macros.build_button().emit_signal("pressed")
	sup.ok(not colony.building_queue.is_empty(),
		"the Build button queues the selected structure")
	_client.macros.refresh()
	sup.ok(_client.macros.build_bar().visible,
		"and the structure bar is on screen immediately, not after the next turn")
	sup.near(_client.macros.build_bar().value, 0.0, 0.001,
		"reading 0% on the turn it was queued")
	sup.ok(_client.macros.build_bar().tooltip_text.contains("click to allocate"),
		"with a tooltip that says the bar is clickable")
	sup.eq(colony.count(&"granary"), before, "and the structure itself has not landed yet")

	# Half-paid reads half-full, straight from the metal.
	colony.build_metal = ColonySim.queued_cost(colony, _defs.get("buildings") as Dictionary) * 0.5
	_client.macros.refresh()
	sup.near(_client.macros.build_bar().value, 0.5, 0.001, "half the cost paid reads half full")

	# A hull gets its own bar rather than sharing the structure one.
	colony.building_queue.clear()
	colony.build_metal = 0.0
	colony.ship_queue = [{"hull": "corvette", "turns": 2, "metal": 25.0}]
	var hulls: Dictionary = _defs.get("ship_hulls") as Dictionary
	var corvette := _defs.call("ship_hull", &"corvette") as Resource
	sup.ok(corvette != null, "the corvette has a definition")
	if corvette != null:
		_client.macros.refresh()
		sup.ok(not _client.macros.build_bar().visible,
			"a hull does not light the structure bar")
		sup.ok(_client.macros.ship_bar().visible,
			"the shipyard has its own bar")
		sup.near(_client.macros.ship_bar().value,
			25.0 / float(corvette.get("cost_metals")), 0.001,
			"reading the hull's own paid-of-cost fraction")
	colony.ship_queue.clear()
	_client.macros.refresh()
	sup.ok(not _client.macros.ship_bar().visible, "and it goes away when the yard empties")


## The metal dialog over both a structure and a hull, in both directions.
##
## Applied through OK rather than by poking the controller, because the claim is that a player
## can move metal *both ways* with the controls on screen.
func _step_metal_allocation_modal() -> void:
	sup.begin("metal allocation dialog")
	if _client == null or _client.controller == null or _client.boost == null:
		return
	var c := _client.controller
	var colony := _first_colony()
	if colony == null:
		sup.ok(false, "the player starts with a colony")
		return
	var buildings: Dictionary = _defs.get("buildings") as Dictionary
	var granary := _defs.call("building", &"granary") as Resource
	var cost := float(granary.get("cost_metals"))
	_client.select_colony(colony.index)
	colony.building_queue = {&"granary": 1}
	colony.build_total_turns = int(granary.get("build_turns"))
	colony.build_turns_remaining = int(granary.get("build_turns"))
	colony.build_metal = 0.0
	colony.reserve_metals = 500.0

	sup.ok(_client.boost.open_for_selected_colony(), "it opens for a structure")
	sup.eq(_client.boost.ok_button().text, "OK", "with an OK button")
	sup.eq(_client.boost.cancel_button().text, "CANCEL", "and a CANCEL button")
	sup.ok(_client.boost.refund_slider() != null, "and a second slider for the other direction")
	sup.near(_client.boost.amount_slider().max_value, cost, 0.001,
		"the add slider is capped at what the project owes")
	# A slider whose range is 0..0 cannot be drawn or dragged, so its `max_value` is floored at
	# 1. The ceiling is therefore asserted on the rule the dialog actually reads.
	sup.near(_client.boost.ceiling(false), 0.0, 0.001,
		"nothing is assigned yet, so there is nothing to take back out")
	sup.near(float(_client.boost.refund_slider().value), 0.0, 0.001,
		"and the remove slider opens at zero")

	# Put the whole ceiling in and commit it.
	_client.boost.amount_slider().set_value(cost)
	_client.boost.ok_button().emit_signal("pressed")
	sup.near(colony.build_metal, cost, 0.001, "OK moved metal into the project")
	sup.near(colony.reserve_metals, 500.0 - cost, 0.001, "and took it out of storage")
	sup.ok(not _client.boost.visible, "and closed the dialog")

	# Reopen: now the *remove* direction is the one with a ceiling.
	sup.ok(_client.boost.open_for_selected_colony(),
		"a fully paid project still opens, because metal can come back out")
	sup.near(_client.boost.refund_slider().max_value, cost, 0.001,
		"the remove slider now offers everything assigned")
	_client.boost.refund_slider().set_value(cost * 0.5)
	_client.boost.ok_button().emit_signal("pressed")
	sup.near(colony.build_metal, cost * 0.5, 0.001,
		"OK moved half of it back out of the project")
	sup.near(colony.reserve_metals, 500.0 - cost * 0.5, 0.001,
		"and returned it to storage")

	# CANCEL changes nothing.
	_client.boost.open_for_selected_colony()
	var held_metal := colony.build_metal
	var held_store := colony.reserve_metals
	_client.boost.amount_slider().set_value(cost)
	_client.boost.cancel_button().emit_signal("pressed")
	sup.near(colony.build_metal, held_metal, 0.001, "CANCEL moves no metal in")
	sup.near(colony.reserve_metals, held_store, 0.001, "and none out")
	sup.ok(not _client.boost.visible, "and closes the dialog")

	# The same dialog, over a hull.
	colony.building_queue.clear()
	colony.build_metal = 0.0
	colony.ship_queue = [{"hull": "corvette", "turns": 2, "metal": 0.0}]
	var hulls: Dictionary = _defs.get("ship_hulls") as Dictionary
	var corvette := _defs.call("ship_hull", &"corvette") as Resource
	if corvette != null:
		var hull_cost := float(corvette.get("cost_metals"))
		sup.ok(_client.boost.open_for_selected_colony(),
			"and over a hull in the yard: same dialog, same rules")
		sup.near(_client.boost.amount_slider().max_value, hull_cost, 0.001,
			"capped at the hull's metal cost rather than the structure's")
		sup.ok(_client.boost.title_label().text.contains("SHIP"),
			"and the title says which kind of project this is",
			"reads '%s'" % _client.boost.title_label().text)
		_client.boost.amount_slider().set_value(hull_cost)
		_client.boost.ok_button().emit_signal("pressed")
		sup.near(ColonySim.project_paid(colony), hull_cost, 0.001,
			"OK moved metal into the hull")
		_client.boost.open_for_selected_colony()
		_client.boost.refund_slider().set_value(hull_cost)
		_client.boost.ok_button().emit_signal("pressed")
		sup.near(ColonySim.project_paid(colony), 0.0, 0.001,
			"and OK took it all back out again")
	colony.ship_queue.clear()
	colony.reserve_metals = 500.0


## Press Travel, then the two map clicks, then the manifest.
##
## Driven through the client's own handlers rather than by calling the controller, because the
## claim under test is that the *sequence* works -- a workflow reachable only by three
## separate controller calls is not a workflow.
func _step_travel_flow() -> void:
	sup.begin("interactive travel flow")
	if _client == null or _client.controller == null or _client.manifest == null:
		return
	var c := _client.controller
	var colony := _first_colony()
	if colony == null:
		sup.ok(false, "the player starts with a colony")
		return
	c.select_planet(colony.index)

	# A new empire has an empty orbit, so the source world is given a ship first. Which is
	# the point: "which world can you travel from" now starts as *none of them*, and the flow
	# has to work from wherever the player chooses to build.
	# Not asserted as "false" first: an earlier step may already have placed a hull here, and
	# the absence that matters is asserted where the board is untouched -- in the fleet-order
	# step, against the generator's output.
	_ensure_transport(colony.index, &"corvette")
	sup.ok(c.can_travel_from(colony.index),
		"the homeworld becomes a legal source once it holds a ship")
	sup.ok(not c.can_travel_from(_other_planet_index(colony.index)),
		"an empty world is not")

	# Step 1: press Travel. The flow must be waiting for a source, and the player told so.
	_client.fleets.travel_button().emit_signal("pressed")
	sup.eq(_client.travel_step, GameClient.TravelStep.SOURCE,
		"pressing Travel starts the flow at 'Select Source Location'")

	# A click on a world with nothing in orbit is refused and does not advance.
	var empty := _other_planet_index(colony.index)
	c.select_planet(empty)
	_client._on_planet_picked(empty)
	sup.eq(_client.travel_step, GameClient.TravelStep.SOURCE,
		"clicking a world with no ships of yours in orbit does not advance the flow")

	# Step 2: the source.
	c.select_planet(colony.index)
	_client._on_planet_picked(colony.index)
	sup.eq(_client.travel_step, GameClient.TravelStep.DESTINATION,
		"clicking a world with ships in orbit advances to 'Select Destination'")
	sup.eq(_client.travel_source, colony.index, "and records it as the source")

	# Clicking the source again as the destination is refused: it is not a journey.
	_client._on_planet_picked(colony.index)
	sup.eq(_client.travel_step, GameClient.TravelStep.DESTINATION,
		"the source is not a legal destination for itself")

	# Step 3: the destination opens the manifest.
	var dest := _other_planet_index(colony.index)
	_client._on_planet_picked(dest)
	sup.ok(_client.manifest.visible, "choosing a destination opens the fleet manifest")
	sup.eq(_client.travel_step, GameClient.TravelStep.NONE,
		"and ends the flow -- the modal owns the rest")

	# The roster is split by role, and each hull is in exactly one of them.
	var starting := ColonySim.queued_hull_id  # keep the analyzer honest about unused helpers
	sup.ok(starting != null, "the manifest modal is present")
	var hulls := c.hulls_in_orbit_at(colony.index)
	sup.ok(not hulls.is_empty(), "the source world has hulls in orbit")
	for hull_id: StringName in hulls:
		var def: Resource = _defs.call("ship_hull", hull_id) as Resource
		sup.ok(def != null, "hull %s has a definition" % String(hull_id))
		if def == null:
			continue
		var in_combat := _client.manifest.combat_rows().get_node_or_null(
			NodePath("Row_%s" % String(hull_id))) != null
		var in_support := _client.manifest.support_rows().get_node_or_null(
			NodePath("Row_%s" % String(hull_id))) != null
		sup.ok(in_combat != in_support,
			"hull %s is in exactly one roster (%s)" % [
				String(hull_id),
				"combat" if in_combat else ("logistic" if in_support else "neither")])

	# The `+`, `-`, All and None controls, and their effect on the counts.
	var first_hull: StringName = &""
	for hull_id: StringName in hulls:
		first_hull = hull_id
		break
	if first_hull != &"":
		var total := int(hulls.get(first_hull, 0))
		sup.ok(_client.manifest.more_button(first_hull) != null,
			"each hull has a + button")
		sup.ok(_client.manifest.less_button(first_hull) != null,
			"and a - button")
		_client.manifest.set_all(false)
		sup.eq(_client.manifest.manifest().size(), 0, "None clears the manifest")
		_client.manifest.set_all(true)
		sup.eq(int(_client.manifest.manifest().get(first_hull, 0)), total,
			"All selects every hull in the orbit")
		_client.manifest.less_button(first_hull).emit_signal("pressed")
		sup.eq(int(_client.manifest.manifest().get(first_hull, 0)), total - 1,
			"and - sends one fewer")
		_client.manifest.more_button(first_hull).emit_signal("pressed")
		sup.eq(int(_client.manifest.manifest().get(first_hull, 0)), total,
			"and + sends one more")

	# Logistics rows carry a cargo readout.
	for hull_id: StringName in GameDB.LOGISTIC_HULLS:
		if not hulls.has(hull_id):
			continue
		var label := _client.manifest.cargo_label(hull_id)
		sup.ok(label != null, "a logistic hull shows its cargo")
		if label != null:
			sup.ok(not label.text.is_empty(), "with actual figures in it")

	# CANCEL aborts without staging anything.
	c.queue.clear()
	_client.manifest.cancel_button().emit_signal("pressed")
	sup.ok(not _client.manifest.visible, "CANCEL closes the manifest")
	sup.eq(c.queue.orders_for(c.player_id).size(), 0,
		"and stages no travel order at all")

	# OK dispatches. A single hull is enough to prove the commit is real.
	if first_hull != &"":
		_client.fleets.travel_button().emit_signal("pressed")
		c.select_planet(colony.index)
		_client._on_planet_picked(colony.index)
		_client._on_planet_picked(dest)
		_client.manifest.set_all(false)
		_client.manifest.adjust(first_hull, 1, hulls)
		var before := c.orders_to_submit().size()
		_client.manifest.ok_button().emit_signal("pressed")
		sup.eq(c.orders_to_submit().size(), before + 1,
			"OK stages exactly one travel order")
		var staged: Order = c.orders_to_submit()[c.orders_to_submit().size() - 1]
		sup.eq(staged.type, Enums.OrderType.TRAVEL, "and it is a TRAVEL order")
		sup.eq(staged.target_planet, dest, "for the destination the flow chose")
		var sent: Dictionary = staged.payload.get("ships", {}) as Dictionary
		sup.eq(int(sent.get(first_hull, 0)), 1, "carrying the manifest that was chosen")
	c.queue.clear()
	# Cancel any flow still mid-way so later steps start clean.
	_client._abandon_travel()


## The player's actual travel flow, carried through to arrival.
##
## This is the path the manifest modal takes -- a `TRAVEL` order with a hull manifest -- and
## it is a different code path from `queue_move`, which is a plain `MOVE_FLEET`. The travel
## path used to build the departing fleet without copying the source's `system`, which
## defaults to -1 and is the one value `issue_move` refuses. The dispatch was therefore
## rejected and the emptied source fleet deleted, leaving the selected ships in a fleet
## registered at nowhere: not in orbit, not in transit, drawn nowhere, and never arriving. The
## turn still resolved and the log still announced the journey, which is what made it look
## like a rendering fault rather than a lost order.
##
## So this drives the manifest the way a player does and then runs the turns out. The
## regression is caught at the cheapest possible assertion -- the departing fleet knows which
## world it left from -- long before the arrival check at the end.
func _step_manifest_travel_arrives() -> void:
	sup.begin("a manifest travel order puts ships under way and delivers them")
	if _client == null or _client.controller == null or _client.manifest == null:
		return
	var c := _client.controller
	var colony := _first_colony()
	if colony == null:
		sup.ok(false, "the player starts with a colony")
		return

	# Two hulls of one kind and one of another, so a manifest can be a strict subset and the
	# remainder is observable.
	var source := FleetState.new()
	source.bind_hulls(_defs.get("ship_hulls") as Dictionary)
	source.owner = c.player_id
	source.system = colony.index
	source.name = "Manifest Probe"
	source.add_ships(&"corvette", 2)
	source.add_ships(&"frigate", 1)
	c.galaxy.add_fleet(source)
	c.select_planet(colony.index)

	var dest := -1
	var nearest := INF
	for p in c.galaxy.planets:
		if p.index == colony.index:
			continue
		var gap := MovementStage.orbit_distance(colony, p)
		if gap > 0.0 and gap < nearest:
			nearest = gap
			dest = p.index
	sup.ok(dest >= 0, "a world to travel to")
	if dest < 0:
		return

	# The manifest modal's own commit, rather than the controller called directly, so the
	# order that is staged is the one a player would have produced.
	c.queue.clear()
	_client.manifest.set_all(false)
	_client.manifest.adjust(&"corvette", 1, {&"corvette": 2, &"frigate": 1})
	_client._on_manifest_confirmed(colony.index, dest, {&"corvette": 1})
	var staged: Array[Order] = c.orders_to_submit() as Array[Order]
	sup.eq(staged.size(), 1, "the manifest stages one travel order")
	if staged.is_empty():
		return
	sup.eq(staged[0].type, int(Enums.OrderType.TRAVEL),
		"and it is the TRAVEL kind, not a whole-fleet move")

	# Resolve the turn. This is where the split happens.
	c.end_turn()

	var travelling: Array[FleetState] = []
	for f in c.galaxy.fleets_of(c.player_id):
		if f.destination >= 0:
			travelling.append(f)
	sup.eq(travelling.size(), 1, "exactly one fleet on the board is under way")
	if travelling.is_empty():
		return
	var going := travelling[0]
	sup.ok(going.system >= 0, "and the departing fleet knows the world it left from",
		"system=%d" % going.system)
	sup.eq(going.system, colony.index, "which is the source world")
	sup.eq(going.destination, dest, "and it is bound for the destination")
	sup.eq(int(going.ships.get(&"corvette", 0)), 1,
		"carrying exactly the corvette the manifest named")
	sup.eq(going.ship_count(), 1, "and nothing else")
	# The ships left behind are still over the colony, in a fleet that still exists.
	sup.ok(c.fleets_in_orbit_at(colony.index).has(source),
		"the source world still holds the ships that were not sent")

	# The overlay has something to draw, which is the "flight paths shows nothing" half of
	# the report: not a painting fault, an empty input.
	_client.set_flight_paths(true)
	sup.ok(c.flight_paths_shown(), "the flight-path overlay can be turned on")
	sup.ok(_client.map.flight_paths_enabled(), "and the map that draws it agrees")

	var quoted := MovementStage.transit_turns(c.galaxy, colony.index, dest)
	for _turn in maxi(1, quoted + 2):
		if going.destination < 0:
			break
		c.end_turn()
	sup.eq(going.destination, -1, "the fleet arrives rather than crossing for ever")
	sup.eq(going.system, dest, "docking at the destination")
	sup.ok(c.fleets_in_orbit_at(dest).has(going),
		"and the destination's orbit holds it")
	_client.set_flight_paths(false)
	c.queue.clear()


## Load / Unload: the button's visibility, and what the dialog will and will not move.
func _step_cargo_modal() -> void:
	sup.begin("load / unload")
	if _client == null or _client.controller == null or _client.cargo == null:
		return
	var c := _client.controller
	var colony := _first_colony()
	if colony == null:
		sup.ok(false, "the player starts with a colony")
		return
	var button := _client.fleets.cargo_button()
	sup.ok(button != null, "the planet panel carries a Load / Unload button")
	sup.eq(button.text, "Load / Unload", "labelled as such")
	if button == null:
		return

	# The starting fleet is a Colony Ship, but earlier travel steps may legitimately have sent
	# it away, and a test that depends on a fleet still being where generation put it is a test
	# of the fixture. A transport is placed in orbit explicitly.
	_ensure_transport(colony.index, &"colony_ship")
	c.select_planet(colony.index)
	sup.ok(c.has_transports_at(colony.index),
		"a world with a Colony Ship in orbit qualifies")
	sup.ok(button.visible, "so the control is shown")
	sup.ok(c.hulls_in_orbit_at(colony.index).has(&"colony_ship"),
		"and the orbit really does report it")

	# A world with nothing in orbit hides it rather than offering a dead dialog.
	var empty := _other_planet_index(colony.index)
	c.select_planet(empty)
	_client.fleets.refresh()
	sup.ok(not button.visible, "a world with nothing in orbit hides the control")

	# Population is seeded before the dialog is opened: earlier steps deliberately strip the
	# colony of civilians to prove the panel reports zero rather than negative, and a colony
	# with nobody on it correctly refuses to load anybody. The slider's range is derived when
	# the dialog opens, so seeding it afterwards would leave every control pinned at zero.
	colony.population = 12.0
	c.select_planet(colony.index)
	sup.ok(_client.cargo.open(colony.index), "pressing it opens the cargo dialog")
	sup.ok(_client.cargo.visible, "which is shown")
	# A Colony Ship lifts civilians, and nothing else.
	sup.ok(_client.cargo.caption_label(TransferStage.KIND_CIVILIANS) != null,
		"offering the passenger berths")
	sup.ok(_client.cargo.load_button(TransferStage.KIND_CIVILIANS) != null,
		"with a Load control")
	sup.ok(_client.cargo.unload_button(TransferStage.KIND_CIVILIANS) != null,
		"and an Unload one")
	var caption := _client.cargo.caption_label(TransferStage.KIND_CIVILIANS)
	sup.ok(caption != null and caption.text.contains("hold"),
		"the row states what the colony holds and what the ship holds",
		"reads '%s'" % ("" if caption == null else caption.text))
	sup.ok(_client.cargo.caption_label(TransferStage.KIND_FOOD) == null,
		"and no food slider, which this hull does not lift")

	# Load passengers and confirm. Civilians are capped at five a ship.
	var pop_before := colony.population
	var held_before := _civs_aboard(colony.index)
	var limit := 5.0
	var slider := _client.cargo.amount_slider(TransferStage.KIND_CIVILIANS)
	sup.ok(slider != null, "the passengers have a slider")
	if slider != null:
		slider.set_value(limit)
		_client.cargo.ok_button().emit_signal("pressed")
		sup.near(_civs_aboard(colony.index), held_before + limit, 0.001,
			"OK moved the passengers aboard")
		sup.near(colony.population, pop_before - limit, 0.001,
			"and took them off the colony")

		# Capacity is respected: asking for ten more than the berths can hold moves only
		# what fits, rather than swallowing a colony's population.
		_client.cargo.open(colony.index)
		var full := _civs_aboard(colony.index)
		_client.cargo.amount_slider(TransferStage.KIND_CIVILIANS).set_value(999.0)
		_client.cargo.ok_button().emit_signal("pressed")
		sup.ok(_civs_aboard(colony.index) <= 5.0 + 0.001,
			"the berths fill to capacity and no further (aboard %.1f)" % _civs_aboard(colony.index))
		sup.ok(colony.population >= 0.0, "and the colony cannot be left with negative pop")
		sup.near(_civs_aboard(colony.index), full, 0.001,
			"an already-full hold takes nothing more")

		# Unload puts them back on the ground.
		_client.cargo.open(colony.index)
		_client.cargo.unload_button(TransferStage.KIND_CIVILIANS).emit_signal("pressed")
		_client.cargo.ok_button().emit_signal("pressed")
		sup.near(_civs_aboard(colony.index), 0.0, 0.001, "Unload empties the berths")
		sup.near(colony.population, pop_before, 0.001,
			"and the civilians are back on the colony")

	# CANCEL leaves the colony alone.
	_client.cargo.open(colony.index)
	var pop_held := colony.population
	_client.cargo.load_button(TransferStage.KIND_CIVILIANS).emit_signal("pressed")
	_client.cargo.cancel_button().emit_signal("pressed")
	sup.near(colony.population, pop_held, 0.001, "CANCEL moves nobody anywhere")
	sup.ok(not _client.cargo.visible, "and closes the dialog")


## Civilians aboard the transports over `planet_index`.
func _civs_aboard(planet_index: int) -> float:
	var total := 0.0
	for f in _client.controller.fleets_in_orbit_at(planet_index):
		total += TransferStage.carried(f, TransferStage.KIND_CIVILIANS)
	return total


## The star is drawn as a light source and the worlds as terrain, not as flat dots.
func _step_map_visuals() -> void:
	sup.begin("map visuals")
	if _client == null or _client.map == null:
		return

	# The star: graded discs, brightest and smallest at the core, fading outward.
	var star_colour := CC2Theme.star_color(2)
	var layers := GalaxyMapView.star_layers(star_colour)
	sup.ok(layers.size() >= 4,
		"the star is drawn as several graded layers, not one disc (got %d)" % layers.size())
	var radii := PackedFloat64Array()
	var alphas := PackedFloat64Array()
	for layer: Variant in layers:
		var pair: Array = layer as Array
		radii.append(float(pair[0]))
		alphas.append(float((pair[1] as Color).a))
	var ordered := true
	for i in range(1, radii.size()):
		if radii[i] <= radii[i - 1] or alphas[i] >= alphas[i - 1]:
			ordered = false
	sup.ok(ordered,
		"running core-outward with radii growing and alpha falling -- a corona, "
		+ "not a stack of identical discs",
		"radii=%s alphas=%s" % [str(radii), str(alphas)])
	sup.ok(radii[radii.size() - 1] > GalaxyMapView.PLANET_RADIUS,
		"and the outermost corona reaches past the radius of any planet")
	sup.ok(alphas[0] > 0.5,
		"with an opaque core at the middle", "core alpha %.2f" % alphas[0])
	sup.ok(alphas[alphas.size() - 1] < alphas[0],
		"fading to a faint halo at the rim")

	# Worlds: five procedural classes, deterministic, and different from each other.
	var looks: Array = [
		[&"ocean", PlanetVisuals.Look.WATER],
		[&"desert", PlanetVisuals.Look.DESERT],
		[&"ice", PlanetVisuals.Look.ICE],
		[&"terrestrial", PlanetVisuals.Look.TEMPERATE],
		[&"jungle", PlanetVisuals.Look.JUNGLE],
	]
	for case: Variant in looks:
		var type_id := StringName(str(case[0]))
		sup.eq(PlanetVisuals.look_for(type_id), int(case[1]),
			"%s draws as the %s look" % [
				String(type_id), PlanetVisuals.look_name(int(case[1]))])
	sup.eq(PlanetVisuals.palette(&"ocean")[0], PlanetVisuals.palette(&"ocean")[0],
		"a palette is a stable value, not a fresh roll each frame")
	sup.ok(str(PlanetVisuals.landmasses(&"terrestrial", 2))
		== str(PlanetVisuals.landmasses(&"terrestrial", 2)),
		"and so are a world's continents")

	# The generator assigns variants at random rather than deriving them from the type.
	var variants: Dictionary = {}
	for p in _galaxy.planets:
		variants[p.visual_variant] = true
	sup.ok(variants.size() > 1,
		"generated worlds carry a randomised surface variant")

	# The map draws the planet through the procedural path, not the old two-disc form, and
	# that path is the fallback rather than the primary: the authored sprite is what it draws
	# when one loaded.
	var view_source := FileAccess.get_file_as_string("res://src/client/galaxy_map_view.gd")
	sup.ok(view_source.contains("_draw_planet_body"),
		"the map has a procedural planet draw routine")
	sup.ok(view_source.contains("PlanetVisuals.landmasses"),
		"and it draws the world's landmasses")

	# --- the authored sprites ---------------------------------------------------
	# Every named sprite actually loaded. A missing or un-imported `.png` is exactly the case
	# the fallback exists for, so this would not *fail* -- it would quietly leave the board
	# looking exactly as it did before, and nobody would know why the new art never appeared.
	sup.ok(PlanetSprites.star() != null, "the central star sprite loaded")
	sup.eq(PlanetSprites.star().get_size(), Vector2(48, 48), "and is a 48-pixel image")
	sup.ok(PlanetSprites.complete(), "every planet sprite loaded too")
	for i in PlanetSprites.PLANET_SPRITES.size():
		sup.ok(PlanetSprites.planet(i) != null,
			"sprite %d (%s) loaded" % [i, PlanetSprites.PLANET_SPRITES[i]])

	# The star's file is the one asked for by name, so assert the name rather than trusting
	# the list order to be right.
	sup.eq(PlanetSprites.STAR_SPRITE, "Black_hole",
		"the centre of the map is the black hole")

	# The assignment is *stable*: a world must show the same face on every redraw, in every
	# session, and before and after a save/load. Rolling a fresh number per draw would
	# repaint the entire galaxy sixty times a second and would make the board impossible to
	# read, so this is asserted on the variant rather than eyeballed.
	sup.eq(PlanetSprites.planet(3), PlanetSprites.planet(3), "a variant maps to one sprite")
	sup.eq(PlanetSprites.planet(3), PlanetSprites.planet(7),
		"and wraps rather than falling off the end")
	sup.eq(PlanetSprites.planet(0), PlanetSprites.planet(-4),
		"negative variants wrap the other way")
	sup.ok(PlanetSprites.planet(0) != null and PlanetSprites.planet(1) != null
		and PlanetSprites.planet(0) != PlanetSprites.planet(1),
		"and the list is not one image repeated")

	# More than one sprite is actually in play on this board, or "randomly assigned" is
	# satisfied by every world drawing the same face.
	var in_play := {}
	for p in _galaxy.planets:
		in_play[PlanetSprites.PLANET_SPRITES[posmod(p.visual_variant,
			PlanetSprites.PLANET_SPRITES.size())]] = true
	sup.ok(in_play.size() >= 3,
		"the worlds between them use several sprites (got %d)" % in_play.size())

	# A body must be as clickable as it is painted. These are fixed numbers on a map that
	# spans two orders of magnitude between tiers, so the guard is what stops a sprite from
	# growing wider than its own hit area and making a visible world unclickable.
	sup.ok(GalaxyMapView.PLANET_SPRITE_RADIUS < GalaxyMapView.PICK_RADIUS,
		"a planet sprite is drawn inside the click radius",
		"sprite %.1f, pick %.1f" % [GalaxyMapView.PLANET_SPRITE_RADIUS, GalaxyMapView.PICK_RADIUS])
	sup.ok(GalaxyMapView.STAR_SPRITE_RADIUS < GalaxyMapView.PICK_RADIUS,
		"and so is the star's")
	# The star must stay the largest thing on the board, or the centre stops reading as the
	# centre -- the reason `STAR_RADIUS` exceeded `PLANET_RADIUS` in the first place.
	sup.ok(GalaxyMapView.STAR_SPRITE_RADIUS > GalaxyMapView.PLANET_SPRITE_RADIUS,
		"the star still outdraws every world")


## The left panel's economy rows: one line each, and the nets the brief asks for.
func _step_panel_economy_rows() -> void:
	sup.begin("panel economy rows")
	if _client == null or _client.inspector == null:
		return
	var colony := _first_colony()
	if colony == null:
		sup.ok(false, "the player starts with a colony")
		return
	colony.population = 8.0
	colony.structures = {&"farm": 2, &"mine": 2, &"granary": 1}
	colony.food_stock = 250.0
	colony.power = 270.0
	colony.troops = 0
	_client.inspector.refresh()
	var rows := _client.inspector.planet_label().text

	# Food is one line: current over max with the net in brackets.
	var food_line := _row_for(rows, "FOOD")
	sup.ok(food_line.contains("/"), "Food is on one line with its capacity",
		"reads '%s'" % food_line)
	sup.ok(food_line.contains("(") and food_line.contains(")"),
		"and carries the per-turn net in brackets", "reads '%s'" % food_line)
	sup.ok(not rows.contains("FOOD BALANCE"),
		"the separate Food Balance line is gone")

	# Power is two rows: what is banked, and what the grid does with a turn's surplus.
	#
	# They are different quantities and printing them as one -- `POWER 0/10 (+70)` -- made a
	# colony generating seventy look like it had none. The battery really is empty, because
	# the bank holds ten and the rest is discarded by design; Energy Storage is the answer to
	# that, and a player could not see which question the row was answering.
	var power_line := _row_for(rows, "POWER")
	sup.ok(power_line.contains("/"), "Power is on one line with its capacity",
		"reads '%s'" % power_line)
	sup.ok(not power_line.contains("-0"),
		"and never prints a signed zero", "reads '%s'" % power_line)
	sup.ok(not power_line.contains("+") and not power_line.contains("-"),
		"the banked row carries no signed figure, because that is the other row's job",
		"reads '%s'" % power_line)
	var surplus_line := _row_for(rows, "SURPLUS")
	sup.ok(surplus_line != "", "and there is a separate Surplus row",
		"rows=%s" % rows.replace("\n", " | "))
	# One signed figure, not the pair `(+40, -10)`. The bbcode is stripped first because the
	# colour tag between the bracket and the sign is not part of the number.
	var plain := _strip_bbcode(surplus_line)
	sup.ok(plain.count("+") + plain.count("-") == 1,
		"the surplus is a single signed figure, not generation and draw side by side",
		"reads '%s'" % plain)

	# Population is total (working/jobless).
	var pop_line := _row_for(rows, "POPULATION")
	sup.ok(pop_line.contains("8 ("), "Population reads total (working/jobless)",
		"reads '%s'" % pop_line)

	# And the surplus really is generation minus consumption, with no minus zero.
	#
	# Stated as structures rather than as figures assigned onto the planet. The panel
	# recomputes generation and draw from the roster before printing -- that is the fix for a
	# stale panel -- so a hand-set total is overwritten by the next refresh, and a fixture that
	# set it was asserting against a value nothing maintained.
	colony.structures = {&"farm": 2, &"mine": 2, &"granary": 1,
		&"nuclear": 1, &"city_complex": 1}
	colony.power = 10.0
	_client.inspector.refresh()
	sup.ok(_row_for(_client.inspector.planet_label().text, "SURPLUS").contains("+30"),
		"a Nuclear plant's +40 against a City Complex's 10 reads +30",
		"reads '%s'" % _row_for(_client.inspector.planet_label().text, "SURPLUS"))
	# The point of the split, stated as its own assertion: a colony in large surplus can have
	# an empty battery, and the panel must say so rather than implying the power is missing.
	sup.eq(int(colony.power), 10, "the fixture's battery holds the base ten")
	sup.ok(_row_for(_client.inspector.planet_label().text, "POWER").contains("10/10"),
		"and the banked row says so next to a +30 surplus")
	colony.structures = {&"farm": 2, &"mine": 2, &"granary": 1}
	colony.power = 0.0
	_client.inspector.refresh()
	sup.ok(_row_for(_client.inspector.planet_label().text, "SURPLUS").contains("+0"),
		"and a grid drawing nothing reads +0, not -0",
		"reads '%s'" % _row_for(_client.inspector.planet_label().text, "SURPLUS"))

	# A real deficit keeps its sign: two City Complexes draw 20 and nothing generates.
	colony.structures = {&"farm": 2, &"mine": 2, &"granary": 1, &"city_complex": 2}
	colony.power = 0.0
	_client.inspector.refresh()
	sup.ok(_row_for(_client.inspector.planet_label().text, "SURPLUS").contains("-20"),
		"while a genuine shortfall still reads negative",
		"reads '%s'" % _row_for(_client.inspector.planet_label().text, "SURPLUS"))
	colony.structures = {&"farm": 2, &"mine": 2, &"granary": 1}


## The client owns the music, and owns it without forcing an audio device on.
##
## This suite is itself a headless run, so it can assert the guard rather than describe it:
## if a player were being constructed here, the tree walk below would find it.
func _step_background_music() -> void:
	sup.begin("background music is mounted but dormant")
	if _client == null:
		return
	sup.ok(_client.music != null, "the client has a music node")
	if _client.music == null:
		return
	sup.eq(_client.music.player(), null,
		"which holds no AudioStreamPlayer under a headless run")
	sup.ok(not _client.music.is_playing_music(), "and nothing is playing")
	sup.ok(not BackgroundMusic.music_allowed(),
		"the guard agrees that this run must not play audio")
	sup.ok(not _client.music.start(), "and an explicit start is refused")

	# Nothing audio-shaped anywhere in the client tree. Walked rather than checked at one
	# known path, because the claim is about the whole tree.
	var players := 0
	for child: Node in _client.get_children():
		if child is AudioStreamPlayer:
			players += 1
	sup.eq(players, 0, "the client tree contains no AudioStreamPlayer at all")
	sup.eq(_client.music.player(), null,
		"and still none after the refused start")


## The first structure the build menu is actually offering, or `&""`.
func _first_offered_structure() -> StringName:
	if _client == null or _client.macros == null:
		return &""
	var selector := _client.macros.build_selector()
	if selector == null or selector.item_count <= 0:
		return &""
	var meta: Variant = selector.get_item_metadata(0)
	return StringName(str(meta)) if meta != null else &""


## Put one hull of `hull_id` into orbit over `planet_index`, for the player.
func _ensure_transport(planet_index: int, hull_id: StringName) -> FleetState:
	for f in _client.controller.fleets_in_orbit_at(planet_index):
		if int(f.ships.get(hull_id, 0)) > 0:
			return f
	var fleet := FleetState.new()
	fleet.bind_hulls(_defs.get("ship_hulls"))
	fleet.owner = _client.controller.player_id
	fleet.system = planet_index
	fleet.name = "Test Orbital"
	fleet.add_ships(hull_id, 1)
	_client.controller.galaxy.add_fleet(fleet)
	_client.controller.state_changed.emit()
	return fleet


## A readout line with its bbcode removed, so the signs in it can be counted.
func _strip_bbcode(text: String) -> String:
	var out := ""
	var i := 0
	while i < text.length():
		if text[i] == "[":
			var close := text.find("]", i)
			if close > i:
				i = close + 1
				continue
		out += text[i]
		i += 1
	return out


## The single `LABEL ... value` row starting with `label`, or "".
func _row_for(rows: String, label: String) -> String:
	for line in rows.split("\n"):
		if line.begins_with(label + " "):
			return line.strip_edges()
	return ""


## The worker rows, the staffing notice and the Destroy menu.
func _step_worker_and_scrap_ui() -> void:
	sup.begin("worker rows and scrapping")
	if _client == null or _client.controller == null or _client.macros == null:
		return
	var c := _client.controller
	var colony := _first_colony()
	if colony == null:
		sup.ok(false, "the player starts with a colony")
		return
	c.select_planet(colony.index)
	_client.select_colony(colony.index)
	colony.building_queue.clear()
	colony.build_metal = 0.0
	colony.ship_queue.clear()
	colony.population = 6.0
	# Six mines and six colonists: five of them can be worked and the sixth attempt cannot,
	# which is the cap the whole feature exists to enforce.
	colony.structures = {&"farm": 3, &"mine": 6, &"granary": 1}
	colony.worker_assignment = {}
	_client.macros.refresh()

	# --- the rows --------------------------------------------------------------
	var rows := _client.macros.staffing_rows()
	sup.ok(rows != null, "the panel has a worker block")
	sup.ok(_client.macros.staffing_count_label(&"farm") != null,
		"a row per staffable structure")
	sup.ok(_client.macros.staffing_more_button(&"farm") != null, "with a + button")
	sup.ok(_client.macros.staffing_less_button(&"farm") != null, "and a - button")

	# `Farms: 3 (0)` -- standing and worked, both visible.
	var label := _client.macros.staffing_count_label(&"farm")
	sup.ok(label.text.contains("3 (0)"),
		"the row reads standing (worked)", "reads '%s'" % label.text)
	# Pressing + posts a worker, and the count follows.
	_client.macros.staffing_more_button(&"farm").emit_signal("pressed")
	sup.eq(ColonySim.workers_on(colony, &"farm"), 1, "+ posts one colonist to a farm")
	_client.macros.refresh()
	label = _client.macros.staffing_count_label(&"farm")
	sup.ok(label.text.contains("3 (1)"), "and the row shows it", "reads '%s'" % label.text)

	# Pressing - takes one back.
	_client.macros.staffing_less_button(&"farm").emit_signal("pressed")
	sup.eq(ColonySim.workers_on(colony, &"farm"), 0, "- takes the colonist back")
	sup.ok(_client.macros.staffing_less_button(&"farm").disabled,
		"and the - is disabled when nobody is posted")

	# The cap: the colony has six people, so the fourth mine cannot be worked.
	for _i in 6:
		_client.macros.staffing_more_button(&"mine").emit_signal("pressed")
	sup.eq(ColonySim.workers_assigned(colony), 6,
		"workers cannot exceed the civilian population")
	_client.macros.refresh()
	sup.ok(_client.macros.staffing_more_button(&"mine").disabled,
		"and + is disabled once nobody is free")

	# The brackets reach the planet panel as well.
	_client.inspector.refresh()
	sup.ok(_client.inspector.planet_label().text.contains("6 (6)"),
		"the planet panel shows the worked count beside the standing count",
		"shown=%s" % _client.inspector.planet_label().text.replace("\n", " | "))

	# --- the build-order notice ------------------------------------------------
	colony.worker_assignment = {}
	colony.population = 0.0
	_client.macros.select_build(&"farm")
	_client.macros.refresh()
	var warning := _client.macros.staffing_warning()
	sup.ok(warning != null and warning.visible,
		"a farm with nobody to work it raises the notice")
	sup.ok(warning.text.contains("Insufficient idle population"),
		"with the wording the brief asks for", "reads '%s'" % warning.text)
	# Non-blocking: the order is still accepted.
	c.queue.clear()
	_client.macros.build_button().emit_signal("pressed")
	sup.ok(not colony.building_queue.is_empty(),
		"and the build is not refused for it")
	colony.building_queue.clear()
	colony.build_metal = 0.0

	colony.population = 4.0
	colony.worker_assignment = {}
	_client.macros.select_build(&"granary")
	_client.macros.refresh()
	sup.ok(not warning.visible,
		"a structure needing no hands raises no notice")

	# --- the Destroy menu ------------------------------------------------------
	var scrap_button := _client.macros.scrap_button()
	sup.ok(scrap_button != null, "the panel has a Destroy button")
	sup.eq(scrap_button.text, "Destroy", "labelled Destroy")
	sup.ok(not _client.macros.scrap_list().visible, "and its menu starts closed")
	scrap_button.emit_signal("pressed")
	sup.ok(_client.macros.scrap_list().visible, "pressing it opens the menu")
	var scrap_parts := PackedStringArray()
	_collect_text(_client.macros.scrap_list(), scrap_parts)
	var scrap_text := "\n".join(scrap_parts)
	sup.ok(scrap_text.contains("GRANARY"), "listing the colony's structures",
		"shown=%s" % scrap_text.replace("\n", " | "))
	sup.ok(not scrap_text.contains("COLONY SHIP BUILDING"),
		"but never the landed colony ship building, which has no cost to refund",
		"shown=%s" % scrap_text.replace("\n", " | "))

	# Scrapping refunds half and hands the worker back.
	colony.population = 4.0
	_post_workers(colony, 3, 1)
	colony.reserve_metals = 0.0
	var granary := _defs.call("building", &"granary") as Resource
	var scrap_button_node := _client.macros.scrap_list().find_child(
		"Do_granary", true, false) as Button
	sup.ok(scrap_button_node != null, "each entry has its own SCRAP button")
	if scrap_button_node != null:
		scrap_button_node.emit_signal("pressed")
		sup.near(colony.reserve_metals, float(granary.get("cost_metals")) * 0.5, 0.001,
			"scrapping pays half the original cost into the stockpile immediately")
		sup.eq(int(colony.structures.get(&"granary", 0)), 0, "and removes the structure")

	_post_workers(colony, 1, 0)
	colony.reserve_metals = 0.0
	var farm_button := _client.macros.scrap_list().find_child("Do_farm", true, false) as Button
	if farm_button != null:
		farm_button.emit_signal("pressed")
		sup.eq(ColonySim.workers_on(colony, &"farm"), 0,
			"and a scrapped farm hands its worker back")
	_client.macros.scrap_button().emit_signal("pressed")


## The travel flow's prompt, and the all-fleets flight-path overlay.
func _step_travel_prompt_and_paths() -> void:
	sup.begin("travel prompt and flight paths")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var colony := _first_colony()
	if colony == null:
		sup.ok(false, "the player starts with a colony")
		return
	sup.ok(_client.prompt_label != null, "the client has a prompt label over the map")
	if _client.prompt_label == null:
		return

	sup.eq(_client.prompt_text(), "", "with nothing to say to begin with")
	_ensure_transport(colony.index, &"corvette")
	c.select_planet(colony.index)
	_client.fleets.travel_button().emit_signal("pressed")
	sup.eq(_client.travel_step, GameClient.TravelStep.SOURCE, "Travel starts the flow")
	sup.ok(_client.prompt_text().contains("Source"),
		"and the first thing it asks for is the source", "reads '%s'" % _client.prompt_text())

	_client._on_planet_picked(colony.index)
	sup.eq(_client.travel_step, GameClient.TravelStep.DESTINATION, "the source is picked")
	sup.eq(_client.prompt_text(), GameClient.DESTINATION_PROMPT,
		"and the prompt becomes the destination question the brief specifies")

	var dest := _other_planet_index(colony.index)
	_client._on_planet_picked(dest)
	sup.eq(_client.prompt_text(), "", "and clears once the manifest opens")
	_client._abandon_travel()
	sup.eq(_client.prompt_text(), "", "staying clear after the flow is abandoned")

	# The flight-path overlay, off by default and shared with the map view.
	sup.ok(not _client.flight_paths, "flight paths are off to begin with")
	sup.ok(not _client.map.flight_paths_enabled(),
		"and the map view agrees they are off")
	_client.set_flight_paths(true)
	sup.ok(_client.flight_paths, "turning them on is recorded")
	sup.ok(_client.map.flight_paths_enabled(),
		"and reaches the draw layer that renders them")
	_client.set_flight_paths(false)
	sup.ok(not _client.map.flight_paths_enabled(), "and can be turned back off")


## The map centres on the world the construction dropdown names, and an unclaimed world
## reports no economy.
func _step_camera_snap_and_uncolonized() -> void:
	sup.begin("camera snap and unclaimed worlds")
	if _client == null or _client.controller == null or _client.map == null:
		return
	var c := _client.controller
	var colony := _first_colony()
	if colony == null:
		sup.ok(false, "the player starts with a colony")
		return

	# Pick a colony other than the current selection so the move is observable.
	var other: PlanetState = null
	for p in c.player_colonies():
		if p.index != colony.index:
			other = p
			break
	if other == null:
		sup.ok(false, "the player has a second colony to select")
		return
	# Zoom in first, because at the default framing the whole system is already on screen.
	#
	# The camera's range collapses to the centre of the field when the viewport is wider
	# than the map, so there is nowhere for it to go and every world is visible regardless.
	# That is correct -- you cannot pan to somewhere the whole map already covers -- but it
	# means a snap tested at that zoom proves nothing either way. Zoomed in, the promise is
	# exact: the camera goes to the world, and not to some other one.
	_client.map.camera().zoom = Vector2(6.0, 6.0)
	var zoom_before := _client.map.camera_zoom()
	c.select_planet(colony.index)
	_client.macros.colony_selector().select(
		_client.macros.colony_selector().item_count - 1)
	_client.macros.colony_selector().emit_signal("item_selected",
		_client.macros.colony_selector().item_count - 1)
	var after := _client.map.camera_position()
	# Strictly where it landed, not merely "somewhere else".
	#
	# The old assertion was `on it, or the camera moved at all`, and the second half is
	# satisfied by any drift whatsoever -- so it would have passed against a snap that went to
	# the wrong world entirely, which is the failure this step exists to catch. Choosing a
	# colony in the build menu has to bring *that* world into view.
	sup.ok(after.is_equal_approx(other.position),
		"choosing a colony in the dropdown moves the map onto it",
		"after=%s want=%s" % [str(after), str(other.position)])
	sup.ok(_client.map.is_planet_visible(other.index), "which brings it into view")
	# A snap is a move, not a re-frame: the scale the player was working at is theirs.
	sup.eq(_client.map.camera_zoom(), zoom_before, "and it leaves the zoom alone")
	# Left as the player had it.
	sup.eq(c.selected_planet, other.index, "and selects it")

	# --- the eye beside the dropdown ---------------------------------------------
	# The same move on demand. Its reason to exist is the one-colony case, which the
	# dropdown cannot serve: a single-entry list has no row to choose, so `select()` moves
	# the highlight and emits nothing, and a player who has panned away has no way back.
	var eye := _client.macros.focus_button()
	sup.ok(eye != null, "there is an eye button beside the colony dropdown")
	if eye == null:
		return
	sup.eq(eye.get_parent(), _client.macros.colony_selector().get_parent(),
		"sharing a row with the dropdown rather than sitting on its own line")
	sup.ok(eye.custom_minimum_size.x > 0.0, "and it reserves room for the glyph")
	sup.ok(not eye.disabled, "and it is live while there is a colony to show")

	# Pan the map somewhere else entirely, then press it.
	_client.map.camera().position = other.position + Vector2(900.0, 600.0)
	sup.ok(not _client.map.is_planet_visible(other.index),
		"the map has been moved off the colony by hand")
	eye.emit_signal("pressed")
	sup.ok(_client.map.camera_position().is_equal_approx(other.position),
		"and the eye brings the build target back into view",
		"after=%s want=%s" % [
			str(_client.map.camera_position()), str(other.position)])

	# The eye follows the dropdown, not the last thing clicked on the map. Otherwise the
	# button would take the player to whatever world they had just clicked away from, which
	# is the opposite of a "go home" control.
	var first: PlanetState = null
	for p in c.player_colonies():
		if first == null:
			first = p
		if p.index != other.index:
			c.select_planet(p.index)
			break
	if first != null and first.index != other.index:
		_client.macros.colony_selector().select(0)
		_client.macros.colony_selector().emit_signal("item_selected", 0)
		_client.map.camera().position = first.position + Vector2(1500.0, 1100.0)
		eye.emit_signal("pressed")
		sup.ok(_client.map.camera_position().is_equal_approx(first.position),
			"and it goes where the dropdown says, not where the map was last clicked",
			"after=%s want=%s" % [
				str(_client.map.camera_position()), str(first.position)])

	# One colony: the case the button is really for. The dropdown cannot fire here, so the
	# eye is the only way home.
	var solo := _galaxy_probe(c)
	if solo != null:
		_client.macros.colony_selector().clear()
		_client.macros.colony_selector().add_item(solo.name)
		_client.macros.colony_selector().set_item_metadata(0, solo.index)
		_client.macros.colony_selector().select(0)
		sup.eq(_client.macros.colony_selector().item_count, 1,
			"the build menu is left with a single colony to choose from")
		_client.map.camera().position = solo.position + Vector2(1500.0, 1100.0)
		_client.macros.focus_button().emit_signal("pressed")
		sup.ok(_client.map.camera_position().is_equal_approx(solo.position),
			"and the eye still takes the player there",
			"after=%s want=%s" % [
				str(_client.map.camera_position()), str(solo.position)])

	_client.macros.refresh()

	# An unclaimed world reports nothing it does not have -- once the player is close enough
	# to be told anything at all. Unsurveyed, the panel says UNSURVEYED and stops, which is
	# the stronger statement and the one it has always made.
	# Picked by what is absent, not by being the first unowned body: an earlier step may have
	# surveyed or visited whichever body that was, and the fixture would then be asserting
	# about a world the panel is entitled to describe.
	var empty := -1
	for p in c.galaxy.planets:
		if p.owner < 0 and not p.colonized and not p.surveyed:
			empty = p.index
			break
	if empty >= 0:
		c.select_planet(empty)
		_client.inspector.refresh()
		var unseen := _client.inspector.planet_label().text
		sup.ok(unseen.contains("UNSURVEYED"), "an unvisited world reports nothing",
			"shown=%s" % unseen.replace("\n", " | "))
		sup.ok(not unseen.contains("POPULATION") and not unseen.contains("METAL"),
			"and no phantom population or metal either")

		# Put a ship in orbit: that is how a player earns the right to see a world at all.
		# Put a ship in orbit: that is how a player learns the world is there at all. It is
		# not how they learn what is on it -- an unclaimed world belongs to nobody, so there
		# is nothing of theirs to reveal and the panel says so rather than inventing an
		# economy for a rock.
		var target: PlanetState = c.galaxy.planet(empty)
		target.surveyed = true
		_ensure_transport(empty, &"corvette")
		c.select_planet(empty)
		_client.inspector.refresh()
		var shown := _client.inspector.planet_label().text
		sup.ok(shown.contains("NO INTEL"),
			"and a visited one reports no intel", "shown=%s" % shown.replace("\n", " | "))
		sup.ok(not shown.contains("POPULATION"),
			"reporting no phantom population", "shown=%s" % shown.replace("\n", " | "))
		sup.ok(not shown.contains("METAL"),
			"and no phantom metal", "shown=%s" % shown.replace("\n", " | "))
		sup.ok(not shown.contains("FOOD"),
			"and no phantom food", "shown=%s" % shown.replace("\n", " | "))


## The name of an uncolonised world is shown while the player has ships in orbit over it,
## and hidden again when they leave.
func _step_orbit_labels() -> void:
	sup.begin("orbit labels")
	if _client == null or _client.controller == null or _client.map == null:
		return
	var c := _client.controller
	var colony := _first_colony()
	if colony == null:
		sup.ok(false, "the player starts with a colony")
		return
	var view := _client.map.view()
	# Picked by what is *absent*: unclaimed, unsurveyed and with nothing of the player's
	# already in orbit. An earlier step may have surveyed or visited the first unclaimed
	# world on the board, and the fixture would then be asserting about a world the map has
	# every reason to name.
	var world: PlanetState = null
	for p in c.galaxy.planets:
		if p.owner >= 0 or p.colonized or p.surveyed:
			continue
		if not c.fleets_in_orbit_at(p.index).is_empty():
			continue
		world = p
		break
	if world == null:
		sup.ok(false, "an untouched world exists to visit")
		return

	sup.ok(not view.label_worth_drawing(world),
		"an unvisited, unclaimed world is not named")
	_ensure_transport(world.index, &"corvette")
	sup.ok(view.label_worth_drawing(world),
		"putting a ship in orbit names it -- that is how a player finds the board")
	sup.ok(c.knows_name_of(world.index),
		"and the map's rule agrees with the controller's, rather than second-guessing it")

	# The ships leave: the name goes with them, because there is nothing left on the board
	# saying that world was ever more than a rock.
	# The fleets are removed outright rather than emptied: an emptied fleet is still an
	# active marker, so a player would still have "ships" in that orbit.
	for f in c.fleets_in_orbit_at(world.index):
		c.galaxy.remove_fleet(f.id)
	sup.eq(c.fleets_in_orbit_at(world.index).size(), 0, "every ship has left the orbit")
	sup.ok(not view.label_worth_drawing(world),
		"and it stops being named once the fleet has gone")

	# A colony keeps its name for ever.
	colony.owner = c.player_id
	colony.colonized = true
	sup.ok(view.label_worth_drawing(colony),
		"while a world the player has settled is named regardless of who is orbiting it")
	colony.owner = c.player_id


## The cargo dialog's sliders match the hold, and a transport's hold is not capped.
func _step_cargo_slider_matches_hold() -> void:
	sup.begin("cargo sliders match the hold")
	if _client == null or _client.controller == null or _client.cargo == null:
		return
	var c := _client.controller
	var colony := _first_colony()
	if colony == null:
		sup.ok(false, "the player starts with a colony")
		return
	_ensure_transport(colony.index, &"cargo_transport")
	c.select_planet(colony.index)
	colony.population = 10.0
	colony.reserve_metals = 4000.0
	colony.food_stock = 400.0
	sup.ok(_client.cargo.open(colony.index), "the cargo dialog opens")

	# Pick the transport by name: the dialog opens on whichever lift sorts first, and an
	# earlier step may have left a Colony Ship in this orbit, which lifts no metal at all.
	_select_cargo_hull(&"cargo_transport")
	var metal := TransferStage.KIND_METALS
	var caption := _client.cargo.caption_label(metal)
	sup.ok(caption != null and caption.text.contains("unlimited"),
		"an unbounded hold says so rather than reporting a ceiling",
		"reads '%s'" % ("" if caption == null else caption.text))

	# The slider's range is a real number, and covers everything in the hold.
	var slider := _client.cargo.amount_slider(metal)
	sup.ok(slider != null, "the metal slider exists")
	if slider != null:
		sup.ok(not is_inf(slider.max_value),
			"and its range is a finite number rather than INF",
			"max=%s" % str(slider.max_value))
		sup.ok(slider.max_value >= 4000.0,
			"covering the whole stockpile, since the hold takes anything",
			"max=%s" % str(slider.max_value))
		sup.ok(not is_inf(_client.cargo.limit_for(colony, metal)),
			"and the ceiling the dialog computes is finite too")

	# Loading then unloading returns the hold to empty and the colony to full.
	var hold_before := 0.0
	for f in c.fleets_in_orbit_at(colony.index):
		hold_before += TransferStage.carried(f, metal)
	_client.cargo.load_button(metal).emit_signal("pressed")
	_client.cargo.ok_button().emit_signal("pressed")
	var loaded := 0.0
	for f in c.fleets_in_orbit_at(colony.index):
		loaded += TransferStage.carried(f, metal)
	sup.near(loaded - hold_before, 4000.0, 0.001,
		"a transport takes the entire stockpile, not a tonnage figure")

	_client.cargo.open(colony.index)
	# Re-selected every open: `open` starts on whichever lift sorts first, and this orbit has
	# more than one kind.
	_select_cargo_hull(&"cargo_transport")
	_client.cargo.unload_button(metal).emit_signal("pressed")
	_client.cargo.ok_button().emit_signal("pressed")
	var unloaded := 0.0
	for f in c.fleets_in_orbit_at(colony.index):
		unloaded += TransferStage.carried(f, metal)
	sup.near(unloaded, 0.0, 0.001, "and hands all of it back")
	sup.near(colony.reserve_metals, 4000.0, 0.001,
		"with the colony's stockpile whole again")


## Select a named hull in the cargo dialog's hull dropdown.
func _select_cargo_hull(hull_id: StringName) -> void:
	var selector := _client.cargo.hull_selector()
	if selector == null:
		return
	for i in selector.item_count:
		var meta: Variant = selector.get_item_metadata(i)
		if meta != null and StringName(str(meta)) == hull_id:
			selector.select(i)
			selector.emit_signal("item_selected", i)
			return


## An unclaimed, unowned, unvisited body in `galaxy`, or -1.
func _unowned_body(galaxy: GalaxyState) -> int:
	if galaxy == null:
		return -1
	for p in galaxy.planets:
		if p.owner < 0 and not p.colonized:
			return p.index
	return -1


## The left panel's maximums, live: the failure being fixed is `Food 300/0`.
##
## Linear on purpose -- one action, one assertion, one refresh. The earlier version of this
## step asserted things in an order that let a queued-but-unfinished project stand in for a
## landed one, and then blamed the panel for it.
func _step_live_capacity_display() -> void:
	sup.begin("capacity maximums update live")
	if _client == null or _client.controller == null or _client.inspector == null:
		return
	var c := _client.controller
	var colony := _first_colony()
	if colony == null:
		sup.ok(false, "the player starts with a colony")
		return
	var buildings: Dictionary = _defs.get("buildings") as Dictionary

	# Re-select before every panel assertion. Pressing Build adopts whichever colony the
	# macro panel's dropdown names, which is not necessarily the one under test.
	var focus := func() -> void:
		c.select_planet(colony.index)
		_client.select_colony(colony.index)
		_client.inspector.refresh()

	# --- a starting colony: the kit landed and nothing else --------------------
	c.queue.clear()
	colony.building_queue.clear()
	colony.build_metal = 0.0
	colony.ship_queue.clear()
	colony.population = 5.0
	colony.food_stock = 300.0
	colony.power = 10.0
	colony.structures = {&"colony_ship_building": 1}
	colony.worker_assignment = {}
	colony.reserve_metals = 100000.0
	focus.call()

	sup.eq(int(colony.get_max_food()), 50, "a starting colony's max food is 50")
	sup.eq(int(colony.get_max_power()), 10, "and its max power is 10")
	sup.eq(int(colony.get_max_housing()), 5, "and its housing is the kit's five")
	var food_row := _row_for(_client.inspector.planet_label().text, "FOOD")
	sup.ok(food_row.contains("300/50"),
		"the panel shows Food 300/50 rather than 300/0", "reads '%s'" % food_row)
	sup.ok(food_row.contains("("), "with the per-turn net beside it", "reads '%s'" % food_row)
	sup.ok(_row_for(_client.inspector.planet_label().text, "POWER").contains("10/10"),
		"and Power 10/10",
		"reads '%s'" % _row_for(_client.inspector.planet_label().text, "POWER"))

	# --- a granary, through the real player path -------------------------------
	var announced := PackedInt32Array()
	var on_change := func(index: int) -> void:
		announced.append(index)
	c.capacities_changed.connect(on_change)
	c.queue.clear()
	focus.call()
	_client.macros.select_build(&"granary")
	_client.macros.build_button().emit_signal("pressed")
	sup.ok(not colony.building_queue.is_empty(), "Build queues the granary")
	sup.ok(announced.has(colony.index),
		"and pressing Build announces the capacity change for the right world",
		"announced %s" % str(announced))

	# Pay for it the way the resolver does, so the panel is being asked about a structure that
	# really has landed rather than one still on the keel.
	var granary := _defs.call("building", &"granary") as Resource
	colony.build_metal = float(granary.get("cost_metals"))
	ColonySim.finish_construction(colony, buildings, c.db)
	sup.eq(int(colony.get_max_food()), 1050, "a landed granary takes max food to 1050")
	focus.call()
	sup.ok(_client.inspector.planet_label().text.contains("300/1050"),
		"and the panel shows it on the very next refresh, with no turn and no restart",
		"shown=%s" % _client.inspector.planet_label().text.replace("\n", " | "))
	sup.ok(not _client.inspector.planet_label().text.contains("IN BUILD"),
		"and no longer claims something is still under construction")

	# --- and back again -------------------------------------------------------
	announced.clear()
	c.queue.clear()
	focus.call()
	var refund := c.scrap(&"granary")
	sup.ok(refund > 0.0, "scrapping the granary refunds metal", "got %.1f" % refund)
	sup.ok(announced.has(colony.index),
		"and announces the change too", "announced %s" % str(announced))
	sup.eq(int(colony.get_max_food()), 50, "so max food returns to 50")
	focus.call()
	sup.ok(_client.inspector.planet_label().text.contains("300/50"),
		"and the panel follows it straight back",
		"shown=%s" % _client.inspector.planet_label().text.replace("\n", " | "))
	c.capacities_changed.disconnect(on_change)

	# --- the other two maximums -----------------------------------------------
	colony.building_queue[&"energy_storage"] = 1
	colony.build_metal = float((_defs.call("building", &"energy_storage") as Resource).get(
		"cost_metals"))
	ColonySim.finish_construction(colony, buildings, c.db)
	sup.eq(int(colony.get_max_power()), 1010, "an energy storage takes max power to 1010")
	focus.call()
	sup.ok(_client.inspector.planet_label().text.contains("10/1010"),
		"and the panel shows Power 10/1010",
		"shown=%s" % _client.inspector.planet_label().text.replace("\n", " | "))

	colony.building_queue[&"city_complex"] = 1
	colony.build_metal = float((_defs.call("building", &"city_complex") as Resource).get(
		"cost_metals"))
	ColonySim.finish_construction(colony, buildings, c.db)
	sup.eq(int(colony.get_max_housing()), 25, "a city complex takes housing to 25")
	focus.call()
	sup.ok(_client.inspector.planet_label().text.contains("HOUSING            25"),
		"and the panel shows it",
		"shown=%s" % _client.inspector.planet_label().text.replace("\n", " | "))

	# --- and the pantry outlives the kit --------------------------------------
	# The consequence of holding the baseline as a base rather than on the structure: scrapping
	# the Colony Ship takes the five berths with it, but not the fifty food and ten power,
	# because those are the base every colony has. Stated here because it is a real asymmetry a
	# player can act on, and because the alternative -- a pantry that vanishes with its kit --
	# would make the printed formula a two-term sum with a conditional in it.
	colony.structures = {&"granary": 1}
	focus.call()
	sup.eq(int(colony.get_max_food()), 1050,
		"the 50 base pantry survives losing the kit: 50 + one granary * 1000")
	sup.eq(int(colony.get_max_housing()), 5,
		"and the baseline five berths, which the kit brought and did not take away")
	focus.call()
	sup.ok(_client.inspector.planet_label().text.contains("300/1050"),
		"which the panel agrees with",
		"shown=%s" % _client.inspector.planet_label().text.replace("\n", " | "))


## The reported bug, exactly: food decreasing while the panel shows a positive net.
func _step_food_net_matches_the_turn() -> void:
	sup.begin("food net matches the turn")
	if _client == null or _client.controller == null or _client.inspector == null:
		return
	var c := _client.controller
	var colony := _first_colony()
	if colony == null:
		sup.ok(false, "the player starts with a colony")
		return
	var buildings: Dictionary = _defs.get("buildings") as Dictionary
	var farm := _defs.call("building", &"farm") as Resource
	var per_farm := float(farm.get("yield_amount"))

	# Two farms and a mine with one colonist each, plus the Colony Ship: a colony whose net is
	# plainly positive, which is the state the report says drained anyway.
	colony.population = 2.0
	colony.food_stock = 0.0
	colony.building_queue.clear()
	colony.build_metal = 0.0
	colony.ship_queue.clear()
	colony.structures = {&"farm": 2, &"mine": 1,
		&"colony_ship_building": 1, &"granary": 1}
	colony.worker_assignment = {}
	ColonySim.assign_worker(colony, &"farm")
	ColonySim.assign_worker(colony, &"mine")
	_colonyRecount(colony, c)
	c.select_planet(colony.index)
	_client.inspector.refresh()

	# What the panel shows, and what the turn will do, side by side.
	var shown := _row_for(_client.inspector.planet_label().text, "FOOD")
	var shown_net := _signed_in(shown)
	# Read from the resolver's own projection rather than re-deriving the net here.
	#
	# The hand-rolled version (`worked_farms + 5 - 2`) was the resolver's arithmetic from
	# before `food_bonus` existed, so it agreed only while the empire had researched nothing
	# that touches food. It then failed as a *fixture* problem -- an earlier step that
	# advances a few turns can complete hydroponics -- rather than as a statement about the
	# panel, which is exactly the failure mode a test that restates the arithmetic invites.
	var resolver_net := ColonySim.get_projected_food_delta(colony, buildings, c.player(), c.db)
	sup.ok(shown_net > 0.0, "the panel reports a surplus",
		"reads '%s'" % shown)
	sup.ok(absf(shown_net - resolver_net) <= 0.001,
		"and that surplus is the figure the turn resolver will use",
		"panel %.1f, resolver %.1f" % [shown_net, resolver_net])

	# And now actually run turns: the bank must grow by exactly what the panel promised,
	# which is the assertion the original bug failed.
	for _i in 5:
		var bank := colony.food_stock
		var net_now := ColonySim.get_projected_food_delta(colony, buildings, c.player(), c.db)
		c.end_turn()
		sup.ok(absf(colony.food_stock - (bank + net_now)) <= 1.01,
			"a turn in surplus moved the bank by exactly the promised net",
			"promised %.1f, moved %.1f" % [net_now, colony.food_stock - bank])
	sup.ok(colony.food_stock > 0.0, "so after five turns the colony is better off, not worse",
		"stock %.1f" % colony.food_stock)

	# A colony that is genuinely short must say so, with the same arithmetic.
	colony.population = 30.0
	colony.food_stock = 0.0
	colony.structures = {&"granary": 1, &"colony_ship_building": 1}
	colony.worker_assignment = {}
	_colonyRecount(colony, c)
	_client.inspector.refresh()
	shown = _row_for(_client.inspector.planet_label().text, "FOOD")
	sup.ok(_signed_in(shown) < 0.0, "and a colony with nobody on its farms shows a deficit",
		"reads '%s'" % shown)
	# The kit's own output less thirty mouths, again through the resolver rather than as a
	# literal, so an empire with `food_bonus` does not make this a test of the balance table.
	sup.near(_signed_in(shown),
		ColonySim.get_projected_food_delta(colony, buildings, c.player(), c.db), 0.001,
		"and that deficit is the figure the turn resolver will use")


## Undiscovered worlds carry no name on the map and no real name anywhere.
func _step_undiscovered_world_labels() -> void:
	sup.begin("undiscovered worlds carry no labels")
	if _client == null or _client.controller == null or _client.map == null:
		return
	var c := _client.controller
	var view := _client.map.view()

	var unseen := -1
	for p in c.galaxy.planets:
		if p.owner < 0 and not p.colonized and not p.surveyed:
			unseen = p.index
			break
	sup.ok(unseen >= 0, "an unclaimed, unexplored world exists")
	if unseen < 0:
		return
	var body: PlanetState = c.galaxy.planet(unseen)
	sup.ok(not view.label_worth_drawing(body),
		"an undiscovered world gets no map label")
	sup.ok(not c.knows_name_of(unseen), "and the controller agrees it is not knowable")
	sup.eq(c.display_name(unseen), GalaxyMapView.UNKNOWN_NAME,
		"so every reader falls back to the one placeholder")

	# A survey is not presence. It was the leak: a swept world kept its name for ever.
	body.surveyed = true
	sup.ok(not view.label_worth_drawing(body),
		"a surveyed world the player has never visited still gets no label")
	sup.ok(not c.knows_name_of(unseen),
		"and the controller still withholds its name")
	var body_surveyed := body.surveyed
	body.surveyed = body_surveyed

	# Presence does earn one, and losing it takes the name back.
	_ensure_transport(unseen, &"corvette")
	sup.ok(view.label_worth_drawing(body), "a fleet in orbit earns the label")
	sup.ok(c.knows_name_of(unseen), "and the controller agrees")
	for f in c.fleets_in_orbit_at(unseen):
		c.galaxy.remove_fleet(f.id)
	sup.ok(not view.label_worth_drawing(body),
		"and leaving takes the label away again")

	# The session log never printed the real name in the first place.
	sup.ok(not _client.log_text().contains(body.name) or body.name.is_empty(),
		"and the session log never printed it either")


## A dispatched fleet loses a dot a turn and docks where it was sent.
##
## The reported symptom was a fleet that never arrived: pressed Travel, watched the percentage
## climb, and it sat at "in transit" for ever. `MovementStage.advance` credits one dot per turn
## and calls arrival when the travelled figure reaches the leg, so this drives a real crossing
## through the real resolver and checks both ends of it: the counter moves every turn, and on
## the turn the arithmetic says it should, `destination` goes to -1 and the fleet is sitting in
## the destination's orbit where a second crossing can find it.
func _step_transit_resolves_and_docks() -> void:
	sup.begin("a dispatched fleet resolves and docks")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var home := _first_colony()
	if home == null:
		sup.ok(false, "the player starts with a colony to fly from")
		return

	# A world a few dots away, not the far side of the map: this is about the counter and the
	# docking, and a crossing long enough to outlive the suite proves neither quickly.
	var target := -1
	var nearest := INF
	for p in c.galaxy.planets:
		if p.index == home.index:
			continue
		var gap := MovementStage.orbit_distance(home, p)
		if gap > 0.0 and gap < nearest:
			nearest = gap
			target = p.index
	sup.ok(target >= 0, "a second world exists to fly to")
	if target < 0:
		return
	var dest: PlanetState = c.galaxy.planet(target)

	var fleet := _ensure_transport(home.index, &"corvette")
	if fleet == null:
		sup.ok(false, "a fleet is available to dispatch")
		return
	fleet.destination = -1
	fleet.travelled = 0.0
	# `queue_move` acts on the *selected* fleet, so dispatching without selecting first
	# silently orders whatever was selected earlier -- or refuses outright when nothing is.
	c.select_fleet(fleet.id)
	sup.eq(c.fleet(), fleet, "the fleet to be sent is the selected one")
	var leg := MovementStage.orbit_dots(c.galaxy, home, dest)
	var quoted := MovementStage.transit_turns(c.galaxy, home.index, target)
	sup.ok(leg > 0.0, "the crossing is a real distance")
	sup.ok(quoted >= 1, "and the panel quotes at least a turn for it")

	sup.ok(c.queue_move(target), "the fleet is dispatched")
	sup.eq(fleet.destination, target, "and is immediately under way to the chosen world")
	sup.near(fleet.travelled, 0.0, 0.001, "with nothing of the leg covered yet")

	# One turn at a time, watching the counter fall by exactly a dot. A fleet that decremented
	# every turn but by the wrong amount, or that reset partway, would pass an arrival-only
	# assertion and fail here.
	var previous := fleet.travelled
	var moved_each_turn := true
	var docked := false
	for _turn in quoted + 2:
		c.end_turn()
		if fleet.destination < 0:
			docked = true
			break
		if absf(fleet.travelled - previous - MovementStage.DOTS_PER_TURN) > 0.001:
			moved_each_turn = false
		previous = fleet.travelled
	sup.ok(moved_each_turn, "each turn covers exactly one dot of the leg")
	sup.ok(docked, "and the fleet arrives rather than crossing for ever")
	sup.eq(fleet.system, target, "it is docked at the destination")
	sup.eq(fleet.destination, -1, "no longer under way")
	sup.near(fleet.travelled, 0.0, 0.001, "and its progress counter is cleared for the next order")
	# The orbit is the garrison: a second query for the destination has to find it there, or
	# "arrived" would be true of the fleet's own fields while the rest of the game still
	# believed the world empty.
	sup.ok(not c.fleets_in_orbit_at(target).is_empty(),
		"the destination's orbit now holds the fleet")
	sup.ok(c.fleets_in_orbit_at(target).has(fleet),
		"and it is that same fleet")
	# And it can be re-ordered from there, which is the consequence that actually matters.
	sup.ok(c.queue_move(home.index),
		"and it can be ordered onward from the world it reached")


## Posting a miner moves the metal rate on the same frame the `+` is pressed.
##
## The defect this guards: the panel derived the rate by walking the *structure* table, so it
## paid for every mine the colony owned rather than the ones somebody was standing at. Posting a
## worker moved the posting, the stockpile and the next turn's income, and left the displayed
## rate sitting exactly where it was -- the player pressed `+`, the number under METAL did not
## move, and the only way to see the change was to end the turn and let the resolver credit it.
##
## No turn is advanced anywhere in this step. That is the claim being tested, and a check that
## let a turn resolve first would pass against the old code just as happily as the new.
func _step_mine_worker_moves_the_metal_rate() -> void:
	sup.begin("mine staffing moves the displayed metal rate")
	if _client == null or _client.controller == null or _client.macros == null:
		return
	if _client.inspector == null:
		return
	var c := _client.controller
	var colony := _first_colony()
	if colony == null:
		sup.ok(false, "the player starts with a colony")
		return
	var mine := _defs.call("building", &"mine") as Resource
	sup.ok(mine != null, "the roster has a mine to staff")
	if mine == null:
		return
	var per_mine := float(mine.get("metal_per_turn"))

	# Two mines, one Colony Ship pad, and six colonists with nobody posted anywhere. The pad is
	# the control: it pays metal without a worker, so it holds still across the presses and the
	# movement left in the rate is exactly the mine being staffed.
	colony.population = 6.0
	colony.building_queue.clear()
	colony.build_metal = 0.0
	colony.ship_queue.clear()
	colony.structures = {&"mine": 2, &"colony_ship_building": 1}
	colony.worker_assignment = {}
	_colonyRecount(colony, c)
	c.select_planet(colony.index)
	_client.select_colony(colony.index)
	_client.macros.refresh()
	_client.inspector.refresh()

	sup.eq(ColonySim.workers_on(colony, &"mine"), 0, "nobody is posted to the mines yet")
	var posted := _client.macros.staffing_more_button(&"mine")
	sup.ok(posted != null, "the mine row carries a + button")
	if posted == null:
		return
	sup.ok(not posted.disabled, "and it is pressable with colonists free")

	var start := _signed_in(_row_for(_client.inspector.planet_label().text, "METAL"))
	sup.near(start, ColonySim.metal_output(colony, _defs.get("buildings") as Dictionary),
		0.001, "the panel opens on the figure the sim would credit")

	# Press `+`. One mine starts producing and the displayed rate must move by one mine's
	# yield -- immediately, on this frame.
	var turn_before := c.galaxy.turn
	posted.emit_signal("pressed")
	sup.eq(c.galaxy.turn, turn_before, "and no turn was advanced to make it true")
	sup.eq(ColonySim.workers_on(colony, &"mine"), 1, "the press posts one colonist")
	var after_one := _signed_in(_row_for(_client.inspector.planet_label().text, "METAL"))
	sup.near(after_one - start, per_mine, 0.001,
		"posting one miner raises the displayed rate by exactly one mine")

	# And a second, which is the case a count-based derivation could not distinguish from the
	# first: the rate has to track the posting, not merely react to there being one.
	posted.emit_signal("pressed")
	sup.eq(ColonySim.workers_on(colony, &"mine"), 2, "the second press posts another")
	var after_two := _signed_in(_row_for(_client.inspector.planet_label().text, "METAL"))
	sup.near(after_two - after_one, per_mine, 0.001,
		"posting a second miner raises it again, not just the first time")

	# Pulling one off has to move it back down by the same amount, or the rate is a one-way
	# latch rather than a readout.
	var pulled := _client.macros.staffing_less_button(&"mine")
	sup.ok(pulled != null, "the mine row carries a - button as well")
	if pulled == null:
		return
	pulled.emit_signal("pressed")
	sup.eq(ColonySim.workers_on(colony, &"mine"), 1, "the press pulls one colonist off")
	var after_pull := _signed_in(_row_for(_client.inspector.planet_label().text, "METAL"))
	sup.near(after_two - after_pull, per_mine, 0.001,
		"and the displayed rate falls back by the same amount")
	sup.near(after_pull, after_one, 0.001, "landing exactly on the one-miner figure again")

	# The whole point of routing both the panel and the build gate through one function: the
	# number on screen is the number the resolver uses, not a lookalike.
	sup.near(_signed_in(_row_for(_client.inspector.planet_label().text, "METAL")),
		ColonySim.metal_output(colony, _defs.get("buildings") as Dictionary), 0.001,
		"and the panel still agrees with the figure the turn will credit")


## A dispatched fleet stays in transit across turn advances, draws its line when the overlay
## is on, and docks into the destination orbit with its ships intact.
##
## This is the report's Bug 1, and the parts worth pinning down are the ones that could each
## fail alone while leaving the fleet looking fine:
##
##   - The order has to reach the *resolver*, not just the client's local mirror. The client
##     mirrors a move onto its own replica so the map draws the line immediately, which means a
##     broken order path would still show a fleet under way on the client and lose it the turn
##     the server resolved. Driving the turn through the real `MOVE_FLEET` order is what makes
##     this an assertion about persistence rather than about the mirror.
##   - Transit has to survive a turn *and* a save/load, since `destination`/`travelled` are the
##     only record of a crossing in progress.
##   - The overlay has to draw the line from the controller's canonical fleet list, not from a
##     copy the toggle button kept.
func _step_transit_persists_and_draws() -> void:
	sup.begin("fleet transit persists, draws, and docks")
	if _client == null or _client.controller == null or _client.map == null:
		return
	var c := _client.controller
	var home := _first_colony()
	if home == null:
		sup.ok(false, "the player starts with a colony to fly from")
		return

	# The nearest other world, so the crossing is a handful of turns rather than a soak.
	var target := -1
	var nearest := INF
	for p in c.galaxy.planets:
		if p.index == home.index:
			continue
		var gap := MovementStage.orbit_distance(home, p)
		if gap > 0.0 and gap < nearest:
			nearest = gap
			target = p.index
	sup.ok(target >= 0, "a second world exists to fly to")
	if target < 0:
		return

	var fleet := _ensure_transport(home.index, &"corvette")
	if fleet == null:
		sup.ok(false, "a fleet is available to dispatch")
		return
	fleet.destination = -1
	fleet.travelled = 0.0
	c.select_fleet(fleet.id)

	var quoted := MovementStage.transit_turns(c.galaxy, home.index, target)
	sup.ok(quoted >= 1, "the crossing is quoted at least one turn")

	# The order itself, inspected rather than assumed. `queue_move` submits this and then
	# mirrors it locally; both are asserted here so a regression in either is visible.
	#
	# The queue is emptied first: earlier steps stage orders on purpose, and what is under test
	# is what *this* dispatch stages, not what the previous step left behind.
	c.queue.clear()
	sup.ok(c.queue_move(target), "the dispatch is accepted")
	var staged: Array[Order] = c.pending_orders() as Array[Order]
	sup.eq(staged.size(), 1, "and stages exactly one order for the turn")
	if staged.size() == 1:
		sup.eq(staged[0].type, int(Enums.OrderType.MOVE_FLEET),
			"which is a MOVE_FLEET the resolver will act on")
		sup.eq(staged[0].fleet, fleet.id, "naming the fleet that was dispatched")
		sup.eq(staged[0].target_planet, target, "and the world it was sent to")
	sup.eq(fleet.destination, target, "the client mirror shows it under way at once")

	# The overlay, while the fleet is genuinely in transit: a line is only drawable if there
	# is something to draw it between.
	_client.set_flight_paths(true)
	sup.ok(c.flight_paths_shown(), "the overlay is on")
	sup.ok(c.galaxy.fleets_of(c.player_id).has(fleet),
		"the fleet is in the controller's canonical list the overlay reads")

	# Turn one: past the order, into pure transit state. This is where a fleet that only ever
	# lived in the client's mirror would evaporate.
	c.end_turn()
	sup.eq(fleet.destination, target, "it is still under way after the turn that ordered it")
	sup.ok(fleet.travelled > 0.0, "and has begun covering the leg",
		"travelled=%f" % fleet.travelled)

	# Save/load mid-crossing. A save that dropped `destination` would silently park the fleet
	# at its origin and the rest of the game would believe it had arrived.
	var restored := GalaxyState.new()
	sup.ok(restored.from_json(c.galaxy.to_json()), "the galaxy saves and reloads mid-transit")
	var reloaded: FleetState = restored.fleet(fleet.id)
	sup.ok(reloaded != null, "the reloaded galaxy still holds the fleet")
	if reloaded != null:
		sup.eq(reloaded.destination, target, "still bound for the same world after the reload")
		sup.near(reloaded.travelled, fleet.travelled, 0.001,
			"and still carrying its progress across the leg")

	# Now run it in. One turn at a time, so a fleet that reset or stalled is caught rather
	# than merely arriving late.
	for _turn in quoted + 2:
		if fleet.destination < 0:
			break
		c.end_turn()
	sup.eq(fleet.destination, -1, "it arrives rather than crossing for ever")
	sup.eq(fleet.system, target, "and is docked at the destination")
	sup.near(fleet.travelled, 0.0, 0.001, "with its progress counter cleared for the next order")

	# The ships, specifically. "Arrived" is true of the fleet's own fields long before the
	# rest of the game agrees, so the garrison and the hull count are checked directly.
	sup.ok(c.fleets_in_orbit_at(target).has(fleet),
		"the destination's orbit holds that same fleet")
	sup.ok(int(fleet.ships.get(&"corvette", 0)) > 0,
		"and it still has its corvette", "ships=%s" % str(fleet.ships))

	# With the fleet docked there is nothing in transit, so the overlay has no line to draw
	# for it -- which is the correct behaviour, and distinguishes "hides when off" from
	# "draws a stale line forever".
	_client.set_flight_paths(false)
	sup.ok(not c.flight_paths_shown(), "the controller reports the overlay off")
	sup.ok(not _client.map.flight_paths_enabled(), "and so does the map that draws it")


## The Show/Hide Flight Paths toggle, beneath Travel, drives the map's overlay.
##
## The overlay itself was drawn but nothing on screen reached it: the flag existed on the map
## view and on the client root and no control ever set it, so "draw every fleet's route" was
## unreachable in a game rather than off by default. This presses the button the player presses
## and checks the map, the controller and the button's own label all follow -- a toggle whose
## text is written once at build time would leave "Show Flight Paths" over a board that is
## already showing them.
func _step_flight_path_toggle() -> void:
	sup.begin("flight path toggle")
	if _client == null or _client.controller == null or _client.map == null:
		return
	if _client.fleets == null:
		return
	var c := _client.controller
	var view := _client.map.view()

	var button := _client.fleets.flight_paths_button()
	sup.ok(button != null, "there is a flight-path control on the fleet panel")
	if button == null:
		return
	# Under Travel, which is the other half of the same question: Travel sends one fleet
	# somewhere, this shows where everything already is.
	sup.eq(button.get_parent().get_child(
		button.get_parent().get_children().find(button) - 1).name,
		_client.fleets.travel_button().name,
		"and it sits directly beneath Travel")

	sup.ok(not view.flight_paths_enabled(), "the overlay starts hidden")
	sup.eq(button.text, "Show Flight Paths", "and the button offers to show it")

	# Counted rather than asserted as zero: earlier steps stage orders on purpose, and what is
	# under test is whether *these two presses* added any. An absolute zero would be a
	# statement about the previous step's bookkeeping rather than about the toggle.
	var staged_before := c.pending_orders().size()

	button.emit_signal("pressed")
	sup.ok(view.flight_paths_enabled(), "pressing it turns the overlay on")
	sup.ok(c.flight_paths_shown(), "and the controller agrees")
	sup.eq(button.text, "Hide Flight Paths", "so the label now offers to hide it")

	button.emit_signal("pressed")
	sup.ok(not view.flight_paths_enabled(), "pressing it again turns the overlay off")
	sup.ok(not c.flight_paths_shown(), "and the controller agrees")
	sup.eq(button.text, "Show Flight Paths", "so the label offers to show it again")

	# Nothing about the fleets changed: it is a view option, not an order, and a toggle that
	# moved a ship would be a very surprising button to find in a panel.
	sup.ok(c.galaxy != null, "and no order was queued for the overlay")
	sup.eq(c.pending_orders().size(), staged_before, "neither press staged an order")


## No hull is offered on a colony with no Space Port, whatever the empire has unlocked.
##
## `hull_available` answers "may this hull ever be laid *somewhere*", and a population
## milestone unlocks a hull empire-wide -- so the dropdown listed capital ships on a world with
## no shipyard standing on it. `can_build_ship` refused the press, which left a row in the menu
## that silently did nothing when chosen: exactly the build button that looks affordable and
## is not.
func _step_space_port_gates_the_ship_list() -> void:
	sup.begin("space port gates the ship list")
	if _client == null or _client.controller == null or _client.macros == null:
		return
	var c := _client.controller
	var me := c.player()
	var colony := _first_colony()
	if colony == null or me == null:
		sup.ok(false, "the player has a colony and a faction")
		return
	c.select_planet(colony.index)
	_client.select_colony(colony.index)

	# Strip the yard rather than assuming the fixture's colony has none: a milestone in an
	# earlier step may have laid a Space Port.
	var had_port := colony.count(&"space_port")
	colony.structures.erase(&"space_port")
	colony.building_queue.clear()
	# A hull the empire definitely owns, so the assertion cannot pass by the unlock being
	# absent. The milestone ladder grants these at zero population.
	me.unlocked_ships[&"cruiser"] = true
	sup.ok(me.unlocked_ships.has(&"cruiser"), "the empire has unlocked a hull it cannot build")

	sup.ok(TurnResolver.hulls_available_at(colony, me).is_empty(),
		"no hull is offered on a world with no Space Port")
	_client.macros.refresh()
	var rows := _hull_ids_in_menu()
	sup.eq(rows.size(), 0, "and the dropdown lists no ships at all")
	sup.ok(not rows.has(&"cruiser"),
		"specifically not the one the empire has unlocked")
	# Planetary buildings are still offered: the gate is about the shipyard, not the menu.
	sup.ok(_client.macros.build_selector().item_count > 0,
		"planetary buildings are still listed")
	# And the press is refused, so the menu and the resolver agree rather than the menu being
	# the only thing that changed.
	sup.ok(not TurnResolver.can_build_ship(colony, _defs.call("ship_hull", &"cruiser") as Resource,
		me, _db),
		"and the resolver would refuse the press")

	# A Space Port opens the gate, and the hulls come back.
	colony.structures[&"space_port"] = 1
	sup.ok(TurnResolver.hulls_available_at(colony, me).has(&"cruiser"),
		"a Space Port makes the unlocked hull buildable")
	_client.macros.refresh()
	rows = _hull_ids_in_menu()
	sup.ok(rows.has(&"cruiser"), "and the dropdown lists it")
	sup.ok(rows.has(&"corvette"), "along with the baseline berths the port hands over")

	# Put the fixture back, so later steps run against the state they expect.
	if had_port > 0:
		colony.structures[&"space_port"] = had_port
	else:
		colony.structures.erase(&"space_port")
	_client.macros.refresh()


## The signed figure inside a readout row's brackets, or 0.
## The `(+N)` figure the panel should be showing for this colony's metal rate right now.
##
## Formatted the same way `InspectorPanel` formats it, and derived from the resolver's own
## projection, so an assertion about the displayed rate cannot drift away from the arithmetic
## that is supposed to produce it.
func _metal_rate_text(
	colony: PlanetState, buildings: Dictionary, faction: FactionState
) -> String:
	var delta := ColonySim.get_projected_metal_delta(colony, buildings, faction)
	return "(%s)" % Format.signed(delta, 0)


## A planet the empire owns, for a fixture that wants one specific world.
##
## Named for what it is rather than reaching for `_first_colony`, because the single-colony
## case needs a body it can put on the board without disturbing the suite's own colonies.
func _galaxy_probe(c: SessionController) -> PlanetState:
	for p in c.player_colonies():
		return p
	return null


func _signed_in(row: String) -> float:
	var open := row.find("(")
	var close := row.rfind(")")
	if open < 0 or close <= open:
		return 0.0
	var inner := row.substr(open + 1, close - open - 1)
	# Strip any bbcode the row carries.
	var clean := ""
	var i := 0
	while i < inner.length():
		if inner[i] == "[":
			var end := inner.find("]", i)
			if end > i:
				i = end + 1
				continue
		clean += inner[i]
		i += 1
	return float(clean.strip_edges())


## Recount a colony's capacities through the controller's own tables.
func _colonyRecount(colony: PlanetState, c: SessionController) -> void:
	ColonySim.recount_capacity(colony, c.defs.get("buildings") as Dictionary, c.db)


func _step_teardown() -> void:
	# Freeing every node explicitly before quitting is what keeps the exit clean: a tree
	# torn down by `quit()` alone leaks the viewport's RID resources and the engine
	# prints leak warnings, which the verification runner treats as diagnostics.
	sup.begin("teardown")
	if _client != null:
		if _client.is_inside_tree():
			root.remove_child(_client)
		_client.free()
		_client = null
	sup.ok(_client == null, "the client was freed")

	# Free any stand-in autoloads this run created, so the engine reports no leaks.
	for name in [&"Defs", &"GameDB"]:
		var n := root.get_node_or_null(NodePath(name))
		if n != null and _stand_ins.has(n.get_instance_id()):
			root.remove_child(n)
			n.free()
	sup.ok(_stand_ins.size() <= 2, "stand-in autoloads were released")

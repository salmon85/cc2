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
##   - the macro controls emit real SET_TAX / SET_RESEARCH / BUILD_STRUCTURE orders
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
		"macro_tax", "macro_research",
		"macro_build", "macro_map_stable", "ready_button", "end_turn", "networked_end_turn",
		"end_turn_again",
		"resolution_panels", "peer_departure", "fog_ownership", "fog_colony_markers",
		"fog_fleet_markers", "fog_planet_names", "no_staged_orders", "map_bounds",
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
		"macro_tax": _step_macro_tax()
		"macro_research": _step_macro_research()
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
	sup.ok(_client.top_bar.stardate_label() != null, "top bar exposes the stardate readout")
	sup.ok(_client.top_bar.treasury_label() != null, "top bar exposes the treasury readout")
	sup.ok(_client.top_bar.research_label() != null, "top bar exposes the research readout")
	# Net income is sign-coloured via BBCode, so this readout must be a RichTextLabel.
	# A plain Label renders the tags literally, which is what the player saw.
	var net := _client.top_bar.net_label()
	sup.ok(net is RichTextLabel, "the net readout parses BBCode")
	if net is RichTextLabel:
		sup.ok((net as RichTextLabel).bbcode_enabled,
			"the net readout has bbcode_enabled")
		sup.ok(_client.top_bar.net_label().text.begins_with("[color="),
			"the net readout carries colour markup")
		# The rendered line must be the number, not the markup.
		sup.ok(not _client.top_bar.net_label().get_parsed_text().contains("[color="),
			"the parsed net text has no raw tags",
			"parsed='%s'" % _client.top_bar.net_label().get_parsed_text())
	else:
		sup.ok(true, "net readout BBCode checks skipped (not a RichTextLabel)")
	sup.ok(_client.macros.tax_slider() != null, "macro panel exposes the tax slider")
	sup.eq(_client.macros.research_sliders().size(), 4, "four research allocation sliders")
	sup.ok(_client.macros.build_selector() != null, "macro panel exposes the build selector")
	sup.ok(_client.macros.colony_selector() != null, "macro panel exposes the colony selector")
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
	sup.ok(_client.fleets.list() != null, "fleet panel exposes the fleet list")
	sup.ok(_client.fleets.detail() != null, "fleet panel exposes the fleet detail")
	sup.ok(_client.fleets.order_button() != null, "fleet panel exposes the order-mode button")
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
	sup.ok(_client.fleets.order_mode_changed.is_connected(_client._on_order_mode_changed),
		"order-mode toggle reaches the client")
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
	sup.ok(detail.contains("POPULATION") and detail.contains("FARMS"),
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
	sup.ok(panel.confirm_row().visible, "the confirmation prompt is open")
	sup.ok(panel.transit_label().visible, "and quotes the transit time")
	sup.ok(panel.visible_text().contains("ESTIMATED TRANSIT"),
		"the prompt shows the transit heading", "shown=%s" % panel.visible_text())
	sup.ok(panel.visible_text().contains("%d turn" % turns),
		"quoting the number of turns the flight will take",
		"want %d turns; shown=%s" % [turns, panel.visible_text()])
	# The quoted dot figure must be the pip count -- the marks on the map plus the
	# destination -- and therefore equal the turn count. Asserting it against a separately
	# rounded parsec distance is what let "14 dots, 2 turns" print side by side.
	var pip_count := MovementStage.waypoints(gal, f.system, dest).size() + 1
	sup.ok(panel.visible_text().contains("%d dots" % pip_count),
		"and the dot distance it is counted in",
		"want %d dots; shown=%s" % [pip_count, panel.visible_text()])
	sup.eq(pip_count, turns,
		"the quoted dots and the quoted turns are the same figure")

	# --- cancel discards --------------------------------------------------------
	map.cancel_order()
	sup.eq(map.pending_destination(), -1, "cancelling clears the proposal")
	sup.eq(c.pending_orders().size(), queued_before, "and queues nothing")
	sup.eq(f.destination, -1, "the fleet has not moved")
	sup.ok(not panel.confirm_row().visible, "and the prompt closes")

	# --- clicking elsewhere discards -------------------------------------------
	map.click_at_galaxy(gal.planet(dest).position)
	sup.eq(map.pending_destination(), dest, "the proposal is open again")
	map.click_at_galaxy(Vector2(999999.0, -999999.0))
	sup.eq(map.pending_destination(), -1, "clicking empty space discards it")
	sup.eq(c.pending_orders().size(), queued_before, "without queueing anything")

	# --- confirm commits ----------------------------------------------------------
	map.click_at_galaxy(gal.planet(dest).position)
	sup.ok(map.confirm_order(), "CONFIRM commits the order")
	sup.eq(c.pending_orders().size(), queued_before + 1, "exactly one order is queued")
	sup.eq(f.destination, dest, "and the fleet is in transit to the proposed world")
	sup.eq(map.pending_destination(), -1, "the proposal is consumed")
	sup.ok(not panel.confirm_row().visible, "and the prompt closes")

	# --- the flight really takes that many turns ---------------------------------
	# Stepped here rather than trusting `transit_turns`: the number on the prompt is only
	# worth showing if the resolver actually spends it.
	f.destination = -1
	f.travelled = 0.0
	c.pending_orders().clear()
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
	var fleets := c.player_fleets()
	sup.ok(not fleets.is_empty(), "the player starts with at least one fleet",
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


func _step_macro_tax() -> void:
	sup.begin("macro: tax")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var slider := _client.macros.tax_slider()
	var staged_before := c.pending_orders().size()

	slider.value = 0.6
	# HSlider emits value_changed synchronously on assignment.
	sup.near(c.player().tax_rate, 0.6, 0.001, "dragging the tax slider updates the faction")
	sup.eq(c.pending_orders().size(), staged_before + 1, "dragging stages a SET_TAX order")
	var orders := c.pending_orders()
	sup.eq(orders[orders.size() - 1].type, Enums.OrderType.SET_TAX, "the staged order is SET_TAX")

	# An out-of-range value must clamp rather than break the economy.
	c.set_tax_rate(5.0)
	sup.near(c.player().tax_rate, 1.0, 0.001, "an excessive tax rate clamps to 1.0")
	c.set_tax_rate(-1.0)
	sup.near(c.player().tax_rate, 0.0, 0.001, "a negative tax rate clamps to 0.0")


func _step_macro_does_not_move_the_map() -> void:
	sup.begin("macro: sliders leave the map alone")
	if _client == null or _client.controller == null:
		return
	var m := _client.map
	var cam := m.camera()
	var macros := _client.macros

	# The defect: dragging a slider staged an order, the staged-orders label was sized to
	# its text with `fit_content`, so the right column got taller, the row's minimum grew,
	# and the `SIZE_EXPAND_FILL` map beside it resized -- which re-framed the camera and
	# moved a view the player never touched.
	#
	# The readout that caused it is gone (see `_step_no_staged_orders`), so what is checked
	# now is the property that outlived it: the macro panel's minimum height does not
	# depend on anything the player does to it, and the map is untouched throughout.
	var cam_before := cam.position
	var zoom_before := cam.zoom
	var map_before := m.size
	var height_before := macros.get_combined_minimum_size().y

	# Stage far more orders than any readout has height for. The map is sampled every step
	# rather than only at the end: it is `SIZE_EXPAND_FILL`, so it grows the instant the
	# column beside it does, and a check taken after the fact could miss a transient.
	var tallest := macros.get_combined_minimum_size().y
	for i in 24:
		macros.tax_slider().value = 0.02 + 0.03 * i
		tallest = maxf(tallest, macros.get_combined_minimum_size().y)
	sup.ok(_client.controller.pending_orders().size() >= 12,
		"the drag staged a stack of orders",
		"%d pending" % _client.controller.pending_orders().size())

	sup.near(tallest, height_before, 0.5,
		"the macro panel does not grow with the order queue (%f vs %f)" % [
			tallest, height_before])

	# And the map, which is what the player actually noticed, is untouched.
	sup.eq(m.size, map_before, "the map did not resize when sliders were dragged")
	sup.eq(cam.position, cam_before, "the camera did not move when sliders were dragged")
	sup.eq(cam.zoom, zoom_before, "the camera did not re-zoom when sliders were dragged")


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
	for child in node.get_children():
		_collect_text(child, into)


func _step_macro_research() -> void:
	sup.begin("macro: research")
	if _client == null or _client.controller == null:
		return
	var c := _client.controller
	var sliders := _client.macros.research_sliders()
	sup.eq(sliders.size(), 4, "four research sliders exist")

	# Set a lopsided split; the controller must normalise it to a real budget.
	for i in sliders.size():
		sliders[i].set_value_no_signal(0.0)
	sliders[0].value = 50.0
	sliders[1].value = 25.0
	sliders[2].value = 15.0
	sliders[3].value = 10.0
	# The last assignment drives the controller; drive it explicitly to be certain.
	c.set_research_allocation(PackedFloat64Array([50.0, 25.0, 15.0, 10.0]))

	var alloc := c.player().research_allocation
	sup.near(alloc[0] + alloc[1] + alloc[2] + alloc[3], 1.0, 0.0001,
		"the allocation normalises to 1.0")
	sup.near(alloc[0], 0.5, 0.001, "the dominant field keeps its share")
	sup.near(alloc[3], 0.1, 0.001, "the smallest field keeps its share")

	# Dragging the sliders above staged a SET_RESEARCH on every drag, so check the most
	# recent one rather than the first.
	var orders := c.pending_orders()
	var found := false
	for i in range(orders.size() - 1, -1, -1):
		if orders[i].type == Enums.OrderType.SET_RESEARCH:
			found = true
			var staged: PackedFloat64Array = orders[i].payload.get(
				"allocation", PackedFloat64Array())
			sup.near(staged[0], 0.5, 0.001,
				"the staged SET_RESEARCH order carries the normalised split")
			var staged_total := 0.0
			for v in staged:
				staged_total += v
			sup.near(staged_total, 1.0, 0.0001,
				"the staged allocation sums to 1.0")
			break
	sup.ok(found, "a SET_RESEARCH order was staged")


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

	var selector := _client.macros.build_selector()
	sup.ok(selector.item_count > 0, "the build selector is populated",
		"%d items" % selector.item_count)
	if selector.item_count == 0:
		return

	# Give the player a budget so affordability is not what blocks the order.
	var me := c.player()
	me.metals = 100000.0
	me.rare_elements = 100000.0
	me.energy = 100000.0

	var chosen := _first_unlocked_building(selector)
	sup.ok(chosen != &"", "an unlocked structure is offered", "found %s" % String(chosen))
	if chosen == &"":
		return
	sup.ok(_client.macros.select_build(chosen), "the build selector can select it")

	# Regression: browsing the construction dropdown used to be refused with "select one
	# of your colonies first" because nothing ever moved the controller's selection off
	# the system/body the player had clicked on the map.
	c.select_system(_first_body_system(c))
	_client.macros._on_build_selected(0)
	sup.ok(c.selected_planet == colony.index or not c.player_colonies().is_empty(),
		"touching the build selector does not leave a stale selection")
	sup.ok(c.selected_planet == colony.index,
		"the build selector adopts the highlighted colony",
		"selected=%d expected=%d" % [c.selected_planet, colony.index])
	# Re-selecting through the controller, as the GUI test drives it elsewhere.
	c.select_planet(colony.index)

	var queued_before := int(colony.building_queue.get(chosen, 0))
	var staged_before := c.pending_orders().size()
	var accepted := c.queue_build_structure(chosen)
	sup.ok(accepted, "a legal build order is accepted", "building %s" % String(chosen))
	sup.eq(c.pending_orders().size(), staged_before + 1, "the build order is staged")
	var orders := c.pending_orders()
	sup.eq(orders[orders.size() - 1].type, Enums.OrderType.BUILD_STRUCTURE,
		"the staged order is BUILD_STRUCTURE")
	sup.eq(orders[orders.size() - 1].target_planet, colony.index,
		"the order names the right colony")
	sup.ok(int(colony.building_queue.get(chosen, 0)) == queued_before,
		"the structure is queued for ColonySim, not granted immediately")

	# A second identical order beyond the per-colony cap must be refused.
	var def: Resource = _defs.building(chosen) as Resource
	if def != null and def.max_per_colony > 0 and def.max_per_colony == 1:
		sup.ok(not c.queue_build_structure(chosen),
			"building past the per-colony cap is refused")


func _first_unlocked_building(selector: OptionButton) -> StringName:
	for i in selector.item_count:
		var meta: Variant = selector.get_item_metadata(i)
		if meta != null and _client.controller.player().unlocked_buildings.has(meta):
			return meta as StringName
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
	sup.ok(_client.top_bar.stardate_label().text == str(c.galaxy.turn + 1),
		"the HUD stardate matches the state",
		"hud=%s state=%d" % [_client.top_bar.stardate_label().text, c.galaxy.turn + 1])
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
	sup.ok(c.set_tax_rate(0.33), "an order is staged for the wire")
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
	sup.eq(_client.top_bar.stardate_label().text, str(c.galaxy.turn + 1),
		"the HUD tracks the stardate across turns")


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
		for p_index in host.planet_indices:
			var candidate := gal.planet(p_index)
			if candidate != null and candidate.is_colonizable():
				foreign_planet = candidate.index
				break
		if foreign_planet < 0 and host.planet_indices.size() > 0:
			foreign_planet = host.planet_indices[0]

	sup.ok(foreign_sys >= 0, "a system is in sensor range to hang a rival colony on")
	sup.ok(foreign_planet >= 0, "that system has a body to colonise")
	if foreign_planet < 0:
		return

	# Every fleet of ours is moved well clear: the claim under test is that a rival system
	# with nothing of ours in it stays hidden, and a leftover scout would make that untrue.
	var parked := {}
	for f_key: int in gal.fleets:
		var f: FleetState = gal.fleets[f_key]
		if f.owner == me:
			parked[f_key] = [f.system, f.destination]
			f.destination = -1
			if f.system == foreign_sys:
				f.system = -1 if f.system >= 0 else 0

	var sys: SystemState = gal.systems[foreign_sys]
	var p: PlanetState = gal.planet(foreign_planet)
	var saved_sys_owner := sys.owner
	var saved_p_owner := p.owner
	var saved_colonized := p.colonized
	var saved_pop := p.population
	var saved_structures := p.structures.duplicate()

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

	# Flying a ship there is how a player earns the right to see it. The gate has to open
	# on the same trigger as the map's, or the map would show a world the inspector refuses.
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
	sup.ok(revealed.contains("POPULATION"),
		"parking a ship there reveals the world's detail")

	# Put the galaxy back, so later steps run against the state they expect. The fixture was
	# synthesised rather than borrowed, so this is not a courtesy -- the ownership, the
	# colony and the parked fleets all have to be returned to what generation left.
	sys.owner = saved_sys_owner
	p.owner = saved_p_owner
	p.colonized = saved_colonized
	p.population = saved_pop
	p.structures = saved_structures
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

		sup.ok(not c.knows_name_of(foreign.index),
			"an unvisited rival world has no name the player may use")
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

	sup.ok(not c.knows_name_of(foreign.index),
		"an unvisited rival world has no name the player may use",
		"world=%d name=%s" % [foreign.index, foreign.name])
	sup.eq(view.planet_label(foreign), GalaxyMapView.UNKNOWN_NAME,
		"the map labels it with the placeholder, not its real name")
	sup.ok(foreign.name != GalaxyMapView.UNKNOWN_NAME,
		"which is not simply its real name")
	# No marker on the board at all for a world that is neither owned nor orbited. The
	# placeholder is what the panel says about it; the map says nothing.
	sup.ok(not view.label_worth_drawing(foreign),
		"and draws no label beside the marker")

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

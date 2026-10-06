extends Control
class_name GameClient
## Root of the client presentation layer: builds the layout, owns the `SessionController`,
## and routes every signal between the panels and the simulation.
##
## Layout is a three-column frame — map in the centre, inspector and fleet registry on the
## left, macro controls on the right — with the status HUD pinned across the top. Every
## panel is constructed in code rather than authored into the `.tscn` so the tree is
## impossible to desynchronise from the types the panels expect; the scene file exists to
## give the client a stable identity the launcher can instantiate.

## Emitted when the turn resolves and the client has refreshed against the new report.
signal turn_committed(report: Dictionary)

## Emitted with a human-readable line for anything the player should be told about.
signal status_message(text: String)

var controller: SessionController = null

var top_bar: TopBar = null
var map: GalaxyMap = null
var inspector: InspectorPanel = null
var macros: MacroPanel = null
var fleets: FleetPanel = null

## The Travel workflow. An overlay rather than a child of the fleet panel, because it has to
## sit above the map: the player is choosing between worlds and needs to see them to choose.
var travel: TravelModal = null

## The metal-allocation dialog behind the construction progress bars.
var boost: BoostModal = null

## The fleet manifest: which ships leave a source world, and which stay. Opened by the travel
## flow once both ends of the route are known.
var manifest: FleetManifestModal = null

## Load / unload between a colony's stockpiles and the lifts in its orbit.
var cargo: CargoModal = null

## Which step of the travel flow is waiting for a map click, or -1 when none is.
##
## The flow is: press Travel, click the source world, click the destination, then the manifest.
## Two of those three steps are map clicks, and a map click with no question outstanding is a
## misclick -- so the step has to be remembered somewhere the map can reach. It lives here
## rather than on the map because the map is a pure drawing layer and this is a decision.
var travel_step: int = TravelStep.NONE

## The stages of the interactive travel flow.
enum TravelStep {
	NONE,     ## Not travelling; a map click selects normally.
	SOURCE,   ## Waiting for the world whose orbit the ships come from.
	DESTINATION, ## Waiting for where they are going.
}

## The world chosen as the travel source, or -1.
var travel_source: int = -1

## Background music. Present as a node in every run so the accessor is never null, but it
## holds no `AudioStreamPlayer` at all unless the run is allowed to open an audio device --
## see `BackgroundMusic`.
var music: BackgroundMusic = null

var _log: RichTextLabel = null
## Every line the session log has shown, kept as plain strings.
##
## The log is a security surface -- it is where a leaked world name shows up -- and a
## `RichTextLabel` cannot be read back in a headless run: its `text` property stays empty
## until the text server shapes the buffer, which needs a rasteriser. Testing against it
## means testing against "", which passes everything. Mirroring the lines here gives both
## the panel and the tests one source, so a name cannot be displayed but unverifiable.
var _log_lines_buffer := PackedStringArray()


func _ready() -> void:
	theme = CC2Theme.build()
	# The client paints its own background; a Control at the root has no visual by
	# default and would flash the project clear colour on first frame.
	var bg := ColorRect.new()
	bg.color = CC2Theme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_build_music()
	_build_layout()
	_build_travel_overlay()
	_build_boost_overlay()
	_build_manifest_overlay()
	_build_cargo_overlay()
	# `start()` may have been called before this node entered the tree, in which case the
	# panels it needs did not exist yet.
	if _pending_galaxy != null:
		_attach_session()


## Mount the background music.
##
## Added before the layout so it is the first thing in the tree, and it starts itself from its
## own `_ready`. In a headless run `start()` returns immediately and the node stays empty, so
## this call is safe from `app.gd`, from a dedicated server that never builds a client, and
## from the GUI suite alike -- there is no mode in which adding it is not the right thing.
func _build_music() -> void:
	music = BackgroundMusic.new()
	music.name = "BackgroundMusic"
	add_child(music)


func _build_layout() -> void:
	var root_col := VBoxContainer.new()
	root_col.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_col.add_theme_constant_override("separation", 0)
	add_child(root_col)

	top_bar = TopBar.new()
	root_col.add_child(top_bar)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	root_col.add_child(body)

	# Left column: the planet readout over the fleet registry.
	#
	# This is the column that lost the system survey, so the proportions moved rather than
	# the panels. The registry gets the larger share because a fleet's detail block is
	# what a player opens this column for, and the planet readout above it is a summary of
	# something already visible on the map. `stretch_ratio` rather than minimum heights:
	# hard pixel minimums only describe one window height, and the ratio keeps the split
	# sensible in a short window where both panels are squeezed.
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(280, 0)
	left.add_theme_constant_override("separation", 0)
	body.add_child(left)

	inspector = InspectorPanel.new()
	inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inspector.size_flags_stretch_ratio = 3.0
	left.add_child(inspector)

	var left_split := VSeparator.new()
	left.add_child(left_split)

	# The fleet column lost its registry list in Phase 8, so it now holds the fleet detail and
	# the Travel button only. The stretch ratio is unchanged in *meaning* -- the planet readout
	# above still gets the larger share -- but the panel below has far less to say, so it takes
	# a smaller share of the column as well.
	fleets = FleetPanel.new()
	fleets.custom_minimum_size = Vector2(280, 140)
	fleets.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fleets.size_flags_stretch_ratio = 1.0
	left.add_child(fleets)

	# Centre: the map owns the remaining space.
	map = GalaxyMap.new()
	body.add_child(map)

	var right_split := VSeparator.new()
	body.add_child(right_split)

	# Right column: macro controls over the event log.
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(290, 0)
	right.add_theme_constant_override("separation", 0)
	body.add_child(right)

	macros = MacroPanel.new()
	macros.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(macros)

	var right_split2 := VSeparator.new()
	right.add_child(right_split2)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.custom_minimum_size = Vector2(0, 120)
	_log.add_theme_stylebox_override(
		"normal", CC2Theme.sunk(CC2Theme.BG_SUNK, CC2Theme.BORDER)
	)
	right.add_child(_log)


## Mount the travel modal as an overlay over the whole frame.
##
## Centred and hidden until the player opens it. It is added *after* the layout so it draws
## above everything, and it fills only its own content -- the map stays visible around it,
## which is the point: the destination dropdown is a list of names, and a name the player
## cannot see on the board is a name they have to remember.
func _build_travel_overlay() -> void:
	travel = TravelModal.new()
	travel.set_anchors_preset(Control.PRESET_CENTER)
	travel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	travel.grow_vertical = Control.GROW_DIRECTION_BOTH
	travel.visible = false
	add_child(travel)


## Mount the boost modal next to the travel modal, also centred and hidden until asked for.
##
## It is a sibling rather than a child of the macro panel so it can overlay the map: the
## player is deciding how much metal to move out of a colony they are looking at.
func _build_boost_overlay() -> void:
	boost = BoostModal.new()
	boost.set_anchors_preset(Control.PRESET_CENTER)
	boost.grow_horizontal = Control.GROW_DIRECTION_BOTH
	boost.grow_vertical = Control.GROW_DIRECTION_BOTH
	boost.visible = false
	add_child(boost)


## Mount the fleet manifest, centred over the map.
##
## The player is choosing between ships and needs to be able to see them, so this sits above the
## board rather than inside the fleet panel beside it.
func _build_manifest_overlay() -> void:
	manifest = FleetManifestModal.new()
	manifest.set_anchors_preset(Control.PRESET_CENTER)
	manifest.grow_horizontal = Control.GROW_DIRECTION_BOTH
	manifest.grow_vertical = Control.GROW_DIRECTION_BOTH
	manifest.visible = false
	add_child(manifest)


## Mount the cargo dialog, also centred over the map.
func _build_cargo_overlay() -> void:
	cargo = CargoModal.new()
	cargo.set_anchors_preset(Control.PRESET_CENTER)
	cargo.grow_horizontal = Control.GROW_DIRECTION_BOTH
	cargo.grow_vertical = Control.GROW_DIRECTION_BOTH
	cargo.visible = false
	add_child(cargo)


## Point the whole client at a galaxy. Panels are bound here and nowhere else, so the
## wiring order is a single readable block.
func start(galaxy: GalaxyState, player_faction: int = 0, seed_override: int = 0) -> bool:
	controller = SessionController.new()
	# A caller-supplied seed lets the launcher reproduce a reported bug exactly.
	if seed_override != 0:
		galaxy.seed_value = seed_override
	if not controller.attach(galaxy, player_faction):
		status_message.emit("could not start a session")
		return false
	_pending_galaxy = galaxy
	# `start()` is often called in the same breath as `add_child()`, before `_ready()`
	# has built the panels. Defer the binding rather than dereferencing null panels.
	if not is_node_ready():
		return true
	_attach_session()
	return true


## The galaxy to bind once the panels exist. Null means "already bound".
var _pending_galaxy: GalaxyState = null

## True once the signal graph has been connected.
var _wired: bool = false


## Build the session bindings. Safe to call twice; the second call is a no-op.
func _attach_session() -> void:
	if controller == null or top_bar == null or map == null:
		return
	if _pending_galaxy == null:
		return
	var galaxy := _pending_galaxy
	_pending_galaxy = null

	top_bar.bind(controller)
	inspector.bind(controller)
	macros.bind(controller)
	fleets.bind(controller)
	map.bind(controller)
	travel.bind(controller)
	boost.bind(controller)
	manifest.bind(controller)
	cargo.bind(controller)

	_wire()
	_log_line("SESSION %d OPENED - %d SYSTEMS - %d FACTIONS" % [
		galaxy.seed_value, galaxy.systems.size(), galaxy.factions.size()
	])
	_refresh()


func _wire() -> void:
	# `start()` can be called more than once (a caller restarting onto a new galaxy) and
	# the panels are rebound each time, so the edges are connected exactly once. Godot
	# errors on a duplicate connection, and `Signal` is a value type whose copy does not
	# share a connection list -- so a per-edge `is_connected` guard is not reliable here.
	if _wired:
		return
	_wired = true

	top_bar.ready_pressed.connect(_on_ready_pressed)
	map.system_picked.connect(_on_system_picked)
	map.planet_picked.connect(_on_planet_picked)
	map.end_turn_requested.connect(_on_end_turn)
	map.interaction_refused.connect(_on_refused)
	# The proposal round trip, still live: the map knows what was clicked and the modal owns
	# the decision. Neither may decide alone -- the modal's OK button is the only commit, and
	# the map never queues anything itself.
	map.order_proposed.connect(_on_order_proposed)
	map.order_cancelled.connect(_on_order_cancelled)
	fleets.fleet_selected.connect(_on_fleet_selected)
	fleets.travel_requested.connect(_on_travel_requested)
	fleets.land_requested.connect(_on_land_requested)
	fleets.cargo_requested.connect(_on_cargo_requested)
	travel.travel_confirmed.connect(_on_travel_confirmed)
	travel.travel_cancelled.connect(_on_travel_cancelled)
	manifest.travel_confirmed.connect(_on_manifest_confirmed)
	manifest.travel_cancelled.connect(_on_manifest_cancelled)
	cargo.transfer_confirmed.connect(_on_transfer_confirmed)
	cargo.transfer_cancelled.connect(_on_transfer_cancelled)
	macros.build_requested.connect(_on_build_requested)
	macros.construction_boosted.connect(_on_construction_boosted)
	macros.ship_construction_boosted.connect(_on_construction_boosted)
	boost.boost_confirmed.connect(_on_boost_confirmed)
	boost.boost_cancelled.connect(_on_boost_cancelled)
	controller.turn_resolved.connect(_on_turn_resolved)
	controller.state_changed.connect(_refresh)
	controller.action_rejected.connect(_on_action_rejected)
	# The server's ready tally drives the top bar's READY button, so the two have to be
	# refreshed from the same place whether the change came from this window's button or
	# from the other player's.
	if controller.turn_submitter != null \
			and not controller.turn_submitter.lobby_ready_changed.is_connected(
				_refresh_ready_button):
		controller.turn_submitter.lobby_ready_changed.connect(func(_r: int, _t: int) -> void:
			_refresh_ready_button())


## Pass the lobby ready flag to the server.
##
## A refusal is reported rather than swallowed: the player pressed a control and
## nothing happened, and the honest reason ("no server to tell") is far more useful than
## a button that silently does nothing.
func _on_ready_pressed(is_ready: bool) -> void:
	if controller == null or not controller.set_ready(is_ready):
		_log_line("[color=#%s]not connected: ready flag not sent[/color]" % CC2Theme.AMBER.to_html(false))
		return
	_log_line("ready" if is_ready else "no longer ready")
	_refresh_ready_button()


## Redraw the top bar's ready button after the flag changed.
func _refresh_ready_button() -> void:
	if top_bar != null:
		top_bar.refresh()


func _refresh() -> void:
	if controller == null:
		return
	# The panels each subscribe to `state_changed` themselves; this keeps the log and the
	# panels consistent after any action the root handled itself.
	_log_lines(4)


func _log_line(line: String) -> void:
	if _log == null:
		return
	_log_lines_buffer.append(line)
	_log.append_text("[color=#%s]%s[/color]\n" % [CC2Theme.WHITE_DIM.to_html(false), line])


## Everything the session log currently shows.
##
## The log is the panel a player reads when they are not sure what they just clicked, so a
## name must not be readable here merely because it was readable elsewhere.
func log_text() -> String:
	return "\n".join(_log_lines_buffer)


func _log_lines(count: int) -> void:
	if _controller_news().is_empty():
		return
	var news := _controller_news()
	for i in range(maxi(0, news.size() - count), news.size()):
		_log_line(news[i])


func _controller_news() -> PackedStringArray:
	if controller == null or controller.galaxy == null:
		return PackedStringArray()
	return controller.galaxy.news_lines()


# --- Handlers --------------------------------------------------------------

## Commit a turn from the keyboard (Space/Enter on the map).
##
## Single player only. A networked player commits by pressing READY, which ships the
## staged orders and raises the flag in one action; resolving here as well would let a
## networked client advance the turn on its own authority, which is the one thing the
## client must never be able to do.
func _on_end_turn() -> void:
	if controller == null or controller.is_networked():
		return
	var before := controller.galaxy.turn
	var report := controller.end_turn()
	if report.is_empty():
		return
	_log_line("STARDATE %d -> %d" % [before + 1, controller.galaxy.turn + 1])


## The star was clicked. Its name is not fogged: there is one system, it is drawn and named
## on the map's crosshair, and the survey panel that used to repeat it here is gone.
func _on_system_picked(index: int) -> void:
	controller.select_system(index)
	var sys := controller.galaxy.system(index)
	if sys != null:
		_log_line("SELECTED %s" % sys.name)


## A body was clicked. The map already selected it before emitting, so this is the log
## line and nothing else -- the inspector redraws through `state_changed`.
##
## The name is not read from the state here. This line was the one reader still bypassing
## the fog: the map drew "Unknown Planet" over a rival world and the inspector headed the
## detail the same way, while the log -- which is what a player actually reads to confirm
## what they just clicked -- printed the real name in plain text. Fog that a player can
## switch off by clicking harder is not fog.
func _on_planet_picked(index: int) -> void:
	if controller.galaxy.planet(index) == null:
		return
	# A travel step outstanding swallows the click: the world is an answer to "which orbit?"
	# or "where to?", not a new selection to report.
	if _advance_travel_flow(index):
		return
	_log_line("SELECTED %s" % controller.display_name(index))


## Feed a map click to the travel flow. Returns true when the click was consumed as an answer.
##
## Both steps refuse a world that cannot serve the answer, and say why in the log rather than
## quietly advancing the flow on a world with no ships: a click on a rival's planet mid-travel
## should leave the player where they were and told what was wrong, not silently become a
## source that resolves to an empty manifest.
func _advance_travel_flow(index: int) -> bool:
	if travel_step == TravelStep.SOURCE:
		if not controller.can_travel_from(index):
			_log_line("[color=#%s]no ships of yours in orbit there[/color]"
				% CC2Theme.AMBER.to_html(false))
			return true
		travel_source = index
		travel_step = TravelStep.DESTINATION
		_log_line("TRAVEL SOURCE -> %s" % controller.display_name(index))
		status_message.emit("Select Destination")
		return true
	if travel_step == TravelStep.DESTINATION:
		if index == travel_source:
			_log_line("[color=#%s]source and destination are the same world[/color]"
				% CC2Theme.AMBER.to_html(false))
			return true
		if not manifest.open(travel_source, index):
			_log_line("[color=#%s]cannot open a manifest for that route[/color]"
				% CC2Theme.ALERT.to_html(false))
			return true
		travel_step = TravelStep.NONE
		_log_line("TRAVEL DESTINATION -> %s" % controller.display_name(index))
		return true
	return false


## Open the travel flow: press Travel, then click the source world.
##
## A refusal is logged rather than swallowed. "no ships of yours in orbit" is the difference
## between a button that is broken and one that is telling the player why.
func _on_travel_requested() -> void:
	if controller == null or controller.galaxy == null:
		return
	if controller.player_fleets().is_empty():
		_log_line("[color=#%s]TRAVEL REFUSED: you have no ships[/color]"
			% CC2Theme.AMBER.to_html(false))
		status_message.emit("you have no ships to send")
		return
	_abandon_travel()
	travel_step = TravelStep.SOURCE
	status_message.emit("Select Source Location")
	_log_line("TRAVEL: select the world your ships are orbiting")


## Abandon an in-flight travel selection without disturbing anything else.
func _abandon_travel() -> void:
	travel_step = TravelStep.NONE
	travel_source = -1
	if travel != null:
		travel.close()
	if manifest != null:
		manifest.close()


## The manifest's OK: create a transit fleet from the selected ships and dispatch it.
##
## The travel order carries the manifest rather than naming a fleet, so the resolver splits the
## source orbit into "these ships go" and "these stay" and puts the first group into transit.
func _on_manifest_confirmed(source: int, destination: int, ships: Dictionary) -> void:
	var fleet := controller.orbital_fleet(source)
	if fleet == null:
		_log_line("[color=#%s]TRAVEL REFUSED: nothing left in orbit[/color]"
			% CC2Theme.ALERT.to_html(false))
		return
	var count := 0
	for key: Variant in ships:
		count += int(ships[key])
	if controller.queue_travel(destination, ships, fleet.id):
		# Adopt the source world so the fleet panel shows the fleet that is leaving rather than
		# continuing to describe the one that stayed.
		controller.select_planet(source)
		controller.select_fleet(fleet.id)
	_log_line("TRAVEL STAGED -> %s (%d ship%s)" % [
		controller.display_name(destination), count, "" if count == 1 else "s"])


func _on_manifest_cancelled() -> void:
	_log_line("TRAVEL DISCARDED")


## A destination was proposed on the map. Quote the flight and open the travel modal with
## that world already chosen; the order is not queued until the modal's OK.
func _on_order_proposed(index: int) -> void:
	fleets.show_proposal(index)
	if travel.open_for_selected_fleet():
		travel.set_destination(index)
		return
	status_message.emit("select a fleet that is not already under way")


func _on_order_cancelled() -> void:
	fleets.hide_proposal()
	if travel != null:
		travel.close()
	_abandon_travel()
	_log_line("ORDER DISCARDED")


## The modal's OK button. This is the only route to a move order now.
func _on_travel_confirmed(destination: int, ships: Dictionary) -> void:
	# The map's proposal is consumed by this commit, so clear it silently: the flight is
	# being sent, not discarded, and `order_cancelled` would say otherwise in the log.
	map.clear_proposal()
	fleets.hide_proposal()
	if controller.queue_travel(destination, ships):
		var count := 0
		for key: Variant in ships:
			count += int(ships[key])
		_log_line("TRAVEL STAGED -> %s (%d ship%s)" % [
			controller.display_name(destination), count, "" if count == 1 else "s"])
	else:
		_log_line("[color=#%s]TRAVEL REFUSED[/color]" % CC2Theme.ALERT.to_html(false))


## The landing button was pressed. Consume the kit and settle the world.
func _on_land_requested() -> void:
	var f := controller.fleet()
	var where := "" if f == null else controller.display_name(f.system)
	if controller.land_colony_ship():
		_log_line("COLONY SHIP LANDED at %s" % where)
		return
	_log_line("[color=#%s]LANDING REFUSED[/color]" % CC2Theme.ALERT.to_html(false))


func _on_travel_cancelled() -> void:
	_log_line("TRAVEL DISCARDED")


## The progress bar was clicked. Open the dialog; nothing is spent yet.
func _on_construction_boosted() -> void:
	if boost.open_for_selected_colony():
		return
	status_message.emit("nothing under construction to put metal into")


## The dialog's OK. This is the only place a player moves metal by hand.
##
## The modal has already clamped each direction to its own ceiling, and `ColonySim` clamps
## again -- the UI guard is so the player cannot pick an absurd number, and the sim guard is so
## a packet cannot. The signal carries a signed amount: positive put metal into the project,
## negative took it back out, and both applied by the modal itself before the log line.
func _on_boost_confirmed(metals: float) -> void:
	if metals >= 0.0:
		_log_line("CONSTRUCTION BOOSTED by %d metal" % int(metals))
		return
	_log_line("CONSTRUCTION REFUNDED by %d metal" % int(-metals))


func _on_boost_cancelled() -> void:
	_log_line("METAL TRANSFER CANCELLED")


## The Load / Unload button on the planet panel. Opens for the selected world.
func _on_cargo_requested() -> void:
	if cargo.open(controller.selected_planet):
		return
	_log_line("[color=#%s]CARGO REFUSED: nothing in orbit here to load[/color]"
		% CC2Theme.AMBER.to_html(false))


func _on_transfer_confirmed(
	planet: int, hull_id: StringName, loads: Dictionary, unloads: Dictionary
) -> void:
	_log_line("CARGO -> %s: %d loaded, %d unloaded" % [
		controller.display_name(planet), loads.size(), unloads.size()])


func _on_transfer_cancelled() -> void:
	_log_line("CARGO CANCELLED")


func _on_refused(reason: String) -> void:
	status_message.emit(reason)


func _on_fleet_selected(fleet_id: int) -> void:
	if fleet_id < 0:
		return
	var f := controller.fleet()
	if f != null:
		_log_line("FLEET %03d SELECTED" % f.id)


func _on_build_requested(building_id: StringName) -> void:
	var planet := controller.galaxy.planet(controller.selected_planet)
	if planet == null:
		return
	_log_line("CONSTRUCT %s @ P%02d" % [String(building_id).to_upper(), planet.index])


func _on_turn_resolved(report: Dictionary) -> void:
	turn_committed.emit(report)
	var stats := report.get("stats", {}) as Dictionary
	if not stats.is_empty():
		_log_line("TURN REPORT: %d orders resolved" % int(stats.get("orders", 0)))


func _on_action_rejected(reason: String) -> void:
	_log_line("[color=#%s]REFUSED: %s[/color]" % [CC2Theme.ALERT.to_html(false), reason])


## Programmatic End-Turn path used by the automated GUI test. Goes through the button so
## the test exercises the same signal chain a click does.
## Advance a single-player turn.
##
## The END TURN button is gone. A networked player commits by pressing READY, which ships
## their staged orders with the flag; a single player has no lobby and therefore no READY,
## so the turn is advanced from here. The map emits `end_turn_requested` on Space/Enter,
## and this is the programmatic equivalent of that keypress -- the same path, not a
## parallel one, so a bug in one is a bug in both.
func press_end_turn() -> void:
	map.end_turn_requested.emit()


## Select a colony by planet index, as the macro panel's colony selector would.
func select_colony(planet_index: int) -> void:
	controller.select_planet(planet_index)
	macros.refresh()

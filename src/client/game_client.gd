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
	_build_layout()
	# `start()` may have been called before this node entered the tree, in which case the
	# panels it needs did not exist yet.
	if _pending_galaxy != null:
		_attach_session()


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

	fleets = FleetPanel.new()
	fleets.custom_minimum_size = Vector2(280, 220)
	fleets.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fleets.size_flags_stretch_ratio = 2.0
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
	fleets.fleet_selected.connect(_on_fleet_selected)
	fleets.order_mode_changed.connect(_on_order_mode_changed)
	macros.build_requested.connect(_on_build_requested)
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
	_log_line("SELECTED %s" % controller.display_name(index))


func _on_refused(reason: String) -> void:
	status_message.emit(reason)


func _on_fleet_selected(fleet_id: int) -> void:
	if fleet_id < 0:
		return
	var f := controller.fleet()
	if f != null:
		_log_line("FLEET %03d SELECTED" % f.id)


func _on_order_mode_changed(on: bool) -> void:
	map.set_order_mode(on)
	status_message.emit(
		"move order mode ON - click a planet" if on else "move order mode OFF"
	)


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

extends PanelContainer
class_name FleetPanel
## Fleet selection, the ship manifest readout, and the Travel button that opens the modal.
##
## The Fleet Registry list is gone as of Phase 8. It showed every fleet the player owned in
## an `ItemList`, and with one system and no unexplored space there is nothing for it to filter
## out -- so it was a list of the player's own ships with no decision attached to it. What
## replaced it is the travel modal, which lists the ships that actually matter (the ones being
## chosen for a flight) and has `+` / `-` buttons on them.

## Emitted when the fleet this panel is showing changes.
##
## Phase 8 removed the registry list, so the player no longer picks a fleet here -- clicking
## one on the map does it. The panel still reports which fleet it has adopted, because every
## other panel and the session log want to know when that changes, and having the panel
## announce it means they do not each have to diff the controller's selection themselves.
signal fleet_selected(fleet_id: int)

## The fleet id last reported through `fleet_selected`, so the change is reported once.
var _reported_fleet: int = -2

var _controller: SessionController = null

var _detail: RichTextLabel = null
var _travel_button: Button = null
var _hint: Label = null

## Load / unload between the selected world's stockpiles and the lifts in its orbit.
##
## Placed directly beneath Travel because it is the other half of the same question -- what is
## on the ground here, and what is in the ships above it -- and a player looking for one should
## find the other next to it.
var _cargo_button: Button = null

## Land the fleet's Colony Ship on the world it is over. Only shown when that is legal, so
## the button is a statement rather than a question.
var _land_button: Button = null

## Draw every transit fleet's route at once, rather than only the selected one's.
##
## The map already draws the selected fleet's line and its waypoint pips; this is the
## everything-at-once view, for an empire with several wings in the air at once and no way to
## see where any of them are going. Off by default: it is an overlay over a board that is
## perfectly legible without it, and a screen of lines is not an improvement to look at.
var _paths_button: Button = null

## The destination the player has proposed, or -1. The modal owns the actual workflow now.
var _proposal: int = -1


## Emitted when the player wants every transit route drawn, or wants them hidden again.
signal flight_paths_toggled(on: bool)


func _ready() -> void:
	_build()


func _build() -> void:
	theme = CC2Theme.build()
	custom_minimum_size = Vector2(240, 0)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	add_child(col)

	var heading := Label.new()
	heading.text = "FLEET"
	heading.add_theme_color_override("font_color", CC2Theme.CYAN)
	heading.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(heading)

	# "Stage move" is replaced by "Travel". The old button armed a mode that then needed a
	# map click and a confirmation; the modal is the whole workflow in one window, so a
	# toggle for it would be a step that no longer exists.
	_travel_button = Button.new()
	_travel_button.text = "Travel"
	_travel_button.tooltip_text = "Choose a destination and which ships to send"
	_travel_button.focus_mode = Control.FOCUS_NONE
	_travel_button.pressed.connect(_on_travel_pressed)
	col.add_child(_travel_button)

	# The all-fleets route overlay, directly beneath Travel because it is the other half of
	# the same question -- Travel sends one fleet somewhere, this shows where everything is
	# already going.
	_paths_button = Button.new()
	_paths_button.text = "Show Flight Paths"
	_paths_button.tooltip_text = "Draw every fleet in transit and where it is headed"
	_paths_button.focus_mode = Control.FOCUS_NONE
	_paths_button.pressed.connect(_on_paths_pressed)
	col.add_child(_paths_button)

	# Load / unload. Keyed on the *selected planet* rather than on the selected fleet: the
	# dialog is about a world and its orbit, and a transport sitting over the colony is what
	# the player wants whether or not they happened to click it first.
	_cargo_button = Button.new()
	_cargo_button.text = "Load / Unload"
	_cargo_button.tooltip_text = "Move cargo, troops or civilians between this world and its orbit"
	_cargo_button.focus_mode = Control.FOCUS_NONE
	_cargo_button.pressed.connect(_on_cargo_pressed)
	col.add_child(_cargo_button)

	# The Colony Ship is the one structure a colony cannot build: it flies here and is spent.
	# The button is enabled only when the fleet actually carries one over an unclaimed world,
	# because "no kit aboard" and "already settled" are two different reasons a press would
	# be refused and a player deserves to see which before pressing.
	_land_button = Button.new()
	_land_button.text = "Land Colony Ship"
	_land_button.tooltip_text = "Consume this fleet's Colony Ship to settle the world below"
	_land_button.focus_mode = Control.FOCUS_NONE
	_land_button.pressed.connect(_on_land_pressed)
	col.add_child(_land_button)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)
	_hint.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(_hint)

	_detail = RichTextLabel.new()
	_detail.bbcode_enabled = true
	_detail.fit_content = true
	_detail.scroll_active = false
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_detail)


func bind(controller: SessionController) -> void:
	_controller = controller
	if _controller == null:
		return
	if not _controller.state_changed.is_connected(refresh):
		_controller.state_changed.connect(refresh)
	refresh()


func refresh() -> void:
	if _controller == null or _controller.galaxy == null:
		return
	# Reported through a member rather than emitted from the handler that selected it, so
	# that the map's click and a controller-side selection are announced identically.
	var current: int = _controller.selected_fleet
	if _controller.fleet() == null:
		current = -1
	if current != _reported_fleet:
		_reported_fleet = current
		fleet_selected.emit(current)
	_refresh_land_button()
	_refresh_cargo_button()
	_refresh_paths_button()
	_refresh_detail()


## Draw the button's label from the state it controls, so the two cannot disagree.
##
## A toggle whose text is written once at build time says "Show Flight Paths" over an overlay
## that is already up, which is the one thing a toggle must never do. The map owns the actual
## flag, so the button reads it rather than keeping a second copy -- there is no local
## `_flight_paths` to drift.
func _refresh_paths_button() -> void:
	if _paths_button == null or _controller == null or _controller.galaxy == null:
		return
	var on := _controller.flight_paths_shown()
	_paths_button.text = "Hide Flight Paths" if on else "Show Flight Paths"
	_paths_button.tooltip_text = (
		"Hide every fleet's route" if on else "Draw every fleet in transit and where it is headed"
	)


## Enable the landing button only when a landing would actually be accepted.
func _refresh_land_button() -> void:
	if _land_button == null:
		return
	var landable := _controller.can_land_colony_ship()
	_land_button.visible = landable
	_land_button.disabled = not landable
	_land_button.tooltip_text = "Consume this fleet's Colony Ship to settle the world below"


## Show the cargo control only when there is something in orbit that can actually be loaded.
##
## Visibility rather than a disabled button, for the same reason as the landing control: "you
## have no transport here" is a different thing to be told than "you pressed a button and
## nothing happened", and only one of them is worth a row on screen.
func _refresh_cargo_button() -> void:
	if _cargo_button == null or _controller == null:
		return
	var have_lifts := _controller.has_transports_at(_controller.selected_planet)
	_cargo_button.visible = have_lifts
	_cargo_button.disabled = not have_lifts


func _refresh_detail() -> void:
	var f := _controller.fleet()
	if f == null:
		_detail.text = "[color=#%s]NO FLEET SELECTED[/color]" % CC2Theme.WHITE_DIM.to_html(false)
		_hint.text = "Select a fleet on the map, then press TRAVEL to send it somewhere."
		return

	var lines := PackedStringArray()
	lines.append(Format.heading(f.name if f.name != "" else "FLEET %03d" % f.id))
	lines.append(Format.field("AT", _controller.display_name(f.system)))
	lines.append(Format.field("SHIPS", str(f.ship_count())))
	lines.append(Format.field("ATTACK", Format.fixed(f.base_weapon_damage(), 1)))
	lines.append(Format.field("DEFENCE", Format.fixed(f.base_hull_points(), 1)))
	lines.append(Format.field("HULL", Format.fixed(f.base_hull_points(), 1)))
	lines.append(Format.field("SHIELDS", Format.fixed(f.base_shield_points(), 1)))
	lines.append(Format.field("MORALE", Format.percent(f.morale)))

	if f.survey_rate() > 0.0:
		lines.append(Format.field("SURVEY", Format.percent(f.survey_rate())))
	if f.troop_capacity() > 0.0:
		lines.append(Format.field("TROOP BAYS", Format.fixed(f.troop_capacity(), 0)))
		lines.append(Format.field("TROOPS ABOARD", Format.fixed(f.troops_carried(), 0)))
	if f.civilian_capacity() > 0.0:
		lines.append(Format.field("CIVILIAN BERTHS", Format.fixed(f.civilian_capacity(), 0)))
		lines.append(Format.field("CIVILIANS ABOARD", Format.fixed(
			TransferStage.carried(f, &"civilians"), 0)))
	if f.cargo_capacity() > 0.0:
		lines.append(Format.field("CARGO", Format.fixed(
			TransferStage.carried(f, &"metals")
			+ TransferStage.carried(f, &"food")
			+ TransferStage.carried(f, &"power"), 0)))
	if f.has_colony_ship():
		lines.append(Format.field("COLONY KIT", "yes"))

	lines.append("")
	var hulls := PackedStringArray()
	for key: StringName in f.ships:
		var def: Resource = f.hulls().get(key, null) as Resource
		var label := String(key) if def == null else String(def.display_name)
		hulls.append("%s x%d" % [label, int(f.ships[key])])
	hulls.sort()
	for entry in hulls:
		lines.append("  " + entry)

	if f.destination >= 0:
		lines.append("")
		lines.append(Format.field("IN TRANSIT TO",
			_controller.display_name(f.destination)))
		lines.append("[color=#%s]  ordered - awaiting resolution[/color]" % CC2Theme.CYAN.to_html(false))
		_hint.text = "This fleet is under way. It cannot be re-ordered until it arrives."
	else:
		_hint.text = "Press TRAVEL to choose a destination and the ships to send."
	_detail.text = "\n".join(lines)


func _on_travel_pressed() -> void:
	travel_requested.emit()


## The player flipped the route overlay. The panel does not hold the flag, so it asks the
## controller for the opposite of what the map currently shows rather than tracking its own.
func _on_paths_pressed() -> void:
	var want := not (_controller != null and _controller.flight_paths_shown())
	flight_paths_toggled.emit(want)
	_refresh_paths_button()


## Consume the fleet's Colony Ship and settle the world it is over.
##
## Routed through the client root rather than mutating state here, so the log and the panels
## hear about it the same way every other action reaches them.
func _on_land_pressed() -> void:
	land_requested.emit()


## Routed through the client root rather than opening the dialog here: the dialog overlays the
## map, and the map is a sibling of this panel.
func _on_cargo_pressed() -> void:
	cargo_requested.emit()


## Emitted when the player asks for the travel workflow. The client root owns the modal,
## because the modal has to overlay the map and the map is a sibling of this panel.
signal travel_requested


## Emitted when the player presses the landing button.
signal land_requested


## Emitted when the player presses Load / Unload.
signal cargo_requested


# --- Proposal compatibility -------------------------------------------------

## Show the transit quote for `planet_index`, as a hint rather than a prompt.
##
## The confirm/cancel round trip the panel used to own is gone: the modal's OK button is the
## commit, and there is no separate proposal to confirm. What is kept is the transit figure,
## because a player still wants to know how long a flight is before choosing one, and the
## modal shows the same number from the same function.
func show_proposal(planet_index: int) -> void:
	_proposal = planet_index
	if _controller == null or _controller.galaxy == null or planet_index < 0:
		_hint.text = ""
		return
	var f := _controller.fleet()
	if f == null:
		_hint.text = ""
		return
	var turns := MovementStage.transit_turns(_controller.galaxy, f.system, planet_index)
	# The dot figure is the *pip count*, taken from the same list the map draws and the turn
	# count is derived from -- not a separately rounded parsec figure. Printed from a
	# separate computation it read "26 dots, 3 turns" beside a line of twenty-six pips, which
	# is two numbers a player cannot reconcile rather than one number they can check.
	var dots := MovementStage.waypoints(_controller.galaxy, f.system, planet_index).size() + 1
	_hint.text = "ESTIMATED TRANSIT to %s\n%d turn%s  (%d dots on the map)" % [
		_controller.display_name(planet_index), turns, "" if turns == 1 else "s", dots]


func hide_proposal() -> void:
	_proposal = -1
	refresh()


func pending_destination() -> int:
	return _proposal


# --- Accessors used by the root and the GUI test ---------------------------

## The fleet list. Removed in Phase 8 along with the registry it belonged to.
##
## Kept as an accessor returning null so a caller that still asks gets a definite answer, and
## so the GUI suite can assert on the absence as an absence rather than on a list being empty.
func list() -> ItemList:
	return null


## The order-mode button. Replaced by the Travel button; retained as a null accessor.
func order_button() -> Button:
	return null


func travel_button() -> Button:
	return _travel_button


## The Show/Hide Flight Paths toggle, beneath Travel.
func flight_paths_button() -> Button:
	return _paths_button


## The Land Colony Ship button, shown only when a landing is legal.
func land_button() -> Button:
	return _land_button


## The Load / Unload button, shown only when the selected world has a lift in orbit.
func cargo_button() -> Button:
	return _cargo_button


func detail() -> RichTextLabel:
	return _detail


func hint_label() -> Label:
	return _hint


func confirm_button() -> Button:
	return null


func cancel_button() -> Button:
	return null


func confirm_row() -> HBoxContainer:
	return null


func transit_label() -> Label:
	return null


## Every string this panel is currently showing, in one place.
##
## A panel that hides a world behind a placeholder in one readout and prints its real name in
## another leaks exactly as much as one that never hid it, and the two are refreshed by
## different code. Tests ask the panel what it displays rather than recomputing the rule.
func visible_text() -> String:
	var parts := PackedStringArray()
	if _detail != null:
		parts.append(_detail.text)
	if _hint != null:
		parts.append(_hint.text)
	if _travel_button != null:
		parts.append(_travel_button.text)
	if _paths_button != null:
		parts.append(_paths_button.text)
	if _cargo_button != null and _cargo_button.visible:
		parts.append(_cargo_button.text)
	if _land_button != null and _land_button.visible:
		parts.append(_land_button.text)
	return "\n".join(parts)


## Kept so the root's signal wiring from before Phase 8 still resolves. Nothing emits it.
func set_order_mode(_on: bool) -> void:
	pass
extends PanelContainer
class_name FleetPanel
## Fleet list and selection, plus the staging control for move orders.
##
## Selects a fleet in the list; the map then draws the fleet's marker in the phosphor
## highlight and any click on a star becomes a move order for that fleet.

## Emitted when the player changes the selected fleet id (or -1 to clear).
signal fleet_selected(fleet_id: int)

## Emitted when the order-mode toggle changes.
signal order_mode_changed(on: bool)

var _controller: SessionController = null

var _list: ItemList = null
var _detail: RichTextLabel = null
var _order_button: Button = null
var _order_hint: Label = null
var _rebuilding := false

## The CONFIRM / CANCEL prompt, hidden until a destination is proposed.
var _confirm_row: HBoxContainer = null
var _confirm_button: Button = null
var _cancel_button: Button = null
var _transit_label: Label = null

## Emitted when the player commits a proposed flight.
signal order_confirmed(planet_index: int)

## Emitted when the player discards a proposed flight.
signal order_cancelled


func _ready() -> void:
	_build()


func _build() -> void:
	theme = CC2Theme.build()
	custom_minimum_size = Vector2(240, 0)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	add_child(col)

	var heading := Label.new()
	heading.text = "FLEET REGISTRY"
	heading.add_theme_color_override("font_color", CC2Theme.CYAN)
	heading.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(heading)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 140)
	_list.allow_reselect = true
	_list.add_theme_stylebox_override(
		"panel", CC2Theme.sunk(CC2Theme.BG_SUNK, CC2Theme.BORDER)
	)
	_list.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)
	_list.add_theme_color_override("font_selected_color", CC2Theme.BG)
	_list.add_theme_color_override("font_hovered_color", CC2Theme.PHOSPHOR)
	_list.add_theme_stylebox_override(
		"selected", CC2Theme.box(CC2Theme.PHOSPHOR, CC2Theme.PHOSPHOR, 0, 2)
	)
	_list.add_theme_stylebox_override(
		"selected_focus", CC2Theme.box(CC2Theme.PHOSPHOR, CC2Theme.PHOSPHOR, 0, 2)
	)
	_list.add_theme_stylebox_override(
		"hovered", CC2Theme.box(Color(0.05, 0.12, 0.09), CC2Theme.BORDER, 0, 2)
	)
	_list.item_selected.connect(_on_item_selected)
	col.add_child(_list)

	_order_button = Button.new()
	_order_button.text = "STAGE MOVE: OFF"
	_order_button.toggle_mode = true
	_order_button.focus_mode = Control.FOCUS_NONE
	_order_button.tooltip_text = "When on, clicking a star on the map queues a move order"
	_order_button.toggled.connect(_on_order_toggled)
	col.add_child(_order_button)

	_order_hint = Label.new()
	_order_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_order_hint.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)
	_order_hint.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(_order_hint)

	_build_confirm_row(col)

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


## The confirmation prompt.
##
## A proposal the player has not yet accepted, so it is out of the way until there is one.
## `visible = false` rather than a rebuild, because the panel is rebuilt on every refresh
## and a rebuild would drop the prompt the instant the mouse moved.
func _build_confirm_row(col: Control) -> void:
	_confirm_row = HBoxContainer.new()
	_confirm_row.add_theme_constant_override("separation", 6)
	_confirm_row.visible = false
	col.add_child(_confirm_row)

	_confirm_button = Button.new()
	_confirm_button.text = "CONFIRM"
	_confirm_button.tooltip_text = "Send this fleet to the proposed destination"
	_confirm_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_confirm_button.focus_mode = Control.FOCUS_NONE
	_confirm_button.pressed.connect(_on_confirm_pressed)
	_confirm_row.add_child(_confirm_button)

	_cancel_button = Button.new()
	_cancel_button.text = "CANCEL"
	_cancel_button.tooltip_text = "Discard this flight"
	_cancel_button.focus_mode = Control.FOCUS_NONE
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_confirm_row.add_child(_cancel_button)

	_transit_label = Label.new()
	_transit_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_transit_label.add_theme_color_override("font_color", CC2Theme.PHOSPHOR)
	_transit_label.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	_transit_label.visible = false
	col.add_child(_transit_label)


## Show the prompt for a proposed destination, quoting what the flight will cost.
##
## `planet_index` is the proposal; the transit figure comes from the same `transit_turns`
## the resolver will effectively execute, so the number on screen is the number of turns
## the fleet will spend. Quoting anything else -- a rounded estimate, a per-hull speed --
## would make the one number the player has to decide on the one number they cannot trust.
func show_proposal(planet_index: int) -> void:
	if _controller == null or _controller.galaxy == null or planet_index < 0:
		hide_proposal()
		return
	var f := _controller.fleet()
	if f == null:
		hide_proposal()
		return
	var dest := _controller.galaxy.planet(planet_index)
	if dest == null:
		hide_proposal()
		return
	var turns := MovementStage.transit_turns(_controller.galaxy, f.system, planet_index)
	# The dot count is the *pip count*, taken from the same list the map draws and the
	# turn count is derived from -- not a separately rounded parsec figure. Printed from a
	# separate computation it read "14 dots, 2 turns" beside a line of fourteen pips, which
	# is two numbers a player cannot reconcile rather than one number they can check.
	var dots := MovementStage.waypoints(_controller.galaxy, f.system, planet_index).size() + 1
	_transit_label.text = "ESTIMATED TRANSIT\n%d turn%s  (%d dots on the map)" % [
		turns, "" if turns == 1 else "s", dots]
	_transit_label.visible = true
	_confirm_row.visible = true


func hide_proposal() -> void:
	if _confirm_row != null:
		_confirm_row.visible = false
	if _transit_label != null:
		_transit_label.visible = false


func _on_confirm_pressed() -> void:
	# The map owns the proposal; the panel just forwards the intent and lets the map decide
	# whether it can still be honoured.
	order_confirmed.emit(-1)


func _on_cancel_pressed() -> void:
	hide_proposal()
	order_cancelled.emit()


func refresh() -> void:
	if _controller == null or _controller.galaxy == null:
		return
	_refresh_list()
	_refresh_detail()


func _refresh_list() -> void:
	var fleets := _controller.player_fleets()

	# Rebuild only when something the caption shows has actually changed; otherwise
	# selecting a row would clear the selection on every refresh.
	#
	# The key has to cover each fleet's *where* and its order destination, not just the
	# roster. Keying on ids alone -- which is what this did -- meant that ordering a fleet
	# somewhere left every caption stale, so the registry showed the location a fleet had
	# left rather than the one it is bound for.
	var ids := PackedInt32Array()
	for f in fleets:
		ids.append(f.id)
		ids.append(f.system)
		ids.append(f.destination)
		ids.append(f.ship_count())
	if ids != _list.get_meta("ids", PackedInt32Array()):
		_list.set_meta("ids", ids)
		_rebuilding = true
		_list.clear()
		for f in fleets:
			_list.add_item(_caption(f))
			_list.set_item_metadata(_list.item_count - 1, f.id)
		_rebuilding = false

	var want := _controller.selected_fleet
	var idx := -1
	for i in fleets.size():
		if fleets[i].id == want:
			idx = i
			break
	if _selected_row() != idx:
		_rebuilding = true
		if idx >= 0:
			_list.select(idx)
		else:
			_list.deselect_all()
		_rebuilding = false


## Row index of the current selection, or -1.
##
## `ItemList` has no `selected` property; `get_selected_items` is the accessor. Reading a
## single-index list through the plural accessor keeps the intent explicit.
func _selected_row() -> int:
	var rows := _list.get_selected_items()
	return rows[0] if not rows.is_empty() else -1


## Where a fleet is, as a short name. Fleets sit on planets now, so a fleet's location is
## a world. The name comes from the controller so this panel cannot disagree with the map,
## the inspector and the log about which worlds the player is entitled to read.
func _caption(f: FleetState) -> String:
	var here := _controller.galaxy.planet(f.system)
	var where := _controller.display_name(f.system) if here != null else "IN TRANSIT"
	if f.destination >= 0:
		var dest := _controller.galaxy.planet(f.destination)
		if dest != null:
			where = "-> %s" % _controller.display_name(f.destination)
	return "%s  %-12s %d ships" % [f.name if f.name != "" else "F%03d" % f.id, where, f.ship_count()]


func _refresh_detail() -> void:
	var f := _controller.fleet()
	if f == null:
		_detail.text = "[color=#%s]NO FLEET SELECTED[/color]" % CC2Theme.WHITE_DIM.to_html(false)
		if _confirm_row != null and not _confirm_row.visible:
			_order_hint.text = \
				"Select a fleet, then enable STAGE MOVE and click a planet on the map."
		return

	var lines := PackedStringArray()
	lines.append(Format.heading(f.name if f.name != "" else "FLEET %03d" % f.id))
	lines.append(Format.field("SHIPS", str(f.ship_count())))
	lines.append(Format.field("HULL", Format.fixed(f.base_hull_points(), 1)))
	lines.append(Format.field("SHIELDS", Format.fixed(f.base_shield_points(), 1)))
	lines.append(Format.field("WEAPONS", Format.fixed(f.base_weapon_damage(), 1)))
	lines.append(Format.field("ACCURACY", Format.fixed(f.base_accuracy() * 100.0, 0) + "%"))
	lines.append(Format.field("SPEED", Format.fixed(f.base_speed(), 2)))
	lines.append(Format.field("SENSORS", Format.fixed(f.base_sensor_range(), 2)))
	lines.append(Format.field("MORALE", Format.percent(f.morale)))

	if f.troop_capacity() > 0.0:
		lines.append(Format.field("TROOPS", Format.fixed(f.troop_capacity(), 1)))
	if f.free_cargo() > 0.0:
		lines.append(Format.field("CARGO FREE", Format.fixed(f.free_cargo(), 1)))

	if f.destination >= 0:
		var dest := _controller.galaxy.planet(f.destination)
		lines.append(Format.field("IN TRANSIT TO",
			_controller.display_name(f.destination) if dest != null else "?"))
		lines.append("[color=#%s]  ordered - awaiting resolution[/color]" % CC2Theme.CYAN.to_html(false))
	elif _confirm_row == null or not _confirm_row.visible:
		# Only overwrite the hint when no proposal is open: the prompt's own line is the
		# answer the player is reading, and `refresh` runs on every `state_changed`.
		_order_hint.text = "STAGE MOVE armed. Click a planet on the map to plan a flight."
	_detail.text = "\n".join(lines)


func _on_item_selected(index: int) -> void:
	if _rebuilding or _controller == null:
		return
	var meta: Variant = _list.get_item_metadata(index)
	if meta == null:
		return
	var id: int = int(meta)
	_controller.select_fleet(id)
	fleet_selected.emit(id)


func _on_order_toggled(on: bool) -> void:
	_order_button.text = "STAGE MOVE: ON" if on else "STAGE MOVE: OFF"
	if on:
		_order_button.add_theme_color_override("font_color", CC2Theme.BG)
		_order_button.add_theme_stylebox_override(
			"pressed", CC2Theme.box(CC2Theme.PHOSPHOR, CC2Theme.PHOSPHOR, CC2Theme.BORDER_W, 4)
		)
	order_mode_changed.emit(on)


func list() -> ItemList:
	return _list


## Every string this panel is currently showing, in one place.
##
## A panel that hides a world behind a placeholder in its caption but prints the real name
## in its detail readout leaks exactly as much as one that never hid it, and the two are
## refreshed by different code. Tests need to ask the panel what it displays rather than
## recompute the rule they are trying to check.
func visible_text() -> String:
	var parts := PackedStringArray()
	if _list != null:
		for i in _list.item_count:
			parts.append(_list.get_item_text(i))
	if _detail != null:
		parts.append(_detail.text)
	if _order_hint != null:
		parts.append(_order_hint.text)
	if _transit_label != null and _transit_label.visible:
		parts.append(_transit_label.text)
	if _confirm_row != null and _confirm_row.visible:
		parts.append(_confirm_button.text)
		parts.append(_cancel_button.text)
	return "\n".join(parts)


func confirm_button() -> Button:
	return _confirm_button


func cancel_button() -> Button:
	return _cancel_button


func confirm_row() -> HBoxContainer:
	return _confirm_row


func transit_label() -> Label:
	return _transit_label


func detail() -> RichTextLabel:
	return _detail


func order_button() -> Button:
	return _order_button


func set_order_mode(on: bool) -> void:
	if _order_button.button_pressed != on:
		_order_button.set_pressed_no_signal(on)
	_order_button.text = "STAGE MOVE: ON" if on else "STAGE MOVE: OFF"

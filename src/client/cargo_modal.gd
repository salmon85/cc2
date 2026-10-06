extends PanelContainer
class_name CargoModal
## Load and unload between a colony's stockpiles and the lifts in its orbit.
##
## One dialog for three hull types because the *shape* of the decision is the same each time:
## something is on the ground, something is in the hold, and a slider moves metal / food /
## power, troops or civilians across between them, bounded at both ends. What differs is the
## noun, and burying that noun in a per-hull dialog is three dialogs to keep working.
##
## The hull is chosen first, then the transfers. That order is not cosmetic: the available
## capacity and the maximum loadable are properties of *which* lift is selected, so choosing
## the hull afterwards would mean re-deriving every ceiling under the player mid-decision.
##
## Nothing is applied until OK. A half-finished dialog leaves the colony exactly as it found it,
## which is the same rule the travel manifest follows and for the same reason -- a control that
## commits as you drag a slider cannot be reasoned about.

## Emitted when the player commits. `loads` and `unloads` are `{kind: amount}` maps, so one
## signal carries a whole mixed operation.
signal transfer_confirmed(planet: int, hull_id: StringName, loads: Dictionary, unloads: Dictionary)

## Emitted when the player dismisses the dialog.
signal transfer_cancelled

var _controller: SessionController = null

var _planet_index: int = -1
var _hull_id: StringName = &""

## Pending movement per kind. Positive is a load (surface -> hold), negative an unload.
var _pending: Dictionary = {}

var _title: Label = null
var _hull_selector: OptionButton = null
var _stock_label: Label = null
var _rows: VBoxContainer = null
var _ok_button: Button = null
var _cancel_button: Button = null

var _rebuilding := false


func _ready() -> void:
	_build()
	visible = false


func _build() -> void:
	theme = CC2Theme.build()
	custom_minimum_size = Vector2(400, 0)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	add_child(col)

	_title = Label.new()
	_title.add_theme_color_override("font_color", CC2Theme.CYAN)
	_title.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(_title)

	_hull_selector = OptionButton.new()
	_hull_selector.tooltip_text = "Which lift in orbit to work with"
	_hull_selector.focus_mode = Control.FOCUS_NONE
	_hull_selector.item_selected.connect(_on_hull_selected)
	col.add_child(_hull_selector)

	_stock_label = Label.new()
	_stock_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stock_label.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)
	_stock_label.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(_stock_label)

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 4)
	col.add_child(_rows)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	col.add_child(buttons)
	_ok_button = Button.new()
	_ok_button.name = "OK"
	_ok_button.text = "OK"
	_ok_button.tooltip_text = "Apply these transfers"
	_ok_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ok_button.focus_mode = Control.FOCUS_NONE
	_ok_button.pressed.connect(_on_ok)
	buttons.add_child(_ok_button)
	_cancel_button = Button.new()
	_cancel_button.name = "Cancel"
	_cancel_button.text = "CANCEL"
	_cancel_button.focus_mode = Control.FOCUS_NONE
	_cancel_button.pressed.connect(_on_cancel)
	buttons.add_child(_cancel_button)


func bind(controller: SessionController) -> void:
	_controller = controller


# --- Lifecycle -------------------------------------------------------------

## Open the dialog for a world, listing the lifts actually in its orbit.
##
## Refuses a world with no logistics hull in orbit. A dialog whose hull dropdown is empty is a
## control that cannot do anything, and the button that opens it should not have been visible.
func open(planet_index: int) -> bool:
	if _controller == null or _controller.galaxy == null:
		return false
	var planet: PlanetState = _controller.galaxy.planet(planet_index)
	if planet == null or planet.owner != _controller.player_id or not planet.colonized:
		return false
	var lifts := _lift_hulls(planet_index)
	if lifts.is_empty():
		return false
	_planet_index = planet_index
	_pending.clear()
	_rebuild_hulls(lifts)
	_hull_id = lifts[0]
	refresh()
	visible = true
	return true


func close() -> void:
	if not visible:
		return
	visible = false
	_planet_index = -1
	_hull_id = &""
	_pending.clear()
	transfer_cancelled.emit()


func planet_index() -> int:
	return _planet_index


func selected_hull() -> StringName:
	return _hull_id


## The logistic hull ids in orbit over the open world, in a stable order.
func _lift_hulls(planet_index: int) -> Array[StringName]:
	var out: Array[StringName] = []
	if _controller == null:
		return out
	for hull_id: StringName in _controller.hulls_in_orbit_at(planet_index):
		if GameDB.LOGISTIC_HULLS.has(hull_id):
			out.append(hull_id)
	return out


func _rebuild_hulls(lifts: Array[StringName]) -> void:
	_rebuilding = true
	_hull_selector.clear()
	for hull_id in lifts:
		var def := _hull(hull_id)
		_hull_selector.add_item(String(hull_id) if def == null else String(def.display_name))
		_hull_selector.set_item_metadata(_hull_selector.item_count - 1, hull_id)
		if hull_id == _hull_id:
			_hull_selector.select(_hull_selector.item_count - 1)
	if _hull_selector.selected < 0 and _hull_selector.item_count > 0:
		_hull_selector.select(0)
	_hull_selector.disabled = _hull_selector.item_count == 0
	_rebuilding = false


# --- Contents --------------------------------------------------------------

## Rebuild every row from the model. Called on open and whenever the selected hull changes,
## because the available capacity and the maximum loadable are properties of the lift.
func refresh() -> void:
	if _controller == null or _planet_index < 0:
		return
	var planet: PlanetState = _controller.galaxy.planet(_planet_index)
	if planet == null:
		return
	_title.text = "LOAD / UNLOAD  -  %s" % _controller.display_name(_planet_index)
	_stock_label.text = "Colony: metal %d | food %d/%d | power %d/%d | troops %d | pop %d" % [
		int(planet.reserve_metals), int(planet.food_stock), int(planet.food_capacity),
		int(planet.power), int(planet.power_capacity),
		planet.troops, int(round(planet.population))]
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	for kind: StringName in _kinds_for(_hull_id):
		_rows.add_child(_kind_row(planet, kind))
	# Populated after the rows exist. Building a row only creates its caption: the figures in
	# it need the row tree to look the slider up in, and a dialog that opened with a row of
	# blank labels and one labelled "CIVILIANS:" was a dialog that had to be poked to become
	# informative.
	_update_captions()


## The kinds this hull can actually move. Asked of the hull rather than of the whole roster,
## so a Troop Transport never offers a food slider it would refuse on OK.
func _kinds_for(hull_id: StringName) -> Array[StringName]:
	var out: Array[StringName] = []
	var def := _hull(hull_id)
	if def == null:
		return out
	for kind: StringName in TransferStage.KINDS:
		if def.call("carries", _kind_code(kind)):
			out.append(kind)
	return out


## One kind: a label, the slider, and `LOAD` / `UNLOAD` at the two ends.
##
## A single signed slider rather than two, because the two directions are the same decision
## with opposite signs and two sliders would let a player ask for a load and an unload that
## conflict. The ceiling is the larger of what the colony can give and what the hold can take,
## so the slider spans the whole range and the sign says which way.
func _kind_row(planet: PlanetState, kind: StringName) -> Control:
	var row := VBoxContainer.new()
	row.name = "Row_%s" % String(kind)
	row.add_theme_constant_override("separation", 2)

	var caption := Label.new()
	caption.name = "Caption_%s" % String(kind)
	caption.add_theme_color_override("font_color", CC2Theme.PHOSPHOR_DIM)
	caption.add_theme_font_size_override("font_size", CC2Theme.FONT_TINY)
	row.add_child(caption)

	var line := HBoxContainer.new()
	# Named because the GUI suite presses these buttons the way a player does, and an
	# unnamed container makes that lookup depend on the layout rather than on the control.
	line.name = "Line_%s" % String(kind)
	line.add_theme_constant_override("separation", 4)
	row.add_child(line)

	var unload := Button.new()
	unload.name = "Unload_%s" % String(kind)
	unload.text = "Unload"
	unload.tooltip_text = "Move from the hold onto the colony"
	unload.focus_mode = Control.FOCUS_NONE
	unload.pressed.connect(func() -> void: _set_pending(kind, -limit_for(planet, kind)))
	line.add_child(unload)

	var slider := HSlider.new()
	slider.name = "Amount_%s" % String(kind)
	slider.min_value = -limit_for(planet, kind)
	slider.max_value = limit_for(planet, kind)
	slider.step = 1.0
	slider.value = 0.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(0, 16)
	slider.focus_mode = Control.FOCUS_NONE
	slider.value_changed.connect(func(v: float) -> void: _on_slider(kind, v))
	line.add_child(slider)

	var load_button := Button.new()
	load_button.name = "Load_%s" % String(kind)
	load_button.text = "Load"
	load_button.tooltip_text = "Move from the colony into the hold"
	load_button.focus_mode = Control.FOCUS_NONE
	load_button.pressed.connect(func() -> void: _set_pending(kind, limit_for(planet, kind)))
	line.add_child(load_button)
	return row


## The most that could move in *either* direction for `kind`, right now.
##
## The larger of the two ceilings, so the slider has room for both: what the colony can give
## and what the hold can take are different numbers, and whichever is bigger bounds both.
func limit_for(planet: PlanetState, kind: StringName) -> float:
	var out := 0.0
	for f in _controller.fleets_in_orbit_at(_planet_index):
		if not _fleet_lifts(f, _hull_id):
			continue
		# The load direction is bounded by the colony; the unload by what is aboard. With an
		# unbounded hold the first is a real number, so the maximum is a real number -- and
		# an unbounded hold must never reach a slider, whose range would be `INF`.
		var loadable := TransferStage.loadable(planet, f, kind)
		if is_inf(loadable):
			loadable = TransferStage.planet_stock(planet, kind)
		out = maxf(out, maxf(loadable, TransferStage.carried(f, kind)))
	return out


## Whether `fleet` holds at least one of `hull_id`.
func _fleet_lifts(f: FleetState, hull_id: StringName) -> bool:
	if hull_id == &"":
		return true
	return int(f.ships.get(hull_id, 0)) > 0


func _on_slider(kind: StringName, value: float) -> void:
	_pending[kind] = value
	_update_captions()


func _set_pending(kind: StringName, value: float) -> void:
	var planet := _controller.galaxy.planet(_planet_index) if _controller != null else null
	if planet == null:
		return
	var limit := limit_for(planet, kind)
	_pending[kind] = clampf(value, -limit, limit)
	var slider := _slider(kind)
	if slider != null:
		slider.set_value_no_signal(float(_pending[kind]))
	_update_captions()


func _slider(kind: StringName) -> HSlider:
	if _rows == null:
		return null
	return _rows.get_node_or_null(
		NodePath("Row_%s/Line_%s/Amount_%s" % [String(kind), String(kind), String(kind)])) as HSlider


## The per-row caption: what is where right now, and where the slider is.
func _update_captions() -> void:
	if _controller == null or _planet_index < 0 or _rows == null:
		return
	var planet: PlanetState = _controller.galaxy.planet(_planet_index)
	if planet == null:
		return
	for kind: StringName in _kinds_for(_hull_id):
		var caption := _rows.get_node_or_null(
			NodePath("Row_%s/Caption_%s" % [String(kind), String(kind)])) as Label
		if caption == null:
			continue
		var aboard := 0.0
		var capacity := 0.0
		var unbounded := false
		for f in _controller.fleets_in_orbit_at(_planet_index):
			if not _fleet_lifts(f, _hull_id):
				continue
			aboard += TransferStage.carried(f, kind)
			var hold := TransferStage.capacity_for(f, kind)
			if is_inf(hold):
				unbounded = true
			else:
				capacity += hold
		var pending := float(_pending.get(kind, 0.0))
		var movement := ""
		if not is_zero_approx(pending):
			movement = "%+d %s" % [
				int(pending), "into hold" if pending > 0.0 else "onto colony"]
		# An unbounded hold reports the load and not a ratio. Printing `hold 400/0` for a
		# transport that has taken four hundred is the exact phantom the ceiling created.
		var hold_text := "unlimited, %d aboard" % int(aboard) if unbounded \
			else "%d/%d" % [int(aboard), int(capacity)]
		caption.text = "%s: colony %d, hold %s   %s" % [
			TransferStage.kind_name(kind),
			int(TransferStage.planet_stock(planet, kind)), hold_text, movement]


func _hull(hull_id: StringName) -> Resource:
	if _controller == null or _controller.defs == null:
		return null
	return _controller.defs.ship_hull(hull_id) as Resource


func _kind_code(kind: StringName) -> int:
	match kind:
		TransferStage.KIND_METALS: return ShipHullData.CargoKind.METALS
		TransferStage.KIND_FOOD: return ShipHullData.CargoKind.FOOD
		TransferStage.KIND_POWER: return ShipHullData.CargoKind.POWER
		TransferStage.KIND_TROOPS: return ShipHullData.CargoKind.TROOPS
		TransferStage.KIND_CIVILIANS: return ShipHullData.CargoKind.CIVILIANS
	return ShipHullData.CargoKind.NONE


func _on_hull_selected(index: int) -> void:
	if _rebuilding or _controller == null:
		return
	var meta: Variant = _hull_selector.get_item_metadata(index)
	if meta == null:
		return
	_hull_id = StringName(str(meta))
	_pending.clear()
	refresh()


## Commit every kind at once: the loads first, then the unloads.
##
## Loads first because the two directions compete for the same planet stockpile, and doing the
## unload first would hand capacity back before the load had claimed it -- the difference is
## only visible when a colony is at its storage cap, which is exactly when a player is trying
## to swap a hold.
func _on_ok() -> void:
	if _controller == null or _planet_index < 0:
		return
	var loads: Dictionary = {}
	var unloads: Dictionary = {}
	for kind: StringName in _pending:
		var amount := float(_pending[kind])
		if amount > 0.0:
			loads[kind] = amount
		elif amount < 0.0:
			unloads[kind] = -amount
	if loads.is_empty() and unloads.is_empty():
		return
	visible = false
	var planet := _planet_index
	var hull := _hull_id
	for kind: StringName in loads:
		_controller.transfer_at_planet(planet, hull, kind, float(loads[kind]), true)
	for kind: StringName in unloads:
		_controller.transfer_at_planet(planet, hull, kind, float(unloads[kind]), false)
	transfer_confirmed.emit(planet, hull, loads, unloads)
	_planet_index = -1
	_hull_id = &""
	_pending.clear()


func _on_cancel() -> void:
	close()


# --- Accessors for the GUI suite -------------------------------------------

func title_label() -> Label:
	return _title


func hull_selector() -> OptionButton:
	return _hull_selector


func stock_label() -> Label:
	return _stock_label


func rows() -> VBoxContainer:
	return _rows


func ok_button() -> Button:
	return _ok_button


func cancel_button() -> Button:
	return _cancel_button


## The slider for `kind`, or null when this hull does not lift it.
func amount_slider(kind: StringName) -> HSlider:
	return _slider(kind)


## The `LOAD` button for `kind`, or null.
func load_button(kind: StringName) -> Button:
	if _rows == null:
		return null
	return _rows.get_node_or_null(
		NodePath("Row_%s/Line_%s/Load_%s" % [String(kind), String(kind), String(kind)])) as Button


## The `UNLOAD` button for `kind`, or null.
func unload_button(kind: StringName) -> Button:
	if _rows == null:
		return null
	return _rows.get_node_or_null(
		NodePath("Row_%s/Line_%s/Unload_%s" % [String(kind), String(kind), String(kind)])) as Button


## The caption for `kind`: colony stock, hold load, and any pending movement.
func caption_label(kind: StringName) -> Label:
	if _rows == null:
		return null
	return _rows.get_node_or_null(
		NodePath("Row_%s/Caption_%s" % [String(kind), String(kind)])) as Label


## What the player has asked to move, as `{kind: signed amount}`.
func pending() -> Dictionary:
	return _pending.duplicate(true)


func visible_text() -> String:
	var parts := PackedStringArray()
	if _title != null:
		parts.append(_title.text)
	if _stock_label != null:
		parts.append(_stock_label.text)
	if _hull_selector != null:
		for i in _hull_selector.item_count:
			parts.append(_hull_selector.get_item_text(i))
	for kind: StringName in _kinds_for(_hull_id):
		var caption := caption_label(kind)
		if caption != null:
			parts.append(caption.text)
	return "\n".join(parts)
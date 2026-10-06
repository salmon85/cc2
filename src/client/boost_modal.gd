extends PanelContainer
class_name BoostModal
## The metal-allocation dialog behind the construction progress bars.
##
## Clicking a bar opens this rather than spending on the spot. That indirection is the
## correction: a bare "click to spend stored metal" *press* spends the entire stockpile, which
## is never what a player pressing a bar meant — they meant "let me put some metal into this".
##
## Four numbers are shown, and all four are the ones the resolver will use:
##   - the project, by name
##   - how much of its metal cost is already paid
##   - the ceiling on a transfer in, which is `min(colony storage, metal still owed)`
##   - the ceiling on a transfer out, which is the metal already assigned
##
## **The same dialog serves a building and a ship.** From the player's side they are one
## decision — this thing I clicked Build on is eating my metal — and splitting them into two
## dialogs is how they end up with two different rules. `ColonySim` reads the project slot
## rather than the building queue, so a hull in the yard is handled by the same code path.
##
## Two controls, because the pool holds metal the player may want back. "Add" pulls out of
## storage, capped by what the project still owes; "Remove" returns assigned metal to storage,
## capped by what has been assigned and never below zero. Both are one slider and a set of
## buttons rather than two sliders, because the interesting values are the two extremes — the
## whole useful amount, and none of it — and a slider between them is mostly a way of
## mis-clicking.

## Emitted when the player commits. `metals` is positive to add to the project and negative to
## take back out, so one signal carries both directions and the client does not need to know
## which button was pressed to route it to the right controller call.
signal boost_confirmed(metals: float)

## Emitted when the player dismisses the dialog without moving any metal.
signal boost_cancelled

var _controller: SessionController = null

var _title: Label = null
var _detail: Label = null
var _add_prompt: Label = null
var _add_amount: HSlider = null
var _add_label: Label = null
var _remove_prompt: Label = null
var _remove_amount: HSlider = null
var _remove_label: Label = null
## The four quick buttons, held directly rather than found by walking the tree: each row's
## `get_parent()` is the row itself, so a lookup by path would depend on the container layout
## having stayed exactly as built.
var _add_max_button: Button = null
var _add_zero_button: Button = null
var _remove_max_button: Button = null
var _remove_zero_button: Button = null

var _ok_button: Button = null
var _cancel_button: Button = null

## Guard so the programmatic slider writes do not read as a player drag.
var _rebuilding := false


func _ready() -> void:
	_build()
	visible = false


func _build() -> void:
	theme = CC2Theme.build()
	custom_minimum_size = Vector2(380, 0)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	add_child(col)

	_title = Label.new()
	_title.text = "ALLOCATE METAL"
	_title.add_theme_color_override("font_color", CC2Theme.CYAN)
	_title.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(_title)

	_detail = Label.new()
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)
	_detail.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(_detail)

	_build_side(col, true)
	_build_side(col, false)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	col.add_child(buttons)
	_ok_button = Button.new()
	_ok_button.name = "OK"
	_ok_button.text = "OK"
	_ok_button.tooltip_text = "Apply this allocation"
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


## One direction: a prompt, a slider, quick buttons and a readout.
func _build_side(col: Control, adding: bool) -> void:
	var prompt := Label.new()
	prompt.add_theme_color_override(
		"font_color", CC2Theme.PHOSPHOR_DIM if adding else CC2Theme.AMBER)
	prompt.add_theme_font_size_override("font_size", CC2Theme.FONT_TINY)
	prompt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if adding:
		prompt.text = "ADD metal from storage into this project (capped at what it still owes)."
		_add_prompt = prompt
	else:
		prompt.text = "REMOVE assigned metal, returned to storage (down to 0 assigned)."
		_remove_prompt = prompt
	col.add_child(prompt)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	col.add_child(row)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 1.0
	slider.value = 0.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(0, 18)
	slider.focus_mode = Control.FOCUS_NONE
	# Bound per side rather than through one shared handler that has to work out which slider
	# moved: a single handler asking "which of me changed?" is a guess, and in a headless run
	# `has_focus()` answers for neither.
	slider.value_changed.connect(func(v: float) -> void:
		if not _rebuilding:
			_update_label(v, adding))
	row.add_child(slider)

	var quick := HBoxContainer.new()
	quick.add_theme_constant_override("separation", 4)
	row.add_child(quick)
	var max_button := Button.new()
	max_button.name = "MaxAdd" if adding else "MaxRemove"
	max_button.text = "All"
	max_button.tooltip_text = "The whole useful amount in this direction"
	max_button.focus_mode = Control.FOCUS_NONE
	max_button.pressed.connect(func() -> void: _set_side(ceiling(adding), adding))
	if adding:
		_add_max_button = max_button
	else:
		_remove_max_button = max_button
	quick.add_child(max_button)
	var zero_button := Button.new()
	zero_button.name = "ZeroAdd" if adding else "ZeroRemove"
	zero_button.text = "None"
	zero_button.tooltip_text = "Zero in this direction"
	zero_button.focus_mode = Control.FOCUS_NONE
	zero_button.pressed.connect(func() -> void: _set_side(0.0, adding))
	if adding:
		_add_zero_button = zero_button
	else:
		_remove_zero_button = zero_button
	quick.add_child(zero_button)

	var readout := Label.new()
	readout.add_theme_color_override(
		"font_color", CC2Theme.PHOSPHOR if adding else CC2Theme.AMBER)
	readout.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if adding:
		_add_label = readout
	else:
		_remove_label = readout
	col.add_child(readout)

	if adding:
		_add_amount = slider
	else:
		_remove_amount = slider


func bind(controller: SessionController) -> void:
	_controller = controller


## Open the dialog for the selected colony's current project, whichever kind it is.
##
## Refuses when there is nothing under construction, and also when there is nothing to *move*
## in either direction. A dialog whose add slider and remove slider both read "0" is not a
## question -- but a project that is fully paid for still opens, because its remove direction
## is exactly the amount assigned to it. Refusing there would strand metal the player had put
## in with no way to take it back out.
func open_for_selected_colony() -> bool:
	if _controller == null or _controller.galaxy == null:
		return false
	var planet := _selected_colony()
	if planet == null:
		return false
	if ColonySim.project_kind(planet) == ColonySim.ProjectKind.NONE:
		return false
	if ceiling(true) <= 0.0 and ceiling(false) <= 0.0:
		return false
	refresh()
	# Opens with the whole useful amount in the "add" direction. That is what a player opening
	# a progress bar almost always wants, and it is capped by what the project owes, so it is
	# never a suggestion to waste the colony's stockpile.
	_set_side(ceiling(true), true)
	_set_side(ceiling(false), false)
	visible = true
	return true


func close() -> void:
	if not visible:
		return
	visible = false
	boost_cancelled.emit()


## Re-read the project from the colony. Safe to call while hidden.
func refresh() -> void:
	if _controller == null or _controller.galaxy == null:
		return
	var planet := _selected_colony()
	if planet == null:
		return
	var buildings := _building_table()
	var hulls := _hull_table()
	var kind := ColonySim.project_kind(planet)
	var cost := ColonySim.project_cost(planet, buildings, hulls)
	var paid := ColonySim.project_paid(planet)
	var label := "STRUCTURE" if kind == ColonySim.ProjectKind.STRUCTURE else "SHIP"
	_title.text = "ALLOCATE METAL -> %s (%s)" % [_project_name(planet, buildings, hulls), label]
	_detail.text = "%d%% complete (%d of %d metal assigned)\nStorage holds %d metal." % [
		int(round(ColonySim.project_progress(planet, buildings, hulls) * 100.0)),
		int(paid), int(cost), int(planet.reserve_metals)]
	# Both sliders are clamped to their own ceiling, so the player physically cannot drag past
	# what the direction allows. Note that the two ceilings are *not* the same number: the add
	# ceiling is bounded by storage, the remove ceiling by what has been assigned.
	for adding: bool in [true, false]:
		var side := _slider(adding)
		var limit := ceiling(adding)
		side.max_value = maxf(1.0, limit)
		side.min_value = 0.0
		if float(side.value) > limit:
			_set_side(limit, adding)
		else:
			_update_label(float(side.value), adding)


## The largest transfer this direction allows right now.
func ceiling(adding: bool) -> float:
	var planet := _selected_colony()
	if planet == null:
		return 0.0
	if adding:
		return ColonySim.max_assignment(planet, _building_table(), _hull_table())
	return ColonySim.max_refund(planet)


func _slider(adding: bool) -> HSlider:
	return _add_amount if adding else _remove_amount


func _label_for(adding: bool) -> Label:
	return _add_label if adding else _remove_label


## Set a slider without its `value_changed` handler treating it as a player drag.
func _set_side(value: float, adding: bool) -> void:
	_rebuilding = true
	_slider(adding).set_value_no_signal(maxf(0.0, value))
	_rebuilding = false
	_update_label(maxf(0.0, value), adding)


func _update_label(amount: float, adding: bool) -> void:
	var planet := _selected_colony()
	if planet == null:
		return
	var readout := _label_for(adding)
	if readout == null:
		return
	if adding:
		readout.text = "+%d metal  (%d still owed, %d left in storage)" % [
			int(amount), int(ColonySim.project_remaining(
				planet, _building_table(), _hull_table())),
			int(planet.reserve_metals - amount)]
	else:
		readout.text = "-%d metal  (%d assigned after, %d back in storage)" % [
			int(amount),
			int(ColonySim.project_paid(planet) - amount),
			int(planet.reserve_metals + amount)]


func _project_name(planet: PlanetState, buildings: Dictionary, hulls: Dictionary) -> String:
	if ColonySim.project_kind(planet) == ColonySim.ProjectKind.SHIP:
		var hull_id := ColonySim.queued_hull_id(planet)
		var hull: Resource = hulls.get(hull_id, null) as Resource
		return String(hull_id) if hull == null else String(hull.display_name)
	var names := PackedStringArray()
	for building_id: StringName in planet.building_queue:
		var def: Resource = buildings.get(building_id, null) as Resource
		var label := String(building_id)
		if def != null:
			label = String(def.display_name)
		var count := int(planet.building_queue[building_id])
		names.append(label if count <= 1 else "%s x%d" % [label, count])
	names.sort()
	return ", ".join(names)


func _selected_colony() -> PlanetState:
	if _controller == null or _controller.galaxy == null:
		return null
	return _controller.galaxy.planet(_controller.selected_planet)


func _building_table() -> Dictionary:
	if _controller == null or _controller.defs == null:
		return {} as Dictionary
	return _controller.defs.get("buildings") as Dictionary


func _hull_table() -> Dictionary:
	if _controller == null or _controller.defs == null:
		return {} as Dictionary
	return _controller.defs.get("ship_hulls") as Dictionary


## Both directions are committed together, and in that order.
##
## Add first, then remove: the two are clamped against the same pool and the same project, so
## doing them in the other order could make the remove move metal that the add was about to
## take. Netting them the other way round would also let a player refund metal and immediately
## re-add it in one press, which is two operations where they asked for one.
func _on_ok() -> void:
	if _controller == null:
		return
	var add := float(_add_amount.value) if _add_amount != null else 0.0
	var remove := float(_remove_amount.value) if _remove_amount != null else 0.0
	if add <= 0.0 and remove <= 0.0:
		return
	visible = false
	if add > 0.0:
		_controller.boost_construction(add)
	if remove > 0.0:
		_controller.refund_construction(remove)
	boost_confirmed.emit(add - remove)


func _on_cancel() -> void:
	close()


# --- Accessors used by the GUI suite ---------------------------------------

func title_label() -> Label:
	return _title


func detail_label() -> Label:
	return _detail


## The "add metal" slider.
func amount_slider() -> HSlider:
	return _add_amount


## The "add metal" readout. Kept under the old name because that is what the GUI suite asks
## for; the remove-side readout has its own.
func amount_label() -> Label:
	return _add_label


## The "remove assigned metal" slider.
func refund_slider() -> HSlider:
	return _remove_amount


## The "remove assigned metal" readout.
func refund_label() -> Label:
	return _remove_label


func add_prompt_label() -> Label:
	return _add_prompt


func refund_prompt_label() -> Label:
	return _remove_prompt


## The question the dialog exists to ask, on the add side.
func prompt_label() -> Label:
	return _add_prompt


## The button that fills the add slider to its whole useful amount.
func max_button() -> Button:
	return _add_max_button


## The button that zeroes the add slider.
func none_button() -> Button:
	return _add_zero_button


## The button that fills the remove slider to everything assigned.
func refund_max_button() -> Button:
	return _remove_max_button


## The button that zeroes the remove slider.
func refund_none_button() -> Button:
	return _remove_zero_button


func ok_button() -> Button:
	return _ok_button


func cancel_button() -> Button:
	return _cancel_button


func visible_text() -> String:
	var parts := PackedStringArray()
	for node: Control in [_title, _detail, _add_prompt, _add_label, _remove_prompt, _remove_label]:
		var label := node as Label
		if label != null:
			parts.append(label.text)
	for button: Control in [_ok_button, _cancel_button]:
		var control := button as Button
		if control != null:
			parts.append(control.text)
	return "\n".join(parts)
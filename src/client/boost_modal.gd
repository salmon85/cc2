extends PanelContainer
class_name BoostModal
## The metal-transfer dialog behind the construction progress bar.
##
## Clicking the bar opens this rather than spending on the spot. That indirection is the
## correction: a bare "click to spend stored metal" *press* spends the entire stockpile, which
## is never what a player pressing a bar meant — they meant "let me put some metal into this".
## Everything spent is gone; the dialog makes the amount a decision instead of a side effect.
##
## Three numbers are shown, and all three are the ones the resolver will use:
##   - the project, by name
##   - how much of its metal cost is already paid
##   - the ceiling on a transfer, which is `min(colony storage, metal still owed)`
##
## The slider is clamped to that ceiling, so overpaying is not offered. `ColonySim` clamps
## again on the way in — the UI guard is for the player, the sim guard is for the wire.

## Emitted when the player commits a transfer, carrying the metal to move.
signal boost_confirmed(metals: float)

## Emitted when the player dismisses the dialog without transferring anything.
signal boost_cancelled

var _controller: SessionController = null

var _title: Label = null
var _detail: Label = null
var _amount: HSlider = null
var _amount_label: Label = null
var _prompt: Label = null
var _ok_button: Button = null
var _cancel_button: Button = null

## Guard so the programmatic slider write does not read as a player drag.
var _rebuilding := false


func _ready() -> void:
	_build()
	visible = false


func _build() -> void:
	theme = CC2Theme.build()
	custom_minimum_size = Vector2(360, 0)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	add_child(col)

	_title = Label.new()
	_title.text = "TRANSFER METAL"
	_title.add_theme_color_override("font_color", CC2Theme.CYAN)
	_title.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(_title)

	_detail = Label.new()
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)
	_detail.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(_detail)

	_prompt = Label.new()
	_prompt.text = "How much metal do you want to transfer from storage?"
	_prompt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_prompt.add_theme_color_override("font_color", CC2Theme.PHOSPHOR_DIM)
	_prompt.add_theme_font_size_override("font_size", CC2Theme.FONT_TINY)
	col.add_child(_prompt)

	_amount = HSlider.new()
	_amount.min_value = 0.0
	_amount.max_value = 1.0
	_amount.step = 1.0
	_amount.value = 0.0
	_amount.custom_minimum_size = Vector2(0, 18)
	_amount.focus_mode = Control.FOCUS_NONE
	_amount.value_changed.connect(_on_amount_changed)
	col.add_child(_amount)

	_amount_label = Label.new()
	_amount_label.add_theme_color_override("font_color", CC2Theme.PHOSPHOR)
	_amount_label.add_theme_font_size_override("font_size", CC2Theme.FONT_BODY)
	col.add_child(_amount_label)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	col.add_child(buttons)
	_ok_button = Button.new()
	_ok_button.name = "OK"
	_ok_button.text = "OK"
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


## Open the dialog for the selected colony's current project.
##
## Refuses when there is nothing under construction or nothing worth transferring, and says
## so rather than opening an empty dialog: a slider reading "0 of 0" is not a question.
func open_for_selected_colony() -> bool:
	if _controller == null or _controller.galaxy == null:
		return false
	var planet := _selected_colony()
	if planet == null or planet.building_queue.is_empty():
		return false
	var ceiling := _ceiling(planet)
	if ceiling <= 0.0:
		return false
	refresh()
	# Opens at the *whole useful amount* rather than at zero. That is the amount a player
	# pressing a progress bar almost always wants, and it is capped by what the project owes,
	# so it is never a suggestion to waste the colony's stockpile.
	_amount.set_value_no_signal(ceiling)
	_update_label(ceiling)
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
	var cost := ColonySim.queued_cost(planet, buildings)
	var paid := planet.build_metal
	var ceiling := _ceiling(planet)
	_title.text = "TRANSFER METAL -> %s" % _project_name(planet, buildings)
	_detail.text = "%d%% complete (%d of %d metal)\nStorage holds %d metal." % [
		int(round(ColonySim.construction_progress(planet, buildings) * 100.0)),
		int(paid), int(cost), int(planet.reserve_metals)]
	# The slider's range is the ceiling, so the player physically cannot drag past it.
	_amount.max_value = maxf(1.0, ceiling)
	_amount.min_value = 0.0
	if float(_amount.value) > ceiling:
		_rebuilding = true
		_amount.set_value_no_signal(ceiling)
		_rebuilding = false
	if not visible or float(_amount.value) <= 0.0:
		_update_label(ceiling if not visible else float(_amount.value))


## The most metal that could usefully move: storage, capped by what the project still owes.
func _ceiling(planet: PlanetState) -> float:
	return ColonySim.max_boost(planet, _building_table())


func _update_label(amount: float) -> void:
	var planet := _selected_colony()
	if planet == null:
		return
	var buildings := _building_table()
	var remaining := ColonySim.metal_remaining(planet, buildings)
	_amount_label.text = "%d metal  (%d still owed, %d left in storage)" % [
		int(amount), int(remaining), int(planet.reserve_metals - amount)]


func _project_name(planet: PlanetState, buildings: Dictionary) -> String:
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


func _on_amount_changed(value: float) -> void:
	if _rebuilding:
		return
	_update_label(value)


func _on_ok() -> void:
	if _controller == null:
		return
	var amount := float(_amount.value)
	if amount <= 0.0:
		return
	visible = false
	boost_confirmed.emit(amount)


func _on_cancel() -> void:
	close()


# --- Accessors used by the GUI suite ---------------------------------------

func title_label() -> Label:
	return _title


func detail_label() -> Label:
	return _detail


func amount_slider() -> HSlider:
	return _amount


func amount_label() -> Label:
	return _amount_label


## The question the dialog exists to ask.
func prompt_label() -> Label:
	return _prompt


func ok_button() -> Button:
	return _ok_button


func cancel_button() -> Button:
	return _cancel_button


func visible_text() -> String:
	var parts := PackedStringArray()
	if _title != null:
		parts.append(_title.text)
	if _detail != null:
		parts.append(_detail.text)
	if _prompt != null:
		parts.append(_prompt.text)
	if _amount_label != null:
		parts.append(_amount_label.text)
	if _ok_button != null:
		parts.append(_ok_button.text)
	if _cancel_button != null:
		parts.append(_cancel_button.text)
	return "\n".join(parts)
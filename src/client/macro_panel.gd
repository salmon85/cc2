extends PanelContainer
class_name MacroPanel
## Empire-level controls: imperial tax, research allocation, and the construction queue.
##
## Every control writes through `SessionController`, which turns it into a real
## `SET_TAX` / `SET_RESEARCH` / `BUILD_STRUCTURE` order. Nothing here edits the galaxy
## directly, so what the sliders show is exactly what the Phase 4 resolver will execute.

## Emitted when the player stages a structure, with the building id.
signal build_requested(building_id: StringName)

var _controller: SessionController = null

var _tax_slider: HSlider = null
var _tax_value: Label = null
var _tax_income: Label = null

var _research_sliders: Array[HSlider] = []
var _research_values: Array[Label] = []

var _build_selector: OptionButton = null
var _build_info: Label = null
var _queue_label: RichTextLabel = null
var _colony_selector: OptionButton = null

const RESEARCH_NAMES: Array[String] = ["ENG", "PROP", "BIOL", "PSYC"]
const MAX_RESEARCH := 100

## Building ids in build-queue order, grouped the way a player thinks about them rather
## than alphabetically: extraction first, then industry, then defence, then support.
const BUILD_ORDER: Array[StringName] = [
	&"farm", &"mine", &"factory", &"garrison", &"shield_generator",
	&"missile_battery", &"shipyard", &"orbital_station", &"terraformer",
]

## Set while rebuilding the selector so its `item_selected` does not stage a phantom order.
var _rebuilding := false


func _ready() -> void:
	_build()


func _build() -> void:
	theme = CC2Theme.build()
	custom_minimum_size = Vector2(260, 0)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	add_child(col)

	_build_tax(col)
	col.add_child(_separator())
	_build_research(col)
	col.add_child(_separator())
	_build_construction(col)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(spacer)

	col.add_child(_heading("STAGED ORDERS"))
	_queue_label = RichTextLabel.new()
	_queue_label.bbcode_enabled = true
	_queue_label.fit_content = true
	_queue_label.scroll_active = false
	_queue_label.custom_minimum_size = Vector2(0, 80)
	col.add_child(_queue_label)


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", CC2Theme.CYAN)
	l.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	return l


func _separator() -> HSeparator:
	return HSeparator.new()


func _build_tax(col: Control) -> void:
	col.add_child(_heading("IMPERIAL TAX"))
	_tax_slider = HSlider.new()
	_tax_slider.min_value = 0.0
	_tax_slider.max_value = 1.0
	_tax_slider.step = 0.01
	_tax_slider.value = 0.35
	_tax_slider.custom_minimum_size = Vector2(0, 18)
	_tax_slider.focus_mode = Control.FOCUS_NONE
	_tax_slider.value_changed.connect(_on_tax_changed)
	col.add_child(_tax_slider)

	_tax_value = Label.new()
	_tax_value.add_theme_color_override("font_color", CC2Theme.PHOSPHOR)
	_tax_value.add_theme_font_size_override("font_size", CC2Theme.FONT_BODY)
	col.add_child(_tax_value)

	_tax_income = Label.new()
	_tax_income.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)
	_tax_income.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(_tax_income)


## Four independent 0-100 sliders, normalised into a budget when committed. They read as
## relative weights rather than percentages summing to 100, which matches how a player
## thinks about "half my research into engineering".
func _build_research(col: Control) -> void:
	col.add_child(_heading("RESEARCH ALLOCATION"))
	for i in RESEARCH_NAMES.size():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		col.add_child(row)

		var name_label := Label.new()
		name_label.text = RESEARCH_NAMES[i]
		name_label.custom_minimum_size = Vector2(38, 0)
		name_label.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)
		name_label.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
		row.add_child(name_label)

		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = float(MAX_RESEARCH)
		slider.step = 1.0
		slider.value = 25.0
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.custom_minimum_size = Vector2(0, 18)
		slider.focus_mode = Control.FOCUS_NONE
		slider.value_changed.connect(_on_research_changed)
		row.add_child(slider)
		_research_sliders.append(slider)

		var value_label := Label.new()
		value_label.custom_minimum_size = Vector2(52, 0)
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value_label.add_theme_color_override("font_color", CC2Theme.PHOSPHOR)
		value_label.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
		row.add_child(value_label)
		_research_values.append(value_label)


func _build_construction(col: Control) -> void:
	col.add_child(_heading("CONSTRUCTION"))

	_colony_selector = OptionButton.new()
	_colony_selector.tooltip_text = "Colony to build in"
	_colony_selector.focus_mode = Control.FOCUS_NONE
	_colony_selector.item_selected.connect(_on_colony_selected)
	col.add_child(_colony_selector)

	_build_selector = OptionButton.new()
	_build_selector.tooltip_text = "Structure to queue"
	_build_selector.focus_mode = Control.FOCUS_NONE
	_build_selector.item_selected.connect(_on_build_selected)
	col.add_child(_build_selector)

	_build_info = Label.new()
	_build_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_build_info.custom_minimum_size = Vector2(0, 34)
	_build_info.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)
	_build_info.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(_build_info)


# --- Binding ---------------------------------------------------------------

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
	var me := _controller.player()
	if me == null:
		return

	# Tax: write the slider from state, not the other way round, so a turn that changes
	# the rate cannot leave the slider showing a stale value.
	if not is_equal_approx(_tax_slider.value, me.tax_rate):
		_tax_slider.set_block_signals(true)
		_tax_slider.value = me.tax_rate
		_tax_slider.set_block_signals(false)
	_tax_value.text = Format.percent(me.tax_rate)
	_tax_income.text = "Net/turn %s   Production %s   Upkeep %s" % [
		Format.signed(me.last_net),
		Format.fixed(me.last_production, 0),
		Format.fixed(me.last_expenses, 0),
	]

	_refresh_research(me)
	_refresh_colonies()
	_refresh_buildings()
	_refresh_queue()


func _refresh_research(me: FactionState) -> void:
	var total := me.total_tech_points()
	for i in _research_sliders.size():
		var pct := me.research_allocation[i] * 100.0
		var slider := _research_sliders[i]
		if not is_equal_approx(slider.value, pct):
			slider.set_block_signals(true)
			slider.value = pct
			slider.set_block_signals(false)
		_research_values[i].text = "%d%% (%.0f)" % [int(round(pct)), me.tech_points[i]]


func _refresh_colonies() -> void:
	var colonies := _controller.player_colonies()
	var texts := PackedStringArray()
	for p in colonies:
		texts.append("P%02d %s" % [p.index, String(p.type_id).capitalize()])

	_rebuilding = true
	# Keep the player's colony choice across refreshes; rebuilding the list every turn
	# would otherwise reset the build target to the first colony.
	var want := _controller.selected_planet
	_colony_selector.clear()
	for t in texts:
		_colony_selector.add_item(t)
	var idx := 0
	for i in colonies.size():
		if colonies[i].index == want:
			idx = i
			break
	if _colony_selector.item_count > 0:
		_colony_selector.select(idx)
		# `select()` only moves the highlight; it never tells anyone. Deliberately *not*
		# pushing that choice into the controller here: this runs on every `state_changed`,
		# so any write would immediately re-enter `refresh` and stomp whatever the player
		# just selected on the map or in the inspector. The selection is established at the
		# points where the player actually chose something — `_on_colony_selected` and
		# `_adopt_selected_colony` before a build is staged.
	_colony_selector.disabled = _colony_selector.item_count == 0
	_rebuilding = false


func _refresh_buildings() -> void:
	var me := _controller.player()
	if me == null or _controller.defs == null:
		return
	_rebuilding = true
	var previous := _selected_build_id()
	_build_selector.clear()
	for id in BUILD_ORDER:
		if not me.unlocked_buildings.has(id):
			continue
		var def: Resource = _controller.defs.building(id) as Resource
		if def == null:
			continue
		_build_selector.add_item(String(def.display_name))
		_build_selector.set_item_metadata(_build_selector.item_count - 1, id)
	var idx := _index_of_build(previous)
	if idx < 0:
		idx = 0
	if _build_selector.item_count > 0:
		_build_selector.select(idx)
	_rebuilding = false
	_refresh_build_info()


func _refresh_build_info() -> void:
	if _build_info == null:
		return
	var id := _selected_build_id()
	if id == &"":
		_build_info.text = "No structures available. Research more technology."
		return
	var def: Resource = null
	if _controller != null and _controller.defs != null:
		def = _controller.defs.building(id) as Resource
	if def == null:
		_build_info.text = ""
		return
	var planet := _selected_colony()
	var held := planet.count(id) if planet != null else 0
	var cap := "unlimited" if def.max_per_colony <= 0 else str(def.max_per_colony)
	_build_info.text = "%s  |  %d turn(s)  |  cost M%d R%d E%d  |  upkeep %d  |  %s/%s" % [
		def.description, def.build_turns,
		int(def.cost_metals), int(def.cost_rare), int(def.cost_energy),
		int(def.upkeep), str(held), cap,
	]
	_build_info.add_theme_color_override(
		"font_color", CC2Theme.ALERT if (planet == null or not _controller.can_afford(def))
		else CC2Theme.WHITE_DIM
	)


func _refresh_queue() -> void:
	var orders := _controller.pending_orders()
	if orders.is_empty():
		_queue_label.text = "[color=#%s]No orders staged.[/color]" % CC2Theme.WHITE_DIM.to_html(false)
		return
	var lines := PackedStringArray()
	for o in orders:
		lines.append("[color=#%s]  %s[/color]" % [
			CC2Theme.PHOSPHOR.to_html(false), o.describe()
		])
	_queue_label.text = "\n".join(lines)


# --- Control handlers ------------------------------------------------------

func _on_tax_changed(value: float) -> void:
	if _controller == null:
		return
	_controller.set_tax_rate(value)
	_tax_value.text = Format.percent(value)


func _on_research_changed(_value: float) -> void:
	if _controller == null:
		return
	var weights := PackedFloat64Array()
	for s in _research_sliders:
		weights.append(s.value)
	_controller.set_research_allocation(weights)
	# Re-read so the labels show the normalised split that was actually submitted.
	var me := _controller.player()
	if me != null:
		_refresh_research(me)


func _on_colony_selected(index: int) -> void:
	if _rebuilding or _controller == null:
		return
	var colonies := _controller.player_colonies()
	if index < 0 or index >= colonies.size():
		return
	_controller.select_planet(colonies[index].index)


func _on_build_selected(_index: int) -> void:
	if _rebuilding or _controller == null:
		return
	_refresh_build_info()
	var id := _selected_build_id()
	if id == &"":
		return
	# Touching the structure dropdown must not be rejected just because the controller's
	# selection is something else — a system the player clicked, or an uncolonised body.
	# The colony named by the selector above is the intended target, so make it so before
	# the order is submitted.
	_adopt_selected_colony()
	# Selecting a structure is a *request*, not an order: the player still has to press
	# the build button, so browsing the menu cannot spend the treasury. A refusal here is
	# not an error — the controller has already reported why on `action_rejected`.
	_controller.queue_build_structure(id)
	build_requested.emit(id)


## Point the controller at the colony highlighted in the colony selector, unless the
## player has already selected exactly that body.
func _adopt_selected_colony() -> void:
	var sel := _colony_selector.selected
	if sel < 0:
		return
	var colonies := _controller.player_colonies()
	if sel >= colonies.size():
		return
	if colonies[sel].index != _controller.selected_planet:
		_controller.select_planet(colonies[sel].index)


func _selected_build_id() -> StringName:
	if _build_selector == null or _build_selector.selected < 0:
		return &""
	var meta: Variant = _build_selector.get_item_metadata(_build_selector.selected)
	return meta as StringName if meta != null else &""


func _selected_colony() -> PlanetState:
	if _controller == null or _controller.galaxy == null:
		return null
	return _controller.galaxy.planet(_controller.selected_planet)


# --- Accessors used by the root and the GUI test ---------------------------

func tax_slider() -> HSlider:
	return _tax_slider


func tax_value_label() -> Label:
	return _tax_value


func research_sliders() -> Array[HSlider]:
	return _research_sliders


func build_selector() -> OptionButton:
	return _build_selector


func colony_selector() -> OptionButton:
	return _colony_selector


func queue_label() -> RichTextLabel:
	return _queue_label


func select_build(building_id: StringName) -> bool:
	var idx := _index_of_build(building_id)
	if idx < 0:
		return false
	_build_selector.select(idx)
	_refresh_build_info()
	return true


## Position of a structure in the selector, or -1.
##
## `OptionButton` exposes `get_item_metadata` but has no `find_metadata`, so the lookup is
## a scan. The item count is nine, so this is cheaper than maintaining a side map that
## could drift out of step when the unlocked set changes between turns.
func _index_of_build(building_id: StringName) -> int:
	if building_id == &"" or _build_selector == null:
		return -1
	for i in _build_selector.item_count:
		var meta: Variant = _build_selector.get_item_metadata(i)
		if meta != null and StringName(str(meta)) == building_id:
			return i
	return -1

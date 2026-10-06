extends PanelContainer
class_name MacroPanel
## Empire-level controls: the colony and structure selectors, the construction progress bar,
## and the colony warnings readout.
##
## Two things are gone as of Phase 8. The imperial tax slider is gone because the income it
## controlled no longer exists. The four research allocation sliders are gone because research
## is passive: the empire's civilian population drives it and there is nothing to allocate.
## Both are retained here as accessors returning null so a caller that still asks gets a
## definite answer rather than a crash, and the GUI suite asserts on those nulls -- the
## absence is the thing under test, so it is asserted as an absence.

## Emitted when the player clicks the construction progress bar. The root opens the boost
## modal; the panel does not spend anything itself.
signal construction_boosted

## Emitted when the player presses the Build button, with the structure to construct.
signal build_requested(building_id: StringName)

## Emitted when the player clicks the *ship* progress bar. Separate from `construction_boosted`
## only so a caller can tell which bar was pressed; both open the same dialog, because from the
## player's side a hull and a structure are the same decision.
signal ship_construction_boosted

var _controller: SessionController = null

var _build_selector: OptionButton = null
var _build_info: Label = null
var _colony_selector: OptionButton = null

## The interactive construction progress bar. Clicking it raises `construction_boosted`,
## which opens the boost modal.
var _build_bar: ProgressBar = null
var _build_mode_selector: OptionButton = null

## The Build button. Choosing a structure is a *selection*; this is what starts it.
var _build_button: Button = null

## The shipyard's progress bar. A hull in the yard gets its own bar rather than sharing the
## structure one, because the two are queued independently -- a colony can have a City Complex
## going and a Corvette behind it in the same turn, and one bar showing two unrelated projects
## would be a bar that is wrong half the time.
var _ship_bar: ProgressBar = null

## Hull selector for the Space Port, populated the moment a port exists.
var _ship_selector: OptionButton = null
var _build_ship_button: Button = null

## Standing warnings for the selected colony, rendered as an amber block.
var _warnings: Label = null

## Building ids in build-queue order, grouped the way a player thinks about them: extraction
## first, then housing and storage, then power, then industry, then defence and lift.
##
## `colony_ship_building` is deliberately *absent*. It is the one structure a colony cannot
## build: a Colony Ship flies to the world and is consumed on landing, so the only way to get
## one is to send a ship. Listing it here would offer a button that cannot do what it says.
const BUILD_ORDER: Array[StringName] = [
	&"farm", &"mine", &"granary", &"city_complex",
	&"energy_storage", &"solar", &"coal", &"nuclear",
	&"space_port", &"barracks", &"planetary_defense",
]

## Structures the construction menu must never offer, whatever else is unlocked.
##
## Declared separately from `BUILD_ORDER` so the GUI suite can assert the exclusion directly
## rather than inferring it from an array that a later roster change would silently extend.
const UNBUILDABLE: Array[StringName] = [&"colony_ship_building"]

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

	_build_construction(col)


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", CC2Theme.CYAN)
	l.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	return l


func _subheading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", CC2Theme.CYAN_DIM)
	l.add_theme_font_size_override("font_size", CC2Theme.FONT_TINY)
	return l


func _build_construction(col: Control) -> void:
	col.add_child(_heading("CONSTRUCTION"))

	# The colony dropdown lists *planet names*, not "P03 Terrestrial". This is the Phase 8
	# change: the name is what the player recognises everywhere else -- on the map, in the
	# inspector, in the log -- so the one control that picks a target for their spending was
	# the only place it did not use it. `display_name` rather than `p.name` directly, so the
	# fog rule still applies and a dropdown can never become a name leak.
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

	# One project per turn, or as many ships per turn as the colony's metal output can carry.
	_build_mode_selector = OptionButton.new()
	_build_mode_selector.tooltip_text = "How this colony spends its construction allowance"
	_build_mode_selector.focus_mode = Control.FOCUS_NONE
	_build_mode_selector.add_item("ONE PROJECT", Enums.BuildMode.SINGLE)
	_build_mode_selector.add_item("SHIPS PER TURN", Enums.BuildMode.PER_TURN)
	_build_mode_selector.item_selected.connect(_on_build_mode_selected)
	col.add_child(_build_mode_selector)

	_build_info = Label.new()
	_build_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_build_info.custom_minimum_size = Vector2(0, 34)
	_build_info.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)
	_build_info.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(_build_info)

	# The Build button. Choosing a structure from the dropdown above only *selects* it; this
	# is what formally starts the project. Separating the two is what stops a player browsing
	# the menu from committing a spend on every dropdown they pass through.
	_build_button = Button.new()
	_build_button.text = "Build"
	_build_button.tooltip_text = "Start the selected structure on this colony"
	_build_button.focus_mode = Control.FOCUS_NONE
	_build_button.pressed.connect(_on_build_button_pressed)
	col.add_child(_build_button)

	# The bar for the hull in the yard. Created here, immediately below the structure bar and
	# the Build button, because it is the same kind of control about the same kind of decision:
	# "the thing I clicked Build on, how far along is it, and how much metal is in it".
	_ship_bar = ProgressBar.new()
	_ship_bar.tooltip_text = "Click to allocate metal to the hull in the yard"
	_ship_bar.custom_minimum_size = Vector2(0, 16)
	_ship_bar.show_percentage = false
	_ship_bar.max_value = 1.0
	_ship_bar.step = 0.0
	_ship_bar.focus_mode = Control.FOCUS_NONE
	_ship_bar.gui_input.connect(_on_ship_bar_input)
	col.add_child(_ship_bar)

	# The interactive progress bar. A `ProgressBar` is not clickable on its own, so the click
	# handler is attached through `gui_input` rather than a `pressed` signal that does not
	# exist for this class. A click *opens the boost modal*; it does not spend on the spot,
	# because a bare click spends the whole stockpile and that is never what it meant.
	_build_bar = ProgressBar.new()
	_build_bar.tooltip_text = "Click to transfer metal into this project"
	_build_bar.custom_minimum_size = Vector2(0, 16)
	_build_bar.show_percentage = false
	_build_bar.max_value = 1.0
	_build_bar.step = 0.0
	_build_bar.focus_mode = Control.FOCUS_NONE
	_build_bar.gui_input.connect(_on_build_bar_input)
	col.add_child(_build_bar)

	col.add_child(_subheading("SHIPS"))
	_ship_selector = OptionButton.new()
	_ship_selector.tooltip_text = "Hull to build at this colony's Space Port"
	_ship_selector.focus_mode = Control.FOCUS_NONE
	col.add_child(_ship_selector)

	_build_ship_button = Button.new()
	_build_ship_button.text = "Build Ship"
	_build_ship_button.tooltip_text = "Lay the selected hull down at this Space Port"
	_build_ship_button.focus_mode = Control.FOCUS_NONE
	_build_ship_button.pressed.connect(_on_build_ship_button_pressed)
	col.add_child(_build_ship_button)

	_warnings = Label.new()
	_warnings.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warnings.add_theme_color_override("font_color", CC2Theme.AMBER)
	_warnings.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(_warnings)

	# The slack goes to the construction section rather than to a staged-orders readout: a
	# panel whose height is driven by its own contents resizes the map beside it, which is
	# a bug this panel had once and now must not have again.
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.custom_minimum_size = Vector2(0, 12)
	col.add_child(spacer)
	_build_info.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_info.vertical_alignment = VERTICAL_ALIGNMENT_TOP


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
	if _controller.player() == null:
		return
	_refresh_colonies()
	_refresh_buildings()
	_refresh_build_info()
	_refresh_ships()
	_refresh_progress()
	_refresh_warnings()


func _refresh_colonies() -> void:
	var colonies := _controller.player_colonies()
	_rebuilding = true
	# Keep the player's colony choice across refreshes; rebuilding the list every turn
	# would otherwise reset the build target to the first colony.
	var want := _controller.selected_planet
	_colony_selector.clear()
	for p in colonies:
		# The planet's real name, gated through the controller's fog rule.
		_colony_selector.add_item(_controller.display_name(p.index))
		_colony_selector.set_item_metadata(_colony_selector.item_count - 1, p.index)
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
		# just selected on the map or in the inspector.
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
		# The unbuildable list is checked here as well as being absent from `BUILD_ORDER`, so
		# adding a structure to the wrong array cannot quietly offer it.
		if UNBUILDABLE.has(id) or not me.unlocked_buildings.has(id):
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


func _refresh_build_info() -> void:
	if _build_info == null:
		return
	var id := _selected_build_id()
	if id == &"":
		_build_info.text = "No structures available."
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
	_build_info.text = "%s\ncost M%d | %d turn(s) | upkeep %d | %s/%s" % [
		def.description, int(def.cost_metals), def.build_turns,
		int(def.upkeep), str(held), cap,
	]
	# Coloured by whether this colony can *start* it, never by whether it can pay for it.
	#
	# Construction draws metal out of storage a slice each turn and there is no upfront gate, so
	# a red cost line for "you cannot afford this right now" would be a lie: a colony with four
	# mines and an empty bank starts a City Complex today and pays for it over three turns. The
	# figure shown is the cost, and the way to hurry it along is the bar's dialog, not a
	# refusal at the queue.
	var blocked: bool = planet == null \
		or not def.can_add(planet.count(id)) \
		or not planet.building_queue.is_empty()
	_build_info.add_theme_color_override(
		"font_color", CC2Theme.ALERT if blocked else CC2Theme.WHITE_DIM
	)


## Populate the hull selector from the colony's Space Port.
##
## The list is whatever `TurnResolver.hulls_available_at` says, so a port appears in the
## roster the moment one is constructed rather than at the start of the following turn, and a
## lost port empties it again. Nothing is written to the faction's unlock set: a port is a
## local grant, and granting it empire-wide would let one berth hand out hulls everywhere.
func _refresh_ships() -> void:
	if _ship_selector == null:
		return
	var me := _controller.player()
	var planet := _selected_colony()
	_rebuilding = true
	var previous := _selected_hull_id()
	_ship_selector.clear()
	if me != null and planet != null and _controller.defs != null:
		for hull_id in TurnResolver.hulls_available_at(planet, me):
			var hull: Resource = _controller.defs.ship_hull(hull_id) as Resource
			if hull == null:
				continue
			_ship_selector.add_item(String(hull.display_name))
			_ship_selector.set_item_metadata(_ship_selector.item_count - 1, hull_id)
	var idx := _index_of_hull(previous)
	if idx < 0:
		idx = 0
	if _ship_selector.item_count > 0:
		_ship_selector.select(idx)
	_ship_selector.disabled = _ship_selector.item_count == 0
	_rebuilding = false
	if _build_ship_button != null:
		_build_ship_button.disabled = _ship_selector.item_count == 0
	if _build_button != null:
		_build_button.disabled = _build_selector == null or _build_selector.item_count == 0


## Draw both progress bars: completion fraction, and whether there is anything to allocate.
##
## Both are driven by metal, and both appear the moment the order is queued rather than when
## it resolves at the end of the turn. The bar appearing immediately is what tells a player
## their Build press registered; a bar that appeared only at the end of the next turn reads as
## a button that did nothing, and a player who thinks the button is broken presses it again.
func _refresh_progress() -> void:
	if _build_bar == null:
		return
	var planet := _selected_colony()
	var buildings: Dictionary = {}
	var hulls: Dictionary = {}
	if _controller != null and _controller.defs != null:
		buildings = _controller.defs.get("buildings") as Dictionary
		hulls = _controller.defs.get("ship_hulls") as Dictionary
	var kind := ColonySim.project_kind(planet)
	var fraction := ColonySim.project_progress(planet, buildings, hulls)
	_build_bar.value = fraction
	_build_bar.visible = planet != null and kind == ColonySim.ProjectKind.STRUCTURE
	if _build_bar.visible:
		_build_bar.tooltip_text = "%d%% complete - click to allocate metal (M%d banked)" % [
			int(round(fraction * 100.0)), int(planet.reserve_metals)]
	else:
		_build_bar.tooltip_text = ""

	# The shipyard's own bar, reading the hull at the head of the queue.
	var ship_fraction := 0.0
	if planet != null and kind == ColonySim.ProjectKind.SHIP:
		ship_fraction = fraction
	if _ship_bar != null:
		_ship_bar.value = ship_fraction
		_ship_bar.visible = planet != null and kind == ColonySim.ProjectKind.SHIP
		_ship_bar.tooltip_text = (
			"%d%% complete - click to allocate metal (M%d banked)" % [
				int(round(ship_fraction * 100.0)), int(planet.reserve_metals)]
		) if _ship_bar.visible else ""

	var mode: int = planet.build_mode if planet != null else int(Enums.BuildMode.SINGLE)
	if _build_mode_selector != null:
		var want := 1 if mode == Enums.BuildMode.PER_TURN else 0
		if _build_mode_selector.selected != want:
			_rebuilding = true
			_build_mode_selector.select(want)
			_rebuilding = false


## Render the selected colony's standing warnings.
##
## Food overflow is the one warning the design document asks for, and it arrives a turn late
## on purpose. Power overflow deliberately does *not* warn: surplus power is lost silently,
## so a world with too many reactors is not nagged, only quietly wasted.
func _refresh_warnings() -> void:
	if _warnings == null:
		return
	var planet := _selected_colony()
	if planet == null or planet.warnings.is_empty():
		_warnings.text = ""
		return
	var lines := PackedStringArray()
	for key: Variant in planet.warnings:
		lines.append(_warning_text(StringName(str(key))))
	lines.sort()
	_warnings.text = "\n".join(lines)


static func _warning_text(key: StringName) -> String:
	match key:
		&"food_overflow": return "FOOD OVERFLOW: stores full, surplus lost"
		&"starving": return "STARVING: reserves empty"
		&"power_short": return "POWER SHORT: new power structures blocked"
	return String(key).capitalize()


# --- Control handlers ------------------------------------------------------

func _on_build_bar_input(event: InputEvent) -> void:
	if _controller == null:
		return
	var pressed := event is InputEventMouseButton \
		and (event as InputEventMouseButton).pressed \
		and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
	if not pressed:
		return
	var planet := _selected_colony()
	if planet == null or planet.building_queue.is_empty():
		return
	# A click *opens the modal*. It does not spend: a bare click used to hand the whole
	# stockpile to the project, and a colony with five hundred metal banked against a
	# twenty-metal Solar Array quietly lost four hundred and eighty of it. The amount is now
	# a decision the player makes, and the modal's slider is capped at what the project owes.
	construction_boosted.emit()


## A click on the shipyard bar. Opens the same dialog: the project is a hull rather than a
## structure, and the dialog reads whichever is in the slot.
func _on_ship_bar_input(event: InputEvent) -> void:
	if _controller == null:
		return
	var pressed := event is InputEventMouseButton \
		and (event as InputEventMouseButton).pressed \
		and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
	if not pressed:
		return
	var planet := _selected_colony()
	if planet == null or ColonySim.project_kind(planet) != ColonySim.ProjectKind.SHIP:
		return
	ship_construction_boosted.emit()


## Select the colony the dropdown names.
##
## Read from the item's *metadata*, not from its position. The list is rebuilt on every
## refresh and the two agree today, but the dropdown now carries names that the fog rule can
## replace with a placeholder -- so two entries can read identically -- and a control that
## identified its target by list position would quietly select the wrong world the moment
## that happened.
func _on_colony_selected(index: int) -> void:
	if _rebuilding or _controller == null:
		return
	var planet_index := _colony_at(index)
	if planet_index < 0:
		return
	_controller.select_planet(planet_index)


func _colony_at(index: int) -> int:
	if _colony_selector == null or index < 0 or index >= _colony_selector.item_count:
		return -1
	var meta: Variant = _colony_selector.get_item_metadata(index)
	return int(meta) if meta != null else -1


## Choosing a structure only *selects* it.
##
## It does not spend anything. The Build button below is what starts the project, so a
## player scrolling through the dropdown cannot commit a purchase on every row they pass.
func _on_build_selected(_index: int) -> void:
	if _rebuilding:
		return
	_refresh_build_info()


## The Build button: formally start the selected structure on the selected colony.
func _on_build_button_pressed() -> void:
	if _controller == null:
		return
	# The colony named by the selector is the intended target, so adopt it before submitting.
	# Without this, pressing Build after clicking a colony row submits against whatever the
	# map last selected.
	_adopt_selected_colony()
	_refresh_build_info()
	var id := _selected_build_id()
	if id == &"":
		return
	if _controller.queue_build_structure(id):
		build_requested.emit(id)


## Build the selected hull at this colony's Space Port.
func _on_build_ship_button_pressed() -> void:
	if _controller == null:
		return
	_adopt_selected_colony()
	var hull_id := _selected_hull_id()
	if hull_id == &"":
		return
	_controller.queue_build_ship(hull_id)


func _on_build_mode_selected(index: int) -> void:
	if _rebuilding or _controller == null:
		return
	var planet := _selected_colony()
	if planet == null:
		return
	var mode := Enums.BuildMode.PER_TURN if index == 1 else Enums.BuildMode.SINGLE
	_controller.set_build_mode(planet.index, mode)


## Point the controller at the colony highlighted in the colony selector, unless the
## player has already selected exactly that body.
func _adopt_selected_colony() -> void:
	var planet_index := _colony_at(_colony_selector.selected)
	if planet_index < 0:
		return
	if planet_index != _controller.selected_planet:
		_controller.select_planet(planet_index)


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

## The imperial tax slider. Removed in Phase 8; retained so a caller gets a definite null.
func tax_slider() -> HSlider:
	return null


## The imperial tax readout. Removed in Phase 8, for the same reason.
func tax_value_label() -> Label:
	return null


## The research allocation sliders. Removed in Phase 8; returns an empty array.
func research_sliders() -> Array[HSlider]:
	return [] as Array[HSlider]


func build_selector() -> OptionButton:
	return _build_selector


func colony_selector() -> OptionButton:
	return _colony_selector


## The structure progress bar. Clicking it opens the metal-allocation dialog.
func build_bar() -> ProgressBar:
	return _build_bar


## The shipyard progress bar. Clicking it opens the same dialog for the hull in the yard.
func ship_bar() -> ProgressBar:
	return _ship_bar


## The single-project / per-turn selector.
func build_mode_selector() -> OptionButton:
	return _build_mode_selector


## The Build button, which formally starts the selected structure.
func build_button() -> Button:
	return _build_button


## The hull selector, populated from the colony's Space Port.
func ship_selector() -> OptionButton:
	return _ship_selector


## The Build Ship button.
func build_ship_button() -> Button:
	return _build_ship_button


func _selected_hull_id() -> StringName:
	if _ship_selector == null or _ship_selector.selected < 0:
		return &""
	var meta: Variant = _ship_selector.get_item_metadata(_ship_selector.selected)
	return meta as StringName if meta != null else &""


## Position of a hull in the ship selector, or -1.
func _index_of_hull(hull_id: StringName) -> int:
	if hull_id == &"" or _ship_selector == null:
		return -1
	for i in _ship_selector.item_count:
		var meta: Variant = _ship_selector.get_item_metadata(i)
		if meta != null and StringName(str(meta)) == hull_id:
			return i
	return -1


## The colony warning readout.
func warnings_label() -> Label:
	return _warnings


## The staged-orders readout, now always null.
##
## Kept as an accessor returning null so a caller that still asks gets a definite answer
## rather than a crash -- the panel no longer has one, and the tests assert exactly that.
func queue_label() -> RichTextLabel:
	return null


func build_info() -> Label:
	return _build_info


func select_build(building_id: StringName) -> bool:
	var idx := _index_of_build(building_id)
	if idx < 0:
		return false
	_build_selector.select(idx)
	_refresh_build_info()
	return true


## Every string this panel is currently showing, in one place.
##
## Used by the GUI suite to assert that no removed heading survives anywhere in the tree --
## searching the source for a string would pass while the label was still on screen.
func visible_text() -> String:
	var parts := PackedStringArray()
	for node in [colony_selector(), build_selector(), build_mode_selector(), ship_selector()]:
		var button: OptionButton = node as OptionButton
		if button == null:
			continue
		for i in button.item_count:
			parts.append(button.get_item_text(i))
	for bar: ProgressBar in [build_bar(), ship_bar()]:
		if bar != null and bar.visible:
			parts.append(bar.tooltip_text)
	if build_info() != null:
		parts.append(build_info().text)
	if warnings_label() != null:
		parts.append(warnings_label().text)
	return "\n".join(parts)


## Position of a structure in the selector, or -1.
##
## `OptionButton` exposes `get_item_metadata` but has no `find_metadata`, so the lookup is
## a scan. The item count is a dozen, so this is cheaper than maintaining a side map that
## could drift out of step when the unlocked set changes between turns.
func _index_of_build(building_id: StringName) -> int:
	if building_id == &"" or _build_selector == null:
		return -1
	for i in _build_selector.item_count:
		var meta: Variant = _build_selector.get_item_metadata(i)
		if meta != null and StringName(str(meta)) == building_id:
			return i
	return -1
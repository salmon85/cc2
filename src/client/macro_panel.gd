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

## Scraps whatever the Destroy menu names: a structure or a hull id.
signal scrap_requested(entry: StringName)

## Emitted when the player asks to post or pull one more worker on a structure.
signal staffing_requested(building_id: StringName, adding: bool)

## Emitted when the player picks a colony in the dropdown and the map should centre on it.
signal camera_snap_requested(planet_index: int)

## Which structures and hulls this panel can offer to scrap right now.
const SCRAP_KIND_SHIP := "ship"


## The non-blocking notice when a queued building would land unworked.
var _staffing_warning: Label = null

## The roster of buildings per farm/mine, each row carrying its own `+` / `-`.
var _staffing_rows: VBoxContainer = null

## The Destroy menu. Hidden until pressed, like the other modals.
var _scrap_list: VBoxContainer = null
var _scrap_button: Button = null

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

	# Destroy sits directly beneath Build, as the mirror of it: one starts a project, the
	# other takes one back. They are the two halves of the same decision about what this
	# colony has standing, and burying scrapping somewhere else is how a colony ends up with
	# nine farms and no way to get rid of any of them.
	_scrap_button = Button.new()
	_scrap_button.name = "Destroy"
	_scrap_button.text = "Destroy"
	_scrap_button.tooltip_text = "Scrap a structure or a ship for half its metal cost"
	_scrap_button.focus_mode = Control.FOCUS_NONE
	_scrap_button.pressed.connect(_on_destroy_pressed)
	col.add_child(_scrap_button)

	_scrap_list = VBoxContainer.new()
	_scrap_list.name = "ScrapList"
	_scrap_list.visible = false
	_scrap_list.add_theme_constant_override("separation", 2)
	col.add_child(_scrap_list)

	_staffing_warning = Label.new()
	_staffing_warning.name = "StaffingWarning"
	_staffing_warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_staffing_warning.visible = false
	_staffing_warning.add_theme_color_override("font_color", CC2Theme.AMBER)
	_staffing_warning.add_theme_font_size_override("font_size", CC2Theme.FONT_TINY)
	col.add_child(_staffing_warning)

	col.add_child(_subheading("WORKERS"))
	_staffing_rows = VBoxContainer.new()
	_staffing_rows.name = "StaffingRows"
	_staffing_rows.add_theme_constant_override("separation", 2)
	col.add_child(_staffing_rows)

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
	_refresh_ships()
	_refresh_build_info()
	_refresh_ships()
	_refresh_progress()
	_refresh_staffing()
	_refresh_scrap_list()
	_refresh_staffing_warning()
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


func _refresh_build_info() -> void:
	if _build_info == null:
		return
	var id := _selected_build_id()
	if id == &"":
		_build_info.text = "No structures available."
		return
	if _selected_build_kind() == KIND_SHIP:
		_refresh_ship_info(id)
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


## The hull's own readout, in the same shape as a structure's.
##
## Not a special case in the panel's *behaviour* -- only in the fields it quotes, because the
## two definitions do not share a vocabulary: a hull has build turns and an upkeep, a structure
## also has a per-colony cap, and quoting the wrong one would print a hull capped at zero.
func _refresh_ship_info(hull_id: StringName) -> void:
	var hull: Resource = null
	if _controller != null and _controller.defs != null:
		hull = _controller.defs.ship_hull(hull_id) as Resource
	if hull == null:
		_build_info.text = ""
		return
	var planet := _selected_colony()
	var held := 0
	if planet != null:
		for fleet in _controller.fleets_in_orbit_at(planet.index):
			held += int(fleet.ships.get(hull_id, 0))
	_build_info.text = "A %s.\ncost M%d | %d turn(s) | upkeep %d | %d in orbit" % [
		String(hull.display_name).to_lower(), int(hull.cost_metals), int(hull.build_turns),
		int(hull.upkeep), held,
	]
	_build_info.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)


## Populate the *one* construction dropdown with structures and hulls.
##
## Hulls go in the same list as buildings rather than in a selector of their own. They used to
## have their own dropdown and their own Build Ship button, which meant building a structure
## and building a ship were two different gestures for two different things, each with its own
## progress bar, in a panel that had to carry both. Now there is one queue, one Build button and
## one bar directly beneath it -- and a hull simply cannot be listed on a world with no Space
## Port, because `hulls_available_at` is empty there.
func _refresh_ships() -> void:
	var me := _controller.player()
	var planet := _selected_colony()
	_rebuilding = true
	var previous := _selected_build_entry()
	_build_selector.clear()
	if me != null and planet != null and _controller.defs != null:
		for id in BUILD_ORDER:
			# The unbuildable list is checked here as well as being absent from `BUILD_ORDER`,
			# so adding a structure to the wrong array cannot quietly offer it.
			if UNBUILDABLE.has(id) or not me.unlocked_buildings.has(id):
				continue
			var def: Resource = _controller.defs.building(id) as Resource
			if def == null:
				continue
			_add_entry(id, String(def.display_name), "structure")
		for hull_id in TurnResolver.hulls_available_at(planet, me):
			var hull: Resource = _controller.defs.ship_hull(hull_id) as Resource
			if hull == null:
				continue
			_add_entry(hull_id, String(hull.display_name), "ship")
	var idx := _index_of_build(previous)
	if idx < 0:
		idx = 0
	if _build_selector.item_count > 0:
		_build_selector.select(idx)
	_build_selector.disabled = _build_selector.item_count == 0
	_rebuilding = false
	if _build_button != null:
		_build_button.disabled = _build_selector.item_count == 0


## Add one row to the construction dropdown, tagged with what kind of thing it is.
##
## The kind travels as item metadata rather than being inferred from the id later: a hull id
## and a building id are both `StringName`s in one namespace, and `is_ship_scrap` has to tell
## them apart. Storing the answer when the row is built is the only moment the distinction is
## known without a lookup.
func _add_entry(id: StringName, label: String, kind: String) -> void:
	_build_selector.add_item(label)
	_build_selector.set_item_metadata(_build_selector.item_count - 1, {
		"id": String(id), "kind": kind,
	})


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


## One row per staffable structure: `Farms  3 (2)   - 2 +`.
##
## Rebuilt from the colony on every refresh rather than mutated in place, because a row's two
## numbers -- how many stand and how many are worked -- are both derived, and a button that
## decrements one of them in a widget while the other is computed from the model is a widget
## that drifts.
func _refresh_staffing() -> void:
	if _staffing_rows == null:
		return
	for child in _staffing_rows.get_children():
		_staffing_rows.remove_child(child)
		child.queue_free()
	var planet := _selected_colony()
	if planet == null:
		return
	for id in ColonySim.STAFFABLE:
		var standing := int(planet.structures.get(id, 0))
		if standing <= 0:
			continue
		_staffing_rows.add_child(_staffing_row(planet, id, standing))


func _staffing_row(planet: PlanetState, id: StringName, standing: int) -> Control:
	var row := HBoxContainer.new()
	row.name = "Staff_%s" % String(id)
	row.add_theme_constant_override("separation", 4)

	var def: Resource = null
	if _controller != null and _controller.defs != null:
		def = _controller.defs.building(id) as Resource
	var caption := "%s %d (%d)" % [
		"+" if def == null else String(def.display_name), standing,
		ColonySim.workers_on(planet, id)]
	# A farm nobody is working is a farm producing nothing, and the bracket is what says so.
	var idle := standing - ColonySim.workers_on(planet, id)
	var label := Label.new()
	label.name = "Count_%s" % String(id)
	label.text = caption
	label.custom_minimum_size = Vector2(96, 0)
	label.add_theme_color_override(
		"font_color", CC2Theme.WHITE_DIM if idle > 0 else CC2Theme.AMBER)
	label.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	row.add_child(label)

	var minus := Button.new()
	minus.name = "Less_%s" % String(id)
	minus.text = "-"
	minus.tooltip_text = "Stop working one of these"
	minus.focus_mode = Control.FOCUS_NONE
	minus.custom_minimum_size = Vector2(24, 0)
	minus.disabled = ColonySim.workers_on(planet, id) <= 0
	minus.pressed.connect(func() -> void: _on_staffing(id, false))
	row.add_child(minus)

	var plus := Button.new()
	plus.name = "More_%s" % String(id)
	plus.text = "+"
	plus.tooltip_text = "Post one colonist to one of these"
	plus.focus_mode = Control.FOCUS_NONE
	plus.custom_minimum_size = Vector2(24, 0)
	plus.disabled = ColonySim.idle_workers(planet) <= 0
	plus.pressed.connect(func() -> void: _on_staffing(id, true))
	row.add_child(plus)
	return row


## The scrap menu's rows, built when it is open.
##
## Only populated while visible: it is a list of everything on the colony, and rebuilding it
## on every state change to keep a hidden list fresh is work for a menu nobody is looking at.
func _refresh_scrap_list() -> void:
	if _scrap_list == null:
		return
	for child in _scrap_list.get_children():
		_scrap_list.remove_child(child)
		child.queue_free()
	if not _scrap_list.visible or _controller == null:
		return
	var targets := _controller.scrap_targets()
	if targets.is_empty():
		var none := Label.new()
		none.text = "Nothing to scrap here."
		none.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)
		none.add_theme_font_size_override("font_size", CC2Theme.FONT_TINY)
		_scrap_list.add_child(none)
		return
	for label: String in targets:
		var entry := StringName(str((targets as Dictionary)[label]))
		var row := HBoxContainer.new()
		row.name = "Scrap_%s" % String(entry)
		row.add_theme_constant_override("separation", 4)
		var text := Label.new()
		text.text = String(label)
		text.custom_minimum_size = Vector2(150, 0)
		text.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)
		text.add_theme_font_size_override("font_size", CC2Theme.FONT_TINY)
		row.add_child(text)
		var button := Button.new()
		button.name = "Do_%s" % String(entry)
		button.text = "SCRAP"
		button.tooltip_text = "Half the metal cost back, straight into storage"
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(func() -> void: _on_scrap(entry))
		row.add_child(button)
		_scrap_list.add_child(row)


## The build-order notice, when the selected entry would land with nobody to work it.
##
## Non-blocking by construction: it is a label, not a refusal. The colony may well have grown
## a colonist before the project finishes, and refusing the order over a shortage three turns
## out would be the sim making a decision for the player.
func _refresh_staffing_warning() -> void:
	if _staffing_warning == null:
		return
	var text := ""
	if _controller != null and _selected_build_kind() == KIND_STRUCTURE:
		text = _controller.staffing_warning(_selected_build_id())
	_staffing_warning.text = text
	_staffing_warning.visible = not text.is_empty()


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


## The planet index behind a colony-dropdown row.
##
## Read from the item's *metadata*, not from its position. The list is rebuilt on every
## refresh and the two agree today, but the dropdown carries names that the fog rule can
## replace with a placeholder -- so two entries can read identically -- and a control that
## identified its target by list position would quietly select the wrong world the moment that
## happened.
func _colony_at(index: int) -> int:
	if _colony_selector == null or index < 0 or index >= _colony_selector.item_count:
		return -1
	var meta: Variant = _colony_selector.get_item_metadata(index)
	return int(meta) if meta != null else -1


## Choosing a structure only *selects* it.
##
## It does not spend anything. The Build button below is what starts the project, so a
## player scrolling through the dropdown cannot commit a purchase on every row they pass.
##
## Selecting a *colony* does move the camera, because the map and the dropdown then agree
## about what is being worked on. Without it the player picks a world by name from a list and
## the map stays wherever it was -- choosing blind, and with no way to tell that the choice
## did anything at all.
func _on_colony_selected(index: int) -> void:
	if _rebuilding or _controller == null:
		return
	var planet_index := _colony_at(index)
	if planet_index < 0:
		return
	_controller.select_planet(planet_index)
	snap_camera_to(planet_index)


func _on_build_selected(_index: int) -> void:
	if _rebuilding:
		return
	_refresh_build_info()
	_refresh_staffing_warning()


## Ask the client root to centre the map on a world.
##
## Routed through the root rather than reaching for the map directly: the panel is a sibling
## of the map under the same parent, and a sibling reference held across a re-parent is a null
## dereference waiting for a layout change.
func snap_camera_to(planet_index: int) -> void:
	camera_snap_requested.emit(planet_index)


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
	if _selected_build_kind() == KIND_SHIP:
		_controller.queue_build_ship(id)
		return
	if _controller.queue_build_structure(id):
		build_requested.emit(id)


## Post or pull one worker. Routed through the client root, like every other action, so the
## log and the panels hear about it the same way.
func _on_staffing(building_id: StringName, adding: bool) -> void:
	staffing_requested.emit(building_id, adding)


func _on_scrap(entry: StringName) -> void:
	scrap_requested.emit(entry)


func _on_destroy_pressed() -> void:
	if _scrap_list == null:
		return
	_scrap_list.visible = not _scrap_list.visible
	_refresh_scrap_list()


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


## Which kind of thing the construction dropdown's selected row is.
const KIND_SHIP := "ship"
const KIND_STRUCTURE := "structure"


## The id of the selected construction entry, structure or hull.
func _selected_build_id() -> StringName:
	var meta: Variant = _selected_build_entry_meta()
	if not (meta is Dictionary):
		return &""
	return StringName(str((meta as Dictionary).get("id", "")))


## Whether the selected construction entry is a hull or a structure.
func _selected_build_kind() -> String:
	var meta: Variant = _selected_build_entry_meta()
	if not (meta is Dictionary):
		return KIND_STRUCTURE
	return String((meta as Dictionary).get("kind", KIND_STRUCTURE))


func _selected_build_entry_meta() -> Variant:
	if _build_selector == null or _build_selector.selected < 0:
		return null
	return _build_selector.get_item_metadata(_build_selector.selected)


func _selected_build_entry() -> StringName:
	return _selected_build_id()


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


## The Build button, which starts whichever entry the dropdown names.
func build_button() -> Button:
	return _build_button


## The Destroy button, and the menu it opens.
func scrap_button() -> Button:
	return _scrap_button


func scrap_list() -> VBoxContainer:
	return _scrap_list


## The farm/mine worker rows, each carrying its own `+` and `-`.
func staffing_rows() -> VBoxContainer:
	return _staffing_rows


## The build-order notice about landing a building with nobody to work it.
func staffing_warning() -> Label:
	return _staffing_warning


## The worked-count row for a structure, or null when none is standing.
func staffing_count_label(building_id: StringName) -> Label:
	if _staffing_rows == null:
		return null
	return _staffing_rows.get_node_or_null(
		NodePath("Staff_%s/Count_%s" % [String(building_id), String(building_id)])) as Label


## The `+` button for a structure's workers, or null.
func staffing_more_button(building_id: StringName) -> Button:
	if _staffing_rows == null:
		return null
	return _staffing_rows.get_node_or_null(
		NodePath("Staff_%s/More_%s" % [String(building_id), String(building_id)])) as Button


## The `-` button for a structure's workers, or null.
func staffing_less_button(building_id: StringName) -> Button:
	if _staffing_rows == null:
		return null
	return _staffing_rows.get_node_or_null(
		NodePath("Staff_%s/Less_%s" % [String(building_id), String(building_id)])) as Button


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
	for node in [colony_selector(), build_selector(), build_mode_selector()]:
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
		if meta is Dictionary and StringName(str((meta as Dictionary).get("id", ""))) == building_id:
			return i
	return -1
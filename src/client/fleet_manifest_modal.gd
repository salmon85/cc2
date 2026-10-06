extends PanelContainer
class_name FleetManifestModal
## The last step of Travel: which ships leave the source world, and which stay.
##
## Reached only after the flow has both a source and a destination, so the two decisions that
## used to be made by accident -- which world, and which of the ships -- are made on purpose
## before anything is queued. OK is the only commit; CANCEL aborts and nothing is staged.
##
## Combat hulls and logistics hulls are listed as separate rosters because "send the warships,
## or send the transports" is two decisions, not one list of twenty rows to scan. A Colony Ship
## is not a warship and answering a fleet of frigates is not what it is for; putting them in
## the same list and relying on the player to know which is which is how a kit gets left in
## orbit.
##
## Cargo is shown on the logistics rows because "does this ship already have anything in it" is
## a per-ship question: four Troop Transports may hold four troops between them, and a single
## row reading "4/16" would tell the player nothing about which one is full.

## Emitted when the player commits. Carries the source world, the destination and the
## `{hull_id: count}` manifest.
signal travel_confirmed(source: int, destination: int, ships: Dictionary)

## Emitted when the player dismisses the modal.
signal travel_cancelled

var _controller: SessionController = null

## Source and destination worlds, -1 when not yet chosen.
var _source: int = -1
var _destination: int = -1

var _route_label: Label = null
var _combat_rows: VBoxContainer = null
var _support_rows: VBoxContainer = null
var _summary: Label = null
var _ok_button: Button = null
var _cancel_button: Button = null
var _all_button: Button = null
var _none_button: Button = null

## The `{hull_id: count}` the player has built up with the `+` / `-` buttons.
var _manifest: Dictionary = {}

## Set while rebuilding the dropdowns so their `item_selected` is not read as a player choice.
var _rebuilding := false


func _ready() -> void:
	_build()
	visible = false


func _build() -> void:
	theme = CC2Theme.build()
	custom_minimum_size = Vector2(460, 0)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	add_child(col)

	var heading := Label.new()
	heading.text = "FLEET MANIFEST"
	heading.add_theme_color_override("font_color", CC2Theme.CYAN)
	heading.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(heading)

	_route_label = Label.new()
	_route_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_route_label.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)
	_route_label.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(_route_label)

	var quick := HBoxContainer.new()
	quick.add_theme_constant_override("separation", 6)
	col.add_child(quick)
	_all_button = Button.new()
	_all_button.name = "AllShips"
	_all_button.text = "All"
	_all_button.tooltip_text = "Send every ship in orbit"
	_all_button.focus_mode = Control.FOCUS_NONE
	_all_button.pressed.connect(func() -> void: set_all(true))
	quick.add_child(_all_button)
	_none_button = Button.new()
	_none_button.name = "NoShips"
	_none_button.text = "None"
	_none_button.tooltip_text="Clear the manifest"
	_none_button.focus_mode = Control.FOCUS_NONE
	_none_button.pressed.connect(func() -> void: set_all(false))
	quick.add_child(_none_button)

	col.add_child(_subheading("COMBAT HULLS"))
	_combat_rows = VBoxContainer.new()
	_combat_rows.add_theme_constant_override("separation", 2)
	col.add_child(_combat_rows)

	col.add_child(_subheading("LOGISTIC HULLS"))
	_support_rows = VBoxContainer.new()
	_support_rows.add_theme_constant_override("separation", 2)
	col.add_child(_support_rows)

	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)
	_summary.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(_summary)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	col.add_child(buttons)
	_ok_button = Button.new()
	_ok_button.name = "OK"
	_ok_button.text = "OK"
	_ok_button.tooltip_text = "Send the selected ships"
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


func _subheading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", CC2Theme.CYAN_DIM)
	l.add_theme_font_size_override("font_size", CC2Theme.FONT_TINY)
	return l


func bind(controller: SessionController) -> void:
	_controller = controller


# --- Lifecycle -------------------------------------------------------------

func close() -> void:
	if not visible:
		return
	visible = false
	_source = -1
	_destination = -1
	travel_cancelled.emit()


## Open the manifest for a source/destination pair the flow has already resolved.
##
## Refuses rather than opening an empty window: a modal listing no ships is not a decision,
## and a modal whose destination equals its source is a promise the resolver cannot keep.
func open(source: int, destination: int) -> bool:
	if _controller == null or _controller.galaxy == null:
		return false
	if _controller.galaxy.planet(source) == null or _controller.galaxy.planet(destination) == null:
		return false
	if source == destination:
		return false
	if _controller.hulls_in_orbit_at(source).is_empty():
		return false
	_source = source
	_destination = destination
	_manifest.clear()
	set_all(true)
	refresh()
	visible = true
	return true


func source_planet() -> int:
	return _source


func destination_planet() -> int:
	return _destination


## Rebuild the contents from the source world. Public so the GUI suite can re-read the modal
## after the board changes without going through the map.
func refresh() -> void:
	if _controller == null or _controller.galaxy == null:
		return
	if _source < 0:
		return
	var hulls := _controller.hulls_in_orbit_at(_source)
	_route_label.text = "%s  ->  %s" % [
		_controller.display_name(_source),
		_controller.display_name(_destination) if _destination >= 0 else "nowhere yet"]
	_rebuild_rows(hulls)


# --- Contents --------------------------------------------------------------

func _rebuild_rows(hulls: Dictionary) -> void:
	for child in _combat_rows.get_children():
		_combat_rows.remove_child(child)
		child.queue_free()
	for child in _support_rows.get_children():
		_support_rows.remove_child(child)
		child.queue_free()

	var ids: Array[StringName] = []
	for key: StringName in hulls:
		ids.append(key)
	ids.sort()
	for hull_id in ids:
		var def := _hull(hull_id)
		if def == null:
			continue
		var parent: VBoxContainer = _combat_rows if Enums.role_is_combat(
			int(def.get("role"))) else _support_rows
		parent.add_child(_ship_row(hulls, hull_id, def))
	_refresh_summary()


## One row: name, `-`, chosen count, `+`, and the cargo readout for a logistics hull.
func _ship_row(hulls: Dictionary, hull_id: StringName, def: Resource) -> Control:
	var row := HBoxContainer.new()
	row.name = "Row_%s" % String(hull_id)
	row.add_theme_constant_override("separation", 4)

	var name_label := Label.new()
	name_label.text = String(def.display_name)
	name_label.custom_minimum_size = Vector2(130, 0)
	name_label.add_theme_color_override("font_color", CC2Theme.PHOSPHOR)
	name_label.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	row.add_child(name_label)

	var minus := Button.new()
	minus.name = "Less_%s" % String(hull_id)
	minus.text = "-"
	minus.tooltip_text = "Send one fewer"
	minus.focus_mode = Control.FOCUS_NONE
	minus.custom_minimum_size = Vector2(26, 0)
	minus.pressed.connect(func() -> void: adjust(hull_id, -1, hulls))
	row.add_child(minus)

	var count_label := Label.new()
	count_label.name = "Count_%s" % String(hull_id)
	count_label.custom_minimum_size = Vector2(38, 0)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_label.add_theme_color_override("font_color", CC2Theme.PHOSPHOR_DIM)
	count_label.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	row.add_child(count_label)

	var plus := Button.new()
	plus.name = "More_%s" % String(hull_id)
	plus.text = "+"
	plus.tooltip_text = "Send one more"
	plus.focus_mode = Control.FOCUS_NONE
	plus.custom_minimum_size = Vector2(26, 0)
	plus.pressed.connect(func() -> void: adjust(hull_id, 1, hulls))
	row.add_child(plus)

	_update_count_label(row, hull_id, hulls)

	# The cargo readout: a Cargo Transport shows its metal, food and power holds, a Troop
	# Transport its troop bays and a Colony Ship its passenger berths. Read off the whole
	# orbital manifest because a source world may hold several of the same hull across more
	# than one fleet.
	var cargo_text := _cargo_text(def)
	if not cargo_text.is_empty():
		var cargo_label := Label.new()
		cargo_label.name = "Cargo_%s" % String(hull_id)
		cargo_label.text = cargo_text
		cargo_label.add_theme_color_override("font_color", CC2Theme.AMBER)
		cargo_label.add_theme_font_size_override("font_size", CC2Theme.FONT_TINY)
		row.add_child(cargo_label)
	return row


func _update_count_label(row: Control, hull_id: StringName, hulls: Dictionary) -> void:
	var label := row.get_node_or_null(NodePath("Count_%s" % String(hull_id))) as Label
	if label == null:
		return
	label.text = "%d/%d" % [int(_manifest.get(hull_id, 0)), int(hulls.get(hull_id, 0))]


## What the orbital fleet is carrying, as a short string, or "" for a hull that lifts nothing.
##
## Every kind the hull declares is listed. A readout that showed only the first would send a
## player looking for a hold the Cargo Transport does not have.
## Not static: the cargo figures come from every fleet in orbit over the open source world,
## which is controller state, not a property of the hull definition alone.
func _cargo_text(def: Resource) -> String:
	var count := maxi(1, int(_controller.hulls_in_orbit_at(_source).get(
		StringName(str(def.get("id"))), 1)))
	var parts := PackedStringArray()
	for kind: Variant in def.get("cargo_kinds") as Array:
		match int(kind):
			ShipHullData.CargoKind.METALS:
				parts.append("metal %d/%d" % [_carried(&"metals"),
					int(float(def.get("cargo_capacity")) * count)])
			ShipHullData.CargoKind.FOOD:
				parts.append("food %d/%d" % [_carried(&"food"),
					int(float(def.get("cargo_capacity")) * count)])
			ShipHullData.CargoKind.POWER:
				parts.append("power %d/%d" % [_carried(&"power"),
					int(float(def.get("cargo_capacity")) * count)])
			ShipHullData.CargoKind.TROOPS:
				parts.append("troops %d/%d" % [_carried(&"troops"),
					int(float(def.get("troop_capacity")) * count)])
			ShipHullData.CargoKind.CIVILIANS:
				parts.append("civilians %d/%d" % [_carried(&"civilians"),
					int(float(def.get("civilian_capacity")) * count)])
	return " ".join(parts)


## Cargo of `kind` summed across every fleet in orbit over the source world.
func _carried(kind: StringName) -> int:
	if _controller == null or _source < 0:
		return 0
	var total := 0.0
	for f in _controller.fleets_in_orbit_at(_source):
		total += TransferStage.carried(f, kind)
	return int(total)


func _refresh_summary() -> void:
	var chosen := 0
	var warships := 0
	var hulls := _controller.hulls_in_orbit_at(_source) if _controller != null else {} as Dictionary
	for hull_id: Variant in _manifest:
		var count := int(_manifest[hull_id])
		chosen += count
		var def := _hull(StringName(str(hull_id)))
		if def != null and Enums.role_is_combat(int(def.get("role"))):
			warships += count
	var turns := 0
	if _destination >= 0 and _controller != null and _controller.galaxy != null:
		turns = MovementStage.transit_turns(_controller.galaxy, _source, _destination)
	_summary.text = "%d of %d ship(s) selected (%d combat) -> %s in %d turn(s)" % [
		chosen, _total_ships(hulls), warships,
		_controller.display_name(_destination) if _destination >= 0 else "nowhere yet", turns]


func _total_ships(hulls: Dictionary) -> int:
	var total := 0
	for key: StringName in hulls:
		total += int(hulls[key])
	return total


func _hull(hull_id: StringName) -> Resource:
	if _controller == null or _controller.defs == null:
		return null
	return _controller.defs.ship_hull(hull_id) as Resource


# --- Manifest --------------------------------------------------------------

## Move the manifest by `delta`, clamped to what the orbit holds.
func adjust(hull_id: StringName, delta: int, hulls: Dictionary = {}) -> void:
	var available := hulls if not hulls.is_empty() else (
		_controller.hulls_in_orbit_at(_source) if _controller != null else {} as Dictionary)
	var held := int(available.get(hull_id, 0))
	var current := int(_manifest.get(hull_id, 0))
	_manifest[hull_id] = clampi(current + delta, 0, held)
	refresh()


## Set the whole manifest, or clear it.
func set_all(on: bool) -> void:
	_manifest.clear()
	if on and _controller != null:
		for hull_id: StringName in _controller.hulls_in_orbit_at(_source):
			_manifest[hull_id] = int(_controller.hulls_in_orbit_at(_source)[hull_id])
	if visible:
		refresh()


## The manifest as `{hull_id: count}`, with zero entries removed.
##
## An empty result means *nothing selected*, which is not the same as "the whole fleet": OK is
## inert on an empty manifest, because sending a fleet you have just deselected everything from
## is not what pressing OK beside an empty manifest reads as.
func manifest() -> Dictionary:
	var out: Dictionary = {}
	for hull_id: Variant in _manifest:
		var count := int(_manifest[hull_id])
		if count > 0:
			out[hull_id] = count
	return out


func _on_ok() -> void:
	var ships := manifest()
	if ships.is_empty() or _source < 0 or _destination < 0:
		return
	visible = false
	travel_confirmed.emit(_source, _destination, ships)
	_source = -1
	_destination = -1


func _on_cancel() -> void:
	close()


# --- Accessors for the GUI suite -------------------------------------------

func route_label() -> Label:
	return _route_label


func ok_button() -> Button:
	return _ok_button


func cancel_button() -> Button:
	return _cancel_button


func all_button() -> Button:
	return _all_button


func none_button() -> Button:
	return _none_button


func summary_label() -> Label:
	return _summary


## The combat-roster container, held separately from the logistic one so a test can assert the
## separation without walking the tree.
func combat_rows() -> VBoxContainer:
	return _combat_rows


func support_rows() -> VBoxContainer:
	return _support_rows


## The `+` button for a hull, or null. Named so a test can press it the way a player does.
func more_button(hull_id: StringName) -> Button:
	for parent in [_combat_rows, _support_rows]:
		var found := parent.get_node_or_null(
			NodePath("Row_%s/More_%s" % [String(hull_id), String(hull_id)])) as Button
		if found != null:
			return found
	return null


## The `-` button for a hull, or null.
func less_button(hull_id: StringName) -> Button:
	for parent in [_combat_rows, _support_rows]:
		var found := parent.get_node_or_null(
			NodePath("Row_%s/Less_%s" % [String(hull_id), String(hull_id)])) as Button
		if found != null:
			return found
	return null


## The chosen/total label for a hull, in whichever roster it is listed.
func count_label(hull_id: StringName) -> Label:
	for parent in [_combat_rows, _support_rows]:
		var found := parent.get_node_or_null(
			NodePath("Row_%s/Count_%s" % [String(hull_id), String(hull_id)])) as Label
		if found != null:
			return found
	return null


## The cargo readout for a hull, or null for a hull that lifts nothing.
func cargo_label(hull_id: StringName) -> Label:
	for parent in [_combat_rows, _support_rows]:
		var found := parent.get_node_or_null(
			NodePath("Row_%s/Cargo_%s" % [String(hull_id), String(hull_id)])) as Label
		if found != null:
			return found
	return null


## Every string the modal is showing, for the roster and fog assertions.
func visible_text() -> String:
	return _collect_text(self)


func _collect_text(node: Node) -> String:
	var parts := PackedStringArray()
	if node is Label:
		parts.append(String((node as Label).text))
	elif node is Button:
		parts.append(String((node as Button).text))
	for child in node.get_children():
		var text := _collect_text(child)
		if not text.is_empty():
			parts.append(text)
	return "\n".join(parts)
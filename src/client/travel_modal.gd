extends PanelContainer
class_name TravelModal
## The Travel workflow: pick a start world, pick a destination, then choose which ships go.
##
## This replaces the old "Stage move" toggle, which asked a player to arm a mode, click a
## planet, and then confirm -- three interactions to express "send these ships there". The
## modal is one: the start world is fixed by where the fleet is, the destination is a
## dropdown, and the manifest is a list of ships with `+` / `-` buttons.
##
## It is a `PanelContainer` rather than a `Window`. A `Window` is an embedded subwindow, which
## is the right tool for a dialog that must sit above the map but is awkward to lay out and
## awkward to drive headlessly; the map is a `SubViewport` in its own right, so an overlay
## `Control` sibling is both simpler and more honest about what it is.

## Emitted when the player commits a manifest. Carries the destination planet index and the
## `{hull_id: count}` manifest. An empty manifest means the whole fleet.
signal travel_confirmed(destination: int, ships: Dictionary)

## Emitted when the player dismisses the modal without committing.
signal travel_cancelled

var _controller: SessionController = null

var _origin_label: Label = null
var _destination_selector: OptionButton = null
var _combat_rows: VBoxContainer = null
var _support_rows: VBoxContainer = null
var _summary: Label = null
var _ok_button: Button = null
var _cancel_button: Button = null

## The `{hull_id: count}` the player has built up with the `+` / `-` buttons.
var _manifest: Dictionary = {}

## Set while rebuilding the dropdown so its `item_selected` is not read as a player choice.
var _rebuilding := false


func _ready() -> void:
	_build()
	visible = false


func _build() -> void:
	theme = CC2Theme.build()
	custom_minimum_size = Vector2(440, 0)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	add_child(col)

	col.add_child(_heading("TRAVEL"))

	_origin_label = Label.new()
	_origin_label.add_theme_color_override("font_color", CC2Theme.CYAN)
	_origin_label.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	col.add_child(_origin_label)

	col.add_child(_subheading("DESTINATION"))
	_destination_selector = OptionButton.new()
	_destination_selector.tooltip_text = "Where these ships are going"
	_destination_selector.focus_mode = Control.FOCUS_NONE
	_destination_selector.item_selected.connect(_on_destination_selected)
	col.add_child(_destination_selector)

	var quick := HBoxContainer.new()
	quick.add_theme_constant_override("separation", 6)
	col.add_child(quick)
	var all_button := Button.new()
	all_button.name = "AllShips"
	all_button.text = "All"
	all_button.tooltip_text = "Send the whole fleet"
	all_button.focus_mode = Control.FOCUS_NONE
	all_button.pressed.connect(func() -> void: set_all(true))
	quick.add_child(all_button)
	var none_button := Button.new()
	none_button.name = "NoShips"
	none_button.text = "None"
	none_button.tooltip_text = "Clear the manifest"
	none_button.focus_mode = Control.FOCUS_NONE
	none_button.pressed.connect(func() -> void: set_all(false))
	quick.add_child(none_button)

	col.add_child(_subheading("COMBAT SHIPS"))
	_combat_rows = VBoxContainer.new()
	_combat_rows.add_theme_constant_override("separation", 2)
	col.add_child(_combat_rows)

	col.add_child(_subheading("NON-COMBAT / CARGO"))
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


# --- Lifecycle -------------------------------------------------------------

func bind(controller: SessionController) -> void:
	_controller = controller


## Open the modal for the currently selected fleet.
##
## Refuses a fleet that is already under way or not over a world, and says so rather than
## opening an empty window: a modal listing no ships and no destination is not a decision.
func open_for_selected_fleet() -> bool:
	if _controller == null or _controller.galaxy == null:
		return false
	var f := _controller.fleet()
	if f == null or f.destination >= 0 or f.system < 0:
		return false
	refresh()
	visible = true
	return true


## Close the modal, reporting the dismissal only if it was open.
##
## Guarded because there are two ways to get here -- the CANCEL button and the map
## discarding a proposal -- and both can fire for one dismissal. Emitting unconditionally
## would log "TRAVEL DISCARDED" twice for a single cancellation, and a log that reports one
## action twice is a log nobody can trust.
func close() -> void:
	if not visible:
		return
	visible = false
	travel_cancelled.emit()


## Point the dropdown at `target`, opening the modal if it is not already shown.
##
## This is how a map click reaches the modal: the click knows which world was hit, and the
## modal knows what else has to be decided, so neither may act alone. Returns false when the
## world cannot be a destination -- the fleet's own world, or one that does not exist.
func set_destination(target: int) -> bool:
	if _controller == null or _controller.galaxy == null:
		return false
	if _controller.galaxy.planet(target) == null:
		return false
	var f := _controller.fleet()
	if f == null or target == f.system:
		return false
	for i in _destination_selector.item_count:
		var meta: Variant = _destination_selector.get_item_metadata(i)
		if meta != null and int(meta) == target:
			_destination_selector.select(i)
			visible = true
			_refresh_summary(f)
			return true
	return false


## Rebuild the contents from the selected fleet. Public so the GUI suite can re-read the
## modal after changing the fleet without going through the map.
func refresh() -> void:
	if _controller == null or _controller.galaxy == null:
		return
	var f := _controller.fleet()
	if f == null:
		return
	_origin_label.text = "FROM  %s" % _controller.display_name(f.system)
	_rebuild_destinations(f)
	_rebuild_rows(f)


func _rebuild_destinations(f: FleetState) -> void:
	_rebuilding = true
	var want := _selected_destination()
	_destination_selector.clear()
	for p in _controller.galaxy.planets:
		# The destination must differ from the start, so the fleet's own world is not
		# offered at all rather than offered and refused.
		if p.index == f.system:
			continue
		_destination_selector.add_item(_controller.display_name(p.index))
		_destination_selector.set_item_metadata(
			_destination_selector.item_count - 1, p.index)
		if p.index == want:
			_destination_selector.select(_destination_selector.item_count - 1)
	if _destination_selector.selected < 0 and _destination_selector.item_count > 0:
		_destination_selector.select(0)
	_destination_selector.disabled = _destination_selector.item_count == 0
	_rebuilding = false


# --- Contents --------------------------------------------------------------

func _rebuild_rows(f: FleetState) -> void:
	for child in _combat_rows.get_children():
		_combat_rows.remove_child(child)
		child.queue_free()
	for child in _support_rows.get_children():
		_support_rows.remove_child(child)
		child.queue_free()

	# Two rosters, built separately and in the order the design document lists them. A
	# player choosing what to send wants "the warships, or the transports" as two decisions,
	# not one list of twenty rows to scan.
	var hulls: Array[StringName] = []
	for key: StringName in f.ships:
		hulls.append(key)
	hulls.sort()

	for hull_id in hulls:
		var def: Resource = _hull(f, hull_id)
		if def == null:
			continue
		var role := int(def.get("role"))
		var parent: VBoxContainer = _combat_rows if Enums.role_is_combat(role) \
			else _support_rows
		parent.add_child(_ship_row(f, hull_id, def))

	_refresh_summary(f)


## One row: name, `-`, the chosen count, `+`, and what the hull is carrying.
func _ship_row(f: FleetState, hull_id: StringName, def: Resource) -> Control:
	var row := HBoxContainer.new()
	row.name = "Row_%s" % String(hull_id)
	row.add_theme_constant_override("separation", 4)

	var name_label := Label.new()
	name_label.text = String(def.display_name)
	name_label.custom_minimum_size = Vector2(120, 0)
	name_label.add_theme_color_override("font_color", CC2Theme.PHOSPHOR)
	name_label.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	row.add_child(name_label)

	var minus := Button.new()
	minus.name = "Less_%s" % String(hull_id)
	minus.text = "-"
	minus.tooltip_text = "Send one fewer"
	minus.focus_mode = Control.FOCUS_NONE
	minus.custom_minimum_size = Vector2(26, 0)
	minus.pressed.connect(func() -> void: adjust(f, hull_id, -1))
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
	plus.pressed.connect(func() -> void: adjust(f, hull_id, 1))
	row.add_child(plus)

	_update_count_label(row, f, hull_id)

	# The cargo readout the design document asks for: Cargo Transports show metal and food,
	# Troop Transports show troops, Colony Ships show civilians. On the row, because "does
	# this ship have anything in it" is a per-ship question.
	var cargo_text := _cargo_text(f, def)
	if not cargo_text.is_empty():
		var cargo_label := Label.new()
		cargo_label.name = "Cargo_%s" % String(hull_id)
		cargo_label.text = cargo_text
		cargo_label.add_theme_color_override("font_color", CC2Theme.AMBER)
		cargo_label.add_theme_font_size_override("font_size", CC2Theme.FONT_TINY)
		row.add_child(cargo_label)

	return row


func _update_count_label(row: Control, f: FleetState, hull_id: StringName) -> void:
	var label := row.get_node_or_null(NodePath("Count_%s" % String(hull_id))) as Label
	if label == null:
		return
	label.text = "%d/%d" % [int(_manifest.get(hull_id, 0)), int(f.ships.get(hull_id, 0))]


## What a hull is carrying, as a short string, or "" for a hull that lifts nothing.
##
## Every kind the hull declares is listed, not just its first: the design document's Cargo
## Transport carries food *and* metal, and a readout that showed only one of them would send
## a player looking for a hold that does not exist.
static func _cargo_text(f: FleetState, def: Resource) -> String:
	var count := maxi(1, int(f.ships.get(def.get("id"), 1)))
	var parts := PackedStringArray()
	for kind: Variant in def.get("cargo_kinds") as Array:
		match int(kind):
			ShipHullData.CargoKind.METALS:
				parts.append("metal %d/%d" % [int(f.cargo.get("metals", 0.0)),
					int(float(def.get("cargo_capacity")) * count)])
			ShipHullData.CargoKind.FOOD:
				parts.append("food %d/%d" % [int(f.cargo.get("food", 0.0)),
					int(float(def.get("cargo_capacity")) * count)])
			ShipHullData.CargoKind.POWER:
				parts.append("power %d/%d" % [int(f.cargo.get("power", 0.0)),
					int(float(def.get("cargo_capacity")) * count)])
			ShipHullData.CargoKind.TROOPS:
				parts.append("troops %d/%d" % [int(f.cargo.get("troops", 0.0)),
					int(float(def.get("troop_capacity")) * count)])
			ShipHullData.CargoKind.CIVILIANS:
				parts.append("civilians %d/%d" % [int(f.cargo.get("civilians", 0.0)),
					int(float(def.get("civilian_capacity")) * count)])
	return " ".join(parts)


func _refresh_summary(f: FleetState) -> void:
	var chosen := 0
	var warships := 0
	for hull_id: Variant in _manifest:
		var count := int(_manifest[hull_id])
		chosen += count
		var def: Resource = _hull(f, StringName(str(hull_id)))
		if def != null and Enums.role_is_combat(int(def.get("role"))):
			warships += count
	var dest := _selected_destination()
	var where := _controller.display_name(dest) if dest >= 0 else "nowhere yet"
	var turns := 0
	if dest >= 0 and f.system >= 0:
		turns = MovementStage.transit_turns(_controller.galaxy, f.system, dest)
	_summary.text = "%d ship(s) selected (%d combat) -> %s, %d turn(s)" % [
		chosen, warships, where, turns]


func _hull(f: FleetState, hull_id: StringName) -> Resource:
	if f == null:
		return null
	return f.hulls().get(hull_id, null) as Resource


# --- Manifest --------------------------------------------------------------

## Move the manifest by `delta`, clamped to what the fleet holds.
func adjust(f: FleetState, hull_id: StringName, delta: int) -> void:
	var held := int(f.ships.get(hull_id, 0))
	var current := int(_manifest.get(hull_id, 0))
	_manifest[hull_id] = clampi(current + delta, 0, held)
	_rebuild_rows(f)


## Set the whole manifest, or clear it.
func set_all(on: bool) -> void:
	var f := _controller.fleet() if _controller != null else null
	if f == null:
		return
	_manifest.clear()
	if on:
		for hull_id: StringName in f.ships:
			_manifest[hull_id] = int(f.ships[hull_id])
	_rebuild_rows(f)


## The manifest as `{hull_id: count}`, with zero entries removed.
##
## An empty result means *nothing selected*, which is not the same as "the whole fleet" and
## is treated as such: OK is inert on an empty manifest, because sending a fleet you have
## deselected everything from is not what pressing OK next to an empty manifest reads as.
func manifest() -> Dictionary:
	var out: Dictionary = {}
	for hull_id: Variant in _manifest:
		var count := int(_manifest[hull_id])
		if count > 0:
			out[hull_id] = count
	return out


func _selected_destination() -> int:
	if _destination_selector == null or _destination_selector.selected < 0:
		return -1
	var meta: Variant = _destination_selector.get_item_metadata(_destination_selector.selected)
	return int(meta) if meta != null else -1


func _on_destination_selected(_index: int) -> void:
	if _rebuilding or _controller == null:
		return
	var f := _controller.fleet()
	if f != null:
		_refresh_summary(f)


func _on_ok() -> void:
	if _controller == null:
		return
	var dest := _selected_destination()
	if dest < 0:
		return
	var ships := manifest()
	if ships.is_empty():
		return
	travel_confirmed.emit(dest, ships)
	visible = false


func _on_cancel() -> void:
	close()


# --- Accessors for the GUI suite -------------------------------------------

func origin_label() -> Label:
	return _origin_label


func destination_selector() -> OptionButton:
	return _destination_selector


func ok_button() -> Button:
	return _ok_button


func cancel_button() -> Button:
	return _cancel_button


func summary_label() -> Label:
	return _summary


## The combat-roster container, held separately from the support one so a test can assert
## the separation the design document asks for without walking the tree.
func combat_rows() -> VBoxContainer:
	return _combat_rows


func support_rows() -> VBoxContainer:
	return _support_rows


## The `+` button for a hull, or null. Named so a test can press it the way a player does.
func more_button(hull_id: StringName) -> Button:
	return _combat_rows.get_node_or_null(
		NodePath("Row_%s/More_%s" % [String(hull_id), String(hull_id)])) as Button


func less_button(hull_id: StringName) -> Button:
	return _combat_rows.get_node_or_null(
		NodePath("Row_%s/Less_%s" % [String(hull_id), String(hull_id)])) as Button


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


## Every string the modal is showing, for the fog and roster assertions.
func visible_text() -> String:
	return _collect_text(self)


func _collect_text(node: Node) -> String:
	var parts := PackedStringArray()
	if node is Label:
		parts.append(String((node as Label).text))
	elif node is Button:
		parts.append(String((node as Button).text))
	elif node is OptionButton:
		var button := node as OptionButton
		for i in button.item_count:
			parts.append(button.get_item_text(i))
	for child in node.get_children():
		var text := _collect_text(child)
		if not text.is_empty():
			parts.append(text)
	return "\n".join(parts)
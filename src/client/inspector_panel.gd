extends PanelContainer
class_name InspectorPanel
## Planet readout.
##
## Shows the selected body's type, population, food balance, structures and defence.
## Everything is a sunk, monospaced-style readout rather than a form, matching the terminal
## aesthetic.
##
## The SYSTEM SURVEY panel that used to sit above this -- name, class, bodies, value, owner
## -- is gone. There is one system, it has one name that the player sees written on the
## map's crosshair every time they look at the centre of the screen, and the other four
## rows described the star rather than anything the player can act on. What it really cost
## was the half of the left column that a five-row readout of the only star in the game
## occupied, which the planet detail and the fleet registry both needed. Removing it is
## also a fog fix in its own right: OWNER is a rival-empire roster, and it was the one
## panel row with no route for the name fog to reach.

var _controller: SessionController = null

var _planet_label: RichTextLabel = null


func _ready() -> void:
	_build()


func _build() -> void:
	theme = CC2Theme.build()
	custom_minimum_size = Vector2(260, 0)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	add_child(col)

	# The BODIES list is gone too. Planets are picked by clicking them on the map, which is
	# where a player is already looking to decide what to do; a duplicate list here made
	# the map and the panel two controls for one job, and the one in the panel could not
	# show anything the map did not.
	col.add_child(_heading("PLANET DETAIL"))

	_planet_label = RichTextLabel.new()
	_planet_label.bbcode_enabled = true
	_planet_label.fit_content = true
	_planet_label.scroll_active = false
	_planet_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_planet_label)


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", CC2Theme.CYAN)
	l.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	return l


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
	_refresh_planet()


## The currently selected planet, or null when nothing is picked.
##
## The player selects one by clicking it on the map; there is no list to select from any
## more, so this is whatever the last map click resolved to.
func _selected_planet() -> PlanetState:
	if _controller == null or _controller.galaxy == null:
		return null
	if _controller.selected_planet < 0:
		return null
	return _controller.galaxy.planet(_controller.selected_planet)


func _refresh_planet() -> void:
	var p := _selected_planet()
	if p == null:
		_planet_label.text = "[color=#%s]NO PLANET SELECTED[/color]" % CC2Theme.WHITE_DIM.to_html(false)
		return

	var lines := PackedStringArray()
	lines.append(Format.heading("%s  [%s]" % [
		_known_name(p),
		_ownership_caption(p),
	]))
	# Habitability is not shown. It was on both sides of this fog -- it survived the survey
	# rule because it is a property of the rock rather than of whoever holds it -- and that
	# was the reasoning that let it stay. But the player has no decision that turns on it:
	# they cannot terraform, they cannot pick a world by it, and the food balance that does
	# depend on it is reported directly. All the row did was put a number next to a name and
	# imply the name mattered for something.
	#
	# Naming is the part that does cross the fog: a name is something somebody surveyed and
	# recorded, and it is the identifier a player reuses across turns.
	if not _planet_detail_known(p):
		lines.append("")
		lines.append("[color=#%s]UNSURVEYED[/color]" % CC2Theme.WHITE_DIM.to_html(false))
		_planet_label.text = "\n".join(lines)
		return

	lines.append(Format.field("TYPE", String(p.type_id).capitalize()))

	# Metal: the stockpile and what the next turn adds to it. The delta is read from the
	# colony's own mines rather than a generic economy figure, so "Metal: 599 (+15)" is the
	# number the resolver is about to credit.
	lines.append(Format.field("METAL", "%d (%s)" % [
		int(p.reserve_metals), Format.signed(_metal_per_turn(p), 0)]))

	# Population: the headcount, then how many are working. The pair is the interesting part
	# -- a colony with ten people and five jobs has five idle, and those five are the ones
	# researching. Idle pop is not waste; it is the research budget.
	var employed := employed_population(p)
	lines.append(Format.field("POPULATION", "%d (%d/%d)" % [
		int(round(p.population)), employed, employed + idle_population(p)]))
	lines.append(Format.field("TROOPS", str(p.troops)))
	lines.append(Format.field("HOUSING", "%d" % int(p.housing)))
	lines.append(Format.field("FOOD", "%d / %d" % [
		int(p.food_stock), int(p.food_capacity)]))
	lines.append(Format.field("FOOD BALANCE", Format.signed_colored(_food_balance(p))))
	lines.append(Format.field("POWER", "%d / %d (+%d, -%d)" % [
		int(p.power), int(p.power_capacity), int(p.power_generated), int(p.power_drawn)]))

	# The Phase 8 building roster, in the order a player thinks about it. `space_port` is in
	# `_ROSTER` and so is in `_is_economic`: it used to be printed on its own line here *and*
	# fall through to the OTHER block, so a colony with a berth showed "SPACEPORTS 1" and
	# "other space_port x1" two lines apart.
	lines.append("")
	for id in _ROSTER:
		lines.append(Format.field(_label_for(id), str(p.count(id))))
	lines.append(Format.field("SHIPS", "%d building, %d queued" % [
		int(p.shipyard_progress), p.ship_queue.size()]))

	if not p.building_queue.is_empty():
		lines.append("")
		lines.append("[color=#%s]IN BUILD (%d turn, %d metal banked)[/color]" % [
			CC2Theme.AMBER.to_html(false), p.build_turns_remaining, int(p.build_metal)
		])
		var queued := PackedStringArray()
		for key in p.building_queue:
			queued.append("%s x%d" % [String(key), int(p.building_queue[key])])
		queued.sort()
		lines.append("  " + ", ".join(queued))

	# Standing warnings. Food overflow arrives a turn late on purpose, so this block is
	# frequently empty on the turn it was earned and populated on the one after.
	var flags := PackedStringArray()
	for key: Variant in p.warnings:
		flags.append(String(key).replace("_", " ").to_upper())
	if not flags.is_empty():
		flags.sort()
		lines.append("")
		lines.append("[color=#%s]%s[/color]" % [
			CC2Theme.AMBER.to_html(false), " | ".join(flags)])

	var other := PackedStringArray()
	for key in p.structures:
		if not _is_economic(StringName(str(key))):
			other.append("%s x%d" % [String(key), int(p.structures[key])])
	other.sort()
	if not other.is_empty():
		lines.append("")
		lines.append("[color=#%s]OTHER[/color]  %s" % [
			CC2Theme.WHITE_DIM.to_html(false), ", ".join(other)
		])

	_planet_label.text = "\n".join(lines)


## The planet's name, or the fog placeholder.
##
## Delegates to `SessionController.display_name`, which is where the rule and the fallback
## formatting both live. The map and the selection log call the same function, so a world
## cannot be nameless on the map and named in the log two inches to its right.
func _known_name(p: PlanetState) -> String:
	if _controller == null:
		return GalaxyMapView.UNKNOWN_NAME
	return _controller.display_name(p.index)


## Whether the player may see this body's economy.
##
## A world the player owns is always known. A world owned by somebody else is known only
## when the player has a fleet parked *on that world specifically*. Consulting the owning
## *system* instead -- which is what this used to do -- is a real over-reveal now that
## there is one system: every world in the game orbits the same star, so "I know who owns
## the system" trivially became "I know the economy of every planet on the map" the moment
## a single ship was anywhere at all.
func _planet_detail_known(p: PlanetState) -> bool:
	if _controller == null or p == null:
		return false
	if p.owner == _controller.player_id:
		return true
	if p.surveyed:
		return true
	for f in _controller.galaxy.fleets_of(_controller.player_id):
		if f.destination < 0 and f.system == p.index:
			return true
	return false


## Food balance per turn: what the colony's staffed farms produce, minus one food per
## civilian. Mirrors `ColonySim` closely enough to preview without running a turn.
##
## The habitability multiplier is gone, and deliberately. In Phase 8 a farm is "requires 1
## pop, generates +5 food/turn" -- an absolute figure -- so scaling it by habitability made
## the number in this panel a different quantity from the one the resolver uses.
func _food_balance(p: PlanetState) -> float:
	var produced := float(p.count(&"farm")) * 5.0
	if p.count(&"colony_ship_building") > 0:
		produced += 5.0
	return produced - p.population


## The Phase 8 structure roster, in the order the readout lists it.
const _ROSTER: Array[StringName] = [
	&"farm", &"mine", &"granary", &"city_complex", &"colony_ship_building",
	&"energy_storage", &"solar", &"coal", &"nuclear",
	&"space_port", &"barracks", &"planetary_defense",
]

## Readable label for a roster entry, without needing the definition table.
func _label_for(id: StringName) -> String:
	match id:
		&"energy_storage": return "ENERGY STOR"
		&"city_complex": return "CITIES"
		&"planetary_defense": return "DEFENSES"
		&"colony_ship_building": return "COLONY SHIP"
		&"space_port": return "SPACE PORTS"
	return String(id).replace("_", " ").to_upper()


## Civilians working an active structure right now.
##
## One person per staffed structure, in `pop_required` order, so the figure is the number of
## buildings the colony can actually man rather than the sum of what it *could* staff. A
## colony with four farms and two people has two employed, not four.
func employed_population(p: PlanetState) -> int:
	if _controller == null or _controller.defs == null or p == null:
		return 0
	var buildings: Dictionary = _controller.defs.get("buildings") as Dictionary
	var jobs := 0
	var hands := int(floor(p.population))
	for building_id: StringName in p.structures:
		var count := int(p.structures[building_id])
		if count <= 0 or hands <= 0:
			continue
		var def: Resource = buildings.get(building_id, null) as Resource
		if def == null or int(def.get("pop_required")) <= 0:
			continue
		var staffed: int = mini(count, hands)
		jobs += staffed
		hands -= staffed
	return jobs


## Civilians with no job, who therefore do nothing but research.
func idle_population(p: PlanetState) -> int:
	return maxi(0, int(round(p.population)) - employed_population(p))


## Metal this colony's mines will credit next turn.
##
## Read from the structure table rather than from the previous turn's report, so the figure is
## the number the resolver is about to use. A mine needing a colonist counts only if the
## colony has one to staff it, which is why this is not simply `mines * 5`.
func _metal_per_turn(p: PlanetState) -> float:
	if _controller == null or _controller.defs == null or p == null:
		return 0.0
	var buildings: Dictionary = _controller.defs.get("buildings") as Dictionary
	return TurnResolver.metal_output_per_turn(p, buildings)


func _is_economic(id: StringName) -> bool:
	return _ROSTER.has(id)


## Heading caption for a selected body.
##
## A body belonging to another empire reads UNCOLONISED, exactly like an empty one. The
## player learns an opponent's holdings by putting a ship in orbit, not by clicking a row
## the sensors happened to light up.
func _ownership_caption(p: PlanetState) -> String:
	if not p.colonized or p.owner != _controller.player_id:
		return "UNCOLONISED"
	return "YOURS"


func planet_label() -> RichTextLabel:
	return _planet_label

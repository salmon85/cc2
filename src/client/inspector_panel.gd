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
	#
	# Two different things a player cannot have, said differently.
	#
	# A world nobody has been near at all is UNSURVEYED: the player does not know it is there
	# in any meaningful sense, and saying nothing is the honest report. A world they have been
	# near is NO INTEL -- they know it exists and roughly what it looks like, and the contents
	# are somebody else's business. One grey placeholder for two unrelated facts either gave
	# away a rival's economy or told a player visiting an empty rock that nothing at all was
	# known about it.
	if not _economy_known(p):
		lines.append("")
		lines.append("[color=#%s]%s[/color]" % [
			CC2Theme.WHITE_DIM.to_html(false),
			"UNSURVEYED" if not _world_visited(p) else "NO INTEL"])
		_planet_label.text = "\n".join(lines)
		return

	lines.append(Format.field("TYPE", String(p.type_id).capitalize()))

	# Recomputed here, not read from the cache as it happens to stand.
	#
	# The panel is the only reader that can be looking at a colony mid-turn -- the player has
	# just pressed Build, or just scrapped something, and the resolver has not run since -- so
	# a panel that trusts a cache is a panel that prints the previous turn's numbers. It cost
	# `Food 300/0` once because nothing had ever written the cached figure at all; the fix is
	# to ask the colony rather than to trust that somebody remembered to tell the panel.
	p.refresh_capacities(_controller.db)

	# The player's *own* bare world: there is no economy to report, and saying so is one line
	# where four rows of zeroes used to be. This is the only uncolonised world that reaches
	# this point -- every other one is refused above.
	if not p.colonized:
		lines.append("[color=#%s]NO COLONY[/color]" % CC2Theme.WHITE_DIM.to_html(false))
		_planet_label.text = "\n".join(lines)
		return

	# Metal: the stockpile and what the next turn adds to it. The delta is read from the
	# colony's own mines rather than a generic economy figure, so "METAL 599 (+15)" is the
	# number the resolver is about to credit.
	lines.append(Format.field("METAL", "%d (%s)" % [
		int(p.reserve_metals), Format.signed(_metal_per_turn(p), 0)]))

	# Population: the headcount, then how many are working and how many are not.
	#
	# `total (working/jobless)`. The idle figure is the second number rather than a separate
	# row because the pair *is* the information: eight people with four jobs means four idle
	# colonist-turns of research and four mouths, and printing "POPULATION 8" above a separate
	# "IDLE 4" row made the player do the subtraction to see the decision.
	var employed := employed_population(p)
	lines.append(Format.field("POPULATION", "%d (%d/%d)" % [
		int(round(p.population)), employed, idle_population(p)]))
	lines.append(Format.field("TROOPS", str(p.troops)))
	lines.append(Format.field("HOUSING", "%d" % int(p.get_max_housing())))

	# Food: one line, current over max, with the per-turn net in brackets.
	#
	# This replaces `FOOD 990/1000` above a separate `FOOD BALANCE +7`. Two rows for one
	# quantity, and the second row's number was the only one that changed turn to turn -- so
	# the reader's eye went to the static part and the moving part scrolled past unremarked.
	# `(+7)` next to the bank it will change is the same information in one glance.
	lines.append(Format.field("FOOD", "%d/%d (%s)" % [
		int(p.food_stock), int(p.get_max_food()), Format.signed_colored(_food_balance(p))]))

	# Power: current over max, with generation minus draw in brackets.
	#
	# It was `POWER 270/1000 (+40, -10)`, which is two signed numbers the reader has to combine
	# before they mean anything, and it carried a literal `-0` whenever a structure drew
	# nothing -- the format printed the sign of zero as a minus sign. One net figure, computed
	# the way a player would: a Nuclear plant at +40 against a City Complex at 10 is +30.
	lines.append(Format.field("POWER", "%d/%d (%s)" % [
		int(p.power), int(p.get_max_power()), Format.signed_colored(_power_balance(p))]))

	# The Phase 8 building roster, in the order a player thinks about it. `space_port` is in
	# `_ROSTER` and so is in `_is_economic`: it used to be printed on its own line here *and*
	# fall through to the OTHER block, so a colony with a berth showed "SPACEPORTS 1" and
	# "other space_port x1" two lines apart.
	lines.append("")
	for id in _ROSTER:
		lines.append(Format.field(_label_for(id), _roster_value(p, id)))
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
## **Only their own.** Not "known", not "visited" -- owned.
##
## This used to admit a surveyed world and any world with one of the player's fleets parked on
## it, on the reasoning that a scout sweep had earned it. Both of those are how a rival's
## colony gets read off the panel: population, stockpile, food balance and the whole structure
## roster of an empire that has done nothing but be a few hundred parsecs away. Sweeping a world
## tells you what kind of rock it is; it does not tell you what is standing on it, and nothing
## in the design says a scout should.
##
## The two looser cases are not thrown away, they are reported differently. `_world_visited`
## decides between UNSURVEYED and NO INTEL, so the player still learns that the world is there
## and that they have been near it -- which is the part they earned -- without being handed the
## contents they did not.
func _economy_known(p: PlanetState) -> bool:
	if _controller == null or p == null:
		return false
	return p.owner == _controller.player_id


## Whether the player has been near this world at all: swept it, or put a ship in orbit.
##
## The bar between "I do not know this exists" and "I know this exists and it is not mine".
## Both are facts about the player's own knowledge, and neither is a fact about the world.
func _world_visited(p: PlanetState) -> bool:
	if _controller == null or p == null:
		return false
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
##
## Read from the colony sim rather than recomputed from a hard-coded 5.0 per farm: the figure
## has to be what the worked farms produce, and it used to be what *every* farm would produce
## if each had a colonist -- so a colony with one farmhand was shown feeding five.
func _food_balance(p: PlanetState) -> float:
	if _controller == null or _controller.defs == null:
		return 0.0
	var buildings: Dictionary = _controller.defs.get("buildings") as Dictionary
	# Read straight from the resolver's arithmetic: worked farms, plus what the colony runs
	# unattended, less one food per civilian. The panel used to add the Colony Ship's five by
	# hand while the resolver did not count them at all, so the readout and the turn disagreed
	# by five every turn and the colony starved while the panel said it was in surplus.
	return ColonySim._food_output(p, buildings) - p.population


## Power balance: what the colony generates minus what its structures draw.
##
## One net figure rather than the two signed halves. `power_generated` and `power_drawn` are
## both still on the planet state and both still shown in the imperial summary, so nothing is
## lost -- but the panel's job is to answer "is my grid in surplus", and a surplus is a
## subtraction, not a pair of numbers.
func _power_balance(p: PlanetState) -> float:
	return p.power_generated - p.power_drawn


## The Phase 8 structure roster, in the order the readout lists it.
const _ROSTER: Array[StringName] = [
	&"farm", &"mine", &"granary", &"city_complex", &"colony_ship_building",
	&"energy_storage", &"solar", &"coal", &"nuclear",
	&"space_port", &"barracks", &"planetary_defense",
]

## A roster row's value: the count, plus the worked count for a staffable structure.
##
## `Farms 3 (2)` reads as "three farms, two of them worked", which is the whole of what
## decides food. Without the bracket a colony with nine farms and one farmhand looks exactly
## like a colony with nine farmhands, and the two differ by forty food a turn.
##
## Read from `ColonySim.workers_on` rather than recomputed here, so the panel and the turn
## resolver cannot disagree about how many people are on a farm.
func _roster_value(p: PlanetState, id: StringName) -> String:
	var standing := int(p.count(id))
	if not ColonySim.STAFFABLE.has(id):
		return str(standing)
	return "%d (%d)" % [standing, ColonySim.workers_on(p, id)]


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
## Delegated to `ColonySim`, which reads the assignment table. This used to *derive* the figure
## by walking the structures and handing out one colonist per staffed building until the
## population ran out -- which is the automatic behaviour the assignment table replaced, kept
## alive in the panel where it disagreed with what the farms actually produced.
func employed_population(p: PlanetState) -> int:
	return ColonySim.workers_assigned(p)


## Civilians with no job, who therefore do nothing but research.
func idle_population(p: PlanetState) -> int:
	return ColonySim.idle_workers(p)


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

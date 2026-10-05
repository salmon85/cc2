extends PanelContainer
class_name InspectorPanel
## System / planet readout.
##
## Shows the selected system's summary and, below it, a body list; selecting a body shows
## its class, habitability, population, food balance, structures and defence. Everything is
## a sunk, monospaced-style readout rather than a form, matching the terminal aesthetic.

var _controller: SessionController = null

var _system_label: RichTextLabel = null
var _planet_label: RichTextLabel = null


func _ready() -> void:
	_build()


func _build() -> void:
	theme = CC2Theme.build()
	custom_minimum_size = Vector2(260, 0)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	add_child(col)

	col.add_child(_heading("SYSTEM SURVEY"))

	_system_label = RichTextLabel.new()
	_system_label.bbcode_enabled = true
	_system_label.fit_content = true
	_system_label.scroll_active = false
	_system_label.custom_minimum_size = Vector2(0, 150)
	col.add_child(_system_label)

	# The BODIES list is gone. Planets are picked by clicking them on the map, which is
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
	_refresh_system()
	_refresh_planet()


func _refresh_system() -> void:
	var sys: SystemState = null
	if _controller.selected_system >= 0:
		sys = _controller.galaxy.system(_controller.selected_system)
	if sys == null:
		_system_label.text = "[color=#%s]NO SYSTEM SELECTED[/color]" % CC2Theme.WHITE_DIM.to_html(false)
		return

	var seen := _controller.can_see(sys.index)
	var lines := PackedStringArray()
	lines.append(Format.field("NAME", sys.name if sys.name != "" else "UNNAMED"))
	if not seen:
		# Unsurveyed systems must not leak detail the player has paid to discover.
		lines.append(Format.field("CLASS", "UNSURVEYED"))
		lines.append(Format.field("BODIES", "?"))
		lines.append(Format.field("VALUE", "??"))
		_system_label.text = "\n".join(lines)
		return

	lines.append(Format.field("CLASS", _star_class_name(sys.star_class)))
	lines.append(Format.field("BODIES", str(sys.body_count())))
	lines.append(Format.field("VALUE", Format.fixed(sys.strategic_value, 2)))
	# Ownership is only reported for the player's own empire. Sensor sweeps can reveal a
	# foreign star, but not its flag: naming the owner here handed every player a free,
	# always-accurate roster of where every other empire had settled, which is the whole
	# game. A foreign system with no claim of our own reads exactly like uncharted.
	if sys.owner == _controller.player_id and _controller.knows_owner_of(sys.index):
		lines.append(Format.field(
			"OWNER", "[color=#%s]%s[/color]" % [
				CC2Theme.faction_color(sys.owner).to_html(false), _faction_name(sys.owner)
			]
		))
	else:
		lines.append(Format.field("OWNER", "UNCLAIMED"))
	if sys.owner == _controller.player_id:
		lines.append("[color=#%s]>> YOUR TERRITORY[/color]" % CC2Theme.PHOSPHOR.to_html(false))
	_system_label.text = "\n".join(lines)


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
		String(p.type_id).capitalize(),
		_ownership_caption(p),
	]))
	lines.append(Format.field("HABITABILITY", Format.percent(p.habitability())))

	# Everything past habitability is a readout of an economy. A world belonging to
	# another empire is surveyed rock: its population, farms, reserves and build queue
	# are exactly the "squares and markers" the fog is supposed to withhold, and they were
	# reachable by clicking any row a sensor sweep happened to light up. Habitability is
	# kept because it is a property of the planet, not of its owner.
	if not _planet_detail_known(p):
		lines.append("")
		lines.append("[color=#%s]UNSURVEYED[/color]" % CC2Theme.WHITE_DIM.to_html(false))
		_planet_label.text = "\n".join(lines)
		return

	lines.append(Format.field("POPULATION", Format.fixed(p.population, 2)))
	lines.append(Format.field("CAPACITY", Format.fixed(p.max_population(), 2)))
	lines.append(Format.field("FOOD BALANCE", Format.signed_colored(_food_balance(p))))
	lines.append(Format.field("FOOD STOCK", Format.fixed(p.food_stock, 1)))

	# Economic structures: the counts the spec calls out, plus the stores they feed.
	lines.append("")
	lines.append(Format.field("FARMS", str(p.count(&"farm"))))
	lines.append(Format.field("MINES", str(p.count(&"mine"))))
	lines.append(Format.field("FACTORIES", str(p.count(&"factory"))))
	lines.append(Format.field("SHIELDS", str(p.count(&"shield_generator"))))
	lines.append(Format.field("BATTERIES", str(p.count(&"missile_battery"))))
	lines.append(Format.field("GARRISONS", str(p.count(&"garrison"))))
	lines.append(Format.field("SHIPYARD", Format.fixed(p.shipyard_progress * 100.0, 0) + "%"))
	lines.append(Format.field("STORES", "M %s  R %s  E %s" % [
		Format.fixed(p.reserve_metals, 0),
		Format.fixed(p.reserve_rare, 0),
		Format.fixed(p.reserve_energy, 0),
	]))

	if not p.building_queue.is_empty():
		lines.append("")
		lines.append("[color=#%s]IN BUILD (%d turn)[/color]" % [
			CC2Theme.AMBER.to_html(false), p.build_turns_remaining
		])
		var queued := PackedStringArray()
		for key in p.building_queue:
			queued.append("%s x%d" % [String(key), int(p.building_queue[key])])
		queued.sort()
		lines.append("  " + ", ".join(queued))

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


## Whether this player's survey knows a body's economics.
##
## The player's own worlds, always. A foreign body only once the player has a fleet
## actually parked in that system -- the same "my ships are sitting in it" standard
## `SessionController.knows_owner_of` applies to ownership, so the two never disagree
## about whether a player is allowed to see what is there.
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


## Food balance per turn: production from farms and habitability, minus consumption from
## population. Mirrors `ColonySim` closely enough to preview without running a turn, and is
## labelled as a projection in the UI copy.
func _food_balance(p: PlanetState) -> float:
	var produced := p.count(&"farm") * 2.0 * maxf(0.0, p.habitability())
	return produced - p.population * 0.15


func _is_economic(id: StringName) -> bool:
	return id in [&"farm", &"mine", &"factory", &"shield_generator",
		&"missile_battery", &"garrison", &"shipyard"]


## Heading caption for a selected body.
##
## A body belonging to another empire reads UNCOLONISED, exactly like an empty one. The
## player learns an opponent's holdings by putting a ship in orbit, not by clicking a row
## the sensors happened to light up.
func _ownership_caption(p: PlanetState) -> String:
	if not p.colonized or p.owner != _controller.player_id:
		return "UNCOLONISED"
	return "YOURS"


func _faction_name(id: int) -> String:
	# Factions carry no display name in the state model — Phase 2 keyed them by id and
	# colour, so the UI names them positionally rather than inventing a roster.
	return "FACTION %d" % id


func _star_class_name(star_class: int) -> String:
	match star_class:
		0: return "M RED DWARF"
		1: return "K ORANGE DWARF"
		2: return "G YELLOW STAR"
		3: return "F WHITE-YELLOW"
		4: return "A WHITE STAR"
		5: return "B BLUE GIANT"
		6: return "O BLUE SUPERGIANT"
		_: return "CLASS ?"


func planet_label() -> RichTextLabel:
	return _planet_label


func system_label() -> RichTextLabel:
	return _system_label

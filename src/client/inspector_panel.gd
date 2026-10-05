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


func planet_label() -> RichTextLabel:
	return _planet_label

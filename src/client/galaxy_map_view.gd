extends Control
class_name GalaxyMapView
## Pure drawing layer for the galaxy map.
##
## Holds no state beyond its controller: every frame it re-reads the galaxy and repaints.
## That is cheap enough at this scale (hundreds of systems, a handful of draw calls each)
## and it means the view can never drift out of sync with the model.
##
## All drawing is done in galaxy coordinates; `GalaxyMap` parents this inside a SubViewport
## so the Camera2D handles zoom and pan without any transform maths here.

## Emitted when a system is clicked, with its galaxy index.
signal system_clicked(system_index: int)

## Emitted when empty space is clicked, so the client can clear the order target.
signal background_clicked

var _controller: SessionController = null

## Set while the pointer is over a star, so the cursor can change.
var _hover: int = -1


func _ready() -> void:
	# The map is a continuous readout, not a control the player manipulates directly —
	# the parent intercepts input so zoom/pan and click routing stay in one place.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


func bind(controller: SessionController) -> void:
	_controller = controller
	if _controller == null:
		return
	if not _controller.state_changed.is_connected(queue_redraw):
		_controller.state_changed.connect(queue_redraw)
	queue_redraw()


## Half-extent of the drawn field, in parsecs. Mirrors `GalaxyGenerator.GALAXY_RADIUS`:
## every planet sits inside this disk, so this is the span the grid has to cover.
const WORLD_SIZE := GalaxyGenerator.GALAXY_RADIUS * 1.1

## Grid pitch. The field is fifty times wider than the old galactic disk, so the old
## 200-unit pitch would draw 60 lines across the viewport and read as a solid mesh.
const GRID_STEP := 1000.0

## Glyph for a body the player has not surveyed: a hollow ring, deliberately dimmer and
## flatter than a known world so known space still draws the eye first.
const UNKNOWN_MARKER_RADIUS := 7.0
const UNKNOWN_MARKER_COLOUR := Color(0.42, 0.55, 0.50, 0.55)

## Radius of a planet's disc, and of the star's. A star is drawn larger than any planet so
## the centre of the system reads as the centre.
const STAR_RADIUS := 13.0
const PLANET_RADIUS := 5.5


func _draw() -> void:
	if _controller == null or _controller.galaxy == null:
		return
	var galaxy := _controller.galaxy

	_draw_field()
	_draw_rings()
	_draw_systems(galaxy)
	_draw_fleets(galaxy)
	_draw_order_line(galaxy)


## Faint grid so a panned map still reads as a navigable surface rather than void.
func _draw_field() -> void:
	var half := WORLD_SIZE * 0.5
	var grid := Color(0.05, 0.11, 0.08, 0.35)
	var x := -half
	while x <= half:
		draw_line(Vector2(x, -half), Vector2(x, half), grid, 1.0)
		x += GRID_STEP
	var y := -half
	while y <= half:
		draw_line(Vector2(-half, y), Vector2(half, y), grid, 1.0)
		y += GRID_STEP
	# Crosshair and a guide ring at the galactic centre, sized to the system rather than
	# to the old 120-unit disk so they still sit inside the field.
	draw_line(Vector2(-18.0, 0.0), Vector2(18.0, 0.0), CC2Theme.CYAN_DIM, 1.0)
	draw_line(Vector2(0.0, -18.0), Vector2(0.0, 18.0), CC2Theme.CYAN_DIM, 1.0)
	draw_arc(Vector2.ZERO, 1200.0, 0.0, TAU, 64, Color(0.05, 0.11, 0.08, 0.5), 1.0)


## Orbit rings, drawn under everything. Each planet gets its own ring, and a faint circle
## per ring is what makes the layout read as orbits rather than as scattered dots.
func _draw_rings() -> void:
	var ring := Color(0.07, 0.17, 0.12, 0.5)
	for i in 64:
		draw_arc(Vector2.ZERO, float(i) * WORLD_SIZE * 0.5 / 64.0, 0.0, TAU, 48, ring, 1.0)


## The star, the planets, owner rings and labels.
func _draw_systems(galaxy: GalaxyState) -> void:
	for sys in galaxy.systems:
		var seen := _visible(sys.index)
		var pos := sys.position
		if not seen:
			draw_arc(pos, STAR_RADIUS, 0.0, TAU, 16, UNKNOWN_MARKER_COLOUR, 1.5)
			continue
		_draw_star(sys)
		for p_index in sys.planet_indices:
			var p := galaxy.planet(p_index)
			if p != null:
				_draw_planet(galaxy, p)


func _draw_star(sys: SystemState) -> void:
	var colour := CC2Theme.star_color(sys.star_class)
	# Soft halo, then the core. Two discs read as a star far better than one at this
	# zoom without needing a texture asset.
	draw_circle(sys.position, STAR_RADIUS, Color(colour.r, colour.g, colour.b, 0.16))
	draw_circle(sys.position, STAR_RADIUS * 0.5, colour)
	if _ownership_known(_controller.galaxy, sys):
		var owner_colour := CC2Theme.faction_color(sys.owner)
		draw_arc(sys.position, STAR_RADIUS + 3.0, 0.0, TAU, 24, owner_colour, 1.5)
	if sys.index == _controller.selected_system:
		draw_arc(sys.position, STAR_RADIUS + 6.0, 0.0, TAU, 24, CC2Theme.PHOSPHOR, 1.5)


## One planet.
##
## The fog rule is unchanged from when stars were the only markers: unless the player owns
## this world or has surveyed it, it draws as a neutral hollow ring with no class colour,
## no owner ring and no colony tick. That is the same bar the star markers already met, so
## making planets the clickable thing did not loosen it.
func _draw_planet(galaxy: GalaxyState, p: PlanetState) -> void:
	var known := p.surveyed or _ownership_known(galaxy, _system_of(galaxy, p))
	var pos := p.position
	if not known:
		draw_arc(pos, UNKNOWN_MARKER_RADIUS, 0.0, TAU, 16, UNKNOWN_MARKER_COLOUR, 1.5)
		return

	var colour := CC2Theme.planet_color(p.type_id) if p.type_id != &"" else CC2Theme.WHITE_DIM
	draw_circle(pos, PLANET_RADIUS, Color(colour.r, colour.g, colour.b, 0.18))
	draw_circle(pos, PLANET_RADIUS * 0.55, colour)

	# An owned world gets a filled owner ring and a colony tick, because "is that mine" is
	# the one question the map has to answer without being asked.
	if p.owner == _controller.player_id and p.colonized:
		draw_arc(pos, PLANET_RADIUS + 2.5, 0.0, TAU, 18, CC2Theme.faction_color(p.owner), 1.5)
		draw_circle(pos, PLANET_RADIUS * 0.24, CC2Theme.faction_color(p.owner))
	elif _ownership_known(galaxy, _system_of(galaxy, p)) and p.colonized:
		# Somebody else's colony: a thin ring, no fill, so it is visible without shouting.
		draw_arc(pos, PLANET_RADIUS + 2.5, 0.0, TAU, 18, CC2Theme.faction_color(p.owner), 1.0)

	if p.index == _controller.selected_planet:
		draw_arc(pos, PLANET_RADIUS + 6.0, 0.0, TAU, 20, CC2Theme.PHOSPHOR, 1.5)
	elif p.index == _hover:
		draw_arc(pos, PLANET_RADIUS + 5.0, 0.0, TAU, 20, CC2Theme.WHITE_DIM, 1.0)

	if _label_worth_drawing(galaxy, p):
		var font := ThemeDB.fallback_font
		var label := planet_label(p)
		# No backing plate. The dark rectangle that used to sit behind this text was
		# drawn from the string's measured size offset by a fixed 2px, which put it
		# beside the label rather than under it -- a black box floating to the right of
		# every named marker. It existed to guarantee contrast over a bright marker,
		# which is not a problem at this font size on the dark map field.
		draw_string(
			font, pos + Vector2(9.0, -6.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1,
			CC2Theme.FONT_TINY, CC2Theme.WHITE_DIM
		)


## Which system a planet orbits in, or -1.
func _system_of(galaxy: GalaxyState, p: PlanetState) -> SystemState:
	for sys in galaxy.systems:
		if sys.planet_indices.has(p.index):
			return sys
	return null


## A planet's display name. Falls back to the catalogue designation, which is unique by
## construction, so an unnamed body is still identifiable rather than a row of blanks.
func planet_label(p: PlanetState) -> String:
	if p.name != "":
		return p.name
	return "P-%d" % (p.index + 1)


## Names get expensive to read once a hundred bodies are on screen, so only label the
## ones the player can act on or is looking at.
func _label_worth_drawing(galaxy: GalaxyState, p: PlanetState) -> bool:
	if p.index == _controller.selected_planet:
		return true
	return p.owner == _controller.player_id


## Fleet markers. Travelling fleets are drawn at their interpolated position with a
## heading tick, so a multi-turn move is legible without any animation.
func _draw_fleets(galaxy: GalaxyState) -> void:
	var font := ThemeDB.fallback_font
	for key in galaxy.fleets:
		var f: FleetState = galaxy.fleets[key]
		if not f.active:
			continue
		var mine := f.owner == _controller.player_id
		# An enemy fleet is only drawn where a sensor sweep would actually find it.
		#
		# This was the largest hole in the fog: every star was correctly hidden and every
		# owner ring correctly suppressed, while a diamond was still drawn on the map for
		# every fleet of every empire, stationary or in transit, anywhere on the board --
		# which is not a scout's snapshot but the opponent's entire deployment, free.
		if not mine and not _fleet_visible(galaxy, f):
			continue
		var here := _fleet_position(galaxy, f)
		var colour := CC2Theme.faction_color(f.owner) if mine else CC2Theme.WHITE_DIM
		var radius := 4.0 if mine else 3.0

		# Diamond marker — distinct from the circular star glyph at any zoom.
		var pts := PackedVector2Array([
			here + Vector2(0.0, -radius * 1.6),
			here + Vector2(radius * 1.6, 0.0),
			here + Vector2(0.0, radius * 1.6),
			here + Vector2(-radius * 1.6, 0.0),
		])
		if mine:
			draw_colored_polygon(pts, colour)
		else:
			draw_polyline(pts + PackedVector2Array([pts[0]]), colour, 1.0)

		if f.destination >= 0:
			var dest := galaxy.planet(f.destination)
			if dest != null:
				# Dashed line to the target plus a small arrowhead showing direction.
				draw_dashed_line(here, dest.position, Color(colour.r, colour.g, colour.b, 0.7), 1.0)
				var dir := (dest.position - here).normalized()
				var tip := dest.position - dir * 7.0
				var perp := Vector2(-dir.y, dir.x) * 3.5
				draw_colored_polygon(
					PackedVector2Array([dest.position - dir * 2.0, tip + perp, tip - perp]),
					colour
				)
			# Progress readout on the first travelling fleet only, to avoid label pileup.
			if mine and f.id == _controller.selected_fleet:
				var pct := int(round(_travel_fraction(galaxy, f) * 100.0))
				draw_string(
					font, here + Vector2(8.0, 14.0), "%d%%" % pct,
					HORIZONTAL_ALIGNMENT_LEFT, -1, CC2Theme.FONT_SMALL, CC2Theme.CYAN
				)

		if f.id == _controller.selected_fleet:
			draw_arc(here, 11.0, 0.0, TAU, 20, CC2Theme.PHOSPHOR, 1.5)


## The cyan line drawn from the selected fleet to a star the player has clicked as a
## destination — the visible confirmation that a move order has been staged.
func _draw_order_line(galaxy: GalaxyState) -> void:
	var f := _controller.fleet()
	if f == null or f.destination < 0:
		return
	var dest := galaxy.planet(f.destination)
	if dest == null:
		return
	var origin := galaxy.planet(f.system)
	if origin == null:
		return
	var colour := CC2Theme.CYAN
	draw_dashed_line(origin.position, dest.position, Color(colour.r, colour.g, colour.b, 0.9), 2.0)
	var dir := (dest.position - origin.position).normalized()
	var tip := origin.position + dir * 26.0
	var perp := Vector2(-dir.y, dir.x) * 5.0
	draw_colored_polygon(PackedVector2Array([tip + dir * 9.0, tip + perp, tip - perp]), colour)


## Interpolated map position of a fleet, which may be between planets.
func _fleet_position(galaxy: GalaxyState, f: FleetState) -> Vector2:
	var here := galaxy.planet(f.system)
	if here == null:
		return Vector2.ZERO
	if f.destination < 0:
		return here.position
	var dest := galaxy.planet(f.destination)
	if dest == null:
		return here.position
	return here.position.lerp(dest.position, clampf(_travel_fraction(galaxy, f), 0.0, 1.0))


## How far along its journey a fleet is. `travelled` accumulates distance, and the stage
## derives the leg length from the same `orbit_distance` the movement code uses.
func _travel_fraction(galaxy: GalaxyState, f: FleetState) -> float:
	var here := galaxy.planet(f.system)
	var dest := galaxy.planet(f.destination)
	if here == null or dest == null:
		return 0.0
	var leg := MovementStage.orbit_distance(here, dest)
	if leg <= 0.0:
		return 1.0
	return clampf(f.travelled / leg, 0.0, 1.0)


## Whether a fleet the player does not own is on the map at all.
##
## An enemy fleet parked on a world is spotted by that world's sensor sweep, and one
## under way is spotted only while it is physically inside an orbit the player can see --
## between two planets it belongs to nobody's sensors, so it is not drawn there either.
func _fleet_visible(galaxy: GalaxyState, f: FleetState) -> bool:
	if f.system >= 0 and _planet_visible(galaxy, f.system):
		return true
	return f.destination >= 0 and _planet_visible(galaxy, f.destination)


## Whether the player can see the world a fleet is sitting on.
func _planet_visible(galaxy: GalaxyState, planet_index: int) -> bool:
	var p := galaxy.planet(planet_index)
	if p == null:
		return false
	if p.surveyed:
		return true
	var sys := _system_of(galaxy, p)
	return sys != null and _visible(sys.index)


## Whether this player is entitled to see who owns `sys`.
##
## Delegates to `SessionController.knows_owner_of`, which is where the rule is written
## down. The map was the only place that consulted it, which is precisely how the map
## could be clean while the inspector printed `OWNER FACTION 3` for the same system.
func _ownership_known(galaxy: GalaxyState, sys: SystemState) -> bool:
	if galaxy == null or sys == null or _controller == null:
		return false
	return _controller.knows_owner_of(sys.index)


## Whether the player can see a system right now.
func _visible(index: int) -> bool:
	return FowStage.can_see(_controller.galaxy, _controller.player_id, index)


## Nearest body -- planet first, then the star -- to a point in galaxy coordinates.
##
## Planets are checked first because they are what the player clicks now, and a click near
## the star is more likely to mean the world next to it than the star itself. Returns -1
## when nothing is close enough. Radius is in galaxy units so the pick feels the same at
## every zoom level once the camera transform is undone by the caller.
func pick(galaxy_pos: Vector2, radius: float = 18.0) -> int:
	if _controller == null or _controller.galaxy == null:
		return -1
	var best := -1
	var best_dist := radius
	for sys in _controller.galaxy.systems:
		for p_index in sys.planet_indices:
			var p := _controller.galaxy.planet(p_index)
			if p == null:
				continue
			var d := p.position.distance_to(galaxy_pos)
			if d < best_dist:
				best_dist = d
				best = p.index
	# The star is the fallback: only wins when no planet is inside the radius.
	for sys in _controller.galaxy.systems:
		var d := sys.position.distance_to(galaxy_pos)
		if d < best_dist:
			best_dist = d
			best = sys.index
	return best


## Update the hover highlight, in galaxy coordinates.
func set_hover(index: int) -> void:
	if _hover != index:
		_hover = index
		queue_redraw()


func hover() -> int:
	return _hover


## Convert a point in this control's local space to galaxy coordinates.
func to_galaxy(local: Vector2) -> Vector2:
	return local - size * 0.5

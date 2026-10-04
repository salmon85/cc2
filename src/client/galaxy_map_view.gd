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


## Galaxy radius used to scale the star field into the viewport. The generator lays
## systems out in roughly [-R, R] on both axes; leaving generous margin stops edge stars
## from being cut off at the default zoom.
const WORLD_SIZE := 2200.0

## Glyph for a star the player has not surveyed: a hollow ring, deliberately dimmer and
## flatter than a known star so known space still draws the eye first.
const UNKNOWN_MARKER_RADIUS := 7.0
const UNKNOWN_MARKER_COLOUR := Color(0.42, 0.55, 0.50, 0.55)


func _draw() -> void:
	if _controller == null or _controller.galaxy == null:
		return
	var galaxy := _controller.galaxy

	_draw_field()
	_draw_lanes(galaxy)
	_draw_systems(galaxy)
	_draw_fleets(galaxy)
	_draw_order_line(galaxy)


## Faint grid so a panned map still reads as a navigable surface rather than void.
func _draw_field() -> void:
	var half := WORLD_SIZE * 0.5
	var step := 200.0
	var grid := Color(0.05, 0.11, 0.08, 0.35)
	var x := -half
	while x <= half:
		draw_line(Vector2(x, -half), Vector2(x, half), grid, 1.0)
		x += step
	var y := -half
	while y <= half:
		draw_line(Vector2(-half, y), Vector2(half, y), grid, 1.0)
		y += step
	# Crosshair at the galactic centre.
	draw_line(Vector2(-18.0, 0.0), Vector2(18.0, 0.0), CC2Theme.CYAN_DIM, 1.0)
	draw_line(Vector2(0.0, -18.0), Vector2(0.0, 18.0), CC2Theme.CYAN_DIM, 1.0)
	draw_arc(Vector2.ZERO, 120.0, 0.0, TAU, 48, Color(0.05, 0.11, 0.08, 0.5), 1.0)


## Known warp lanes, drawn under the stars so the network reads as background.
func _draw_lanes(galaxy: GalaxyState) -> void:
	var colour := Color(0.13, 0.34, 0.24, 0.55)
	var hidden := Color(0.05, 0.09, 0.08, 0.35)
	for sys in galaxy.systems:
		if not _visible(sys.index):
			draw_dashed_line(sys.position, sys.position, hidden, 1.0)
			continue
		for other_index in sys.warp_lanes:
			# Lanes are stored on both ends; only draw from the lower index so each
			# connection is painted once rather than twice at full opacity.
			if other_index <= sys.index:
				continue
			var other := galaxy.system(other_index)
			if other == null or not _visible(other_index):
				continue
			draw_line(sys.position, other.position, colour, 1.0)


## Stars: spectral-class coloured discs, owner rings, labels.
func _draw_systems(galaxy: GalaxyState) -> void:
	for sys in galaxy.systems:
		var seen := _visible(sys.index)
		var pos := sys.position

		# Unknown systems are shown as an anonymous hollow marker so unexplored space is
		# still navigable by shape, without leaking spectral class or ownership.
		#
		# The radius and alpha here are deliberately generous. Sensor ranges are a couple of
		# parsecs against a galaxy spanning hundreds, so nearly every system starts out
		# unsurveyed; a hairline ring left the map reading as an empty black field. These
		# markers sit clearly behind known stars in brightness and carry no class colour,
		# so the fog-of-war rule still holds -- you can see that a star is there, not what
		# it is.
		if not seen:
			draw_arc(pos, UNKNOWN_MARKER_RADIUS, 0.0, TAU, 16, UNKNOWN_MARKER_COLOUR, 1.5)
			continue

		var colour := CC2Theme.star_color(sys.star_class)
		# Soft halo, then the core. Two discs read as a star far better than one at this
		# zoom without needing a texture asset.
		draw_circle(pos, 9.0, Color(colour.r, colour.g, colour.b, 0.16))
		draw_circle(pos, 4.5, colour)

		if sys.owner >= 0:
			# Owner ring in the faction colour; the player's own systems get the bright
			# phosphor variant so the home territory reads instantly.
			var owner_colour := CC2Theme.faction_color(sys.owner)
			draw_arc(pos, 8.0, 0.0, TAU, 20, owner_colour, 1.5)

		if sys.index == _controller.selected_system:
			draw_arc(pos, 14.0, 0.0, TAU, 24, CC2Theme.PHOSPHOR, 1.5)
		elif sys.index == _hover:
			draw_arc(pos, 12.0, 0.0, TAU, 20, CC2Theme.WHITE_DIM, 1.0)

		# Label at a fixed galaxy-space size: it stays legible when zoomed in and stops
		# cluttering when zoomed out.
		if _label_worth_drawing(galaxy, sys):
			var font := ThemeDB.fallback_font
			var label := sys.name if sys.name != "" else "SYS %d" % sys.index
			var size := font.get_string_size(
				label, HORIZONTAL_ALIGNMENT_LEFT, -1, CC2Theme.FONT_SMALL
			)
			var at := pos + Vector2(11.0, -8.0)
			# Dark plate behind the text: the map has no guaranteed background contrast
			# where a label crosses a bright star or a lane.
			draw_rect(
				Rect2(at - Vector2(2.0, 2.0), size + Vector2(4.0, 4.0)),
				Color(0.0, 0.0, 0.0, 0.65)
			)
			draw_string(
				font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, CC2Theme.FONT_SMALL,
				CC2Theme.WHITE_DIM
			)


## Names get expensive to read once a hundred systems are on screen, so only label the
## ones the player can act on or is looking at.
func _label_worth_drawing(galaxy: GalaxyState, sys: SystemState) -> bool:
	if sys.index == _controller.selected_system:
		return true
	if sys.owner == _controller.player_id:
		return true
	for p_index in sys.planet_indices:
		var p := galaxy.planet(p_index)
		if p != null and p.owner == _controller.player_id and p.colonized:
			return true
	return false


## Fleet markers. Travelling fleets are drawn at their interpolated position with a
## heading tick, so a multi-turn move is legible without any animation.
func _draw_fleets(galaxy: GalaxyState) -> void:
	var font := ThemeDB.fallback_font
	for key in galaxy.fleets:
		var f: FleetState = galaxy.fleets[key]
		if not f.active:
			continue
		var here := _fleet_position(galaxy, f)
		var mine := f.owner == _controller.player_id
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
			var dest := galaxy.system(f.destination)
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
	var dest := galaxy.system(f.destination)
	if dest == null:
		return
	var origin := galaxy.system(f.system)
	if origin == null:
		return
	var colour := CC2Theme.CYAN
	draw_dashed_line(origin.position, dest.position, Color(colour.r, colour.g, colour.b, 0.9), 2.0)
	var dir := (dest.position - origin.position).normalized()
	var tip := origin.position + dir * 26.0
	var perp := Vector2(-dir.y, dir.x) * 5.0
	draw_colored_polygon(PackedVector2Array([tip + dir * 9.0, tip + perp, tip - perp]), colour)


## Interpolated map position of a fleet, which may be between systems.
func _fleet_position(galaxy: GalaxyState, f: FleetState) -> Vector2:
	var here := galaxy.system(f.system)
	if here == null:
		return Vector2.ZERO
	if f.destination < 0:
		return here.position
	var dest := galaxy.system(f.destination)
	if dest == null:
		return here.position
	return here.position.lerp(dest.position, clampf(_travel_fraction(galaxy, f), 0.0, 1.0))


## How far along its journey a fleet is. `travelled` accumulates distance, and the stage
## derives the leg length from the same `distance_to` the movement code uses.
func _travel_fraction(galaxy: GalaxyState, f: FleetState) -> float:
	var here := galaxy.system(f.system)
	var dest := galaxy.system(f.destination)
	if here == null or dest == null:
		return 0.0
	var leg := here.distance_to(dest)
	if leg <= 0.0:
		return 1.0
	return clampf(f.travelled / leg, 0.0, 1.0)


## Whether the player can see a system right now.
func _visible(index: int) -> bool:
	return FowStage.can_see(_controller.galaxy, _controller.player_id, index)


## Nearest system to a point in galaxy coordinates, within `radius`.
##
## Returns -1 when nothing is close enough. Radius is in galaxy units so the pick feels the
## same at every zoom level once the camera transform is undone by the caller.
func pick(galaxy_pos: Vector2, radius: float = 18.0) -> int:
	if _controller == null or _controller.galaxy == null:
		return -1
	var best := -1
	var best_dist := radius
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

extends Control
class_name GalaxyMapView
## Pure drawing layer for the galaxy map.
##
## Holds no state beyond its controller: every frame it re-reads the galaxy and repaints.
## That is cheap enough at this scale (hundreds of systems, a handful of draw calls each)
## and it means the view can never drift out of sync with the model.
##
## All drawing is done in the node's own coordinates, which is galaxy coordinates shifted so
## the SubViewport's centre lands on the star; the parent hosts this inside a SubViewport so
## the Camera2D handles zoom and pan without any transform maths here.

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


## Half-extent of the drawn field, in parsecs, as a multiple of the game's own radius.
##
## Every planet sits inside the generator's disk, so this is the span the backdrop and the
## bounds frame have to cover. The factor rather than the absolute value because
## `--map-size` makes the radius a per-game choice.
const WORLD_FACTOR := 1.1

## The half-extent actually drawn for a galaxy.
func world_size(galaxy: GalaxyState) -> float:
	var radius := GalaxyGenerator.GALAXY_RADIUS
	if galaxy != null:
		radius = galaxy.radius()
	return radius * WORLD_FACTOR

## The playable field is deep space, so it is drawn black.
##
## The theme's `BG` carries a green cast for the surrounding CRT chrome. Carrying that
## into the map made the field read as a lit surface with objects on it rather than as
## vacuum with objects in it, and the green tint also leaked into the planet colours by
## contrast -- a white planet on green reads as mint. Pure black is the correct backdrop
## for both, and it is what makes the amber/phosphor accents carry.
const FIELD_COLOUR := Color(0.0, 0.0, 0.0, 1.0)

## The bounds indicator: a hairline frame around the playable area, so "where does the
## system end" is answerable at a glance rather than by panning until the planets stop.
const BOUNDS_COLOUR := Color(1.0, 1.0, 1.0, 0.55)
const BOUNDS_WIDTH := 3.0

## How far outside the outermost planet the frame sits, as a fraction of the half-extent.
## A border drawn exactly on the outer ring would be hidden under the planets sitting on
## it, so it is pushed out to leave the edge of the system legible as empty space.
const BOUNDS_PAD := 1.04

## Glyph for a body the player has not surveyed: a hollow ring, deliberately dimmer and
## flatter than a known world so known space still draws the eye first.
const UNKNOWN_MARKER_RADIUS := 7.0
const UNKNOWN_MARKER_COLOUR := Color(0.42, 0.55, 0.50, 0.55)

## How close, in galaxy units, a click has to be to count as hitting a body.
##
## A named constant because it is the yardstick the hit-testing tolerance is measured
## against: a transform can be wrong by less than this and still select the intended
## planet, which is how an approximate inverse passes a "does it pick the right one" test.
const PICK_RADIUS := 18.0

## Radius of a planet's disc, and of the star's. A star is drawn larger than any planet so
## the centre of the system reads as the centre.
const STAR_RADIUS := 13.0
const PLANET_RADIUS := 5.5


## The backdrop: a flat black field with a crosshair at the star.
##
## The grid and the concentric orbit rings that used to be here were both removed. The
## rings were the explicit ask, and they were doing the grid's job too -- at sixty-four
## circles over a field fifty times wider than the old disk, they read as a bullseye
## behind every object rather than as the orbits they were meant to depict. Nothing was
## lost by dropping both: the planets already sit at their orbital radii, so the layout is
## still legible, and without a mesh behind them the markers are the only thing on screen.
func _draw_field(galaxy: GalaxyState) -> void:
	var w := world_size(galaxy)
	draw_rect(Rect2(-w, -w, w * 2.0, w * 2.0), FIELD_COLOUR)
	# Crosshair at the star, sized to the system rather than to the old 120-unit disk.
	draw_line(Vector2(-18.0, 0.0), Vector2(18.0, 0.0), CC2Theme.CYAN_DIM, 1.0)
	draw_line(Vector2(0.0, -18.0), Vector2(0.0, 18.0), CC2Theme.CYAN_DIM, 1.0)


## The bounds indicator: a rectangular frame around the whole playable area.
##
## Drawn as a rectangle rather than a circle around the star because the playable area is
## the square the generator lays planets inside, and a circle would cut off the corners a
## planet at maximum inclination actually occupies -- telling the player the corner is
## out of bounds when it is not.
func _draw_bounds(galaxy: GalaxyState) -> void:
	var r := world_rect(galaxy)
	var lo := r.position
	var hi := r.end
	draw_line(lo, Vector2(hi.x, lo.y), BOUNDS_COLOUR, BOUNDS_WIDTH)
	draw_line(Vector2(hi.x, lo.y), hi, BOUNDS_COLOUR, BOUNDS_WIDTH)
	draw_line(hi, Vector2(lo.x, hi.y), BOUNDS_COLOUR, BOUNDS_WIDTH)
	draw_line(Vector2(lo.x, hi.y), lo, BOUNDS_COLOUR, BOUNDS_WIDTH)


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


## The placeholder shown in place of a world the player has not named.
##
## An alias for the controller's constant rather than a second copy of it. The two were
## separate strings that happened to agree, which is exactly the arrangement that survives
## until one of them is edited.
const UNKNOWN_NAME := SessionController.UNKNOWN_NAME


## A planet's display name, or the placeholder when the player is not entitled to it.
##
## The name is filtered, not just the economy. It is the one identifier the player uses to
## refer to a place, so a map that named every rival world would be handing over a survey
## nobody performed -- and unlike the economy it is *free* to withhold, since an unnamed
## world is still perfectly clickable.
##
## Note this is the *eligibility* half only. It says what the world would be called if it
## were named on screen; whether a label is drawn at all is `_label_worth_drawing`'s call,
## and the two are deliberately different questions.
func planet_label(p: PlanetState) -> String:
	if _controller == null:
		return UNKNOWN_NAME
	return _controller.display_name(p.index)


## Whether this planet gets a name drawn beside it.
##
## Deliberately the same bar as `SessionController.knows_name_of` -- owned, or one of the
## player's own fleets parked in orbit -- and no looser. A selected body is *not* an
## exception: selecting a world is a camera and inspector action, and honouring it here
## would hand out the name of every rival planet the player ever clicked on, which is a
## quicker route to the same leak than scanning the board ever was.
##
## What remains is the whole visible map. Everything else draws as an unnamed marker.
func _label_worth_drawing(galaxy: GalaxyState, p: PlanetState) -> bool:
	return label_worth_drawing(p)


## Public form of the label rule, so the test exercises the decision itself rather than
## parsing the source for it.
##
## The duplication is deliberate and one-directional: `_draw_planet` calls this, and the
## test calls this, so there is a single implementation that both the drawing and the test
## go through. A test that greps the source for a string only proves the string is there.
func label_worth_drawing(p: PlanetState) -> bool:
	return _controller != null and _controller.knows_name_of(p.index)


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
func pick(galaxy_pos: Vector2, radius: float = PICK_RADIUS) -> int:
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
## The pick radius, so a test can measure transform error against it rather than against a
## tolerance it picked to match the bug it was written after.
func pick_radius() -> float:
	return PICK_RADIUS


func set_hover(index: int) -> void:
	if _hover != index:
		_hover = index
		queue_redraw()


func hover() -> int:
	return _hover


# --- Culling ---------------------------------------------------------------

## Why the draw layer needs a custom rect at all.
##
## A `Control`'s own rect is what the renderer uses to decide whether to draw it at all.
## Left alone, a rectless `Control` laid out at `PRESET_FULL_RECT` reports a
## zero-minimum-size rect that its own `_draw` immediately draws far outside of, so the
## first frame the camera is offset by anything at all the whole layer is culled -- and
## every marker, the backdrop and the bounds frame go with it. That is the "map vanishes
## when I pan" report: the map is not being hidden, it is being skipped.
##
## Setting a custom rect tells the renderer where the drawing actually goes, so the cull
## follows the world rather than the widget.
func _apply_custom_rect() -> void:
	if not is_inside_tree() or _controller == null or _controller.galaxy == null:
		return
	# A generous margin over the drawn field: the field is square and the rect is square,
	# but stroke widths, line caps and the float rounding in the camera transform all reach
	# a few pixels past it, and a cull that is a hair too tight is invisible until the day it
	# is not.
	#
	# This follows the galaxy rather than being fixed at build time, because the field is
	# sized from the map radius -- a per-game property now that `--map-size` can pick it. A
	# rect sized once would enclose a `tiny` map and cull half of an `extreme` one.
	var w := world_size(_controller.galaxy) * BOUNDS_PAD * 1.1 + 64.0
	# The Godot 4 signature is (item, enable, rect). Passing the rect as the second
	# argument type-checks in neither direction, so the enable flag is not optional here
	# even though it looks like the rect is the payload.
	RenderingServer.canvas_item_set_custom_rect(
		get_canvas_item(), true, Rect2(-w, -w, w * 2.0, w * 2.0)
	)


func _draw() -> void:
	_apply_custom_rect()
	if _controller == null or _controller.galaxy == null:
		return
	var galaxy := _controller.galaxy

	_draw_field(galaxy)
	_draw_bounds(galaxy)
	_draw_systems(galaxy)
	_draw_fleets(galaxy)
	_draw_order_line(galaxy)


## The half-extent of the drawn field in *this node's own* coordinates, which are
## `GalaxyMapView` coordinates -- the galaxy coordinates shifted so the viewport's centre
## lands on the star.
func world_rect(galaxy: GalaxyState) -> Rect2:
	var w := world_size(galaxy) * BOUNDS_PAD
	return Rect2(-w, -w, w * 2.0, w * 2.0)

extends Control
class_name GalaxyMap
## The galaxy map: a SubViewport holding a Camera2D and a `GalaxyMapView` draw layer.
##
## Zoom and pan are the camera's job, which keeps the view layer in plain galaxy
## coordinates. This node owns only interaction: wheel zoom, middle/right-drag pan, left
## click to select a system, and click-with-a-fleet-selected to stage a move.

## Emitted when a system is picked with the left button.
signal system_picked(system_index: int)

## Emitted when a planet is clicked, with its galaxy index. Planets are the map's primary
## selectable objects; `system_picked` now fires only for the star.
signal planet_picked(planet_index: int)

## Emitted when empty space is picked.
signal background_picked

## Emitted with an error string when an interaction is refused.
signal interaction_refused(reason: String)

## Emitted when the player commits the turn with the keyboard.
##
## The END TURN button was removed: a networked player commits by pressing READY. Single
## player has no lobby and therefore no READY, so the map keeps the keyboard route — the
## one place a player is already looking when they want to advance.
signal end_turn_requested

## The field is fifty times wider than it was, so the fit zoom had to drop by roughly the
## same factor to keep the whole system on screen at startup. The old floor of 0.35 would
## put the camera nine thousand parsecs out for a 6000-parsec system.
const MIN_ZOOM := 0.007
const MAX_ZOOM := 0.6
const ZOOM_STEP := 1.15
const PAN_BUTTON := MOUSE_BUTTON_MIDDLE

## Smallest usable map area. Below this the control has not been laid out yet, and any
## framing computed against it is meaningless -- see `frame_galaxy`.
const MIN_AREA := 8.0

## Mirrors `GalaxyGenerator.GALAXY_RADIUS`: the system is laid out inside this disk, so it
## is the half-extent the initial camera has to frame. Fifty times the old value, because
## the old figure framed a whole galaxy and this frames one star's neighbourhood.
const GALAXY_RADIUS := GalaxyGenerator.GALAXY_RADIUS

## Slack left around the disk when fitting, so edge systems are not flush against the
## panel border and the crosshair still reads as the galactic centre.
const FIT_MARGIN := 1.25

var _controller: SessionController = null
var _view: GalaxyMapView = null
var _sub_viewport: SubViewport = null
var _container: SubViewportContainer = null
var _camera: Camera2D = null

## Set once the player zooms or pans by hand. Auto-framing on resize only applies while
## this is false, so a window resize never yanks a view the player deliberately framed.
var _user_framed := false

var _panning := false
var _last_mouse := Vector2.ZERO
## Set between a press and its release: a drag pans, a click selects.
var _drag_distance := 0.0
var _pressed_mouse := Vector2.ZERO

## True while the player is holding the modifier that stages move orders instead of
## selecting. Held rather than toggled so a stray click never silently re-targets a fleet.
var _order_mode := false


func _ready() -> void:
	theme = CC2Theme.build()
	clip_contents = true
	custom_minimum_size = Vector2(320, 240)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL

	_build()


func _build() -> void:
	# The SubViewport must be hosted by a SubViewportContainer: a bare SubViewport child
	# of a Control renders to its own target but nothing ever presents that target, so
	# the map area stays empty. `stretch` lets the container drive the size from its own
	# rect, which is what keeps the camera 1:1 with the visible area.
	_container = SubViewportContainer.new()
	_container.stretch = true
	_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_container)

	_sub_viewport = SubViewport.new()
	_sub_viewport.disable_3d = true
	_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub_viewport.transparent_bg = false
	_sub_viewport.size = Vector2i(640, 480)
	_container.add_child(_sub_viewport)

	_view = GalaxyMapView.new()
	# The view is centred on the origin in its SubViewport, so galaxy coordinate (0,0)
	# lands in the middle of the visible area.
	_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sub_viewport.add_child(_view)

	_camera = Camera2D.new()
	_camera.enabled = true
	_camera.position = Vector2.ZERO
	_camera.zoom = Vector2.ONE
	_sub_viewport.add_child(_camera)

	_view.system_clicked.connect(_on_view_system_clicked)
	_view.background_clicked.connect(func() -> void: background_picked.emit())
	gui_input.connect(_on_gui_input)
	# The map has no area until the first layout pass, so framing rides on the deferred
	# call below and on `resized`.
	resized.connect(_on_resized)


func bind(controller: SessionController) -> void:
	_controller = controller
	if _controller == null:
		return
	_view.bind(controller)
	# The map is unusable until it is framed: an unfitted camera leaves the player staring
	# at empty space because systems are small relative to the viewport. `bind()` runs
	# before the container has laid this node out, so the fit is deferred to a frame when
	# there is a real area to fit into.
	frame_galaxy.call_deferred()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_view.set_hover(-1)


# --- Input -----------------------------------------------------------------

func _on_gui_input(event: InputEvent) -> void:
	if _controller == null or _controller.galaxy == null:
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(mb.position, ZOOM_STEP)
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(mb.position, 1.0 / ZOOM_STEP)
			accept_event()
			return
		if mb.button_index == PAN_BUTTON or (
				mb.button_index == MOUSE_BUTTON_RIGHT):
			_panning = mb.pressed
			_last_mouse = mb.position
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_pressed_mouse = mb.position
				_drag_distance = 0.0
			else:
				if _drag_distance < 6.0:
					_click_at(mb.position)
				accept_event()
			return

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_drag_distance = maxf(_drag_distance, mm.position.distance_to(_pressed_mouse))
		if _panning:
			_user_framed = true
			_camera.position -= mm.relative / _camera.zoom.x
			accept_event()
			return
		# Hover highlight in galaxy coordinates: undo the camera transform and the
		# view's centring offset.
		var gal := _to_galaxy(mm.position)
		_view.set_hover(_view.pick(gal))
		accept_event()


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed():
		return
	var key := event as InputEventKey
	# Space commits the turn. Checked before the camera bindings so it does not also
	# pan, and not gated on `_user_framed` because committing has nothing to do with
	# framing the view.
	if key.keycode == KEY_SPACE or key.keycode == KEY_ENTER:
		accept_event()
		end_turn_requested.emit()
		return
	_user_framed = true
	var step := 80.0 / _camera.zoom.x
	match key.keycode:
		KEY_LEFT, KEY_A:
			_camera.position.x -= step
		KEY_RIGHT, KEY_D:
			_camera.position.x += step
		KEY_UP, KEY_W:
			_camera.position.y -= step
		KEY_DOWN, KEY_S:
			_camera.position.y += step
		KEY_HOME:
			_camera.position = Vector2.ZERO
		KEY_EQUAL, KEY_KP_ADD:
			_zoom_at(get_rect().size * 0.5, ZOOM_STEP)
		KEY_MINUS, KEY_KP_SUBTRACT:
			_zoom_at(get_rect().size * 0.5, 1.0 / ZOOM_STEP)
		_:
			return
	accept_event()


## Zoom while keeping the galaxy point under `screen_pos` fixed on screen.
##
## A naive `camera.zoom *= k` drifts towards the top-left, which makes precise inspection
## of a star frustrating; anchoring at the cursor is the behaviour players expect.
func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	_user_framed = true
	var before := _to_galaxy(screen_pos)
	var next := clampf(_camera.zoom.x * factor, MIN_ZOOM, MAX_ZOOM)
	if is_equal_approx(next, _camera.zoom.x):
		return
	_camera.zoom = Vector2(next, next)
	var after := _to_galaxy(screen_pos)
	_camera.position += before - after


## Map a point in this Control to galaxy coordinates.
func _to_galaxy(screen_pos: Vector2) -> Vector2:
	var centre := get_rect().size * 0.5
	return (screen_pos - centre) / _camera.zoom.x + _camera.position


## Route a click: to a planet's owner as a move destination if a fleet is selected and
## the shift key is held, otherwise to selection.
##
## `GalaxyMapView.pick` returns whatever is under the cursor, which is now a *planet* index
## for every body and the star's system index only when the star itself was hit. A star is
## not a move destination -- there is nowhere to put a fleet that is not a planet -- so a
## click on it always selects rather than staging an order.
func _click_at(screen_pos: Vector2) -> void:
	var gal := _to_galaxy(screen_pos)
	var hit: int = _view.pick(gal)
	if hit < 0:
		# Clicking empty space with no intent deselects the fleet, which is the fastest
		# way out of order mode.
		interaction_refused.emit("empty space")
		background_picked.emit()
		return

	if _is_planet(hit) and (_order_mode or Input.is_key_pressed(KEY_SHIFT)):
		var f := _controller.fleet()
		if f == null:
			interaction_refused.emit("select a fleet before issuing a move")
			planet_picked.emit(hit)
			return
		if not _controller.queue_move(hit):
			# The controller has already explained the refusal; mirror it once so the
			# map is not silently unresponsive.
			interaction_refused.emit("move refused")
			return
		planet_picked.emit(hit)
		return

	if _is_planet(hit):
		planet_picked.emit(hit)
		_controller.select_planet(hit)
		return

	system_picked.emit(hit)
	_controller.select_system(hit)


## Whether a pick index refers to a planet rather than to the star.
func _is_planet(index: int) -> bool:
	return _controller != null and _controller.galaxy != null \
		and _controller.galaxy.planet(index) != null


func _on_view_system_clicked(index: int) -> void:
	system_picked.emit(index)


# --- Accessors used by the root and by the GUI test -------------------------

func view() -> GalaxyMapView:
	return _view


func camera() -> Camera2D:
	return _camera


func sub_viewport() -> SubViewport:
	return _sub_viewport


## Toggle the "next click stages a move order" modifier.
func set_order_mode(on: bool) -> void:
	_order_mode = on


func order_mode() -> bool:
	return _order_mode


## Programmatic click path, used by the automated GUI test.
func click_at_galaxy(galaxy_pos: Vector2) -> int:
	var centre := get_rect().size * 0.5
	var screen := (galaxy_pos - _camera.position) * _camera.zoom.x + centre
	_click_at(screen)
	return _view.pick(galaxy_pos)


## Centre on the player's home system and zoom so every system is on screen.
##
## Deferring is the important part. The map is bound during session setup, before the
## container has laid it out, so `size` is still zero at that point and the fit collapses
## to zero -- which `clampf` then pins to `MIN_ZOOM`, shrinking the whole galaxy into a
## handful of pixels and leaving the player looking at an empty field. With no usable area
## yet, `resized` calls back in here once there is one.
func frame_galaxy() -> void:
	if _camera == null:
		return
	var visible := get_rect().size
	if visible.x < MIN_AREA or visible.y < MIN_AREA:
		return
	var galaxy := _controller.galaxy if _controller != null else null

	# The star sits at the origin, and every planet orbits it, so the star is always the
	# centre worth framing from. Centring on the player's homeworld instead would push the
	# far side of the system off screen, which is where their own expansion is heading.
	var centre := Vector2.ZERO
	if galaxy != null:
		var star := galaxy.system(0)
		if star != null:
			centre = star.position

	# Fit the *outermost planet* around that centre, not the nominal disk radius: the
	# outermost ring sits at OUTER_ORBIT, so fitting the raw radius would waste a tenth of
	# the viewport on empty space. Camera zoom magnifies, so the fit is the visible area
	# divided by twice the half-extent it has to cover.
	var need_x := GALAXY_RADIUS * GalaxyGenerator.OUTER_ORBIT
	var need_y := need_x
	if galaxy != null:
		need_x = 0.0
		need_y = 0.0
		for p in galaxy.planets:
			need_x = maxf(need_x, absf(p.position.x - centre.x))
			need_y = maxf(need_y, absf(p.position.y - centre.y))
	var zoom := clampf(minf(
		visible.x / (2.0 * need_x * FIT_MARGIN),
		visible.y / (2.0 * need_y * FIT_MARGIN)
	), MIN_ZOOM, MAX_ZOOM)

	_camera.position = centre
	_camera.zoom = Vector2(zoom, zoom)


## Re-frame whenever the map gains area, unless the player has framed it themselves.
func _on_resized() -> void:
	if _user_framed or _controller == null:
		return
	frame_galaxy()


## Position of the player's first colony, or `Vector2.INF` when the player has none.
##
## Kept for the "recentre on my homeworld" affordance. The default framing no longer uses
## it -- the whole system is one star's neighbourhood and a homeworld-centred view would
## show a fragment of it -- but the accessor is still what a caller needs to know where the
## player actually is.
func _home_system() -> Vector2:
	if _controller == null or _controller.galaxy == null:
		return Vector2.INF
	var galaxy := _controller.galaxy
	var colonies := _controller.player_colonies()
	if colonies.is_empty():
		return Vector2.INF
	# A planet carries its own position now, so there is nothing to walk back up to.
	return colonies[0].position


## Drop any manual framing and return to the default: home system centred, whole galaxy
## in view.
func recentre() -> void:
	_user_framed = false
	frame_galaxy()

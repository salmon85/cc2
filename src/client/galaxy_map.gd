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

## Emitted when a destination is *proposed* for the selected fleet, with its planet index.
##
## A proposal is not an order. Phase 8 made the travel modal the whole dispatch surface, so
## a map click no longer opens a CONFIRM / CANCEL prompt of its own: it opens the modal with
## this destination already chosen, and the modal's OK button is the only commit. Nothing is
## queued and the fleet does not move until that happens.
signal order_proposed(planet_index: int)

## Emitted when a proposal is discarded, by the player or by clicking elsewhere.
signal order_cancelled

## Emitted with an error string when an interaction is refused.
signal interaction_refused(reason: String)

## Emitted when the player commits the turn with the keyboard.
##
## The END TURN button was removed: a networked player commits by pressing READY. Single
## player has no lobby and therefore no READY, so the map keeps the keyboard route — the
## one place a player is already looking when they want to advance.
signal end_turn_requested

## Zoom limits, and the asymmetry between them is deliberate.
##
## Smallest useful zoom, as a fraction of the map's own span.
##
## This is a runaway guard, not a framing constraint: `frame_galaxy` computes the zoom
## that fits the whole system, and a floor set *near* that value would clamp the fit and
## leave the far side of the system off screen -- the exact defect this control was
## rewritten to fix. A factor well below the fit lets the fit through and still stops the
## camera being dragged out to where the whole system is a single pixel. It scales with
## the span so a `tiny` map is not floored at a zoom that would fill the screen with its
## own star.
const MIN_ZOOM_FACTOR := 0.01 / 6000.0

## How much of the viewport the smallest allowed zoom must still fill.
##
## The floor is the only zoom at which the player can pull back, so if the map does not fit
## at that zoom then zooming out -- the control a player reaches for on losing track of
## where their empire is -- leaves them looking at an empty field with the galaxy off the
## edge of it. That is worse than being unable to zoom in any further.
##
## Below 1.0, so the outermost planet is not hard against the frame at the minimum; the
## runaway guard's job is to stop the camera being dragged to infinity, not to define the
## framing.
const MIN_ZOOM_FIT_MARGIN := 0.75

## Largest useful zoom, in absolute terms.
##
## Deliberately *not* scaled by the map span. Markers are drawn at a fixed size in galaxy
## units, so what matters is how many pixels a planet covers -- and that is a function of
## zoom alone. Scaling the ceiling with the radius would give a `tiny` map a ceiling of
## 0.06, at which a planet is a third of a pixel and cannot be clicked: the small map
## would have been the one map you could not zoom in on.
const MAX_ZOOM := 3.0

## Absolute safety net for a degenerate `map_radius` from a corrupt save, which must not
## be able to produce a zero or negative zoom -- `Camera2D` renders those as nothing.
const MIN_ZOOM_FLOOR := 0.0002

const ZOOM_STEP := 1.15
const PAN_BUTTON := MOUSE_BUTTON_MIDDLE

## Smallest usable map area. Below this the control has not been laid out yet, and any
## framing computed against it is meaningless -- see `frame_galaxy`.
const MIN_AREA := 8.0

## The span of the map this control is showing, in parsecs.
##
## Read from the galaxy rather than from `GalaxyGenerator.GALAXY_RADIUS`: the radius is a
## per-game property now that `--map-size` can pick it, and a constant here would frame the
## wrong amount of a `tiny` map by a factor of fifty. Falls back to the default span when
## there is no galaxy yet, which is the state the control is built in.
func map_radius() -> float:
	if _controller != null and _controller.galaxy != null:
		return _controller.galaxy.radius()
	return GalaxyGenerator.radius_for_tier(GalaxyGenerator.DEFAULT_TIER)


## Zoom bounds for the current span.
func min_zoom() -> float:
	return _min_zoom(get_rect().size, _sub_viewport.size if _sub_viewport != null
		else Vector2i.ZERO)


## `min_zoom` for an explicit area, so the caller and the clamping cannot disagree.
func _min_zoom(control_size: Vector2, viewport_size: Vector2i) -> float:
	var guard := maxf(MIN_ZOOM_FLOOR, MIN_ZOOM_FACTOR * map_radius())
	if control_size.x < MIN_AREA or control_size.y < MIN_AREA:
		return guard
	var visible := control_size
	if viewport_size.x > 0 and viewport_size.y > 0:
		visible = Vector2(viewport_size)
	# Measured against the outermost planet rather than the drawn field: the field is empty
	# space by design, so a floor that protected the field would also forbid the player
	# from seeing their own empire.
	var fit := minf(visible.x, visible.y) * MIN_ZOOM_FIT_MARGIN / (2.0 * _body_extent())
	# Only binding when the map is genuinely larger than the viewport. When it is smaller,
	# the fit is a *magnification* above 1, and treating that as a floor would forbid the
	# player from zooming out on a `tiny` map -- the one map size where pulling back is the
	# only way to see anything at all.
	if fit >= 1.0:
		return guard
	return maxf(guard, fit)


## The furthest any planet sits from the star, in galaxy units; the drawn field if unknown.
func _body_extent() -> float:
	if _controller == null or _controller.galaxy == null:
		return _view.world_size(null)
	var reach := 0.0
	for p in _controller.galaxy.planets:
		reach = maxf(reach, p.position.length())
	return maxf(reach, 1.0)


func max_zoom() -> float:
	return MAX_ZOOM


## Slack left around the disk when fitting, so edge systems are not flush against the
## panel border and the crosshair still reads as the galactic centre.
const FIT_MARGIN := 1.25

## Slack beyond the drawn field for the camera limits.
##
## The camera is not allowed inside the field. Without a limit, one hard pan leaves the
## star off screen with nothing but the edge of the bounds frame to go on, and the
## player's own expansion is off in whichever direction they nudged the mouse.
const CAMERA_MARGIN_FACTOR := 1.1


## Keep the SubViewport black behind the map, and leave the camera's bounds to
## `clamp_camera()`.
##
## `limit_*` used to be set here, on the reasoning that they hold under every route into
## the camera without each handler having to remember to clamp. That reasoning is wrong in
## two ways, and both of them are the reported bug:
##
## 1. **They are not a centre constraint the caller can read.** The engine applies them
##    while the camera *renders*, which is after `position` has been read by the hit test,
##    the drawn order line and `camera_bounds()` itself. So the value the game reasons
##    about and the value on screen were different numbers, and anything that read
##    `position` between a move and the next frame disagreed with the picture.
## 2. **They are a fixed axis-aligned box, so they cannot express a viewport that is wider
##    than it is tall.** The field is square; the window is not. A limit tight enough to hold
##    the screen inside the map on the short axis stops the long axis dead, and a limit loose
##    enough for the long axis lets the map fall off the short one. There is no single box
##    that is right for both, and the asymmetry is exactly the "panning blocks upward"
##    report.
##
## `clamp_camera()` already has the bound that is correct for the *actual* viewport, is
## applied immediately, and is the same function the tests assert on -- so it is the only
## authority. The limits are cleared rather than left at their defaults: Godot's default is
## a huge rectangle, which would be harmless, but an explicitly disabled limit is a statement
## rather than an accident waiting for a future `limit_*` assignment.
##
## The clear mode is the other half of "the map must not vanish". Outside the drawn field
## the viewport fell back to the project's clear colour, which is not black, so panning past
## the edge produced a panel of foreign colour -- readable as a rendering fault even on the
## frames when the map behind it was drawn correctly.
func _apply_camera_limits() -> void:
	if _camera == null or _sub_viewport == null:
		return
	# `INT_MAX`/`INT_MIN` is how Godot spells "no limit"; a small sentinel would reintroduce
	# exactly the hardcoded boundary this is removing.
	_camera.limit_left = -INF_INT
	_camera.limit_top = -INF_INT
	_camera.limit_right = INF_INT
	_camera.limit_bottom = INF_INT
	_sub_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_sub_viewport.canvas_item_default_texture_filter = \
		Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR


## Sentinel for an unbounded camera limit, in a type that cannot overflow when the
## camera adds its own extent to it.
const INF_INT := 0x3FFFFFFF


## Keep the camera's centre inside `camera_bounds()`.
##
## Called after every route that moves the camera, and deliberately immediate rather than
## left to the camera's own limits alone. Those are a *centre* constraint: they keep the
## middle of the screen over the map while still letting the edges hang off it, and they
## are applied while the camera renders rather than when the value is written. Anything
## reading `position` in the gap -- a hit test, a drawn order line -- would then disagree
## with what is on screen.
##
## The bound depends on the zoom, which is the last thing set when reframing, so it is
## recomputed on every zoom as well as every pan.
func clamp_camera() -> void:
	if _camera == null:
		return
	var b := camera_bounds()
	_camera.position.x = clampf(_camera.position.x, b.position.x, b.end.x)
	_camera.position.y = clampf(_camera.position.y, b.position.y, b.end.y)


## The rectangle the camera's centre is allowed to occupy.
##
## The field, shrunk by the visible half-extent of the viewport in galaxy units: the
## constraint is on the centre, so letting the centre reach the field's edge would put
## half the screen outside it.
func camera_bounds() -> Rect2:
	var w := _view.world_size(
		_controller.galaxy if _controller != null else null
	) * CAMERA_MARGIN_FACTOR
	if _camera == null:
		return Rect2(-w, -w, w * 2.0, w * 2.0)
	var view := _sub_viewport.size if _sub_viewport != null else Vector2i(640, 480)
	var z := maxf(0.0001, _camera.zoom.x)
	var half := Vector2(float(view.x), float(view.y)) * 0.5 / z
	# Per-axis, not one inset for both. The bounds frame is square but the viewport
	# generally is not, and on a wide window the screen is far wider than the map is tall
	# -- so a shared diagonal inset over-restricts the axis that has room to spare and
	# under-restricts the other. Each axis gets the extent that is actually visible there.
	#
	# The ranges are built by position and *size on the same axis*. They used to share a
	# single span, so the rect's origin came from the upper bound on one axis while its
	# size came from the upper bound on the other. The result was a rectangle whose Y range
	# was entirely positive -- `[+inset, +inset + span]` instead of `[-inset, +inset]` --
	# which is the reported "panning freezes upward": clamping Y into a band that only
	# exists above the star, and quietly truncating X at the same time, because the width
	# was measured from the wrong span.
	var sx := _axis_bounds(-w, w, half.x)
	var sy := _axis_bounds(-w, w, half.y)
	return Rect2(sx.x, sy.x, sx.y - sx.x, sy.y - sy.x)


## The camera centre's range on one axis, given a half-extent of `inset`.
##
## Collapses to the origin when the screen is wider than the map at this zoom -- the only
## centre that keeps the field in frame is then its middle, not either of its edges. It is
## collapsed rather than swapped for that reason: an inverted range would make `clampf`
## return its first argument, which is an edge, not a centre.
func _axis_bounds(lo: float, hi: float, inset: float) -> Vector2:
	var a := lo + inset
	var b := hi - inset
	if b < a:
		return Vector2.ZERO
	return Vector2(a, b)

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

	_apply_camera_limits()

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
	# The span is only known once a galaxy is bound, so the limits have to be reapplied.
	_apply_camera_limits()
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
			# `relative` is in Control-local units while the camera thinks in galaxy
			# units, so the drag has to cross both the container scale and the zoom --
			# dividing by the zoom alone lets the map slide under the cursor at a rate
			# that changes with the window size.
			var dragged := _to_subviewport(mm.position) - _to_subviewport(mm.position - mm.relative)
			_camera.position -= dragged / _camera.zoom.x
			clamp_camera()
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
	# A fixed 80px pan step divided by the zoom is the same *screen* distance at every
	# scale, which is what a player expects from arrow keys; left as-is.
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
	# The zoom cases above have already clamped themselves; this catches the pan cases and
	# costs nothing on the others.
	clamp_camera()
	accept_event()


## Zoom while keeping the galaxy point under `screen_pos` fixed on screen.
##
## A naive `camera.zoom *= k` drifts towards the top-left, which makes precise inspection
## of a star frustrating; anchoring at the cursor is the behaviour players expect.
func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	_user_framed = true
	var before := _to_galaxy(screen_pos)
	var next := clampf(_camera.zoom.x * factor, min_zoom(), max_zoom())
	if is_equal_approx(next, _camera.zoom.x):
		return
	_camera.zoom = Vector2(next, next)
	var after := _to_galaxy(screen_pos)
	_camera.position += before - after
	# After, not before: the bound depends on the zoom, so re-clamping against the old
	# one would either fight the zoom or leave a limit the new zoom has outgrown.
	clamp_camera()


## A position in this Control's local space, as it arrives in a gui_input event.
##
## A `SubViewportContainer` with `stretch` scales its SubViewport to fill its own rect, so
## local units and SubViewport pixels are two different units and the gap between them is
## the window's aspect ratio. Before this existed the code assumed they were the same,
## which is true at exactly one window size and drifts from there -- the reason a click
## landed on the right planet in the test's 1280x720 layout and the wrong one in a
## maximised window. Deriving it from the containers means there is no constant to get
## wrong.
func _to_subviewport(local_pos: Vector2) -> Vector2:
	if _container == null or _sub_viewport == null:
		return local_pos
	var dst := _sub_viewport.size
	var src := _container.size
	if src.x <= 0.0 or src.y <= 0.0 or dst.x <= 0 or dst.y <= 0:
		return local_pos
	return Vector2(
		(local_pos.x - _container.position.x) * float(dst.x) / src.x,
		(local_pos.y - _container.position.y) * float(dst.y) / src.y
	)


## The inverse of `_to_subviewport`: a point in the SubViewport back into this Control.
func _to_local(viewport_pos: Vector2) -> Vector2:
	if _container == null or _sub_viewport == null:
		return viewport_pos
	var dst := _sub_viewport.size
	var src := _container.size
	if src.x <= 0.0 or src.y <= 0.0 or dst.x <= 0 or dst.y <= 0:
		return viewport_pos
	return Vector2(
		_container.position.x + viewport_pos.x * src.x / float(dst.x),
		_container.position.y + viewport_pos.y * src.y / float(dst.y)
	)


## Map a point in this Control to galaxy coordinates.
##
## Two transforms have to be undone to get here, and they are separate because the engine
## keeps them separate: the container's own scale, and the camera's canvas transform. Only
## the second was being inverted before, by hand --
## `(pos - centre) / zoom + camera.position` -- which silently assumes a camera with no
## rotation, no anchor offset and no sub-pixel rounding. Each assumption that fails is an
## offset between where the player clicks and where the game thinks they clicked, and the
## symptom is "I clicked the planet and it selected the one next to it" at some zoom
## levels and not others: exactly the class of bug nobody reproduces on the settings they
## wrote it on.
##
## `get_canvas_transform()` is what the renderer itself uses to place a world point on
## screen, so inverting it is correct by construction for whatever the camera is doing.
func _to_galaxy(local_pos: Vector2) -> Vector2:
	return _sub_viewport.get_canvas_transform().affine_inverse() * _to_subviewport(local_pos)


## The inverse: galaxy coordinates back to a point in this Control.
##
## The programmatic click path runs through here so a synthetic click travels exactly the
## transform a real one does, rather than the test driving a shortcut the player's mouse
## does not take -- which is how a hit-testing bug passes its own test.
func _to_screen(galaxy_pos: Vector2) -> Vector2:
	return _to_local(_sub_viewport.get_canvas_transform() * galaxy_pos)


## Route a click: to a planet as a proposed destination when a fleet is selected and
## staging is armed, otherwise to selection.
##
## A proposal is *not* an order. Clicking a world with a fleet selected draws the flight
## path and opens the confirmation prompt; only `confirm_order()` turns it into something
## the resolver will execute. Dispatching on the click that chose the destination was how a
## mis-click sent a fleet across the map with nothing to undo it, and the undo is the whole
## point of the prompt.
##
## `GalaxyMapView.pick` returns whatever is under the cursor, which is now a *planet* index
## for every body and the star's system index only when the star itself was hit. A star is
## not a move destination -- there is nowhere to put a fleet that is not a planet -- so a
## click on it always selects rather than proposing an order.
func _click_at(screen_pos: Vector2) -> void:
	var gal := _to_galaxy(screen_pos)
	var hit: int = _view.pick(gal)
	if hit < 0:
		# Clicking empty space discards a pending proposal and deselects the fleet, which
		# is both the fastest way out of order mode and the "clicking elsewhere discards
		# the staged path" affordance.
		cancel_order()
		interaction_refused.emit("empty space")
		background_picked.emit()
		return

	if _is_planet(hit) and (_order_mode or Input.is_key_pressed(KEY_SHIFT)):
		if propose_order(hit):
			return
		interaction_refused.emit("move refused")
		return

	if _is_planet(hit):
		# Selecting a different world while a proposal is open discards it: the click that
		# opened the prompt was the answer to it.
		if _pending_destination >= 0 and _pending_destination != hit:
			cancel_order()
		planet_picked.emit(hit)
		_controller.select_planet(hit)
		return

	system_picked.emit(hit)
	_controller.select_system(hit)


## Planet a flight is proposed for, or -1 when nothing is pending.
##
## A proposal lives on the map, not on the fleet: the fleet's own `destination` is an order
## that will execute, and putting a pending target in that field would make the map draw a
## flight that is already under way and would make `advance()` move the fleet before
## anything confirmed it.
var _pending_destination := -1


## Propose a destination for the selected fleet. Returns false when the order is illegal.
##
## The legality check is the controller's, and it is the same check `queue_move` makes --
## so a proposal that the player could never have committed is never shown in the first
## place. What is deferred is only the *commit*.
func propose_order(target_planet: int) -> bool:
	var f := _controller.fleet()
	if f == null:
		interaction_refused.emit("select a fleet before issuing a move")
		return false
	if not _controller.can_queue_move(target_planet):
		interaction_refused.emit("move refused")
		return false
	_pending_destination = target_planet
	_view.preview_destination = target_planet
	_view.queue_redraw()
	order_proposed.emit(target_planet)
	return true


## Commit the pending proposal as a whole-fleet flight.
##
## A shortcut, not the main route: the travel modal is what the UI opens, because only the
## modal can express *which* ships travel. This dispatches the entire fleet and is kept for
## the map's own callers and the headless suite, which have no modal to open. It emits
## `order_cancelled` rather than confirming when the controller refuses, so a caller that
## listens for the commit does not also hear a commit that did not happen.
func confirm_order() -> bool:
	if _pending_destination < 0:
		return false
	var target := _pending_destination
	_pending_destination = -1
	_view.preview_destination = -1
	_view.queue_redraw()
	if _controller.queue_travel(target):
		planet_picked.emit(target)
		return true
	order_cancelled.emit()
	return false


## Propose `target_planet` without emitting anything, for a caller that already knows what it
## wants the modal to show. Returns false when the proposal is not legal.
func set_proposal(target_planet: int) -> bool:
	return propose_order(target_planet)


## Clear the pending proposal silently.
##
## Used by the travel modal, which owns the decision now: when it commits, the map's preview
## is simply stale, and emitting `order_cancelled` as well would log a discard for a flight
## that was actually sent.
func clear_proposal() -> void:
	_pending_destination = -1
	_view.preview_destination = -1
	_view.queue_redraw()


## Discard the pending proposal, leaving the fleet where it is.
func cancel_order() -> void:
	if _pending_destination < 0:
		return
	_pending_destination = -1
	_view.preview_destination = -1
	_view.queue_redraw()
	order_cancelled.emit()


func pending_destination() -> int:
	return _pending_destination


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
	_click_at(_to_screen(galaxy_pos))
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
	var need_x := map_radius() * GalaxyGenerator.OUTER_ORBIT
	var need_y := need_x
	if galaxy != null:
		need_x = 0.0
		need_y = 0.0
		for p in galaxy.planets:
			need_x = maxf(need_x, absf(p.position.x - centre.x))
			need_y = maxf(need_y, absf(p.position.y - centre.y))
	# The floor is taken against the same area the fit was computed from. Using
	# `get_rect()` for one and the sub-viewport for the other would be two numbers that are
	# equal only while the map fills its container exactly.
	var zoom := clampf(minf(
		visible.x / (2.0 * need_x * FIT_MARGIN),
		visible.y / (2.0 * need_y * FIT_MARGIN)
	), _min_zoom(get_rect().size, _sub_viewport.size), max_zoom())

	_camera.position = centre
	_camera.zoom = Vector2(zoom, zoom)
	clamp_camera()


## Centre the camera on a planet, keeping the current zoom.
##
## The construction dropdown names a colony in prose -- "Verdania" -- and the map is somewhere
## else entirely, because the default framing is the whole system. Choosing a target you cannot
## see is choosing blind: the player has to pan back out, find the world by name on a field
## of a hundred bodies, and re-zoom, all before they can see whether they picked the right
## one. Snapping closes that loop.
##
## Deliberately *not* a re-frame: the zoom is left exactly as the player set it. They asked to
## look at a world, not to be moved somewhere else, and a jump that also zooms throws away the
## scale they were working at.
##
## Counts as the player having framed the map themselves, so a later resize does not yank the
## view back out to the whole system.
func focus_planet(planet_index: int) -> bool:
	if _camera == null or _controller == null or _controller.galaxy == null:
		return false
	var planet: PlanetState = _controller.galaxy.planet(planet_index)
	if planet == null:
		return false
	_user_framed = true
	_camera.position = planet.position
	clamp_camera()
	return true


## The camera position right now, in map coordinates.
func camera_position() -> Vector2:
	return Vector2.ZERO if _camera == null else _camera.position


## Whether every in-transit fleet's path is drawn.
func flight_paths_enabled() -> bool:
	return _view.flight_paths_enabled()


## Show or hide every in-transit fleet's path.
##
## A per-fleet overlay is a view of one thing at a time; a player asking "where has everything
## of mine gone" has to click four fleets to answer it. The toggle is off by default so the
## default map is still the map, and on because a field with four dashed lines crossing it is
## exactly the picture a player wants when they are managing movement rather than looking at a
## world.
func set_flight_paths(on: bool) -> void:
	_view.set_flight_paths(on)
	# The overlay is drawn in `_draw`, so a board that is already on screen shows nothing until
	# it is asked to redraw. `set_flight_paths` on the view only sets the flag.
	_view.queue_redraw()


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

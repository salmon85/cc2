extends Control
class_name GalaxyMap
## The galaxy map: a SubViewport holding a Camera2D and a `GalaxyMapView` draw layer.
##
## Zoom and pan are the camera's job, which keeps the view layer in plain galaxy
## coordinates. This node owns only interaction: wheel zoom, middle/right-drag pan, left
## click to select a system, and click-with-a-fleet-selected to stage a move.

## Emitted when a system is picked with the left button.
signal system_picked(system_index: int)

## Emitted when empty space is picked.
signal background_picked

## Emitted with an error string when an interaction is refused.
signal interaction_refused(reason: String)

const MIN_ZOOM := 0.35
const MAX_ZOOM := 3.0
const ZOOM_STEP := 1.15
const PAN_BUTTON := MOUSE_BUTTON_MIDDLE

var _controller: SessionController = null
var _view: GalaxyMapView = null
var _sub_viewport: SubViewport = null
var _camera: Camera2D = null

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
	_sub_viewport = SubViewport.new()
	_sub_viewport.size = Vector2i(640, 480)
	_sub_viewport.disable_3d = true
	_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub_viewport.transparent_bg = false
	add_child(_sub_viewport)

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


func bind(controller: SessionController) -> void:
	_controller = controller
	if _controller == null:
		return
	if not _controller.state_changed.is_connected(_sync_viewport):
		_controller.state_changed.connect(_sync_viewport)
	_view.bind(controller)
	_sync_viewport()


## Keep the SubViewport the same pixel size as the visible rect so the camera maps 1:1
## and a star under the cursor stays under the cursor while panning.
func _sync_viewport() -> void:
	if _sub_viewport == null:
		return
	var want := Vector2i(
	 maxi(64, int(get_rect().size.x)), maxi(64, int(get_rect().size.y))
	)
	if _sub_viewport.size != want:
		_sub_viewport.size = want
	# The view is anchored full-rect inside the SubViewport, so it tracks the viewport
	# on its own. Assigning `size` directly would fight those anchors and emit a layout
	# warning on every pass, so there is nothing to synchronise here.


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_sync_viewport()
	elif what == NOTIFICATION_MOUSE_EXIT:
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


## Route a click: to a fleet's destination if a fleet is selected and the shift key is
## held, otherwise to selection.
func _click_at(screen_pos: Vector2) -> void:
	var gal := _to_galaxy(screen_pos)
	var hit: int = _view.pick(gal)
	if hit < 0:
		# Clicking empty space with no intent deselects the fleet, which is the fastest
		# way out of order mode.
		interaction_refused.emit("empty space")
		background_picked.emit()
		return
	if _order_mode or Input.is_key_pressed(KEY_SHIFT):
		var f := _controller.fleet()
		if f == null:
			interaction_refused.emit("select a fleet before issuing a move")
			system_picked.emit(hit)
			return
		if not _controller.queue_move(hit):
			# The controller has already explained the refusal; mirror it once so the
			# map is not silently unresponsive.
			interaction_refused.emit("move refused")
			return
		system_picked.emit(hit)
		return
	system_picked.emit(hit)
	_on_view_system_clicked(hit)


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


func recentre() -> void:
	_camera.position = Vector2.ZERO
	_camera.zoom = Vector2.ONE

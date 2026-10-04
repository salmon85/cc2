extends PanelContainer
class_name TopBar
## Status HUD: Stardate, treasury, net income per turn, research total, End Turn.
##
## Reads everything from `SessionController` and writes nothing back except through the
## `end_turn_pressed` signal — so the only way this panel can affect the game is the same
## way a player's click would.

## Emitted when the player commits their turn.
signal end_turn_pressed

## Emitted when the pending-order count is clicked (also acts as a "ready" toggle).
signal orders_pressed

var _controller: SessionController = null

var _stardate_label: Label = null
var _turn_label: Label = null
var _treasury_label: Label = null
var _research_label: Label = null
## Net income is coloured by sign, so this readout carries BBCode and must be a
## RichTextLabel — a plain Label would print the tags literally.
var _net_label: RichTextLabel = null
var _pending_label: Label = null
var _end_turn_button: Button = null


func _ready() -> void:
	_build()


func _build() -> void:
	custom_minimum_size = Vector2(0, 44)
	theme = CC2Theme.build()

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	add_child(row)

	_stardate_label = _cell(row, "STARDATE", CC2Theme.PHOSPHOR, CC2Theme.FONT_BIG)
	_turn_label = _cell(row, "TURN", CC2Theme.PHOSPHOR_DIM, CC2Theme.FONT_HEAD)
	_treasury_label = _cell(row, "IMPERIAL TREASURY", CC2Theme.CYAN, CC2Theme.FONT_HEAD)
	_net_label = _cell_bbcode(row, "NET / TURN", CC2Theme.CYAN, CC2Theme.FONT_HEAD)
	_research_label = _cell(row, "RESEARCH", CC2Theme.AMBER, CC2Theme.FONT_HEAD)

	# A spacer so the treasury block sits left and the controls right regardless of how
	# wide the readouts render at this resolution.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var order_button := Button.new()
	order_button.text = "ORDERS"
	order_button.tooltip_text = "Show staged orders for this turn"
	order_button.focus_mode = Control.FOCUS_NONE
	order_button.pressed.connect(func() -> void: orders_pressed.emit())
	row.add_child(order_button)

	_pending_label = Label.new()
	_pending_label.text = "0"
	_pending_label.custom_minimum_size = Vector2(26, 0)
	_pending_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_pending_label.add_theme_color_override("font_color", CC2Theme.AMBER)
	_pending_label.add_theme_font_size_override("font_size", CC2Theme.FONT_HEAD)
	row.add_child(_pending_label)

	_end_turn_button = Button.new()
	_end_turn_button.text = "END TURN"
	_end_turn_button.tooltip_text = "Commit staged orders and advance one stardate"
	_end_turn_button.custom_minimum_size = Vector2(130, 0)
	_end_turn_button.pressed.connect(func() -> void: end_turn_pressed.emit())
	row.add_child(_end_turn_button)


## One labelled readout. Returns the value label so the caller can update it.
func _cell(parent: Control, caption: String, colour: Color, font_size: int) -> Label:
	var box := _cell_box(parent, caption)

	var value_label := Label.new()
	value_label.text = "--"
	value_label.add_theme_color_override("font_color", colour)
	value_label.add_theme_font_size_override("font_size", font_size)
	box.add_child(value_label)
	return value_label


## As `_cell`, but the readout carries BBCode — used where the value's colour depends on
## the value itself. `fit_content` keeps the box sized to its text instead of expanding to
## fill the top bar's 44px.
func _cell_bbcode(parent: Control, caption: String, colour: Color, font_size: int) -> RichTextLabel:
	var box := _cell_box(parent, caption)

	var value_label := RichTextLabel.new()
	value_label.bbcode_enabled = true
	value_label.fit_content = true
	value_label.scroll_active = false
	value_label.text = "--"
	value_label.add_theme_color_override("default_color", colour)
	value_label.add_theme_font_size_override("normal_font_size", font_size)
	box.add_child(value_label)
	return value_label


## The caption-over-value stack both cell builders drop their readout into.
func _cell_box(parent: Control, caption: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	parent.add_child(box)

	var caption_label := Label.new()
	caption_label.text = caption
	caption_label.add_theme_color_override("font_color", CC2Theme.WHITE_DIM)
	caption_label.add_theme_font_size_override("font_size", CC2Theme.FONT_SMALL)
	box.add_child(caption_label)
	return box


## Bind to a controller and start following its state.
func bind(controller: SessionController) -> void:
	_controller = controller
	if _controller == null:
		return
	if not _controller.state_changed.is_connected(refresh):
		_controller.state_changed.connect(refresh)
	refresh()


## Pull the current numbers into the HUD. Safe to call before the panel enters the tree.
func refresh() -> void:
	if _controller == null or _controller.galaxy == null:
		return
	var me := _controller.player()
	if me == null:
		return

	_stardate_label.text = str(_controller.galaxy.turn + 1)
	_turn_label.text = "TURN %d" % (_controller.galaxy.turn + 1)
	_treasury_label.text = Format.credits(me.metals + me.rare_elements + me.energy)
	_net_label.text = Format.signed_colored(me.last_net)
	_research_label.text = Format.fixed(me.total_tech_points(), 1)
	_pending_label.text = str(_controller.pending_orders().size())

	# Dim the button only when there is genuinely nothing to send. A turn with no orders
	# is still a legal turn — the player may just want the clock to advance.
	_end_turn_button.text = "END TURN" if _controller.pending_orders().is_empty() \
		else "RESOLVE (%d)" % _controller.pending_orders().size()


## Programmatic click path, used by the automated GUI test.
func press_end_turn() -> void:
	_end_turn_button.emit_signal(&"pressed")


func end_turn_button() -> Button:
	return _end_turn_button


func stardate_label() -> Label:
	return _stardate_label


func treasury_label() -> Label:
	return _treasury_label


func research_label() -> Label:
	return _research_label


func net_label() -> RichTextLabel:
	return _net_label

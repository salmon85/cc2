extends PanelContainer
class_name TopBar
## Status HUD: Stardate, treasury, net income per turn, research total, and the ready
## button that commits the turn.
##
## Reads everything from `SessionController` and writes nothing back except through the
## `ready_pressed` signal — so the only way this panel can affect the game is the same way
## a player's click would.

## Emitted when the lobby ready button is pressed. Carries the state being asked for, so
## the button toggles rather than only ever setting.
signal ready_pressed(is_ready: bool)

var _controller: SessionController = null

var _turn_label: Label = null
## `Science: 130 (+5)` — the balance and what the last turn added. A balance with no delta is
## a number the player cannot plan against: they cannot tell whether research is keeping up
## with spending until they have waited a turn to see it move.
var _research_label: Label = null
var _ready_button: Button = null


func _ready() -> void:
	_build()


func _build() -> void:
	custom_minimum_size = Vector2(0, 44)
	theme = CC2Theme.build()

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	add_child(row)

	# TURN and SCIENCE, and nothing else.
	#
	# Three readouts were removed here. STARDATE duplicated TURN -- the same number in a
	# different label, so the header said "STARDATE 4 / TURN 4" and made the player work out
	# that they were one quantity. IMPERIAL TREASURY and NET/TURN were income figures left
	# over from the tax slider: there is no income any more, so both were reading a ledger
	# that only ever moved by upkeep. A header row is the most-read surface in the game, and
	# every cell on it has to be something the player can act on.
	_turn_label = _cell(row, "TURN", CC2Theme.PHOSPHOR_DIM, CC2Theme.FONT_HEAD)
	_research_label = _cell(row, "RESEARCH", CC2Theme.AMBER, CC2Theme.FONT_HEAD)

	# A spacer so the treasury block sits left and the controls right regardless of how
	# wide the readouts render at this resolution.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	# The one control that commits a turn. END TURN and the ORDERS counter were both
	# removed: orders are staged by clicking the map and then applied automatically when
	# every connected player has readied, so a separate commit button asked the player to
	# do the same thing twice.
	#
	# Present only in a networked session. A match waits for every connected player to
	# ready up, so without this a GUI client would sit in the lobby forever with no way
	# forward and no indication of why -- the one control that makes `--client` usable at
	# all. Headless clients pass `--ready` instead; this is the equivalent for a window.
	_ready_button = Button.new()
	_ready_button.text = "READY"
	_ready_button.tooltip_text = "Commit your orders and tell the server you are in"
	_ready_button.focus_mode = Control.FOCUS_NONE
	_ready_button.custom_minimum_size = Vector2(110, 0)
	_ready_button.pressed.connect(_on_ready_pressed)
	row.add_child(_ready_button)


## Show the ready button only when there is a server to be ready to, and label it with
## whatever it would do next.
##
## The label carries the lobby tally -- "Ready 1/2" -- so a player is never left guessing
## whether pressing it did anything. The count comes from the server, so both players see
## the same number at the same instant.
##
## The denominator is players *present*, not the slots the server advertises. A four-slot
## server with two people in it says "Ready 1/2", which is the truth about the game being
## played; "Ready 1/4" told both players to wait for two more who might never arrive, and
## left a full lobby looking like a broken one. When someone leaves, the server re-tallies
## and the number drops.
##
## Colour carries the same state twice over: green while you still need to press, red
## once you have and can take it back. Colour alone would not do -- roughly one man in
## twelve cannot reliably distinguish these two hues, so the wording has to survive
## without it.
func _refresh_ready_button() -> void:
	if _ready_button == null:
		return
	var networked := _controller != null and _controller.is_networked()
	_ready_button.visible = networked
	if not networked:
		# Reset text *and* disabled as well as the visibility. A button that was showing
		# the waiting message and is now hidden keeps whatever it last read and stays
		# greyed out, and if networking comes back the stale message reappears on a button
		# the player cannot press.
		_ready_button.text = "READY"
		_ready_button.disabled = false
		return
	var tally := _controller.ready_tally()
	# With nobody else present the denominator would be 1 and the button would read
	# "Ready 0/1" while waiting for the opponent to connect. One is the floor.
	var total := maxi(1, tally.y)
	var mine := _controller.is_ready_flagged()
	# Never report a count below this player's own state: the server's tally arrives by
	# packet, so for the frame between pressing and hearing back the button would
	# otherwise read "Ready 0/2" while sitting in its red, pressed-looking state.
	# The server's tally and this client's own flag are cleared by the resolution that
	# ended the turn they were for. Showing `max(tally.x, mine)` on the frame *after*
	# that -- before the new tally has arrived -- would keep the button reading "Ready 1/1"
	# in its red state for a turn no one has committed to, which reads as a stuck button.
	# Once the client has a galaxy at the current turn, both are authoritative again.
	var shown := tally.x
	if galaxy_turn_is_current():
		shown = maxi(tally.x, 1 if mine else 0)
	_ready_button.text = "Ready %d/%d" % [shown, total]
	var tint := CC2Theme.ALERT if mine else CC2Theme.PHOSPHOR
	_ready_button.add_theme_color_override(&"font_color", tint)
	_ready_button.add_theme_color_override(&"font_hover_color", tint)

	# Awaiting the server's resolution: pressing again would only re-send a closed turn,
	# so the button disables and says why. This is now the *only* place the wait is
	# communicated -- the END TURN button that used to carry the message is gone, and READY
	# is the button the player just pressed, so leaving it reading "Ready 1/1" would hide
	# the one piece of feedback a networked turn gives.
	if _controller.is_awaiting_server():
		_ready_button.text = TurnSyncClient.WAITING_TEXT
	_ready_button.disabled = _controller.is_awaiting_server()


## Whether the client's local ready flag still refers to the turn it is now on.
##
## False in the window between the resolution landing and the server's fresh tally
## arriving, which is exactly when the local flag is known to be stale.
func galaxy_turn_is_current() -> bool:
	if _controller == null or _controller.galaxy == null:
		return true
	return not _controller.is_awaiting_server()


## Toggle the lobby ready flag.
##
## The button is pressed, so the new state is the *opposite* of the current one. Reading
## it back through the controller rather than tracking it here keeps the button honest
## if anything else changes the flag.
func _on_ready_pressed() -> void:
	var want := not _controller.is_ready_flagged()
	ready_pressed.emit(want)


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
	_refresh_ready_button()
	refresh()


## Pull the current numbers into the HUD. Safe to call before the panel enters the tree.
func refresh() -> void:
	# Refreshed before the galaxy check, not after it: the ready button has to be correct
	# during the window *before* the server sends an opening state, which is precisely
	# when a player needs to press it.
	_refresh_ready_button()
	if _controller == null or _controller.galaxy == null:
		return
	var me := _controller.player()
	if me == null:
		return

	_turn_label.text = "TURN %d" % (_controller.galaxy.turn + 1)
	# The delta is a projection, not last turn's receipt.
	#
	# It used to be `last_research_granted`, on the reasoning that a projection would be
	# wrong by whatever the player was checking. That reasoning was sound for a flat rate --
	# there was nothing to check -- and wrong the moment research became a dial. The rate is
	# now the empire's unassigned civilians, so pressing `+` or `-` on a farm worker changes
	# it immediately, and showing the previous turn's figure meant the number the player was
	# adjusting sat still while they adjusted it.
	#
	# `projected_research` is the same function the resolver splits across the four fields,
	# so this is the turn's grant rather than an estimate of it.
	_research_label.text = "%d (%s)" % [
		int(round(me.total_tech_points())),
		Format.signed(
			ResearchStage.projected_research(me, _controller.galaxy, _controller.db), 0)]


## Programmatic click path for the ready button, used by the automated GUI test.
func press_ready() -> void:
	if _ready_button != null:
		_ready_button.emit_signal(&"pressed")


## The lobby ready button, for the automated GUI test and for hiding it in a local game.
func ready_button() -> Button:
	return _ready_button


## The turn readout. Replaces both the old stardate label and the old treasury label: the
## header has one number in it that is a counter, and these accessors all return it so a
## caller written against the earlier header still resolves to something real.
func stardate_label() -> Label:
	return _turn_label


func treasury_label() -> Label:
	return _turn_label


func research_label() -> Label:
	return _research_label


## Removed in Phase 8. Kept as an accessor returning null so a caller written against the
## earlier header gets a definite answer rather than a crash -- the GUI suite asserts on it.
func net_label() -> RichTextLabel:
	return null

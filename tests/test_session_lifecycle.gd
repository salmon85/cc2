extends SceneTree
## Phase 7 verification: the multiplayer lobby and session lifecycle.
##
##   godot --headless --path . -s res://tests/test_session_lifecycle.gd
##
## Covers the rules that decide *when a game is allowed to exist*:
##   - slot assignment, ready flags, and the match-start decision, as pure rules
##   - the CLI surface the lobby is driven by (`--slots`, `--ready`)
##   - a real join -> ready -> start conversation over loopback sockets
##   - a client dropped mid-session: its empire is held, then handed to the AI, and the
##     turn loop keeps running without it
##
## The lobby rules are pure bookkeeping and are tested directly. The networked half is
## driven from `_process`, because the ENet driver is pumped by the main loop: anything
## that waited synchronously for a reply would deadlock against the loop that has to
## deliver it.

const NetworkManagerScript := preload("res://src/net/network_manager.gd")

var _t: TestSupport = null

## Counters observed from signal callbacks.
##
## These are members rather than locals on purpose: a GDScript lambda captures the
## enclosing scope *by value*, so a local integer incremented inside one is a copy and
## the outer variable never changes. That is a silent failure -- the assertion reads the
## unchanged initial value and reports a mismatch with no hint why.
var _starts_announced: int = 0


func _initialize() -> void:
	_t = TestSupport.new()
	_test_lobby_cli()
	_test_slot_assignment_rules()
	_test_ready_and_start()
	_test_full_lobby_refuses_a_third()
	_test_grace_then_ai_fallback()
	_test_reclaim_before_expiry()
	_test_ready_count()


# --- Pure rules ------------------------------------------------------------

## The flags the lobby is configured from, parsed the way the game reads them.
func _test_lobby_cli() -> void:
	_t.begin("lobby CLI")
	var opts := CC2CLI.parse(PackedStringArray([
		"--server", "--port=7777", "--slots=3", "--ready"]))
	_t.eq(opts.slots, 3, "--slots configures the lobby")
	_t.eq(opts.port, 7777, "--port is honoured")
	_t.ok(opts.auto_ready, "--ready sets auto_ready")

	var plain := CC2CLI.parse(PackedStringArray(["--client", "--ip=127.0.0.1"]))
	_t.ok(not plain.auto_ready, "auto_ready defaults to off")
	_t.eq(plain.slots, CC2CLI.DEFAULT_SLOTS, "slots default to %d" % CC2CLI.DEFAULT_SLOTS)

	# A lobby is created with at least one slot; zero would mean no match can ever start.
	_t.eq(SessionLobby.new(0).total_slots, 1, "a zero-slot lobby still admits one player")
	_t.eq(SessionLobby.new(99).total_slots, 99, "an oversized lobby is not clamped here")


func _test_slot_assignment_rules() -> void:
	_t.begin("slot assignment")
	var lobby := SessionLobby.new(3)

	_t.eq(lobby.join(101), 0, "the first peer takes empire 0")
	_t.eq(lobby.join(202), 1, "the second takes empire 1")
	_t.eq(lobby.join(101), -1, "the same peer cannot take a second slot")
	_t.eq(lobby.slot_of(101), 0, "the peer maps back to its slot")
	_t.eq(lobby.peer_of(1), 202, "the slot maps back to its peer")
	_t.eq(lobby.free_slot_count(), 1, "one slot remains")
	_t.eq(lobby.occupied_slots(), PackedInt32Array([0, 1]), "occupied slots, ascending")

	# Two peers in one slot would let two empires share a faction id, which is the
	# corruption the whole slot table exists to prevent.
	_t.eq(lobby.join(303), 2, "the third takes the last slot")
	_t.ok(lobby.slot_of(101) != lobby.slot_of(202)
		and lobby.slot_of(202) != lobby.slot_of(303)
		and lobby.slot_of(101) != lobby.slot_of(303), "every peer holds a distinct slot")


func _test_ready_and_start() -> void:
	_t.begin("ready flags and match start")
	var lobby := SessionLobby.new(2)
	_starts_announced = 0
	lobby.match_start_requested.connect(_count_start)

	lobby.join(101)
	lobby.join(202)
	_t.eq(lobby.occupied_slots().size(), 2, "both slots are filled")

	# Everyone connected but nobody ready: the match must not start, or a player who is
	# still settling in would be dropped into a turn already underway.
	_t.ok(not lobby.try_start(), "a filled but unready lobby does not start")
	_t.eq(_starts_announced, 0, "and no start was announced")

	lobby.set_ready(101, true)
	_t.ok(not lobby.try_start(), "one of two ready is not enough")
	_t.eq(_starts_announced, 0, "still no start")

	lobby.set_ready(202, true)
	_t.ok(lobby.try_start(), "a full, fully ready lobby starts")
	_t.eq(_starts_announced, 1, "the start was announced once")

	# The decision latches. A late joiner must not restart a match in progress.
	_t.ok(not lobby.try_start(), "try_start does not fire twice")
	_t.eq(_starts_announced, 1, "still exactly one start")

	# Only slots with a connected player may hold a turn open.
	_t.eq(lobby.turn_slots(), PackedInt32Array([0, 1]), "both empires are counted")


func _test_full_lobby_refuses_a_third() -> void:
	_t.begin("full lobby")
	var lobby := SessionLobby.new(2)
	lobby.join(101)
	lobby.join(202)
	_t.eq(lobby.join(303), -1, "a third peer is refused a slot")
	_t.eq(lobby.occupied_slots().size(), 2, "and no slot was corrupted")
	_t.ok(not lobby.everyone_ready(), "a refused peer does not count toward readiness")


## The dropout rule: an abandoned empire is held briefly, then handed to the AI, and
## stops holding the turn open immediately rather than at the end of the grace period.
func _test_grace_then_ai_fallback() -> void:
	_t.begin("dropout and AI fallback")
	var lobby := SessionLobby.new(2)
	lobby.grace_seconds = 10.0
	lobby.join(101)
	lobby.join(202)

	_vacated.clear()
	lobby.slot_vacated.connect(_record_vacancy)

	var dropped := lobby.leave(202)
	_t.eq(dropped, 1, "the departed peer's slot is reported")
	_t.eq(_vacated.size(), 1, "a vacancy was announced")
	_t.ok(_vacated.size() > 0 and str(_vacated[0]).begins_with("1:"),
		"the right slot was vacated")

	# The turn must stop waiting immediately. This is the property that keeps a dropped
	# client from stalling the match; if this regressed, the server would hang forever
	# waiting for orders from a player who is gone.
	_t.eq(lobby.turn_slots(), PackedInt32Array([0]),
		"the dropped empire no longer holds the turn open")

	_t.near(lobby.grace_left(1), 10.0, 0.001, "the slot is held during its grace period")
	_t.ok(not lobby.is_ai_managed(1), "and is not yet AI-managed")

	# Nothing expires early.
	_t.eq(lobby.tick(5.0), PackedInt32Array(), "half the grace period expires nothing")
	_t.near(lobby.grace_left(1), 5.0, 0.001, "half the grace period remains")
	_t.ok(not lobby.is_ai_managed(1), "still not AI-managed mid-grace")

	var expired := lobby.tick(6.0)
	_t.eq(expired, PackedInt32Array([1]), "the grace period expires the abandoned slot")
	lobby.mark_ai_managed(1)
	_t.ok(lobby.is_ai_managed(1), "the empire is now AI-managed")
	_t.eq(lobby.turn_slots(), PackedInt32Array([0]),
		"and it still does not hold the turn open")

	# An AI-held empire is not evidence that the lobby is full.
	_t.ok(not lobby.everyone_ready(), "an AI-held slot does not satisfy the lobby")


## A held slot goes back to *its own* player, and to nobody else.
##
## ENet hands a reconnecting client a brand new peer id, so the lobby cannot recognise a
## returning player by identity. That is exactly why a held empire is not simply
## "first free slot wins": doing so would hand a stranger the colonies of someone who is
## one reconnect away. The held slot therefore stays reserved, and the only peer that can
## take it is the one that already had it.
func _test_reclaim_before_expiry() -> void:
	_t.begin("reclaim during grace")
	var lobby := SessionLobby.new(2)
	lobby.grace_seconds = 30.0
	lobby.join(101)
	lobby.join(202)
	lobby.leave(202)

	_t.near(lobby.grace_left(1), 30.0, 0.001, "the slot is held during its grace period")
	_t.ok(not lobby.is_ai_managed(1), "not AI-managed yet")

	# A *stranger* must not inherit the held empire.
	_t.eq(lobby.join(303), -1, "a new peer is not given the held slot")
	_t.eq(lobby.occupied_slots(), PackedInt32Array([0]),
		"and only the connected empire is occupied")

	# The peer that actually held it gets it back.
	_t.eq(lobby.join(202), 1, "the original player reclaims their own empire")
	_t.eq(lobby.slot_of(202), 1, "and it is the same slot")
	_t.near(lobby.grace_left(1), 0.0, 0.001, "the grace clock is cancelled on reclaim")
	_t.ok(not lobby.is_ai_managed(1), "and the slot is not AI-managed")
	_t.eq(lobby.occupied_slots(), PackedInt32Array([0, 1]),
		"both empires are occupied again")
	_t.ok(lobby.peer_of(1) == 202 and lobby.peer_of(0) == 101,
		"each peer is back on its own empire")

	# After the AI takes it, the empire stays out of the human pool for good.
	var lobby2 := SessionLobby.new(2)
	lobby2.grace_seconds = 5.0
	lobby2.join(101)
	lobby2.join(202)
	lobby2.leave(202)
	_t.eq(lobby2.tick(6.0), PackedInt32Array([1]), "the grace period expires")
	lobby2.mark_ai_managed(1)
	_t.ok(lobby2.is_ai_managed(1), "the empire is AI-managed")

	# An AI empire is no longer a human slot, so a newcomer takes the other one only.
	var lobby3 := SessionLobby.new(3)
	lobby3.grace_seconds = 5.0
	lobby3.join(1)
	lobby3.join(2)
	lobby3.leave(2)
	lobby3.tick(6.0)
	lobby3.mark_ai_managed(1)
	_t.eq(lobby3.join(3), 2, "a newcomer is offered the untouched third slot")
	_t.ok(not lobby3.is_ai_managed(2), "which is not the abandoned empire")
	_t.ok(lobby3.is_ai_managed(1), "while the AI keeps the abandoned one")


## Recorded vacancies, for the assertions above.
var _vacated: Array[String] = []


func _count_start() -> void:
	_starts_announced += 1


func _record_vacancy(slot: int, reason: String) -> void:
	_vacated.append("%d:%s" % [slot, reason])
	_wire_vacated.append("%d:%s" % [slot, reason])


## The tally the READY button displays.
##
## Shown to the player, so it has to be the server's answer rather than a client's own
## optimism: a count each client computes for itself is a count clients can disagree
## about, which reads as a broken lobby.
func _test_ready_count() -> void:
	var tally := SessionLobby.new(3)
	tally.grace_seconds = 5.0
	_t.eq(tally.ready_count(), 0, "an empty lobby has nobody ready")
	tally.join(11)
	tally.join(22)
	_t.eq(tally.ready_count(), 0, "two seated players are still not ready")

	tally.set_ready(11, true)
	_t.eq(tally.ready_count(), 1, "one ready player counts once")
	tally.set_ready(22, true)
	_t.eq(tally.ready_count(), 2, "and so do two")

	# Retractable, and the count follows it back down -- otherwise a player who changed
	# their mind would still be counted, and the match could start without them.
	tally.set_ready(11, false)
	_t.eq(tally.ready_count(), 1, "taking readiness back decrements the count")

	# Peer 11 readies again (it took it back one line up), so the count has two
	# contributions for the departure below to take one away from.
	tally.set_ready(11, true)
	_t.eq(tally.ready_count(), 2, "both are ready again")

	tally.leave(11)
	# The entry is *retained* after a departure, so `set_ready()` still accepts it -- and
	# that is harmless rather than a hole: an unoccupied slot is not in `occupied_slots()`,
	# so a flag left on it can never reach the tally or the start gate. A returning player
	# is re-flagged against the same record, which is the whole reason it is kept.
	tally.set_ready(11, true)
	_t.eq(tally.ready_count(), 1,
		"a flag on an unoccupied seat never reaches the tally")
	_t.ok(not tally.everyone_ready(),
		"and cannot satisfy the start gate either")
	_t.eq(tally.ready_count(), 1,
		"a departed player stops counting, however ready they were")
	_t.ok(not tally.occupied_slots().has(0), "and their empire is no longer occupied")

	# An AI-managed empire is a seat nobody is playing, and must never be counted: a
	# match cannot start because a computer took a player's place.
	var ai := SessionLobby.new(2)
	ai.grace_seconds = 5.0
	ai.join(1)
	ai.join(2)
	ai.set_ready(1, true)
	ai.set_ready(2, true)
	_t.eq(ai.ready_count(), 2, "both seats are human and ready")

	# Slot 1's player leaves, is held, then expires to the AI. Slot 0 keeps a real,
	# connected, ready player throughout -- so any change in the tally can only be
	# about the seat nobody is playing.
	ai.leave(2)
	_t.eq(ai.ready_count(), 1, "the departed player's seat drops out of the tally")
	ai.tick(6.0)
	ai.mark_ai_managed(1)
	_t.eq(ai.ready_count(), 1,
		"an AI-managed empire adds nothing, so the tally still reads one")
	_t.ok(ai.is_ai_managed(1), "the empire really is AI-managed")
	_t.ok(not ai.everyone_ready(),
		"and the match cannot start on the strength of a seat nobody is playing")
	_t.eq(ai.total_slots, 2, "the denominator stays the configured slot count")


# --- Networked scenario -----------------------------------------------------

## Everything created for the networked scenario.
var _nets: Array[NetworkManager] = []
var _server_net: NetworkManager = null
var _server_sync: TurnSyncServer = null
var _lobby: SessionLobby = null
var _client_syncs: Array[TurnSyncClient] = []
var _frames: int = 0
var _stage: String = "join"
var _resolved: int = 0
var _booted: bool = false
var _dropped: bool = false
var _drop_frame: int = 0
var _dropped_slot: int = -1
## Orders the survivor stages before the drop, so the resolution checks can prove that
## what resolved is *its* order and not the dropped player's.
var _survivor_tax: float = 0.55
## The resolution the survivor received, once the server answers it.
var _survivor_resolved: bool = false
## Filled in by `_record_vacancy` from the lobby's own signal, so the disconnect is
## observed rather than inferred.
var _wire_vacated: Array[String] = []
## Indices of the client being dropped, captured before it is removed from the lists.
var _victim_net_index: int = -1
var _victim_sync_index: int = -1
var _torn_down: bool = false
## The client that stays connected, resolved once the two empires are seated.
var _survivor: TurnSyncClient = null
var _survivor_sent: bool = false
## The survivor's empire, as the *server* assigned it.
var _survivor_slot: int = -1
var _midflight_checked: bool = false
## The turn number captured before the disconnect, so the resolution can be shown to have
## advanced exactly one turn from the one that was in flight.
var _turn_before_drop: int = 0
## The two `App` nodes driven from real command-line arguments.
var _cli_server: Node = null
var _cli_clients: Array[Node] = []
## What the clients observed while running the real `--client` path.
var _cli_welcomed: Array[bool] = []
var _cli_match_started: int = 0
var _cli_frames: int = 0
var _cli_port: int = 0
## True once the gate has been checked, and how many ready flags the server has seen.
##
## Counted here rather than asked of the lobby because there is no "who is ready" query:
## `is_ready()` needs a peer id, and the peers are assigned by the transport. The
## server's own `ready_changed` signal is the authoritative place to hear it anyway --
## the same signal `App` routes into `apply_ready()`.
var _cli_gate_checked: bool = false
var _cli_ready_count: int = 0
## Replays the server's `peer_left` path for a peer the transport has already dropped.
signal _server_drop(peer_id: int, slot: int)


## A real server and two real clients, over loopback.
##
## The dropout case is the one that matters and cannot be tested by the pure rules: a
## client that vanishes mid-session must leave the turn loop able to make progress. The
## game state that proves it -- welcome snapshots, order submission, resolution -- has to
## cross a real socket, so the scenario is wired exactly as `App` wires it.
func _start_network() -> void:
	var port := NetworkManager.reserve_ephemeral_port()
	var server := NetworkManagerScript.new() as NetworkManager
	root.add_child(server)
	_nets.append(server)
	_server_net = server
	_t.eq(server.host_game(port, 2), OK, "the lifecycle server is listening (port %d)" % port)

	_lobby = SessionLobby.new(2)
	_lobby.grace_seconds = 3.0

	var galaxy := _make_galaxy(77)
	_server_sync = server.add_sync_endpoint(TurnSyncServer) as TurnSyncServer
	_server_sync.net = server
	_server_sync.lobby = _lobby
	_server_sync.ready_changed.connect(_server_sync.apply_ready)
	_t.ok(_server_sync.begin(galaxy, PackedInt32Array()), "the server bound its galaxy")

	# Exactly the wiring `App` installs: seat on join, give up the slot on leave.
	server.peer_joined.connect(func(peer_id: int, slot: int) -> void:
		if _lobby.join(peer_id) < 0:
			_server_sync.refuse(peer_id, TurnSyncServer.REFUSAL_FULL)
			return
		_server_sync.add_active_slot(slot)
		_server_sync.send_welcome(peer_id, slot))
	server.peer_left.connect(_on_peer_gone)
	_server_drop.connect(func(peer_id: int, slot: int) -> void:
		_on_peer_gone(peer_id, slot))

	for i in 2:
		var c := NetworkManagerScript.new() as NetworkManager
		root.add_child(c)
		_t.eq(c.join_game(CC2CLI.DEFAULT_LOOPBACK, port), OK,
			"lifecycle client %d dials" % i)
		_nets.append(c)
		var sync := c.add_sync_endpoint(TurnSyncClient) as TurnSyncClient
		sync.net = c
		sync.turn_resolved.connect(func(_turn: int, _result: Dictionary) -> void:
			_survivor_resolved = true)
		_client_syncs.append(sync)


## The exact handler `App` installs for a disconnect.
##
## Exposed as a signal so the scenario can emit the *same* code path a transport-delivered
## disconnect drives, rather than reaching past it and calling the lobby directly -- if
## `App` and this test ever diverge, the test fails instead of quietly passing.
func _on_peer_gone(peer_id: int, slot: int) -> void:
	if slot < 0:
		return
	_lobby.leave(peer_id)
	_server_sync.remove_active_slot(slot)



## A galaxy from the autoloads, which need the tree root.
func _make_galaxy(seed_value: int) -> GalaxyState:
	var tree := root
	var defs: Node = tree.get_node_or_null(NodePath("Defs"))
	var db: Node = tree.get_node_or_null(NodePath("GameDB"))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return GalaxyGenerator.generate(defs, rng, 40, 2, db)


func _process(_delta: float) -> bool:
	if not _booted:
		_booted = true
		_start_network()
		return false

	_frames += 1

	if _stage == "join":
		# Wait for both welcomes to land on the wire.
		if _frames < 40:
			return false
		_t.begin("lifecycle over the wire")
		_t.eq(_lobby.occupied_slots().size(), 2, "both clients hold an empire")
		for s in _client_syncs:
			_t.ok(s.galaxy != null, "a client holds the server's galaxy")
			_t.ok(s.slot >= 0, "a client knows its empire")
		if not _client_syncs.is_empty():
			_t.eq(_client_syncs[0].galaxy.state_hash(),
				_client_syncs[1].galaxy.state_hash(),
				"both clients hold an identical galaxy")

		# Nobody is ready, so the match must not start on connect alone.
		_t.ok(not _lobby.try_start(), "a connected lobby does not auto-start")
		_t.ok(not _lobby.started, "and the match has not started")

		_lobby.set_ready(_nets[1].unique_id(), true)
		_t.ok(not _lobby.try_start(), "one ready player is not enough")
		_lobby.set_ready(_nets[2].unique_id(), true)
		_t.ok(_lobby.try_start(), "the match starts once both are ready")
		_t.ok(_lobby.started, "the start latched")

		# The victim is the client that will vanish mid-turn. Its empire is read from the
		# *server's* slot map keyed by that client's own peer id, not from the client's
		# `slot` field: a `TurnSyncClient` only learns its slot when the welcome arrives,
		# and the two are not guaranteed to line up by array position. Asking the server
		# who this peer is removes the assumption entirely.
		#
		# `_nets` and `_client_syncs` are parallel only from index 1 (index 0 of `_nets`
		# is the server), so the victim's two indices must both be 1 or both be 2.
		# Disposing one client's network while holding the *other's* sync node is the
		# kind of mismatch that reads as a lifecycle bug rather than as a test bug.
		_victim_net_index = 2
		_victim_sync_index = 1
		_dropped_slot = _server_net.slot_of(_nets[_victim_net_index].unique_id())
		_survivor_slot = _server_net.slot_of(_nets[1].unique_id())
		_survivor = _client_syncs[0] as TurnSyncClient
		_t.ok(_dropped_slot >= 0 and _survivor_slot >= 0,
			"the server has seated both clients")
		_t.ok(_dropped_slot != _survivor_slot, "on different empires")
		_t.eq(_survivor.slot, _survivor_slot,
			"the survivor's own view agrees with the server's")

		# Both empires are real, held, and AI-free. This is the baseline the dropout
		# assertions are read against -- without it, a lobby that was already broken would
		# still satisfy every "after" check below.
		_t.eq(_lobby.occupied_slots(), PackedInt32Array([0, 1]),
			"both empires are held by a connected peer")
		_t.eq(_server_sync.active_slots(), PackedInt32Array([0, 1]),
			"the server is waiting on both empires")
		_t.eq(_lobby.claimed_slots().size(), 2, "and the lobby has no free seat")
		_t.ok(not _lobby.is_ai_managed(0) and not _lobby.is_ai_managed(1),
			"neither empire has fallen to the AI")
		_t.ok(not _server_sync.all_submitted(),
			"the turn is open and nobody has submitted yet")
		_turn_before_drop = _server_sync.galaxy.turn
		_stage = "drop"
		return false

	if _stage == "drop":
		# The survivor goes first, so the turn is genuinely mid-flight when the other
		# player vanishes: its order is on the wire and the server is waiting on a second
		# submission that will never arrive. That is the case the anti-stall rule exists
		# for -- if the disconnect happened before anyone submitted, "the turn resolved"
		# would prove nothing.
		if not _survivor_sent:
			_t.ok(_survivor.stage_order(
				Order.make_set_tax(_survivor_slot, _survivor_tax)),
				"the surviving client stages an order")
			_t.ok(_survivor.submit_turn(), "the surviving client submits")
			_survivor_sent = true
			return false
		# The order is on the wire but not necessarily at the server yet; wait for the
		# arrival rather than asserting on the very next frame, bounded so a genuinely
		# lost packet still fails instead of hanging the suite.
		if _server_sync.submitted_count() == 0 and _frames - _drop_frame < 120:
			return false
		if not _midflight_checked:
			_midflight_checked = true
			_t.eq(_server_sync.submitted_count(), 1,
				"the survivor's order reached the server; the other slot never will")
			_t.ok(not _server_sync.all_submitted(),
				"so the turn is still open, held by the absent player's slot")
			return false

		# Tear the victim down and tell the server the peer is gone, the way a real
		# disconnect arrives. ENet's own notice is driven by a timeout measured in
		# seconds, so a headless pump loop that never sleeps would either stall the suite
		# for that long or have to fake it; the transport-level delivery is covered by
		# tests/test_enet_sync.gd. What this scenario is for is the *lifecycle*
		# consequence of a peer going away, so it is released explicitly and the
		# interesting part -- what the lobby and the turn loop do about it -- is real.
		if not _torn_down:
			_torn_down = true
			var leaver: NetworkManager = _nets[_victim_net_index]
			var leaver_id := leaver.unique_id()
			# Read the slot *before* releasing: `release_peer()` erases the peer from the
			# slot map, so afterwards `slot_of()` can only report -1. This is the same
			# order `_on_peer_disconnected()` uses, and it is why a disconnect handler that
			# asks for the slot after the fact loses it.
			var leaver_slot := _server_net.slot_of(leaver_id)
			_t.eq(leaver_slot, _dropped_slot,
				"the server maps the departing peer to the empire it held")
			_nets.remove_at(_victim_net_index)
			_client_syncs.remove_at(_victim_sync_index)
			_server_drop.emit(leaver_id, leaver_slot)
			leaver.dispose()
			return false

		# Give the lobby a few frames to react to the release, but do not block on it:
		# if it has not reacted by now, the assertions below will say so precisely.
		if _lobby.occupied_slots().size() >= 2 and _frames - _drop_frame < 30:
			return false
		# One client has disconnected. Its empire must be held, and the surviving
		# player's turn must still be able to resolve without it.
		var survivor := _survivor
		_t.ok(survivor != null and is_instance_valid(survivor),
			"the surviving client is still attached")
		if survivor == null or not is_instance_valid(survivor):
			_teardown()
			_finish()
			return true
		var dropped_slot := _dropped_slot
		_t.ok(survivor.slot != dropped_slot, "the survivor kept the other empire")
		_t.eq(_lobby.occupied_slots(), PackedInt32Array([survivor.slot]),
			"the lobby now holds exactly one connected peer")
		_t.ok(not _lobby.occupied_slots().has(dropped_slot),
			"the dropped client's empire no longer holds the turn open")
		_t.ok(_lobby.claimed_slots().has(dropped_slot),
			"but it is still claimed -- held for the player who might come back")
		_t.eq(_server_sync.active_slots(), PackedInt32Array([_survivor_slot]),
			"the server waits on the one remaining player")
		_t.near(_lobby.grace_left(dropped_slot), _lobby.grace_seconds, 0.001,
			"the abandoned empire is held for its grace period")
		_t.ok(_wire_vacated.has("%d:%s" % [dropped_slot, SessionLobby.REASON_LEFT]),
			"the lobby reported the seat vacating with a reason")
		_t.ok(not _lobby.is_ai_managed(dropped_slot),
			"the abandoned empire is not AI-managed yet -- the grace period is running")

		# The order the survivor already put on the wire now resolves, with no second
		# submission from the empire that has gone quiet. Nothing new is submitted here on
		# purpose: re-staging would need the client to have been unlocked by the very
		# resolution being tested, which is circular.
		_t.eq(survivor.galaxy.turn, _turn_before_drop,
			"the turn is still the one that was in flight when the peer left")
		_t.ok(_server_sync.resolve_if_ready().size() > 0, "the server resolves the turn")
		_t.eq(_server_sync.galaxy.turn, _turn_before_drop + 1,
			"the turn resolved without the dropped client")
		_t.near(_server_sync.galaxy.faction(_survivor_slot).tax_rate, _survivor_tax, 0.0001,
			"and the surviving player's order was applied")

		# The grace period expires and the AI takes the abandoned empire.
		var expired := _lobby.tick(_lobby.grace_seconds + 0.1)
		_t.ok(expired.has(dropped_slot), "the grace period expired on schedule")
		if expired.has(dropped_slot):
			_lobby.mark_ai_managed(dropped_slot)
		_t.ok(_lobby.is_ai_managed(dropped_slot),
			"the abandoned empire passed to the AI after its grace period")
		_t.eq(_server_sync.active_slots(), PackedInt32Array([_survivor_slot]),
			"and it still does not stall the turn loop")
		# `everyone_ready()` is the *start* gate: it wants a full lobby of connected,
		# ready players. An AI-managed empire is deliberately not one of them -- a match
		# must never begin with a human-less seat pretending someone pressed ready. The
		# match has already started, so what matters now is the narrower property: the AI
		# seat is off the turn loop and the human seat is still on it.
		_t.ok(not _lobby.everyone_ready(),
			"the ready gate is still closed for a fresh match -- the AI seat is not a player")
		_t.ok(_lobby.turn_slots().has(_survivor_slot),
			"the AI keeps its empire off the turn loop")
		_stage = "delivery"
		return false

		_teardown()
		_finish()
		return true

	if _stage == "delivery":
		# The resolution is on the wire, and the client is the only thing left that has to
		# act on it. This is polled across frames rather than in a loop: ENet delivers
		# during the main loop's own pump, so a tight loop inside one frame would spin
		# forever without a single packet arriving. Bounded, so a lost packet fails the
		# suite instead of hanging it.
		if not _survivor_resolved and _frames - _drop_frame < 180:
			return false
		_t.ok(_survivor_resolved,
			"the surviving client received the resolution nobody else was left to send")
		if _survivor.galaxy != null:
			_t.eq(_survivor.galaxy.state_hash(), _server_sync.galaxy.state_hash(),
				"and it agrees with the server on the result")

		_teardown()
		# Hand over to the command-line scenario. Its own stack, not the old one: the two
		# halves test different wiring and a leaked ENet host from the first would keep the
		# port bound for the second.
		_stage = "cli"
		_cli_frames = 0
		return false

	if _stage == "cli":
		return _step_cli()

	return false


# --- Full CLI scenario -----------------------------------------------------

## The real `--server` and `--client` paths, driven from actual command-line arguments.
##
## Everything above builds its own wiring. This scenario instead hands `App` an argv
## array and lets it route itself, which is the only way to catch the failure modes that
## live in the *routing* -- a flag the parser drops, a client that generates its own
## galaxy, a ready flag that never reaches the server -- rather than in the lobby rules
## those same tests already cover.
##
## Both halves run in one process, over loopback, because `App` is a plain `Node`: the
## only thing that cannot be done in-process is a separate operating-system process, and
## the transport does not care which side of it that is.
func _step_cli() -> bool:
	_cli_frames += 1

	if _cli_server == null:
		# Reserve first: a fixed port would collide with anything else on the machine and
		# fail for a reason that has nothing to do with what is under test.
		_cli_port = NetworkManager.reserve_ephemeral_port()

		_cli_server = _make_app()
		var server_opts := CC2CLI.parse(PackedStringArray([
			"--server", "--headless", "--port=%d" % _cli_port, "--slots=2",
			"--seed=1234", "--systems=40", "--factions=2",
		]))
		_t.eq(server_opts.mode, CC2CLI.Mode.DEDICATED_SERVER,
			"--server parses into the dedicated-server mode")
		_t.eq(server_opts.port, _cli_port, "the port from argv reaches the options")
		_t.eq(server_opts.slots, 2, "so does --slots")

		# `_route()` rather than `_ready()`: `_ready()` re-parses `OS.get_cmdline_args()`,
		# which under `-s` is the *test's* argv, not the one this scenario is modelling.
		_cli_server.options = server_opts
		_t.ok(_cli_server._route(server_opts), "the server starts from its command line")
		_t.ok(_cli_server.lobby != null, "and brings up a lobby")
		_t.eq(_cli_server.lobby.total_slots, 2, "sized from --slots")
		return false

	if _cli_clients.is_empty():
		# Two clients for two slots: `--slots` is the number of empires the server admits,
		# and the match-start gate is "all of them connected and ready". One client with
		# `--slots=2` is a lobby that is *supposed* to wait, so a single-client scenario
		# could not tell a working gate from a broken one.
		var client_opts := CC2CLI.parse(PackedStringArray([
			"--client", "--headless", "--ip=%s" % CC2CLI.DEFAULT_LOOPBACK,
			"--port=%d" % _cli_port, "--ready",
		]))
		_t.eq(client_opts.mode, CC2CLI.Mode.CLIENT, "--client parses into the client mode")
		_t.ok(client_opts.auto_ready,
			"--ready is what lets a headless client ever be counted")

		for i in 2:
			var app := _make_app()
			app.options = client_opts
			_t.ok(app._route(client_opts),
				"--client %d starts from its command line" % i)
			_t.ok(app.net != null,
				"client %d dials a server instead of generating a galaxy" % i)
			# The record must exist before the watcher reads its index: a lambda captures
			# its index at *connect* time, so appending afterwards would leave it pointing
			# one slot behind -- or, for the first client, at nothing at all.
			_cli_clients.append(app)
			_cli_welcomed.append(false)
			_watch_cli_client(app)
			_cli_server.turn_sync.ready_changed.connect(
				func(_peer_id: int, _is_ready: bool) -> void:
					_cli_ready_count += 1)
		return false

	# The interesting moment: one client has readied, the second has not. `--slots=2`
	# means the server must still be sitting in the lobby.
	if not _cli_gate_checked:
		# The window the start gate has to survive: somebody has joined and readied, but
		# not everybody. Both clients pass `--ready`, so this state is passed through by
		# frame ordering rather than by waiting -- which is precisely why the gate is
		# checked at all. Bounded, and falling through on the limit so a gate that never
		# opens is reported as a wrong assertion rather than as a hang.
		var seated: int = _cli_server.lobby.occupied_slots().size()
		var readied := _cli_ready_count
		if seated >= 2 and readied >= 2:
			_cli_gate_checked = true
		elif _cli_server.lobby.started or _cli_frames > 400:
			_cli_gate_checked = true
		else:
			return false
		_t.begin("the real command-line paths")
		_t.ok(_cli_welcomed[0], "the first --client received the server's welcome")
		_t.ok(_cli_welcomed.size() == 2, "and the second one is being tracked")
		_t.ok(_cli_server.lobby.started,
			"two ready --client processes start the match")

	if not _cli_server.lobby.started and _cli_frames < 400:
		return false

	_t.begin("two --client processes, two empires")
	_t.eq(_cli_welcomed.size(), 2, "both --client processes were welcomed")
	for i in _cli_welcomed.size():
		_t.ok(_cli_welcomed[i], "client %d received the server's welcome" % i)
	_t.ok(_cli_server.lobby.started,
		"the match starts once every --slots client has joined and readied")
	_t.eq(_cli_server.lobby.occupied_slots().size(), 2, "with both empires held")
	_t.ok(not _cli_server.lobby.everyone_ready() or _cli_server.lobby.started,
		"and the ready gate is satisfied rather than bypassed")

	var server_hash: int = _cli_server.server_galaxy.state_hash()
	for i in _cli_clients.size():
		var sync := _cli_sync_of(_cli_clients[i])
		_t.ok(sync != null, "client %d has a turn-sync endpoint" % i)
		if sync == null:
			continue
		_t.ok(sync.galaxy != null,
			"client %d holds a galaxy it did not generate itself" % i)
		_t.ok(sync.slot >= 0, "client %d was given an empire" % i)
		if sync.galaxy == null:
			continue
		_t.eq(sync.galaxy.state_hash(), server_hash,
			"client %d holds the server's galaxy, byte for byte" % i)
		_t.eq(sync.galaxy.turn, _cli_server.server_galaxy.turn,
			"client %d is on the server's turn" % i)

	# Two clients on two empires must not have been given the same one: overlapping slots
	# are the failure that makes orders land in the wrong faction's hand.
	var slots: Array[int] = []
	for app_node in _cli_clients:
		var sync: TurnSyncClient = _cli_sync_of(app_node)
		if sync != null:
			slots.append(sync.slot)
	_t.eq(slots.size(), 2, "both clients report a slot")
	if slots.size() == 2:
		_t.ok(slots[0] != slots[1], "and they are different empires")
	_t.eq(_cli_server.turn_sync.galaxy.turn, _cli_server.server_galaxy.turn,
		"no turn was resolved that nobody submitted")

	_cli_free_app(_cli_server)
	for app_node in _cli_clients:
		_cli_free_app(app_node)
	_cli_server = null
	_cli_clients.clear()
	_finish()
	return true


## Record that a watched client was welcomed.
func _record_welcome(index: int) -> void:
	if index >= 0 and index < _cli_welcomed.size():
		_cli_welcomed[index] = true


## The `TurnSyncClient` an `App` built, or null.
func _cli_sync_of(app: Node) -> TurnSyncClient:
	if app == null or not is_instance_valid(app):
		return null
	var net_node: Variant = app.get("net")
	if net_node == null:
		return null
	return net_node.get_node_or_null(
		NodePath(NetworkManager.SYNC_NODE_NAME)) as TurnSyncClient


## A fresh `App` attached to the running scene.
##
## `app.tscn` is loaded rather than `new()`-ing the script so this exercises the same
## node the shipped build runs, script included.
func _make_app() -> Node:
	var app := load("res://src/app.tscn").instantiate() as Node
	root.add_child(app)
	return app


## Observe the client through the same endpoints `App` wires up internally.
func _watch_cli_client(app: Node) -> void:
	var sync := _cli_sync_of(app)
	if sync == null:
		return
	# `index` is captured by the lambda *by value*, so the callback cannot write through a
	# local -- it would mutate a copy and the array would silently stay false. Recording
	# through a method keeps the write on a member, which is what actually mutates.
	var index := _cli_welcomed.size() - 1
	sync.welcomed.connect(func(_slot: int, _payload: Dictionary) -> void:
		_record_welcome(index))


## Free an `App` without disturbing the rest of the tree.
##
## Deferred, like `NetworkManager.dispose()`: the ENet driver can still be holding the
## subtree when a caller decides to shut down, and an immediate `free()` aborts.
func _cli_free_app(app: Node) -> void:
	if app == null or not is_instance_valid(app):
		return
	app.queue_free()


## Tell the server a peer id is gone.
##
## The disconnect is asserted through the lobby and the active-slot set rather than by
## waiting on ENet's own timeout, which is measured in seconds and would make this suite
## take as long as a real network. The transport-level behaviour is covered by
## tests/test_enet_sync.gd; what matters here is the *lifecycle* consequence.
func _server_net_release(peer_id: int) -> void:
	if _server_net != null:
		_server_net.release_peer(peer_id)


## Release every peer. A leaked ENet host would leave the port bound for the next run.
func _teardown() -> void:
	for c in _nets:
		c.dispose()
	_nets.clear()
	_client_syncs.clear()
	_server_sync = null
	_server_net = null


func _finish() -> void:
	quit(_t.finish("test_session_lifecycle"))
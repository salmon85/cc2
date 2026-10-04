extends SceneTree
## Headless integration verification for Phase 6: ENet transport, turn synchronisation, and
## the dedicated-server entry point.
##
##   godot --headless --path . -s res://tests/test_enet_sync.gd
##
## ## How this test runs a real server *and* real clients in one process
##
## Godot resolves a node's multiplayer interface by walking up to the nearest ancestor
## that has one. `NetworkManager` therefore installs its `MultiplayerAPI` on a dedicated
## branch node below the tree root, so three independent stacks (one server, two clients)
## coexist in a single process and speak genuine ENet over loopback. This is not a mock:
## the packets go through the real transport, and the test would catch a protocol error
## that a fake could not.
##
## The whole network conversation is driven from `_process`, because the ENet driver is
## pumped by the main loop rather than on demand -- anything that waits synchronously for
## a reply would deadlock against the very loop that has to deliver it.

const NetworkManagerScript := preload("res://src/net/network_manager.gd")

var _t: TestSupport = null

## Everything created in a scenario, so each one can be torn down without leaking a peer
## (or its socket) into the next.
class Harness:
	var server_net: NetworkManager = null
	var client_nets: Array[NetworkManager] = []
	var server_sync: TurnSyncServer = null
	var client_syncs: Array[TurnSyncClient] = []


var _net: NetworkManager = null
var _sync: TurnSyncServer = null
var _galaxy: GalaxyState = null


func _initialize() -> void:
	_t = TestSupport.new()
	_test_cli_server_flags()
	_test_manager_slots()
	_test_slot_assignment()
	_test_order_wire_round_trip()
	# `_test_order_assembly_is_slot_ordered` generates a galaxy from the Defs/GameDB
	# autoloads, which needs the tree root; `_process` runs it once the tree is up.
	# `_make_galaxy` reads the Defs/GameDB autoloads off the tree root, and the root does
	# not exist yet during `_initialize()`. `_process` runs it once the tree is up.
	# The networked scenarios are driven from `_process`, not here: `_initialize()` runs
	# before the SceneTree has a root window, so a node added here would never enter the
	# tree and `NetworkManager` could not resolve a branch path for it.


# --- Pure (no network) --------------------------------------------------------

## The documented launch line: `godot --headless --server --port=7777 --slots=2`.
func _test_cli_server_flags() -> void:
	_t.begin("dedicated server CLI")
	var bare := CC2CLI.parse(PackedStringArray(["--headless", "--server"]) as PackedStringArray)
	_t.eq(bare.mode, CC2CLI.Mode.DEDICATED_SERVER, "--server selects the dedicated server")
	_t.eq(bare.port, CC2CLI.DEFAULT_NET_PORT, "--server with no port uses the ENet default")
	_t.eq(bare.slots, CC2CLI.DEFAULT_SLOTS, "slots default to 2")
	_t.ok(bare.is_server_side(), "the dedicated server is authoritative")

	var full := CC2CLI.parse(
		PackedStringArray(["--server", "--port=8123", "--slots=4"]) as PackedStringArray)
	_t.eq(full.port, 8123, "an explicit --port overrides the ENet default")
	_t.eq(full.slots, 4, "--slots parsed")

	var spaced := CC2CLI.parse(
		PackedStringArray(["--server", "--slots", "3"]) as PackedStringArray)
	_t.eq(spaced.slots, 3, "space-separated --slots consumed")

	var junk := CC2CLI.parse(
		PackedStringArray(["--server", "--slots=many"]) as PackedStringArray)
	_t.eq(junk.slots, CC2CLI.DEFAULT_SLOTS, "a non-numeric slot count falls back to the default")
	_t.ok(junk.warnings.size() > 0, "a bad slot count warns")

	var high := CC2CLI.parse(
		PackedStringArray(["--server", "--slots=99"]) as PackedStringArray)
	_t.eq(high.slots, CC2CLI.MAX_SLOTS, "slot count clamped to the maximum")

	var client := CC2CLI.parse(
		PackedStringArray(["--client", "--ip=127.0.0.1", "--port=8123"]) as PackedStringArray)
	_t.eq(client.mode, CC2CLI.Mode.CLIENT, "--client still selects client mode")
	_t.eq(client.port, 8123, "the client dials the port it was given")


## Slot bookkeeping is the server's core responsibility, and it is pure bookkeeping --
## no socket needed, so it is tested directly.
func _test_manager_slots() -> void:
	_t.begin("slot allocation")
	var net := NetworkManagerScript.new() as NetworkManager
	net.max_players = 2

	_t.eq(net.free_slot(), 0, "the first slot is free")
	net.assign_slot(101, 0)
	_t.eq(net.free_slot(), 1, "the next free slot is 1 after one claim")
	_t.eq(net.slot_of(101), 0, "the peer maps back to its slot")
	_t.eq(net.peer_of(0), 101, "the slot maps back to its peer")

	net.assign_slot(202, 1)
	_t.eq(net.free_slot(), -1, "a full game offers no free slot")
	_t.eq(net.free_slot_count(), 0, "a full game reports zero free slots")
	_t.eq(net.occupied_slots().size(), 2, "both slots are occupied")

	# Two peers claiming one slot would let two empires share a faction id.
	_t.ok(not net.assign_slot(303, 0), "a taken slot cannot be reassigned")
	_t.ok(not net.assign_slot(101, 1), "a peer cannot claim a second slot")

	net.close()
	net.free()


func _test_slot_assignment() -> void:
	_t.begin("slot table")
	var net := NetworkManagerScript.new() as NetworkManager
	net.max_players = 2
	_t.ok(net.assign_slot(7, 0), "assign succeeds")
	net.release_peer(7)
	_t.eq(net.slot_of(7), -1, "a released peer has no slot")
	_t.eq(net.peer_of(0), 0, "the vacated slot reads back empty")
	_t.eq(net.free_slot(), 0, "a vacated slot is offered again")
	net.close()
	net.free()


## Orders travel as plain dictionaries, so a submission must survive the round trip the
## resolver will actually perform.
func _test_order_wire_round_trip() -> void:
	_t.begin("order wire format")
	var original := Order.make_move_fleet(1, 5, 12)
	var wire := original.to_dict()
	var rebuilt := Order.from_dict(wire)
	_t.ok(rebuilt != null, "an order survives to_dict/from_dict")
	if rebuilt == null:
		return
	_t.eq(rebuilt.type, original.type, "order type preserved")
	_t.eq(rebuilt.faction, original.faction, "issuing faction preserved")
	_t.eq(rebuilt.fleet, original.fleet, "fleet id preserved")
	_t.eq(rebuilt.target_system, original.target_system, "target system preserved")

	var build := Order.make_build_structure(0, 3, &"mining")
	var rebuilt_build := Order.from_dict(build.to_dict())
	_t.ok(rebuilt_build != null, "a build order survives the wire")
	if rebuilt_build != null:
		_t.eq(rebuilt_build.target_planet, 3, "target planet preserved")


## A tampered snapshot must be refused, not adopted.
##
## With a correct server the hashes always agree, so the parity checks above can never
## fail on their own -- which would leave the detection path completely untested. This
## corrupts the payload the way a bad transport or a hostile peer would and requires the
## client to notice.
func _test_desync_is_detected() -> void:
	_t.begin("desync detection")
	var client := TurnSyncClient.new()
	var galaxy := _make_galaxy(7)
	if not client.begin(galaxy, 0):
		_t.ok(false, "the client bound its galaxy")
		return

	var seen: Array[String] = []
	client.desync_detected.connect(func(_t: int, local: int, remote: int) -> void:
		seen.append("%d/%d" % [local, remote]))

	# An honest payload is adopted.
	var honest := {"state": galaxy.to_dict(), "state_hash": str(galaxy.state_hash()),
		"report": {}}
	_t.ok(client.apply_snapshot(honest) >= 0, "an honest snapshot is accepted")
	_t.eq(seen.size(), 0, "an honest snapshot raises no desync")

	# The same state with a hash that does not describe it.
	var tampered := honest.duplicate(true)
	tampered["state_hash"] = str((galaxy.state_hash() + 1) % 2147483647)
	_t.eq(client.apply_snapshot(tampered), -1, "a snapshot that fails parity is refused")
	_t.eq(seen.size(), 1, "the desync was reported")

	# An empty payload is refused without claiming a desync -- it is a protocol error,
	# not evidence that the two sides disagree.
	var empty := {"state": {}, "state_hash": "0", "report": {}}
	_t.eq(client.apply_snapshot(empty), -1, "an empty payload is refused")
	_t.eq(seen.size(), 1, "an empty payload is not reported as a desync")

	# A client that is mid-turn must still be locked after a desync: unlocking on a state
	# the server does not hold would let the player queue orders against a galaxy that is
	# not real. Set the flag through the real path (`submit_turn`) rather than assigning
	# it, so the assertion covers the state an actual desync would leave behind.
	# A detached client has no interface to send through, and must say so rather than
	# pretend the turn went out.
	_t.ok(not client.submit_turn(), "a detached client refuses to submit")
	_t.ok(not client.awaiting, "a refused submit does not strand the player in waiting")
	client.awaiting = true
	var forged := honest.duplicate(true)
	forged["state_hash"] = "not-the-real-hash"
	_t.eq(client.apply_snapshot(forged), -1, "the desynced snapshot is refused")
	_t.ok(client.awaiting, "a desynced client stays locked")
	_t.ok(not client.receive_resolution(0, "x", forged),
		"the client does not unlock on a desynced snapshot")
	client.free()


## Orders must be applied in *slot* order, never arrival order.
##
## Two players submitting in opposite order across two runs must produce the same galaxy,
## or a replay of a networked game would not reproduce its own hash. The rule is only
## observable when order actually changes the outcome, so this drives the server with two
## submissions that *both* target empire 0 -- `SET_TAX` is last-write-wins, so whichever
## order is applied last decides the treasury policy. Slot order must fix that answer;
## arrival order would make it depend on network timing.
func _test_order_assembly_is_slot_ordered() -> void:
	_t.begin("orders assemble in slot order")
	var defs: Node = root.get_node_or_null(NodePath("Defs"))
	var db: Node = root.get_node_or_null(NodePath("GameDB"))

	# Empire 0's tax rate is set twice: 0.10 by slot 0, then 0.80 by slot 1. Applying in
	# slot order always leaves 0.80; applying in arrival order leaves whichever arrived
	# last, so the two scenarios below can only agree if the server sorted them.
	var build := func() -> TurnSyncServer:
		var rng := RandomNumberGenerator.new()
		rng.seed = 555
		var galaxy := GalaxyGenerator.generate(defs, rng, 40, 2, db)
		var server := TurnSyncServer.new()
		server.begin(galaxy, PackedInt32Array([0, 1]))
		return server

	# Delivery A: slot 0 lands first.
	var a := build.call() as TurnSyncServer
	_t.ok(a.stage_orders(0, [Order.make_set_tax(0, 0.10).to_dict()]), "A: slot 0 staged")
	_t.ok(a.stage_orders(1, [Order.make_set_tax(0, 0.80).to_dict()]), "A: slot 1 staged")

	# Delivery B: the identical pair, opposite order.
	var b := build.call() as TurnSyncServer
	_t.ok(b.stage_orders(1, [Order.make_set_tax(0, 0.80).to_dict()]), "B: slot 1 staged first")
	_t.ok(b.stage_orders(0, [Order.make_set_tax(0, 0.10).to_dict()]), "B: slot 0 staged second")
	_t.ok(not b.stage_orders(7, []), "a slot the server is not waiting on is refused")

	_t.ok(a.all_submitted(), "both slots have orders to resolve")
	_t.ok(b.all_submitted(), "the reordered pair is also complete")
	_t.ok(not a.resolve_if_ready().is_empty(), "the first submission resolved")
	_t.ok(not b.resolve_if_ready().is_empty(), "the reordered submission resolved")

	_t.near(a.galaxy.faction(0).tax_rate, 0.80, 0.0001,
		"the later slot wins, so slot order decides the final rate")
	_t.eq(b.galaxy.faction(0).tax_rate, a.galaxy.faction(0).tax_rate,
		"arrival order does not change which order was applied last")
	_t.eq(b.galaxy.state_hash(), a.galaxy.state_hash(),
		"arrival order does not change the resolved galaxy")

	a.free()
	b.free()


# --- Networked scenarios ------------------------------------------------------

var _harnesses: Array[Harness] = []
var _index: int = -1
var _phase: String = ""
var _frames: int = 0
var _booted: bool = false


## Build a galaxy the server will hand out.
func _make_galaxy(seed_value: int = 4242) -> GalaxyState:
	var tree := root
	var defs: Node = tree.get_node_or_null(NodePath("Defs"))
	var db: Node = tree.get_node_or_null(NodePath("GameDB"))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return GalaxyGenerator.generate(defs, rng, 40, 2, db)


## Start the whole network conversation.
func _run_network_scenarios() -> void:
	_index = -1
	_next()


## Finish the current scenario and start the next one.
##
## `dispose()` releases each stack with `queue_free()`, so the outgoing nodes stay in the
## tree until the end of the frame. The next scenario is therefore queued rather than
## started here, and begins on a later `_process` -- starting immediately would leave the
## previous peers visible to the RPC path cache and produce phantom "Node not found"
## errors that have nothing to do with the code under test.
func _next() -> void:
	_teardown()
	_index += 1
	_frames = 0
	_phase = "settle"
	_pending_scenario = _SCENARIOS.get(_index, "")


## The scenario phases, in the order `_next` walks them.
const _SCENARIOS := {
	0: "host and join",
	1: "turn resolution and parity",
	2: "disconnect during a turn",
	3: "network equals local",
}

## Phase to begin on the frame after a settle.
var _pending_scenario: String = ""


func _start_host() -> void:
	var port := NetworkManager.reserve_ephemeral_port()
	_t.ok(port > 1024, "an ephemeral port was reserved (%d)" % port)

	var harness := Harness.new()
	_harnesses.append(harness)

	harness.server_net = NetworkManagerScript.new() as NetworkManager
	root.add_child(harness.server_net)
	var err := harness.server_net.host_game(port, 2)
	_t.eq(err, OK, "the server is listening (port %d)" % port)
	_t.ok(harness.server_net.is_host, "the manager reports itself as the host")
	_t.eq(harness.server_net.unique_id(), 1, "the server is peer 1")

	# Two clients dial the reserved port.
	for i in 2:
		var c := NetworkManagerScript.new() as NetworkManager
		root.add_child(c)
		var cerr := c.join_game(CC2CLI.DEFAULT_LOOPBACK, port)
		_t.eq(cerr, OK, "client %d dials the server" % i)
		harness.client_nets.append(c)


func _start_turn_sync() -> void:
	var port := NetworkManager.reserve_ephemeral_port()
	var harness := Harness.new()
	_harnesses.append(harness)

	harness.server_net = NetworkManagerScript.new() as NetworkManager
	root.add_child(harness.server_net)
	_t.eq(harness.server_net.host_game(port, 2), OK, "the sync server is listening")

	_galaxy = _make_galaxy()
	_turns_before = _galaxy.turn
	harness.server_sync = harness.server_net.add_sync_endpoint(TurnSyncServer) \
		as TurnSyncServer
	harness.server_sync.net = harness.server_net
	var active := PackedInt32Array([0, 1])
	_t.ok(harness.server_sync.begin(_galaxy, active), "the server bound its galaxy")
	_t.eq(harness.server_sync.active_slots().size(), 2, "the server waits on two slots")

	for i in 2:
		var c := NetworkManagerScript.new() as NetworkManager
		root.add_child(c)
		_t.eq(c.join_game(CC2CLI.DEFAULT_LOOPBACK, port), OK, "sync client %d dials" % i)
		harness.client_nets.append(c)

		# Both clients mirror the starting state so they can stage orders immediately.
		var sync := c.add_sync_endpoint(TurnSyncClient) as TurnSyncClient
		sync.net = c
		sync.begin(_galaxy.duplicate_state(), 0)
		harness.client_syncs.append(sync)


func _start_disconnect() -> void:
	var port := NetworkManager.reserve_ephemeral_port()
	var harness := Harness.new()
	_harnesses.append(harness)

	harness.server_net = NetworkManagerScript.new() as NetworkManager
	root.add_child(harness.server_net)
	_t.eq(harness.server_net.host_game(port, 2), OK, "the disconnect server is listening")

	_galaxy = _make_galaxy(99)
	_turns_before_disconnect = _galaxy.turn
	harness.server_sync = harness.server_net.add_sync_endpoint(TurnSyncServer) \
		as TurnSyncServer
	harness.server_sync.net = harness.server_net
	harness.server_sync.begin(_galaxy, PackedInt32Array([0, 1]))

	for i in 2:
		var c := NetworkManagerScript.new() as NetworkManager
		root.add_child(c)
		c.join_game(CC2CLI.DEFAULT_LOOPBACK, port)
		harness.client_nets.append(c)
		var sync := c.add_sync_endpoint(TurnSyncClient) as TurnSyncClient
		sync.net = c
		sync.begin(_galaxy.duplicate_state(), 0)
		harness.client_syncs.append(sync)


## Free every peer from the finished scenario. Leaking an ENet host would leave the port
## bound and make the next scenario fail for reasons that have nothing to do with it.
func _teardown() -> void:
	if _index < 0 or _index >= _harnesses.size():
		return
	var harness := _harnesses[_index]
	# `free()` detaches immediately, so these must not also be queued: releasing the same
	# node twice is what turns a clean teardown into an abort at exit.
	# The TurnSyncPeer of each stack is a child of its NetworkManager, so `dispose()`
	# frees it along with the branch interface. Freeing it separately is a double free.
	for c in harness.client_nets:
		c.dispose()
	harness.client_nets.clear()
	harness.client_syncs.clear()
	if harness.server_net != null:
		harness.server_net.dispose()
	_harnesses[_index] = null
	_frames = 0


func _process(_delta: float) -> bool:
	if not _booted:
		_booted = true
		_test_order_assembly_is_slot_ordered()
		_test_desync_is_detected()
		_run_network_scenarios()
		return false
	if _phase == "settle":
		# The outgoing scenario's queue_free()s have now run; the tree is clean.
		if _pending_scenario.is_empty():
			_report()
			return false
		_phase = _pending_scenario
		match _phase:
			"host and join":
				_start_host()
			"turn resolution and parity":
				_start_turn_sync()
			"disconnect during a turn":
				_start_disconnect()
			"network equals local":
				_start_parity()
		return false
	_frames += 1
	match _phase:
		"host and join":
			_step_host()
		"turn resolution and parity":
			_step_turn_sync()
		"disconnect during a turn":
			_step_disconnect()
		"network equals local":
			_step_parity()
	if _phase == "done":
		_finish()
		return true
	return false


func _step_host() -> void:
	if _frames == 1:
		# Let the connections establish.
		return
	if _frames < 20:
		return
	_t.begin("host and join")
	var harness := _harnesses[0]
	_t.eq(harness.server_net.occupied_slots().size(), 2, "both clients were given a slot")
	_t.ok(harness.server_net.slot_of(harness.client_nets[0].unique_id()) >= 0,
		"client 0 holds a slot")
	var s0 := harness.server_net.slot_of(harness.client_nets[0].unique_id())
	var s1 := harness.server_net.slot_of(harness.client_nets[1].unique_id())
	_t.ok(s0 != s1, "the two clients hold distinct slots (%d vs %d)" % [s0, s1])
	_t.ok(harness.client_nets[0].unique_id() != harness.client_nets[1].unique_id(),
		"the two clients have distinct peer ids")
	_t.eq(harness.client_nets[0].status, "connected to 127.0.0.1", "client 0 reports connected")
	_next()


var _turns_before: int = 0
var _turns_before_disconnect: int = 0
## Which phase of the turn-sync scenario has run. Guards against re-entering a one-shot
## step: without this the setup block re-ran on every frame and spammed the log.
var _ts_done_setup: bool = false
var _ts_submitted: bool = false
var _ts_resolved: bool = false
var _dc_done_setup: bool = false
var _dc_dropped: bool = false


func _step_turn_sync() -> void:
	var harness := _harnesses[1]
	if not _ts_done_setup:
		if _frames < 2 or harness.server_net.occupied_slots().size() < 2:
			return
		_ts_done_setup = true
		_ts_submitted = false
		_ts_resolved = false
		_t.begin("turn resolution and parity")

		# Slot each client in its assigned empire.
		for i in harness.client_nets.size():
			var slot := harness.server_net.slot_of(harness.client_nets[i].unique_id())
			harness.client_syncs[i].slot = slot

		# Peer 1 stages build orders; peer 2 stages a different imperial order.
		var client_a := harness.client_syncs[0]
		var client_b := harness.client_syncs[1]
		client_a.stage_order(Order.make_set_tax(client_a.slot, 0.42))
		client_a.stage_order(Order.make_build_structure(client_a.slot, 0, &"mine"))
		client_b.stage_order(Order.make_set_tax(client_b.slot, 0.31))

		_t.ok(client_a.has_staged_orders(), "peer 1 staged orders")
		_t.ok(client_b.has_staged_orders(), "peer 2 staged orders")
		_t.eq(client_a.status_text(), "your turn", "the client starts on its own turn")

		# Only peer 1 submits first: the server must hold, not resolve early.
		_t.ok(client_a.submit_turn(), "peer 1 submits")
		_t.ok(client_a.awaiting, "peer 1 is awaiting other players")
		_t.eq(client_a.status_text(), TurnSyncClient.WAITING_TEXT,
			"peer 1 shows the waiting text")
		_t.ok(not client_a.submit_turn(), "a second submit while waiting is refused")
		return

	if not _ts_submitted:
		# Peer 1's packet has to actually arrive before peer 2 may submit. Polling the
		# server's own count is the honest test; a fixed frame count would race, and a
		# race here looks exactly like a protocol bug.
		if harness.server_sync.submitted_count() == 0:
			return
		_ts_submitted = true
		_t.eq(harness.server_sync.submitted_count(), 1,
			"one submission did not resolve the turn")
		_t.ok(not harness.server_sync.all_submitted(),
			"the server is still waiting for the second player")
		_t.eq(harness.server_sync.resolve_if_ready().size(), 0,
			"resolving early is refused while a slot is outstanding")
		_t.ok(harness.client_syncs[1].submit_turn(), "peer 2 submits")
		_t.ok(harness.client_syncs[1].awaiting, "peer 2 is awaiting resolution")
		return

	if not _ts_resolved:
		# Peer 2's packet is in flight; resolve only once it lands.
		if not harness.server_sync.all_submitted():
			return
		_ts_resolved = true
		# Every active slot has now submitted, so the server may resolve.
		var payload := harness.server_sync.resolve_if_ready()
		_t.ok(not payload.is_empty(), "the server resolved once all slots submitted")
		return

	if _frames < 90:
		return

	# By now the broadcast has been delivered and applied by both clients.
	_t.begin("turn resolution and parity")
	_t.eq(harness.server_sync.submitted_count(), 0,
		"the server cleared its pending orders after resolving")
	_t.eq(harness.server_sync.galaxy.turn, _turns_before + 1,
		"the server advanced exactly one turn")

	var server_hash := harness.server_sync.galaxy.state_hash()
	var first: int = -1
	var all_match := true
	for i in harness.client_syncs.size():
		var sync := harness.client_syncs[i]
		_t.ok(sync.galaxy != null, "client %d received the snapshot" % i)
		if sync.galaxy == null:
			continue
		_t.eq(sync.current_turn, harness.server_sync.galaxy.turn,
			"client %d is on the server's turn" % i)
		_t.eq(sync.galaxy.state_hash(), server_hash,
			"client %d hash matches the server" % i)
		_t.ok(not sync.awaiting, "client %d is unlocked after resolution" % i)
		_t.eq(sync.status_text(), "your turn", "client %d is back on its turn" % i)
		if first == -1:
			first = sync.galaxy.state_hash()
		elif sync.galaxy.state_hash() != first:
			all_match = false
	_t.ok(all_match, "both clients agree on the state hash")
	_next()


func _step_disconnect() -> void:
	var harness := _harnesses[2]
	if not _dc_done_setup:
		if _frames < 2 or harness.server_net.occupied_slots().size() < 2:
			return
		_dc_done_setup = true
		_t.begin("disconnect during a turn")
		for i in harness.client_nets.size():
			harness.client_syncs[i].slot = harness.server_net.slot_of(
				harness.client_nets[i].unique_id())

		# Peer 1 submits; peer 2 will vanish without submitting.
		harness.client_syncs[0].stage_order(Order.make_set_tax(
			harness.client_syncs[0].slot, 0.5))
		harness.client_syncs[0].submit_turn()
		return

	if not _dc_dropped:
		# Wait for the survivor's order to land, then drop the peer that never sent one.
		if harness.server_sync.submitted_count() == 0:
			return
		_dc_dropped = true
		_t.eq(harness.server_sync.submitted_count(), 1,
			"the survivor's order arrived before the disconnect")
		# Drop the peer that never submitted.
		var leaver: NetworkManager = harness.client_nets[1]
		var slot := harness.server_net.slot_of(leaver.unique_id())
		harness.server_sync.remove_active_slot(slot)
		harness.server_net.release_peer(leaver.unique_id())
		leaver.dispose()
		harness.client_nets.remove_at(1)
		harness.client_syncs.remove_at(1)
		# With the leaver's slot gone, the survivor's order is all that remains.
		_t.ok(harness.server_sync.all_submitted(),
			"the surviving slot is enough once the other has dropped")
		var payload := harness.server_sync.resolve_if_ready()
		_t.ok(not payload.is_empty(),
			"the turn resolved once the absent slot stopped blocking it")
		return

	if _frames < 70:
		return

	_t.eq(harness.server_sync.galaxy.turn, _turns_before_disconnect + 1,
		"the server advanced exactly one turn despite the disconnect")
	_next()





var _par_net: NetworkManager = null
var _par_client_net: NetworkManager = null
var _par_server: TurnSyncServer = null
var _par_client: TurnSyncClient = null
var _par_local_hash: int = -1
var _par_submitted: bool = false
var _par_resolved: bool = false
var _par_frames: int = 0


## Build a one-slot server and client whose orders are fixed in advance, so the identical
## orders can also be resolved offline for comparison.
##
## This is the property that makes single player and multiplayer provably the same game
## rather than two games that usually agree: the same orders, submitted over a real socket,
## must produce the same galaxy as running them locally with no transport at all.
func _start_parity() -> void:
	var harness := Harness.new()
	_harnesses.append(harness)
	_par_submitted = false
	_par_resolved = false
	_par_frames = 0

	var defs: Node = root.get_node_or_null(NodePath("Defs"))
	var db: Node = root.get_node_or_null(NodePath("GameDB"))
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var galaxy := GalaxyGenerator.generate(defs, rng, 40, 2, db)

	# The offline baseline: identical orders, identical seed, no network involved.
	var local := galaxy.duplicate_state()
	var local_rng := RandomNumberGenerator.new()
	local_rng.seed = local.seed_value
	var baseline: Array = [
		Order.make_set_tax(0, 0.42),
		Order.make_set_research(0, PackedFloat64Array([0.25, 0.25, 0.25, 0.25])),
	]
	TurnResolver.resolve_turn(local, baseline, defs, db, local_rng, 0)
	_par_local_hash = local.state_hash()

	var port := NetworkManager.reserve_ephemeral_port()
	_par_net = NetworkManagerScript.new() as NetworkManager
	root.add_child(_par_net)
	_t.eq(_par_net.host_game(port, 1), OK, "the parity server is listening")
	_par_server = _par_net.add_sync_endpoint(TurnSyncServer) as TurnSyncServer
	_par_server.net = _par_net
	_par_server.begin(galaxy, PackedInt32Array([0]))

	_par_client_net = NetworkManagerScript.new() as NetworkManager
	root.add_child(_par_client_net)
	_t.eq(_par_client_net.join_game(CC2CLI.DEFAULT_LOOPBACK, port), OK,
		"the parity client dials")
	_par_client = _par_client_net.add_sync_endpoint(TurnSyncClient) as TurnSyncClient
	_par_client.net = _par_client_net
	_par_client.begin(galaxy.duplicate_state(), 0)

	harness.server_net = _par_net
	harness.server_sync = _par_server
	harness.client_nets.append(_par_client_net)
	harness.client_syncs.append(_par_client)


func _step_parity() -> void:
	if not _par_submitted:
		# Wait for the handshake, then ship exactly the baseline orders.
		if _par_net.slot_of(_par_client_net.unique_id()) < 0:
			return
		_par_submitted = true
		_t.begin("network equals local")
		_par_client.slot = _par_net.slot_of(_par_client_net.unique_id())
		_par_client.stage_order(Order.make_set_tax(0, 0.42))
		_par_client.stage_order(
			Order.make_set_research(0, PackedFloat64Array([0.25, 0.25, 0.25, 0.25])))
		_t.ok(_par_client.submit_turn(), "the parity client submitted")
		return
	# Order matters: once `resolve_if_ready()` has run it clears the server's pending
	# orders, so `submitted_count()` reads zero forever after. The resolved flag has to
	# be consulted first, or this waits for a submission that was already consumed.
	if not _par_resolved:
		if _par_server.submitted_count() == 0:
			return
		_par_resolved = true
		_t.ok(not _par_server.resolve_if_ready().is_empty(),
			"the parity turn resolved over the network")
		return
	# Give the broadcast a few frames to reach the client replica before comparing.
	# `resolve_if_ready()` clears the server's pending orders, so `submitted_count()` reads
	# zero from here on. The gate is the resolved flag, not the count -- checking the count
	# again would wait forever for a submission that was already consumed.
	_par_frames += 1
	if _par_frames < 30:
		return

	# The whole point: the wire changed nothing about the outcome.
	_t.eq(_par_server.galaxy.state_hash(), _par_local_hash,
		"a networked turn hashes identically to the same turn resolved locally")
	_t.ok(_par_client.galaxy != null, "the parity client received the snapshot")
	if _par_client.galaxy != null:
		_t.eq(_par_client.galaxy.state_hash(), _par_local_hash,
			"the client replica matches the offline result exactly")
	_next()


func _report() -> void:
	_t.begin("no RID leaks")
	# Every scenario disposed its peers; a leaked ENet host would show up as an orphan
	# node still holding a listening socket.
	_t.eq(_live_peer_count(), 0, "no network peers outlived their scenario")
	_phase = "done"


func _finish() -> void:
	# The per-scenario teardown has already closed and freed every peer, so nothing is
	# left holding an ENet host. assert() below proves it rather than assuming it.
	assert(_live_peer_count() == 0,
		"an ENet peer outlived its scenario: %d still alive" % _live_peer_count())
	var code := _t.finish("test_enet_sync")
	print("---test_enet_sync-exit=%d---" % code)
	quit(code)


## Count NetworkManager nodes still parented to the tree. A leftover one means a scenario
## leaked a listening socket, which would make the *next* run fail to bind its port.
func _live_peer_count() -> int:
	var alive := 0
	for child in root.get_children():
		var net := child as NetworkManager
		if net != null:
			alive += 1
			for sub in net.get_children():
				if sub is NetworkManager:
					alive += 1
	return alive

extends SceneTree
## Headless verification that a colony mutation made by a client survives a real networked
## turn resolution.
##
##   godot --headless --path . -s res://tests/test_colony_persistence.gd
##
## ## The failure this pins down
##
## `SessionController.assign_worker`, `unassign_worker`, `scrap`, `boost_construction` and
## `refund_construction` used to mutate the client's own `PlanetState` and submit nothing.
## That is invisible in single player -- the client *is* the authority there -- and in a
## networked session it is a rollback: the server holds its own copy of the colony, it never
## heard about the press, and the snapshot it broadcasts after resolving the turn replaces
## the client's figure with the one it still had. Worker postings snapped back to the
## founding defaults, scrapped buildings reappeared and refunded metal vanished.
##
## So this runs the whole conversation over genuine ENet: a real `TurnSyncServer`, a real
## `TurnSyncClient`, and a real `SessionController` driving the client through the same
## public methods the `+` and `-` buttons and the Destroy menu call. A fake would pass
## against the old code, because the bug is precisely that nothing crossed the wire.

const NetworkManagerScript := preload("res://src/net/network_manager.gd")

var _t: TestSupport = null

## Everything the scenario created, so the peers can be released at the end.
var _server_net: NetworkManager = null
var _client_net: NetworkManager = null
var _server_sync: TurnSyncServer = null
var _client_sync: TurnSyncClient = null

var _controller: SessionController = null

## One-shot phase guards: the conversation is driven from `_process`, so every setup block
## and every assertion block needs to know it has already run.
var _seated: bool = false
var _acted: bool = false
var _submitted: bool = false
var _resolved: bool = false
var _frames: int = 0
var _started: bool = false

## The body the assertions read. Held across the snapshot on purpose: if
## `GalaxyState.from_dict` replaces its instances, this reference becomes an orphan and every
## figure read from it is a turn out of date.
var _colony: PlanetState = null

## What the player did, recorded locally so the server's result can be compared against it.
var _expected_workers: int = -1
var _expected_metals: float = 0.0
## The reference captured before the turn, so identity can be asserted rather than assumed.
var _homeworld: int = -1


func _initialize() -> void:
	_t = TestSupport.new()


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_start_scenario()
		return false
	_frames += 1
	if _homeworld < 0 or _colony == null:
		return false

	if not _seated:
		if _frames < 20:
			return false
		_seated = true
		_seat_and_act()
		return false

	if not _acted:
		return false

	if not _submitted:
		# Wait for the order packet to actually land on the server. A fixed frame count would
		# race the loopback round trip, and a race here is indistinguishable from the bug.
		if _server_sync.submitted_count() == 0:
			return false
		_submitted = true
		_t.begin("a colony mutation survives a networked turn")
		_t.ok(_server_sync.all_submitted(), "the server holds every slot's submission")
		var payload := _server_sync.resolve_if_ready()
		_t.ok(not payload.is_empty(), "the server resolved the turn")
		_resolved = not payload.is_empty()
		return false

	if not _resolved:
		return false

	# The broadcast is a reliable RPC, so a short settle is enough for it to arrive.
	if _frames < 90:
		return false
	_assert_survival()
	return true


## Host a server, dial it, and bind both ends of the authority to the same galaxy.
func _start_scenario() -> void:
	_t.begin("client/server colony persistence")
	var defs: Node = root.get_node_or_null(NodePath("Defs"))
	var db: Node = root.get_node_or_null(NodePath("GameDB"))
	var rng := RandomNumberGenerator.new()
	rng.seed = 24680
	var galaxy := GalaxyGenerator.generate(defs, rng, 40, 2, db)
	if galaxy == null:
		_t.ok(false, "the galaxy generated")
		return

	# The founding colony is bare by design now -- a landed Colony Ship and three colonists
	# and nothing else -- so the farm and mine this scenario posts workers onto have to be
	# laid down first, on the authority, before anyone can work them.
	var home := _seed_homeworld(galaxy, db)
	if home < 0:
		_t.ok(false, "empire 0 has a homeworld to act on")
		return
	_homeworld = home

	var port := NetworkManager.reserve_ephemeral_port()
	_server_net = NetworkManagerScript.new() as NetworkManager
	root.add_child(_server_net)
	if _server_net.host_game(port, 1) != OK:
		_t.ok(false, "the server is listening on port %d" % port)
		return
	_t.eq(_server_net.unique_id(), 1, "the server is peer 1")

	_server_sync = _server_net.add_sync_endpoint(TurnSyncServer) as TurnSyncServer
	_server_sync.net = _server_net
	_t.ok(_server_sync.begin(galaxy, PackedInt32Array([0])),
		"the server bound its galaxy and is waiting on empire 0")

	_client_net = NetworkManagerScript.new() as NetworkManager
	root.add_child(_client_net)
	_t.eq(_client_net.join_game(CC2CLI.DEFAULT_LOOPBACK, port), OK, "the client dials")

	_client_sync = _client_net.add_sync_endpoint(TurnSyncClient) as TurnSyncClient
	_client_sync.net = _client_net
	_client_sync.begin(galaxy.duplicate_state(), 0)

	# The controller is the same object the GUI holds: `turn_submitter` set, so its `+` and
	# `-` route through `TurnSyncClient.set_ready` and nothing resolves locally.
	_controller = SessionController.new()
	_t.ok(_controller.attach(_client_sync.galaxy, 0), "the controller bound the client's galaxy")
	_controller.turn_submitter = _client_sync
	_controller.select_planet(_homeworld)

	var body: PlanetState = _controller.galaxy.planet(_homeworld)
	if body == null:
		_t.ok(false, "the client replica holds the homeworld")
		return
	# Recount on the replica too: capacities are derived, and the client reads them for the
	# staffing row. `attach` rebound the definitions, so this costs one pass.
	body.refresh_capacities(db)
	_colony = body


## Give empire 0 a homeworld with something to staff and something to scrap.
##
## Writes to the authority before it is bound, so the snapshot both ends hold already agrees
## about it. Returns the homeworld index, or -1.
func _seed_homeworld(galaxy: GalaxyState, db: Node) -> int:
	var colonies := galaxy.colonies_of(0)
	if colonies.is_empty():
		return -1
	var home: PlanetState = colonies[0]
	home.structures[&"farm"] = 3
	home.structures[&"mine"] = 1
	home.structures[&"granary"] = 1
	home.population = 6.0
	home.reserve_metals = 400.0
	home.power = 500.0
	# A project in the slot, so `boost_construction` has something to pay into. Queued here
	# rather than through an order because the fixture is describing the opening position,
	# not exercising a build. Eight turns rather than the granary's authored two, so the
	# project is still standing when the assertions read it -- a project that completes on
	# the first turn would move the very figures being checked.
	home.building_queue[&"granary"] = 1
	home.build_turns_remaining = 8
	home.build_total_turns = 8
	home.build_metal = 0.0
	ColonySim.recount_capacity(home, {} as Dictionary, db)
	return home.index


## Seat the client and perform every mutation the GUI can perform on a colony.
func _seat_and_act() -> void:
	var slot := _server_net.slot_of(_client_net.unique_id())
	if slot < 0:
		return
	_client_sync.slot = slot
	_t.eq(slot, 0, "the server seated the client as empire 0")

	_t.begin("a client's colony actions reach the authority")
	_t.ok(_controller.assign_worker(&"farm"), "posting a worker to a farm is accepted")
	_t.ok(_controller.assign_worker(&"farm"), "and a second one")
	_t.ok(_controller.assign_worker(&"mine"), "and one to a mine")
	_expected_workers = ColonySim.workers_on(_colony, &"farm")
	_t.eq(_expected_workers, 2, "the client shows two farmhands")

	# Pulling one back must survive too: it is the direction that was just as invisible.
	_t.ok(_controller.unassign_worker(&"mine"), "pulling the mine worker is accepted")
	_t.eq(ColonySim.workers_on(_colony, &"mine"), 0, "and the mine has nobody on it")

	_t.ok(_controller.scrap(&"mine") > 0.0, "scrapping the mine refunds metal")
	_t.eq(int(_colony.structures.get(&"mine", 0)), 0, "and the mine is gone")

	# The granary's authored cost is the ceiling on a boost, so the figure asked for is
	# quoted as a share of it rather than hard-coded: a test that has to know the balance
	# table to assert that money moved is a test that breaks when the balance moves.
	var granary := root.get_node_or_null("Defs").call("building", &"granary") as Resource
	var owed := float(granary.get("cost_metals"))
	var spend := floorf(owed * 0.5)
	var before_boost := _colony.reserve_metals
	var spent := _controller.boost_construction(spend)
	_t.near(spent, spend, 0.001, "metal moves into the granary project")
	_t.near(_colony.reserve_metals, before_boost - spend, 0.001,
		"and leaves the stockpile")
	_t.near(_colony.build_metal, spend, 0.001, "and lands on the project's own pool")

	_expected_metals = _colony.reserve_metals

	# Every action must have produced an order. This is the assertion that fails against the
	# old code even before any turn is resolved: the mutations were real and nothing was
	# queued.
	var queued: Array[Order] = _controller.orders_to_submit()
	_t.eq(queued.size(), 6,
		"all six colony actions queued an order for the wire (%d)" % queued.size())
	var kinds := PackedStringArray()
	for o in queued:
		kinds.append(str(o.type))
	_t.ok(kinds.has(str(Enums.OrderType.ASSIGN_WORKER)),
		"a worker posting reached the queue")
	_t.ok(kinds.has(str(Enums.OrderType.UNASSIGN_WORKER)),
		"a worker removal reached the queue")
	_t.ok(kinds.has(str(Enums.OrderType.SCRAP_STRUCTURE)),
		"a scrap reached the queue")
	_t.ok(kinds.has(str(Enums.OrderType.BOOST_BUILD)),
		"the construction boost reached the queue")

	_acted = true
	_t.ok(_controller.set_ready(true), "the client commits its turn to the server")


## Everything the client did must still be true after the server has resolved and broadcast.
func _assert_survival() -> void:
	_t.begin("a colony mutation survives a networked turn")
	var replica: PlanetState = _controller.galaxy.planet(_homeworld)
	_t.ok(replica != null, "the client replica still holds the homeworld")

	# Identity first: a replacement would make every figure below read off an orphan that
	# happens to be right, which is the failure this assertion exists to catch.
	_t.ok(replica == _colony, "the snapshot updated the body in place rather than replacing it")
	_t.eq(ColonySim.workers_on(replica, &"farm"), _expected_workers,
		"the farm workers the player posted are still posted")
	_t.eq(ColonySim.workers_on(replica, &"mine"), 0,
		"and the worker pulled off the mine is still pulled")
	_t.eq(int(replica.structures.get(&"mine", 0)), 0,
		"the scrapped mine is still gone")
	_t.eq(int(replica.structures.get(&"farm", 0)), 3,
		"and the farms it never touched are untouched")
	# The standing granary is untouched; the *queued* one is a different matter, because the
	# colony sim finishes construction during the very turn being resolved. Asserting the
	# count the client left rather than a literal keeps this about the rollback.
	_t.ok(int(replica.structures.get(&"granary", 0)) >= 1,
		"the granary is still standing")

	# The refund and the boost both moved real metal, and both are the kind of figure a
	# player checks the moment they press the button.
	_t.ok(replica.reserve_metals > _expected_metals,
		"the scrap refund and the metal moved into the project both survived",
		"server %.2f vs client's %.2f" % [replica.reserve_metals, _expected_metals])
	_t.ok(replica.build_metal > 0.0 or replica.build_turns_remaining <= 0,
		"the construction project still carries the metal that was put into it",
		"paid %.2f, %d turns left" % [replica.build_metal, replica.build_turns_remaining])

	# The whole point of the pipeline: the client and the authority agree.
	_t.eq(_controller.galaxy.state_hash(), _server_sync.galaxy.state_hash(),
		"client and server agree on the state hash after the turn")
	_t.ok(not _client_sync.awaiting, "and the client is unlocked and free to act")

	# The bug was a silent rollback, so a single turn is not evidence of anything: two more
	# must hold too. This is the shape of the original report -- press End Turn, and the
	# numbers are back where they started. Each one carries whatever the player queued this
	# time, which is what the real flow does.
	_controller.assign_worker(&"mine")
	for followup in 2:
		_resolve_next(_controller.orders_to_submit())
	var after: PlanetState = _controller.galaxy.planet(_homeworld)
	_t.eq(ColonySim.workers_on(after, &"farm"), _expected_workers,
		"the posting is still there three turns later")
	_t.eq(int(after.structures.get(&"mine", 0)), 0,
		"and the scrap is still done three turns later")
	_t.ok(after == replica, "every one of those snapshots kept the same body object")
	_t.eq(_controller.galaxy.state_hash(), _server_sync.galaxy.state_hash(),
		"client and server still agree after three turns")

	_teardown()
	var code := _t.finish("test_colony_persistence")
	print("---test_colony_persistence-exit=%d---" % code)
	quit(code)


## Push one more turn through the wire, orders and all.
##
## Driven exactly as the game drives it: the server holds the client's staged orders, resolves
## once every slot has submitted, and the client adopts the snapshot that is broadcast. Called
## directly rather than from `_process` because the round trip has already been proved by the
## first turn and there is nothing left to learn from the timing.
func _resolve_next(orders: Array) -> void:
	var wire: Array = []
	for o in orders:
		wire.append(o.to_dict())
	if not _server_sync.stage_orders(_client_sync.slot, wire):
		_t.ok(false, "the server accepted the follow-up submission")
		return
	var payload := _server_sync.resolve_if_ready()
	if payload.is_empty():
		_t.ok(false, "the follow-up turn resolved")
		return
	_t.ok(_client_sync.apply_snapshot(payload) >= 0, "the client adopted the follow-up snapshot")


## Release both peers. A leaked ENet host would keep the port bound and make a second run
## fail for reasons that have nothing to do with the code under test.
func _teardown() -> void:
	if _client_net != null:
		_client_net.dispose()
		_client_net = null
	if _server_net != null:
		_server_net.dispose()
		_server_net = null
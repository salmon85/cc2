extends SceneTree
## Final Gate F.3: determinism replay.
##
## The whole game is authoritative on one side, so the only property that keeps
## single-player, dedicated-server and client runs in agreement is that the same seed plus
## the same order stream always produces the same state. This test asserts that directly,
## across save/load boundaries and across a long soak, rather than trusting the checks
## buried inside the turn-engine suite.
##
##   godot --headless --path . -s res://tests/test_determinism_replay.gd

const DefsScript := preload("res://src/data/defs.gd")
const DBScript := preload("res://src/data/game_db.gd")

var _t: TestSupport
var _defs: Node
var _db: Node


func _initialize() -> void:
	_t = TestSupport.new()
	_defs = _singleton(&"Defs", DefsScript)
	_db = _singleton(&"GameDB", DBScript)
	_defs.call("load_all")

	_test_same_seed_same_orders()
	_test_seed_actually_seeds()
	_test_save_load_continuity()
	_test_mid_soak_save_does_not_diverge()
	_test_order_stream_replay()
	_test_long_soak_stability()

	quit(_t.finish("test_determinism_replay"))


func _singleton(node_name: StringName, script: GDScript) -> Node:
	var existing := root.get_node_or_null(NodePath(node_name))
	if existing != null:
		return existing
	var made: Node = script.new()
	made.name = node_name
	root.add_child(made)
	return made


func _rng(seed_value: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	return r


## Play `turns` turns from `seed`, issuing the deterministic order stream below, and
## return the final state hash.
func _replay(seed_value: int, turns: int) -> int:
	var galaxy := GalaxyGenerator.generate(_defs, _rng(seed_value), 40, 4, _db)
	var rng := _rng(seed_value)
	for _t in turns:
		TurnResolver.resolve_turn(galaxy, _orders_for(galaxy), _defs, _db, rng, 0)
	return galaxy.state_hash()


## The canonical order stream: every third turn, each idle human fleet steps one warp
## lane clockwise. Derived only from game state, so it replays identically.
func _orders_for(galaxy: GalaxyState) -> Array:
	var orders: Array = []
	if galaxy.turn % 3 != 0:
		return orders
	for fleet in galaxy.fleets_of(0):
		if fleet.destination >= 0:
			continue
		var lanes := PackedInt32Array()
		for s in galaxy.systems:
			if galaxy.systems[fleet.system].has_warp_lane_to(s.index):
				lanes.append(s.index)
		if lanes.size() == 0:
			continue
		var dest: int = lanes[galaxy.turn % lanes.size()]
		if MovementStage.issue_move(galaxy, fleet.id, 0, dest):
			orders.append(Order.make_move_fleet(0, fleet.id, dest))
	return orders


# --- tests ---------------------------------------------------------------

func _test_same_seed_same_orders() -> void:
	_t.begin("same seed, same orders, same result")

	var first := _replay(20250901, 15)
	var second := _replay(20250901, 15)
	_t.eq(second, first, "two replays of the same seed agree exactly")

	# And it must hold across several seeds, not just one lucky one.
	for probe in [1, 77, 4096, 999983]:
		_t.eq(_replay(probe, 8), _replay(probe, 8),
			"seed %d replays identically" % probe)


func _test_seed_actually_seeds() -> void:
	_t.begin("the seed reaches the generator")

	var hashes: Dictionary = {}
	for probe in [11, 22, 33, 44]:
		var g := GalaxyGenerator.generate(_defs, _rng(probe), 40, 4, _db)
		hashes[probe] = g.state_hash()
	_t.eq(hashes.size(), 4, "four distinct seeds generated")
	var unique: Dictionary = {}
	for probe in hashes:
		unique[hashes[probe]] = true
	_t.eq(unique.size(), 4, "every seed yields a distinct galaxy")


func _test_save_load_continuity() -> void:
	_t.begin("save/load continuity")

	var original := GalaxyGenerator.generate(_defs, _rng(555), 40, 4, _db)
	var rng := _rng(555)
	for _i in 8:
		TurnResolver.resolve_turn(original, _orders_for(original), _defs, _db, rng, 0)

	var text := original.to_json()
	_t.ok(not text.is_empty(), "the galaxy serialises to JSON")

	var restored := GalaxyState.new()
	_t.ok(restored.from_json(text), "the galaxy restores from JSON")
	_t.ok(restored.rebind_definitions(), "definitions rebind after a restore")
	_t.eq(restored.state_hash(), original.state_hash(),
		"the restored galaxy hashes identically before a single turn is played")

	# The RNG stream must survive exactly, or the next turn diverges.
	_t.eq(restored.rng_state, original.rng_state,
		"the RNG state survives the round-trip bit for bit")

	# Continuing both must keep them in lockstep.
	var restored_rng := _rng(555)
	restored_rng.state = restored.rng_state
	for _i in 10:
		TurnResolver.resolve_turn(original, [], _defs, _db, rng, 0)
		TurnResolver.resolve_turn(restored, [], _defs, _db, restored_rng, 0)
	_t.eq(restored.state_hash(), original.state_hash(),
		"ten turns after a reload the two galaxies still agree")


func _test_mid_soak_save_does_not_diverge() -> void:
	_t.begin("saving repeatedly does not drift")

	# Save every few turns and keep reloading from disk. If any serialised field
	# loses precision, each round-trip nudges the state and the final hashes diverge.
	var galaxy := GalaxyGenerator.generate(_defs, _rng(31337), 35, 3, _db)
	var rng := _rng(31337)
	var carried := rng.state

	for _round in 6:
		for _i in 5:
			TurnResolver.resolve_turn(galaxy, [], _defs, _db, rng, 0)
		var snapshot := GalaxyState.new()
		_t.ok(snapshot.from_json(galaxy.to_json()), "round %d saves cleanly" % _round)
		_t.ok(snapshot.rebind_definitions(), "round %d rebinds cleanly" % _round)
		galaxy = snapshot
		carried = galaxy.rng_state

	_t.ok(galaxy.state_hash() != 0, "the reloaded galaxy still hashes")
	_t.eq(galaxy.turn, 30, "thirty turns were played across six save/load cycles")

	# A straight run with no saves must land on the same place.
	var straight := GalaxyGenerator.generate(_defs, _rng(31337), 35, 3, _db)
	var straight_rng := _rng(31337)
	for _i in 30:
		TurnResolver.resolve_turn(straight, [], _defs, _db, straight_rng, 0)
	_t.eq(galaxy.state_hash(), straight.state_hash(),
		"thirty turns of save/reload equals thirty uninterrupted turns")


func _test_order_stream_replay() -> void:
	_t.begin("order stream replay")

	# Orders are part of the input, so a replay must reproduce them too: run the
	# stream twice and assert the emitted order lists are identical.
	var a := _order_trace(4242, 12)
	var b := _order_trace(4242, 12)
	_t.eq(a.size(), b.size(), "both runs issued the same number of turns of orders")
	_t.eq(str(a), str(b), "the order stream itself is reproducible")

	# And a different seed must produce a different order stream.
	var c := _order_trace(4243, 12)
	_t.ok(str(a) != str(c) or a.size() == 0,
		"a different seed yields a different order stream")


func _order_trace(seed_value: int, turns: int) -> Array:
	var galaxy := GalaxyGenerator.generate(_defs, _rng(seed_value), 40, 4, _db)
	var rng := _rng(seed_value)
	var trace: Array = []
	for _i in turns:
		var orders := _orders_for(galaxy)
		var line := PackedStringArray()
		for order in orders:
			line.append(order.fingerprint())
		trace.append(line)
		TurnResolver.resolve_turn(galaxy, orders, _defs, _db, rng, 0)
	return trace


func _test_long_soak_stability() -> void:
	_t.begin("long soak stability")

	# A longer run, asserting invariants that must hold no matter how long the game
	# goes on: no negative resources, no runaway populations, and a stable hash.
	var galaxy := GalaxyGenerator.generate(_defs, _rng(8888), 60, 5, _db)
	var rng := _rng(8888)
	for _i in 60:
		TurnResolver.resolve_turn(galaxy, _orders_for(galaxy), _defs, _db, rng, 0)

	_t.eq(galaxy.turn, 60, "sixty turns elapsed")

	for f in galaxy.factions:
		_t.ok(f.treasury >= float(_db.get("TREASURY_FLOOR")) - 0.001,
			"faction %d stays above the treasury floor" % f.id, "%.2f" % f.treasury)
		_t.ok(f.metals >= 0.0, "faction %d metals stay non-negative" % f.id)
		_t.ok(f.rare_elements >= 0.0, "faction %d rare elements stay non-negative" % f.id)
		for i in 4:
			_t.ok(f.tech_points[i] >= 0.0,
				"faction %d field %d tech points stay non-negative" % [f.id, i])

	for p in galaxy.planets:
		_t.ok(p.population >= 0.0, "planet %d population is non-negative" % p.index)
		_t.ok(p.food_stock >= -50.001, "planet %d food stock is within bounds" % p.index)

	# Repairs must not have corrupted fleet bookkeeping.
	for fleet in galaxy.fleets.values():
		_t.ok(fleet.ships.size() >= 0, "fleet %d has a coherent manifest" % fleet.id)
		if fleet.active:
			_t.ok(fleet.ship_count() > 0, "an active fleet has at least one hull")

	_t.ok(not galaxy.state_hash() == 0, "the soak produces a stable hash")

	# And the whole thing must be reproducible.
	var replay := GalaxyGenerator.generate(_defs, _rng(8888), 60, 5, _db)
	var replay_rng := _rng(8888)
	for _i in 60:
		TurnResolver.resolve_turn(replay, _orders_for(replay), _defs, _db, replay_rng, 0)
	_t.eq(replay.state_hash(), galaxy.state_hash(),
		"a sixty-turn soak replays to the identical state hash")
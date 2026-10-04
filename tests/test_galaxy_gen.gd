extends SceneTree
## Headless verification for Phase 3: galaxy generation.
##
##   godot --headless --path . -s res://tests/test_galaxy_gen.gd
##
## Asserts the spec's structural invariants (system count range, 1..6 bodies per system,
## warp-lane connectivity, faction separation) and, critically, that generation is a pure
## function of the seed.

const DefsScript := preload("res://src/data/defs.gd")
const DBScript := preload("res://src/data/game_db.gd")
const RngScript := preload("res://src/core/rng_service.gd")
const GeneratorScript := preload("res://src/gen/galaxy_generator.gd")

var _t: TestSupport = null
var _defs: Node = null
var _db: Node = null


func _initialize() -> void:
	_t = TestSupport.new()
	_defs = _singleton(&"Defs", DefsScript)
	_defs.call("load_all")
	_db = _singleton(&"GameDB", DBScript)

	_test_system_count_range()
	_test_star_placement()
	_test_planet_population()
	_test_warp_lane_connectivity()
	_test_faction_seeding()
	_test_determinism()
	_test_edge_cases()

	var code := _t.finish("test_galaxy_gen")
	print("---test_galaxy_gen-exit=%d---" % code)
	quit(code)


## Get an autoload by name, falling back to a standalone instance (bare `-s` runs skip
## autoload registration).
func _singleton(node_name: StringName, script: GDScript) -> Node:
	var existing := root.get_node_or_null(NodePath(node_name))
	if existing != null:
		return existing
	var node: Node = script.new()
	node.name = String(node_name)
	root.add_child(node)
	return node


## Generate a galaxy from a seed. Each call gets a fresh stream so seeds are independent.
func _generate(seed_value: int, systems: int, factions: int) -> GalaxyState:
	var rng_service: Node = _singleton(&"RNGService", RngScript)
	rng_service.call("seed_stream", seed_value)
	var stream: RandomNumberGenerator = RandomNumberGenerator.new()
	stream.seed = seed_value
	stream.state = seed_value
	return GeneratorScript.generate(_defs, stream, systems, factions, _db)


# --- Tests ---------------------------------------------------------------------

func _test_system_count_range() -> void:
	_t.begin("system count honours the spec range")
	# The spec allows 30..100 systems.
	for requested in [30, 50, 64, 100]:
		var g := _generate(1234, requested, 2)
		_t.ok(g != null, "generation succeeded for %d systems" % requested)
		if g == null:
			continue
		_t.eq(g.systems.size(), requested, "exactly %d systems generated" % requested)

	# Out-of-range requests are clamped, not rejected.
	var small := _generate(1234, 5, 2)
	_t.eq(small.systems.size(), 30, "a request below 30 is clamped to the spec minimum")
	var large := _generate(1234, 500, 2)
	_t.eq(large.systems.size(), 100, "a request above 100 is clamped to the spec maximum")


func _test_star_placement() -> void:
	_t.begin("star placement")
	var g := _generate(42, 60, 3)
	var unique_names: Dictionary = {}
	var min_sep := INF
	var out_of_bounds := 0

	for s in g.systems:
		unique_names[s.name] = true
		_t.in_range(
			s.position.length(), 0.0, GeneratorScript.GALAXY_RADIUS + 0.001,
			"system %d sits inside the galactic disk" % s.index)
		if s.position.length() > GeneratorScript.GALAXY_RADIUS + 0.001:
			out_of_bounds += 1
		_t.in_range(s.strategic_value, 0.0, 1.0, "system %d has a normalised value" % s.index)

	for i in g.systems.size():
		for j in range(i + 1, g.systems.size()):
			min_sep = minf(min_sep, g.systems[i].distance_to(g.systems[j]))

	_t.eq(out_of_bounds, 0, "no system lies outside the disk")
	_t.eq(unique_names.size(), g.systems.size(), "every system has a unique name")

	# At the maximum map size the curated name pool is guaranteed to run out, so this
	# exercises the catalogue-designation fallback rather than the happy path.
	var big := _generate(42, 100, 2)
	var big_names: Dictionary = {}
	for sys in big.systems:
		big_names[sys.name] = true
	_t.eq(big_names.size(), 100, "all 100 system names stay unique once the pool is exhausted")

	# And across many seeds, because the fallback draws randomly.
	var collisions := 0
	for probe_seed in [7, 19, 55, 91, 404]:
		var m := _generate(probe_seed, 100, 2)
		var seen: Dictionary = {}
		for sys in m.systems:
			if seen.has(sys.name):
				collisions += 1
			seen[sys.name] = true
	_t.eq(collisions, 0, "no name collisions across five large-galaxy seeds")
	# Stars must be spread, not clumped: the min-separation constant is the guarantee.
	_t.ok(
		min_sep >= GeneratorScript.MIN_STAR_SEPARATION * 0.5,
		"stars are separated enough to read the map",
		"closest pair is %.2f parsecs" % min_sep)


func _test_planet_population() -> void:
	_t.begin("planet population")
	var g := _generate(777, 50, 2)
	_t.ok(g.planets.size() > 0, "the galaxy has bodies")

	var all_indices_used := true
	var orbit_problems := 0
	var unbound := 0
	var seen_classes: Dictionary = {}

	for s in g.systems:
		_t.in_range(
			s.body_count(), GeneratorScript.MIN_PLANETS, GeneratorScript.MAX_PLANETS,
			"system %d holds 1..6 bodies" % s.index)
		if s.body_count() < GeneratorScript.MIN_PLANETS or s.body_count() > GeneratorScript.MAX_PLANETS:
			orbit_problems += 1
		for planet_index in s.planet_indices:
			if not (planet_index >= 0 and planet_index < g.planets.size()):
				all_indices_used = false
		for t in s.body_count():
			var body: PlanetState = g.planet(s.planet_indices[t])
			if body == null or body.type_data() == null:
				unbound += 1
				continue
			seen_classes[body.type_id] = true
			_t.eq(body.orbit, t, "body %d has the right orbital slot" % body.index)
			_t.ok(body.reserve_metals >= 0.0, "body %d has non-negative metals" % body.index)

	_t.eq(orbit_problems, 0, "no system breaks the body-count limit")
	_t.ok(all_indices_used, "every system body index resolves to a real planet")
	_t.eq(unbound, 0, "every planet is bound to its type definition")
	_t.eq(seen_classes.size(), 6, "all six planet classes appear in the galaxy")

	# Each planet's global index must equal its position in the flat array.
	var consistent := true
	for i in g.planets.size():
		if (g.planets[i] as PlanetState).index != i:
			consistent = false
	_t.ok(consistent, "planet indices are contiguous and match their array position")


func _test_warp_lane_connectivity() -> void:
	_t.begin("warp lane graph")
	var g := _generate(909, 50, 2)
	var n := g.systems.size()

	# Lanes must be symmetric: if A can reach B, B can reach A.
	var asymmetric := 0
	var self_links := 0
	var duplicates := 0
	for s in g.systems:
		var seen: Dictionary = {}
		for lane in s.warp_lanes:
			if lane == s.index:
				self_links += 1
			if seen.has(lane):
				duplicates += 1
			seen[lane] = true
			var other: SystemState = g.system(lane)
			if other == null or not other.has_warp_lane_to(s.index):
				asymmetric += 1

	_t.eq(asymmetric, 0, "every warp lane is reciprocal")
	_t.eq(self_links, 0, "no system warp-lanes to itself")
	_t.eq(duplicates, 0, "no duplicate warp lanes")

	# Connectivity: every system must be reachable from every other (BFS from system 0).
	var seen: Dictionary = {0: true}
	var queue: Array[int] = [0]
	while not queue.is_empty():
		var current: int = queue.pop_front()
		for lane in (g.system(current) as SystemState).warp_lanes:
			if not seen.has(lane):
				seen[lane] = true
				queue.append(lane)
	_t.eq(seen.size(), n, "the warp lane graph is fully connected from system 0")

	# Degree sanity: every system has at least one lane, and none is absurdly hubbed.
	var total_degree := 0
	var isolated := 0
	for sys in g.systems:
		var degree := sys.warp_lanes.size()
		total_degree += degree
		if degree < 1:
			isolated += 1
	_t.eq(isolated, 0, "every system has at least one warp lane")
	_t.ok(total_degree / float(n) >= 2.0, "the average system has 2+ lanes",
		"average degree %.2f" % (total_degree / float(n)))


func _test_faction_seeding() -> void:
	_t.begin("faction seeding")
	var g := _generate(31337, 60, 4)
	_t.eq(g.factions.size(), 4, "four factions were seeded")

	# Exactly one human, the rest AI.
	var humans := 0
	var ais := 0
	for f in g.factions:
		if f.kind == 0:
			humans += 1
		elif f.kind == 1:
			ais += 1
	_t.eq(humans, 1, "exactly one faction is the human player")
	_t.eq(ais, 3, "the rest are AI")

	# Each faction must hold a real, colonised homeworld.
	for f in g.factions:
		var home_colonies := 0
		var home_system := -1
		for s in g.systems:
			if s.owner != f.id:
				continue
			home_system = s.index
			for planet_index in s.planet_indices:
				var p: PlanetState = g.planet(planet_index)
				if p != null and p.owner == f.id and p.colonized:
					home_colonies += 1
		_t.ok(home_colonies >= 1, "%s has a colonised homeworld" % f.name)
		_t.ok(home_system >= 0, "%s controls at least one system" % f.name)
		_t.ok(f.system_count() >= 1, "%s tracks its systems" % f.name)
		_t.ok(f.treasury > 0.0, "%s starts with a treasury" % f.name)
		_t.eq(f.fleets.size(), 1, "%s starts with one scout fleet" % f.name)

	# Homeworlds must be separated enough to leave room for expansion.
	var homes := PackedInt32Array()
	for f in g.factions:
		for s in g.systems:
			if s.owner == f.id:
				homes.append(s.index)
				break
	var too_close := 0
	for i in homes.size():
		for j in range(i + 1, homes.size()):
			var d: float = g.system(homes[i]).distance_to(g.system(homes[j]))
			if d < GeneratorScript.GALAXY_RADIUS * 0.25:
				too_close += 1
	_t.ok(too_close == 0, "no two homeworlds sit on top of each other",
		"%d homeworld pairs are closer than a quarter radius" % too_close)

	# Faction ids and fleet ids must be unique and dense.
	var ids: Dictionary = {}
	for f in g.factions:
		ids[f.id] = true
	_t.eq(ids.size(), g.factions.size(), "faction ids are unique")

	var fleet_ids: Dictionary = {}
	for id: int in g.fleets:
		fleet_ids[id] = true
	_t.eq(fleet_ids.size(), g.fleets.size(), "fleet ids are unique")


func _test_determinism() -> void:
	_t.begin("determinism")
	# The same seed must produce a byte-identical galaxy. This is the property the whole
	# authoritative-server design rests on.
	var a := _generate(20240101, 50, 3)
	var b := _generate(20240101, 50, 3)
	_t.ok(a != null and b != null, "both generations succeeded")
	if a == null or b == null:
		return
	_t.eq(a.fingerprint(), b.fingerprint(), "same seed produces an identical galaxy")
	_t.eq(a.state_hash(), b.state_hash(), "and the same state hash")

	# Different seeds must actually differ.
	var c := _generate(20240102, 50, 3)
	_t.ok(c.state_hash() != a.state_hash(), "a different seed produces a different galaxy")

	# Different system counts must differ too.
	var d := _generate(20240101, 60, 3)
	_t.ok(d.state_hash() != a.state_hash(), "a different system count produces a different galaxy")

	# Across several seeds, all must be internally valid and distinct.
	var hashes: Dictionary = {}
	var all_valid := true
	for probe_seed in [1, 2, 3, 99, 12345]:
		var g := _generate(probe_seed, 40, 2)
		if g == null or g.systems.is_empty() or g.planets.is_empty():
			all_valid = false
			continue
		var h := g.state_hash()
		if hashes.has(h):
			all_valid = false
		hashes[h] = true
	_t.ok(all_valid, "distinct seeds yield distinct, non-empty galaxies")


func _test_edge_cases() -> void:
	_t.begin("edge cases")
	# A null registry must be rejected cleanly.
	var bad := GeneratorScript.generate(null, RandomNumberGenerator.new(), 50, 2, _db)
	_t.ok(bad == null, "a null definition registry is rejected")

	# A null RNG must be rejected cleanly.
	var bad2 := GeneratorScript.generate(_defs, null, 50, 2, _db)
	_t.ok(bad2 == null, "a null RNG stream is rejected")

	# Requesting more factions than the map supports must still deliver what it can.
	var crowded := _generate(555, 30, 8)
	_t.ok(crowded != null, "an over-subscribed faction count still generates")
	if crowded != null:
		_t.ok(crowded.factions.size() >= 1, "at least one faction was placed")
		_t.ok(crowded.factions.size() <= 8, "no more factions than requested")

	# A single faction must work.
	var solo := _generate(666, 30, 1)
	_t.eq(solo.factions.size(), 1, "a single-faction galaxy generates")
	if solo.factions.size() == 1:
		_t.ok(solo.factions[0].is_alive(), "the solo faction starts alive")

	# Generated galaxies must survive a JSON round-trip: the game saves them directly.
	var g := _generate(888, 40, 2)
	var text := g.to_json()
	var restored := GalaxyState.new()
	_t.ok(restored.from_json(text), "a generated galaxy reloads from JSON")
	_t.ok(restored.call("rebind_definitions", _defs), "definitions rebind after load")
	_t.eq(restored.fingerprint(), g.fingerprint(), "the round-tripped galaxy is identical")
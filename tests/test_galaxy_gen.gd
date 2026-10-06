extends SceneTree
## Headless verification for Phase 3: galaxy generation.
##
##   godot --headless --path . -s res://tests/test_galaxy_gen.gd
##
## Asserts the structural invariants of the single-system model (one star at the origin,
## `--systems=N` planets on orbit rings, random distinct homeworlds per empire) and,
## critically, that the *layout* is a pure function of the seed while the *opening* is not.

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

	_test_single_star()
	_test_planet_count_range()
	_test_orbit_layout()
	_test_faction_seeding()
	_test_every_requested_faction_exists()
	_test_homeworld_is_random()
	_test_determinism()
	_test_map_size_tiers()
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
##
## `home_seed` seeds the homeworld draw. It is a separate argument because it is a separate
## stream: the layout must be reproducible from the seed alone, while the choice of starting
## planet is meant to vary. Passing a fixed `home_seed` is how a test asks for the same
## opening twice, and passing different values is how it asks for different ones.
func _generate(
	seed_value: int, systems: int, factions: int, home_seed: int = -1,
	scale: float = GeneratorScript.SCALE_EXTREME
) -> GalaxyState:
	var rng_service: Node = _singleton(&"RNGService", RngScript)
	rng_service.call("seed_stream", seed_value)
	var stream: RandomNumberGenerator = RandomNumberGenerator.new()
	stream.seed = seed_value
	stream.state = seed_value
	var homes: RandomNumberGenerator = null
	if home_seed >= 0:
		homes = RandomNumberGenerator.new()
		homes.seed = home_seed
		homes.state = home_seed
	return GeneratorScript.generate(
		_defs, stream, systems, factions, _db, homes, scale)


## As `_generate`, at a chosen map-size scale.
func _generate_sized(
	seed_value: int, systems: int, factions: int, scale: float
) -> GalaxyState:
	var rng_service: Node = _singleton(&"RNGService", RngScript)
	rng_service.call("seed_stream", seed_value)
	var stream: RandomNumberGenerator = RandomNumberGenerator.new()
	stream.seed = seed_value
	stream.state = seed_value
	return GeneratorScript.generate(
		_defs, stream, systems, factions, _db, null, scale)


# --- Tests ---------------------------------------------------------------------

func _test_single_star() -> void:
	_t.begin("there is exactly one star, at the origin")
	var g := _generate(42, 60, 3)
	_t.eq(g.systems.size(), 1, "the galaxy holds one system")
	if g.systems.is_empty():
		return
	var star: SystemState = g.systems[0]
	_t.eq(star.index, 0, "the system is index 0")
	_t.eq(star.position, Vector2.ZERO, "the star sits at the origin")
	_t.ok(star.name != "", "the star has a name")
	_t.in_range(star.star_class, 0, 6, "the star has a valid spectral class")
	_t.eq(star.strategic_value, 1.0, "the whole system is the strategic prize")
	# With one system and no network between stars, the warp lane graph is empty rather
	# than degenerate: a self-lane would let a fleet "travel" to where it already is.
	_t.eq(star.warp_lanes.size(), 0, "the single system has no warp lanes")
	_t.eq(g.systems[0].body_count(), g.planets.size(),
		"every planet in the galaxy belongs to the one system")


func _test_planet_count_range() -> void:
	_t.begin("planet count honours the request")
	# `--systems=N` is now a planet count. The command line never changed; what the flag
	# means did, and these are the bounds the old galaxy used for its system count.
	for requested in [30, 50, 64, 100]:
		var g := _generate(1234, requested, 2)
		_t.ok(g != null, "generation succeeded for %d planets" % requested)
		if g == null:
			continue
		_t.eq(g.planets.size(), requested, "exactly %d planets generated" % requested)

	# Out-of-range requests are clamped, not rejected.
	var small := _generate(1234, 5, 2)
	_t.eq(small.planets.size(), GeneratorScript.MIN_SYSTEMS,
		"a request below the floor is clamped up to the minimum")
	var large := _generate(1234, 500, 2)
	_t.eq(large.planets.size(), GeneratorScript.MAX_SYSTEMS,
		"a request above the ceiling is clamped down to the maximum")


## Planets sit on concentric rings around the star, and the map is fifty times larger
## than the old galactic disk.
func _test_orbit_layout() -> void:
	_t.begin("orbit layout")
	var g := _generate(777, 50, 2)
	_t.ok(g.planets.size() > 0, "the system has bodies")

	var out_of_bounds := 0
	var unbound := 0
	var seen_classes: Dictionary = {}
	var seen_rings: Dictionary = {}
	var ring_conflicts := 0
	var last_radius := -INF
	var rings_ascend := true

	for i in g.planets.size():
		var body: PlanetState = g.planets[i]
		_t.eq(body.index, i, "planet %d is at its own array position" % i)
		_t.eq(body.orbit, i, "planet %d has ring %d" % [i, i])
		if body.type_data() == null:
			unbound += 1
		seen_classes[body.type_id] = true
		_t.ok(body.name != "", "planet %d has a name" % i)

		var radius := body.position.length()
		# The outer ring sits at OUTER_ORBIT of the radius, so the tolerance has to allow
		# for the ring's own placement rather than testing against the raw radius.
		if radius > GeneratorScript.GALAXY_RADIUS + 0.001:
			out_of_bounds += 1
		if seen_rings.has(i):
			ring_conflicts += 1
		seen_rings[i] = true
		if radius < last_radius - 0.001:
			rings_ascend = false
		last_radius = radius

	_t.eq(out_of_bounds, 0, "no planet lies outside the system disk")
	_t.eq(ring_conflicts, 0, "no two planets share an orbit ring")
	_t.ok(rings_ascend, "orbit radii increase with ring index")
	_t.eq(unbound, 0, "every planet is bound to its type definition")
	_t.eq(seen_classes.size(), 6, "all six planet classes appear in the system")

	# The system is meant to be fifty times the old 120-unit disk. If this drifts back the
	# map framing and the sensor ranges drift with it, so pin the number.
	_t.near(GeneratorScript.GALAXY_RADIUS, 120.0 * 50.0, 0.001,
		"the system is fifty times the old galactic radius")

	# The innermost ring must clear the star glyph, or planets are drawn under the star.
	var innermost := INF
	for body in g.planets:
		innermost = minf(innermost, body.position.length())
	_t.ok(
		innermost >= GeneratorScript.GALAXY_RADIUS * GeneratorScript.INNER_ORBIT - 0.001,
		"the innermost orbit clears the star")


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
		for p in g.planets:
			if p.owner == f.id and p.colonized:
				home_colonies += 1
		_t.ok(home_colonies >= 1, "%s has a colonised homeworld" % f.name)
		_t.ok(f.treasury > 0.0, "%s starts with a treasury" % f.name)
		# Nothing in orbit. The generator used to hand every empire a Colony Ship and an
		# Exploration Ship over its homeworld, which made the first hull a player owned
		# something the game gave them rather than something they built. Asserted here as an
		# absence, because that is what it is now.
		_t.eq(f.fleets.size(), 0, "%s starts with no fleet at all" % f.name)
		_t.eq(g.fleets_of(f.id).size(), 0,
			"%s has no hulls anywhere on the board" % f.name)

	# No two empires may start on the same world. With one system this is the only
	# separation rule left, and drawing without checking would hand two players the same
	# planet -- the first thing anyone would notice.
	var homes: Dictionary = {}
	var shared := 0
	for f in g.factions:
		for p in g.planets:
			if p.owner == f.id and p.colonized:
				if homes.has(p.index):
					shared += 1
				homes[p.index] = true
				break
	_t.eq(shared, 0, "no two factions share a homeworld")
	_t.eq(homes.size(), g.factions.size(), "every faction got a distinct starting planet")

	# No starting fleet at all, so an empire's homeworld orbit is empty on turn one. The
	# index is read with a size check rather than `[0]`: an empty `f.fleets` used to be a
	# hard script error here rather than a failed assertion, which is how a suite can report
	# "OK, 329 checks passed" while the engine logged a crash.
	for f in g.factions:
		_t.eq(f.fleets.size(), 0, "%s has no fleet roster entries" % f.name)
		_t.eq(g.fleets_of(f.id).size(), 0,
			"%s has no fleet on the board" % f.name)
		var home := -1
		for p in g.planets:
			if p.owner == f.id and p.colonized:
				home = p.index
				break
		_t.eq(g.orbital_fleet(home, f.id), null,
			"%s's homeworld orbit is empty" % f.name)

	# Faction ids and fleet ids must be unique and dense.
	var ids: Dictionary = {}
	for f in g.factions:
		ids[f.id] = true
	_t.eq(ids.size(), g.factions.size(), "faction ids are unique")

	var fleet_ids: Dictionary = {}
	for id: int in g.fleets:
		fleet_ids[id] = true
	_t.eq(fleet_ids.size(), g.fleets.size(), "fleet ids are unique")


## The player asked for a different starting planet every game, including between two
## games that share a seed. This is the test for exactly that, and for the constraint that
## separates it from plain non-determinism: the *layout* must not move when the homeworld
## does.
func _test_homeworld_is_random() -> void:
	_t.begin("starting planet is random, layout is not")
	var homes_seen: Dictionary = {}
	var identical_layout := true
	var layout_differs_when_seed_differs := false

	for attempt in 20:
		var g := _generate(20240101, 60, 4, attempt)
		_t.ok(g != null, "generation %d with its own home seed succeeded" % attempt)
		if g == null:
			continue
		# The layout fingerprint must be identical for all 20: same seed, same system.
		if attempt == 0:
			_reference_layout = _layout_fingerprint(g)
		elif _layout_fingerprint(g) != _reference_layout:
			identical_layout = false
		homes_seen[_opening_fingerprint(g)] = true

	_t.ok(identical_layout,
		"the planet layout is byte-identical across 20 runs on the same seed")

	# Twenty different home seeds, four empires each: the openings must not all be the
	# same. One collision would not be alarming; twenty identical ones would mean the
	# homeworld draw is falling through to the layout stream.
	_t.ok(homes_seen.size() > 1,
		"the opening varies with the homeworld seed",
		"%d distinct openings across 20 runs" % homes_seen.size())

	# And a different layout seed must still produce a different layout, or the
	# separation above is trivially satisfied by a generator that ignores both seeds.
	var other := _generate(20240102, 60, 4, 0)
	if other != null:
		layout_differs_when_seed_differs = _layout_fingerprint(other) != _reference_layout
	_t.ok(layout_differs_when_seed_differs, "a different seed still changes the layout")

	# With no home stream at all, generation falls back to the layout stream and is
	# therefore reproducible. Replays and the determinism test depend on that.
	var a := _generate(555, 40, 3)
	var b := _generate(555, 40, 3)
	_t.eq(a.fingerprint(), b.fingerprint(),
		"with no separate home stream the whole galaxy is reproducible")


## The layout alone: system, planet types, positions, reserves. Excludes ownership and
## fleets, which are where the homeworld draw shows up.
var _reference_layout: String = ""


func _layout_fingerprint(g: GalaxyState) -> String:
	var parts := PackedStringArray()
	parts.append(g.systems[0].name if not g.systems.is_empty() else "")
	parts.append("star:%d" % (g.systems[0].star_class if not g.systems.is_empty() else -1))
	for p in g.planets:
		parts.append("%s@%.3f,%.3f:%s" % [
			p.name, p.position.x, p.position.y, String(p.type_id)])
	return "\n".join(parts)


## Where each empire started, which is the part that is allowed to vary.
func _opening_fingerprint(g: GalaxyState) -> String:
	var parts := PackedStringArray()
	for f in g.factions:
		for p in g.planets:
			if p.owner == f.id and p.colonized:
				parts.append(str(p.index))
				break
	return ",".join(parts)


## The generator used to clamp the empire count to one per five systems
## (`clampi(faction_count, 1, count / 5)`). On the 30-system minimum map that ceiling is 6,
## so `--factions=8` silently produced six empires and a server opening eight slots had
## fewer empires than seats. A request the caller made explicitly must be honoured.
func _test_every_requested_faction_exists() -> void:
	_t.begin("requested factions are actually generated")
	for want in range(1, 9):
		for systems in [30, 50, 100]:
			var g := _generate(4242 + want * 7 + systems, systems, want)
			_t.ok(g != null, "generating %d factions in %d systems succeeds" % [want, systems])
			if g == null:
				continue
			_t.eq(g.factions.size(), want,
				"%d factions in %d systems yields %d empires" % [want, systems, want])

	# The claim the whole thing rests on: every empire is playable, not merely counted.
	# A fourth slot with no homeworld is a seat at an empty table. A fleet is deliberately
	# *not* part of it: a new empire has a world and nothing else, and everything it puts in
	# orbit it builds itself.
	var g8 := _generate(90210, 40, 8)
	_t.ok(g8 != null, "an eight-empire galaxy generates")
	if g8 != null:
		for f in g8.factions:
			var home := -1
			for p in g8.planets:
				if p.owner == f.id and p.colonized:
					home = p.index
					break
			_t.ok(home >= 0, "%s owns a homeworld" % f.name)
			_t.eq(f.fleets.size(), 0, "%s starts with an empty orbit" % f.name)
			if f.fleets.is_empty():
				continue
			var fleet := g8.fleets.get(f.fleets[0], null) as FleetState
			_t.ok(fleet != null and fleet.system == home,
				"%s's fleet starts on its homeworld" % f.name)

	# Player slots 2 and 3 in particular: these are the seats that were refused.
	_t.ok(g8.factions.size() >= 4, "at least four empires exist for a --slots=4 server")
	if g8.factions.size() >= 4:
		for slot in [2, 3]:
			var f: FactionState = g8.factions[slot]
			var playable := false
			for p in g8.planets:
				if p.owner == f.id and p.colonized:
					playable = true
					break
			_t.ok(playable, "slot %d (0-indexed) has an empire with territory" % slot)

	# A cramped map is allowed to crowd the homeworlds; it is not allowed to drop an
	# empire. Separately checked here because the old clamp traded one for the other.
	var tight := _generate(31337, 30, 8)
	_t.ok(tight != null, "eight empires on the minimum map still generates")
	if tight != null:
		_t.eq(tight.factions.size(), 8, "the minimum map still seats eight empires")


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

## `--map-size` presets: the tier table resolves, and the span it selects genuinely changes
## the layout rather than only changing how the layout is drawn.
func _test_map_size_tiers() -> void:
	_t.begin("map size tiers")

	# Every documented tier resolves to a distinct scale, in the documented order.
	var names := ["tiny", "small", "medium", "large", "extreme"]
	var seen: Array[float] = []
	for n in names:
		_t.ok(GeneratorScript.SIZE_TIERS.has(n), "tier '%s' is defined" % n)
		seen.append(GeneratorScript.radius_for_tier(n))
	for i in range(1, seen.size()):
		_t.ok(seen[i] > seen[i - 1],
			"tier '%s' is larger than '%s'" % [names[i], names[i - 1]])

	# `tiny` is quoted against the pre-50x disk, so it must be that disk exactly rather
	# than an approximation of it -- "1x" has to mean one times the thing it says it does.
	_t.near(GeneratorScript.radius_for_tier("tiny"), 120.0, 0.001,
		"tiny is the original 120-parsec disk")
	_t.near(GeneratorScript.radius_for_tier("extreme"), 6000.0, 0.001,
		"extreme is fifty times that disk")

	# Case and whitespace must not change the game: two spellings of a tier resolve alike.
	_t.near(GeneratorScript.radius_for_tier("  LARGE "),
		GeneratorScript.radius_for_tier("large"), 0.001,
		"a tier name is case- and whitespace-insensitive")
	# An unknown tier falls back rather than producing a zero-sized or absurd map.
	_t.near(GeneratorScript.radius_for_tier("enormous"),
		GeneratorScript.radius_for_tier(GeneratorScript.DEFAULT_TIER), 0.001,
		"an unknown tier falls back to the default")

	# The span must reach the planets, not just the state: this is the assertion that would
	# catch a generator that recorded `map_radius` and then laid orbits out on the old
	# constant, which would produce a `tiny` map with planets scattered 50x past its edge.
	var tiny_g := _generate_sized(4242, 40, 2, GeneratorScript.SCALE_TINY)
	_t.near(tiny_g.map_radius, 120.0, 0.001, "a tiny galaxy records its span")
	var tiny_furthest := 0.0
	for p in tiny_g.planets:
		tiny_furthest = maxf(tiny_furthest, p.position.length())
	_t.ok(tiny_furthest <= tiny_g.radius(),
		"every planet on a tiny map is inside its own span",
		"furthest=%.1f radius=%.1f" % [tiny_furthest, tiny_g.radius()])

	var huge_g := _generate_sized(4242, 40, 2, GeneratorScript.SCALE_EXTREME)
	var huge_furthest := 0.0
	for p in huge_g.planets:
		huge_furthest = maxf(huge_furthest, p.position.length())
	_t.ok(huge_furthest > tiny_furthest * 10.0,
		"an extreme map spreads its planets much further out",
		"tiny=%.1f extreme=%.1f" % [tiny_furthest, huge_furthest])

	# Same seed, same tier: identical layout. The tier is part of the game's identity, so
	# it must not perturb the seed stream.
	_t.eq(_generate_sized(777, 40, 2, GeneratorScript.SCALE_SMALL).fingerprint(),
		_generate_sized(777, 40, 2, GeneratorScript.SCALE_SMALL).fingerprint(),
		"the same seed at the same tier reproduces exactly")

	# The span survives a save. It decides where fleets may travel and how long that
	# takes, so a save that dropped it would reload onto a map the state disagrees with.
	var saved := _generate_sized(99, 40, 2, GeneratorScript.SCALE_TINY)
	var restored := GalaxyState.new()
	_t.ok(restored.from_json(saved.to_json()), "a sized galaxy reloads from JSON")
	_t.near(restored.map_radius, saved.map_radius, 0.001,
		"the map span survives a JSON round-trip")
	_t.eq(restored.fingerprint(), saved.fingerprint(),
		"and the round-tripped galaxy is identical")

	# A save written before map sizes existed carries no span at all; it must fall back to
	# the default rather than collapsing every orbit onto the star.
	var legacy := saved.to_dict() as Dictionary
	legacy.erase("map_radius")
	var old := GalaxyState.new()
	_t.ok(old.from_dict(legacy), "a save with no map_radius still loads")
	_t.ok(old.radius() > 0.0, "and gets a usable span rather than zero")

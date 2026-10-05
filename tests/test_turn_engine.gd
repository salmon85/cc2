extends SceneTree
## Phase 4 verification: the turn engine.
##
## Covers, in order:
##   - order construction and round-trip through the wire format
##   - order queue readiness semantics
##   - movement, including warp-lane travel and engagement discovery
##   - the five-phase combat sequence and its outcome bookkeeping
##   - invasion: bombardment strips batteries, then the ground assault
##   - colony simulation: food, population, economy, construction
##   - research: accumulation gated on surplus, completion gated on prerequisites
##   - fog of war: visibility grows, redaction hides what a faction cannot see
##   - the resolver end-to-end over a 20-turn soak
##   - economy conservation across the soak
##   - determinism: identical seed + identical orders => identical state hash

const DefsScript := preload("res://src/data/defs.gd")
const DBScript := preload("res://src/data/game_db.gd")

var sup: TestSupport
var _defs: Node
var _db: Node


func _initialize() -> void:
	sup = TestSupport.new()
	_defs = _singleton(&"Defs", DefsScript)
	_db = _singleton(&"GameDB", DBScript)
	_defs.call("load_all")

	_test_order_roundtrip()
	_test_order_queue()
	_test_movement()
	_test_map_size_travel()
	_test_combat()
	_test_invasion()
	_test_colony_sim()
	_test_research()
	_test_fog_of_war()
	_test_turn_soak()
	_test_economy_conservation()
	_test_determinism()

	quit(sup.finish("test_turn_engine"))


# --- setup helpers ------------------------------------------------------

## Resolve an autoload, creating a local stand-in if this bare `-s` run lacks it.
func _singleton(node_name: StringName, script: GDScript) -> Node:
	var existing := root.get_node_or_null(NodePath(node_name))
	if existing != null:
		return existing
	var made: Node = script.new()
	made.name = node_name
	root.add_child(made)
	return made


## Shorthand accessors so the test bodies read cleanly.
func _defs_building(id: StringName) -> Resource:
	return _defs.call("building", id) as Resource


func _defs_tech(id: StringName) -> Resource:
	return _defs.call("tech_node", id) as Resource


func _rng(seed_value: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	return r


func _galaxy(seed_value: int, systems: int = 40, factions: int = 3) -> GalaxyState:
	var r := _rng(seed_value)
	return GalaxyGenerator.generate(_defs, r, systems, factions, _db)


## Give `faction_id` a fleet parked on `planet_index`.
func _place_fleet(
	g: GalaxyState, faction_id: int, system_index: int, ships: Dictionary
) -> FleetState:
	var f := FleetState.new()
	f.id = g.next_fleet_id
	g.next_fleet_id += 1
	f.owner = faction_id
	f.system = system_index
	f.morale = 1.0
	f.name = "Test Fleet %d" % f.id
	for hull_id: StringName in ships:
		f.ships[hull_id] = int(ships[hull_id])
	f.bind_hulls(_defs.get("ship_hulls"))
	g.add_fleet(f)
	return f


## Colonize `planet_index` for `faction_id` with a small working colony.
func _colonize(g: GalaxyState, faction_id: int, planet_index: int) -> PlanetState:
	var p: PlanetState = g.planet(planet_index)
	p.owner = faction_id
	p.colonized = true
	p.population = 1.0
	p.structures = {&"farm": 2, &"mine": 2, &"garrison": 1}
	p.food_stock = 8.0
	p.surveyed = true
	var f: FactionState = g.faction(faction_id)
	if f != null:
		f.colonies_founded += 1
	return p


## Index of a planet nobody owns, or -1.
##
## With one system holding every body, `systems[0].planet_indices[0]` used to name a fresh
## world. It no longer does: planet 0 is whichever homeworld the generator drew, and
## colonising it silently re-owns a populated planet at its population cap.
func _unowned_planet(g: GalaxyState, skip: int = 0) -> int:
	for i in range(skip, g.planets.size()):
		var p := g.planet(i)
		if p != null and p.owner < 0 and not p.colonized:
			return i
	return -1


func _system_of_planet(g: GalaxyState, planet_index: int) -> int:
	for s in g.systems:
		if s.planet_indices.has(planet_index):
			return s.index
	return -1


# --- orders -------------------------------------------------------------

func _test_order_roundtrip() -> void:
	sup.begin("order round-trip")

	var o := Order.make_move_fleet(0, 7, 12)
	sup.ok(o.type == Enums.OrderType.MOVE_FLEET, "move order has MOVE_FLEET type")
	sup.eq(o.target_planet, 12, "move order keeps its target planet")
	sup.eq(o.target_system, -1, "a move order names no system")
	sup.ok(not o.describe().is_empty(), "move order describes itself")

	var back := Order.from_dict(o.to_dict())
	sup.ok(back != null, "an order survives to_dict/from_dict")
	sup.eq(back.type, o.type, "type survives the round-trip")
	sup.eq(back.faction, o.faction, "faction survives the round-trip")
	sup.eq(back.fleet, o.fleet, "fleet survives the round-trip")
	sup.eq(back.target_planet, o.target_planet, "target survives the round-trip")
	sup.eq(back.fingerprint(), o.fingerprint(), "fingerprint survives the round-trip")

	sup.expect_guard("from_dict rejects a payload with no type", func() -> Variant:
		return Order.from_dict({"faction": 3})
	)
	sup.expect_guard("from_dict rejects an order type it does not know", func() -> Variant:
		return Order.from_dict({"type": 9999, "faction": 0})
	)

	# Every constructor must produce something describable and round-trippable.
	var all: Array[Order] = [
		Order.make_colonize(1, 3, 9),
		Order.make_siege(1, 3, 4),
		Order.make_build_ship(2, 5, &"corvette"),
		Order.make_build_structure(2, 5, &"factory"),
		Order.make_set_tax(2, 0.5),
		Order.make_set_research(2, PackedFloat64Array([1.0, 0.0, 0.0, 0.0])),
		Order.make_cancel_build(2, 6),
		Order.make_disband(2, 3),
	]
	for candidate in all:
		sup.ok(not candidate.describe().is_empty(),
			"constructor produces a description: %d" % candidate.type)
		var rt := Order.from_dict(candidate.to_dict())
		sup.ok(rt != null and rt.fingerprint() == candidate.fingerprint(),
			"constructor order round-trips: %d" % candidate.type)


func _test_order_queue() -> void:
	sup.begin("order queue")

	var q := OrderQueue.new()
	sup.ok(not q.is_ready(0), "a fresh faction is not ready")

	sup.ok(q.submit(Order.make_move_fleet(0, 1, 2)), "submit accepts an order")
	sup.eq(q.pending_count(), 1, "one order is pending")
	sup.ok(not q.is_ready(0), "submitting does not imply ready")

	q.set_ready(0, true)
	sup.ok(q.is_ready(0), "readiness latches once set")
	sup.ok(q.all_ready(PackedInt32Array([0])),
		"all_ready is true when the only faction is ready")
	sup.ok(not q.all_ready(PackedInt32Array([0, 1])),
		"all_ready is false while one faction lags")

	q.set_ready(1, false)
	sup.ok(not q.all_ready(PackedInt32Array([0, 1])),
		"readiness is tracked per faction, not globally")
	sup.ok(q.is_ready(0), "another faction going unready does not clear ours")
	q.set_ready(1, true)
	sup.ok(q.all_ready(PackedInt32Array([0, 1])),
		"all factions ready makes all_ready true")
	sup.ok(not q.all_ready(PackedInt32Array()),
		"an empty faction set is never all-ready")

	sup.eq(q.orders_for(0).size(), 1, "orders_for returns the queued order")
	q.submit(Order.make_move_fleet(0, 1, 3))
	sup.eq(q.orders_for(0).size(), 2, "a second order is queued alongside the first")
	sup.eq(q.factions_with_orders(), PackedInt32Array([0]),
		"factions_with_orders reports faction 0")

	q.clear()
	sup.eq(q.pending_count(), 0, "clear empties the queue")
	sup.ok(not q.is_ready(0), "clear also drops readiness")


# --- movement -----------------------------------------------------------

## A fleet crosses every map size in a comparable number of *turns*.
##
## This is the substantive claim behind the movement scaling, and it is easy to state and
## easy to get wrong: the span grows by up to fifty times, so if only the layout scaled and
## not the speed, a `tiny` map would be a game nobody ever moves in and an `extreme` one a
## game nobody ever finishes. Asserted as a ratio rather than an exact figure, because the
## actual turns depend on where the generator happened to put the two planets.
func _test_map_size_travel() -> void:
	sup.begin("travel time is comparable across map sizes")
	var turns := {}
	for tier: String in GalaxyGenerator.SIZE_TIERS:
		var g := _sized_galaxy(2024, tier)
		# Park a scout on the innermost world and send it to the outermost. That is the
		# longest leg the map offers, so it is the one that has to stay in budget.
		var inner := 0
		var outer := 0
		var inner_r := INF
		var outer_r := -1.0
		for p in g.planets:
			var r := p.position.length()
			if r < inner_r:
				inner_r = r
				inner = p.index
			if r > outer_r:
				outer_r = r
				outer = p.index
		sup.ok(outer != inner, "%s has two distinct worlds to travel between" % tier)

		var fleet := _place_fleet(g, 0, inner, {&"scout": 1})
		sup.ok(MovementStage.issue_move(g, fleet.id, 0, outer),
			"%s: a scout accepts a cross-system move order" % tier)
		var n := 0
		while fleet.destination >= 0 and n < 5000:
			MovementStage.advance(g)
			n += 1
		sup.eq(fleet.destination, -1, "%s: the scout arrives" % tier)
		sup.ok(n > 0 and n < 500, "%s: the crossing took a sane number of turns" % tier,
			"%d turns across %.0f parsecs" % [n, g.radius() * 2.0])
		turns[tier] = n

	var lo := 9999
	var hi := 0
	for tier: String in turns:
		lo = mini(lo, int(turns[tier]))
		hi = maxi(hi, int(turns[tier]))
	# A fifty-fold difference in span should not produce anything like a fifty-fold
	# difference in turns. This is a wide band on purpose: the point is to catch a whole
	# order of magnitude of drift, not to pin an exact balance figure.
	sup.ok(hi <= lo * 4,
		"every map size is crossed in a comparable number of turns",
		"fastest=%d slowest=%d" % [lo, hi])

	# The span really does differ, or the comparison above would be vacuous.
	sup.ok(MovementStage.map_factor(_sized_galaxy(2024, "extreme"))
		> MovementStage.map_factor(_sized_galaxy(2024, "tiny")) * 10.0,
		"the map factor genuinely differs between the smallest and largest")


## A galaxy laid out at a named tier.
func _sized_galaxy(seed_value: int, tier: String) -> GalaxyState:
	var r := _rng(seed_value)
	return GalaxyGenerator.generate(
		_defs, r, 40, 3, _db, null,
		float(GalaxyGenerator.SIZE_TIERS[tier]))


func _test_movement() -> void:
	sup.begin("movement")

	var g := _galaxy(4242)
	var fleet := _place_fleet(g, 0, 0, {&"scout": 1})
	var origin := fleet.system

	var speed := MovementStage.fleet_speed(fleet, g.faction(0))
	sup.ok(speed > 0.0, "a fleet has positive speed", "%.3f" % speed)
	sup.ok(MovementStage.movement_allowance(g.faction(0)) >= 0.0,
		"movement allowance is non-negative")

	# Every fleet moves at the uniform dot rate. `fleet_speed` used to return the slowest
	# hull's speed scaled by drive research, so a scout and a dreadnought crossed the same
	# map in different numbers of turns and neither number could be quoted to the player
	# before committing. These three fleets differ in exactly the composition that used to
	# matter, so if speed ever varies with hulls again these fail.
	for hulls: Dictionary in [
		{&"scout": 1}, {&"colony_ship": 1}, {&"dreadnought": 1}, {&"scout": 4},
	]:
		var probe := _place_fleet(g, 0, 0, hulls)
		sup.eq(MovementStage.fleet_speed(probe, g.faction(0)), MovementStage.DOTS_PER_TURN,
			"%s travels at the uniform dot rate" % str(hulls))
	sup.eq(speed, MovementStage.DOTS_PER_TURN,
		"and the rate is the one the turn count is quoted in")
	# Pinned to the literal, not to the constant. `eq(speed, DOTS_PER_TURN)` is a tautology
	# -- it passes at ten dots per turn exactly as it passes at one, which is how the map
	# ended up quoting "14 dots, 2 turns" over a line of fourteen pips without a single
	# check failing. The rate is the thing that makes a pip mean a turn, so it gets a
	# literal.
	sup.eq(speed, 1.0,
		"and that rate is one waypoint per turn -- a turn IS a pip on the map")
	# Which makes the quoted figure count the marks rather than approximate them.
	sup.ok(ceili(MovementStage.orbit_dots(g, g.planet(origin), g.planet(origin + 1))
			/ MovementStage.DOTS_PER_TURN) >= 1,
		"any real crossing costs at least one turn")

	# A dot is a fixed fraction of the radius, so the same crossing is the same number of
	# dots on every map size. This is what makes a quoted turn count meaningful across a
	# `--map-size` flag the player chose before the game started.
	var dot := MovementStage.dot_size(g)
	sup.ok(is_equal_approx(dot, g.radius() * MovementStage.DOT_FRACTION),
		"a dot is a fixed fraction of the radius", "%.1f parsecs" % dot)
	var tiny := _sized_galaxy(7, "tiny")
	var extreme := _sized_galaxy(7, "extreme")
	# A dot is a fraction of *this* map's radius, so the same parsec distance is the same
	# number of dots everywhere and a full crossing is identical on every tier. That is the
	# property that lets a quoted turn count survive a `--map-size` flag chosen before the
	# game started.
	sup.ok(is_equal_approx(
			MovementStage.to_dots(g, 2.0 * g.radius()),
			MovementStage.to_dots(extreme, 2.0 * extreme.radius())),
		"a full crossing is the same dot count on every tier",
		"large=%.0f extreme=%.0f" % [
			MovementStage.to_dots(g, 2.0 * g.radius()),
			MovementStage.to_dots(extreme, 2.0 * extreme.radius())])
	# The dot itself is bigger on a bigger map, which is what makes the parsec figures
	# mean something different per tier while the dot figures do not.
	sup.ok(MovementStage.dot_size(extreme) > MovementStage.dot_size(tiny) * 10.0,
		"the parsec size of a dot scales with the map",
		"tiny=%.1f extreme=%.1f" % [
			MovementStage.dot_size(tiny), MovementStage.dot_size(extreme)])

	sup.expect_guard("issue_move rejects a fleet the faction does not own", func() -> Variant:
		return MovementStage.issue_move(g, fleet.id, 1, 5)
	)
	sup.expect_guard("issue_move rejects an unknown fleet", func() -> Variant:
		return MovementStage.issue_move(g, 99999, 0, 5)
	)
	sup.expect_guard("issue_move rejects a move to the planet it is already on", func() -> Variant:
		return MovementStage.issue_move(g, fleet.id, 0, origin)
	)
	sup.expect_guard("issue_move rejects an unknown planet", func() -> Variant:
		return MovementStage.issue_move(g, fleet.id, 0, 99999)
	)

	# Pick a far planet: movement is measured in parsecs, so a short hop and a long one
	# have to be distinguished or the rescaling of the map would not be observable.
	var far := -1
	var far_d := 0.0
	for p in g.planets:
		var d: float = MovementStage.orbit_distance(g.planet(origin), p)
		if d > far_d:
			far_d = d
			far = p.index
	sup.ok(far >= 0 and far_d > 0.0, "the system has a planet worth travelling to",
		"%.1f parsecs" % far_d)
	if far >= 0:
		sup.ok(MovementStage.issue_move(g, fleet.id, 0, far), "a legal move is accepted")
		sup.eq(fleet.destination, far, "the destination is the target planet")
		sup.expect_guard("issue_move refuses a fleet already in transit", func() -> Variant:
			return MovementStage.issue_move(g, fleet.id, 0, origin + 1)
		)

		# A long hop must take more than one turn; a short one may take several. Either
		# way, the fleet ends up where it was sent and nowhere else.
		#
		# The turn count is checked against `transit_turns` as well as against a floor,
		# because that is the number the map quotes to the player before they commit. A
		# prediction that disagreed with the resolver would be worse than no prediction.
		var turns := 0
		while fleet.destination >= 0 and turns < 500:
			MovementStage.advance(g)
			turns += 1
		sup.eq(fleet.system, far, "the fleet arrives at the target planet")
		sup.eq(fleet.destination, -1, "the destination clears on arrival")
		sup.ok(turns > 0, "the fleet did not teleport", "%d turns of travel" % turns)
		sup.eq(turns, MovementStage.transit_turns(g, origin, far),
			"the resolver spends exactly the turn count the map quotes")
		# The brief's rebalance: movements take multiple turns across the map. Asserted on
		# the map's own outermost worlds, which is the longest crossing available.
		var inner := -1
		var outer := -1
		var span := 0.0
		for p in g.planets:
			var r := p.position.length()
			if inner < 0 or r < span:
				span = r
				inner = p.index
			if outer < 0 or r > span:
				span = r
				outer = p.index
		if inner >= 0 and outer >= 0 and inner != outer:
			var widest := MovementStage.transit_turns(g, inner, outer)
			sup.ok(widest >= 3,
				"the longest crossing on this map takes several turns",
				"%d turns over %.0f dots" % [
					widest, MovementStage.orbit_dots(
						g, g.planet(inner), g.planet(outer))])
			# The turn count is the pip count, so it must agree with the marks drawn for
			# this exact crossing. Guards the two against drifting apart again.
			sup.eq(MovementStage.waypoints(g, inner, outer).size() + 1, widest,
				"the longest crossing draws one pip per turn")
			# And it is the same on the biggest map the game can be launched on, which is
			# the whole reason distances are in dots.
			var big := _sized_galaxy(2024, "extreme")
			var b_inner := -1
			var b_outer := -1
			var b_span := 0.0
			for p in big.planets:
				var r := p.position.length()
				if b_inner < 0 or r < b_span:
					b_span = r
					b_inner = p.index
				if b_outer < 0 or r > b_span:
					b_span = r
					b_outer = p.index
			if b_inner >= 0 and b_outer >= 0 and b_inner != b_outer:
				sup.ok(MovementStage.transit_turns(big, b_inner, b_outer) > 1,
					"and on the largest map too",
					"%d turns" % MovementStage.transit_turns(big, b_inner, b_outer))

		# A neighbour on the next ring out is reachable and must not be instant.
		var near := -1
		for p in g.planets:
			if p.index != far:
				near = p.index
				break
		if near >= 0:
			sup.ok(MovementStage.issue_move(g, fleet.id, 0, near), "a second move is accepted")
			var hops := 0
			while fleet.destination >= 0 and hops < 500:
				MovementStage.advance(g)
				hops += 1
			sup.eq(fleet.system, near, "the fleet arrives at the second target")
			sup.ok(hops > 0, "and it travelled rather than teleported", "%d turns" % hops)

	# Engagement discovery: two hostile fleets in one system must be found.
	var g2 := _galaxy(4242)
	var spot := 3
	var a := _place_fleet(g2, 0, spot, {&"scout": 2})
	var d := _place_fleet(g2, 1, spot, {&"scout": 2})
	var pairs := MovementStage.find_engagements(g2)
	sup.eq(pairs.size(), 1, "one engagement is discovered")
	if pairs.size() == 1:
		sup.ok(
			(pairs[0][0] == a.id and pairs[0][1] == d.id)
			or (pairs[0][0] == d.id and pairs[0][1] == a.id),
			"the engagement names both fleets")
		sup.eq(int(pairs[0][0]), a.id, "the lower fleet id is the attacker (stable sort)")

	# Same-faction fleets must never be reported as fighting each other.
	var g3 := _galaxy(99)
	_place_fleet(g3, 0, 5, {&"scout": 1})
	_place_fleet(g3, 0, 5, {&"scout": 1})
	sup.eq(MovementStage.find_engagements(g3).size(), 0, "friendly fleets do not engage")

	# fleets_in_system filters by faction; -1 means everyone.
	sup.eq(MovementStage.fleets_in_system(g3, 5, 0).size(), 2, "fleets_in_system finds both")
	sup.eq(MovementStage.fleets_in_system(g3, 5, -1).size(), 2, "faction -1 sees every fleet")
	sup.eq(MovementStage.fleets_in_system(g3, 5, 2).size(), 0, "an absent faction sees none")


# --- combat -------------------------------------------------------------

func _test_combat() -> void:
	sup.begin("combat")

	# A dreadnought fleet must beat an escort screen decisively.
	var wins := 0
	for trial in 20:
		var g := _galaxy(7000 + trial)
		var spot := 7
		var a := _place_fleet(g, 0, spot, {&"dreadnought": 3})
		var d := _place_fleet(g, 1, spot, {&"scout": 3})

		var eng := CombatStage.resolve(
			g, a, d, g.faction(0), g.faction(1), _rng(500 + trial), _db
		)
		sup.ok(eng != null, "trial %d produced an engagement" % trial)
		sup.ok(eng.rounds > 0 and eng.rounds <= int(_db.get("MAX_COMBAT_ROUNDS")),
			"trial %d ran within the round cap" % trial, str(eng.rounds))
		sup.ok(int(eng.outcome) != int(Enums.CombatOutcome.NONE),
			"trial %d recorded an outcome" % trial, str(eng.outcome))
		if int(eng.outcome) == int(Enums.CombatOutcome.FLEET_DESTROYED):
			wins += 1

	sup.ok(wins >= 15, "dreadnoughts win decisively against scouts", "%d/20 wins" % wins)

	# Four cruisers against one scout is not a fight.
	var g2 := _galaxy(7100)
	var lone := _place_fleet(g2, 0, 2, {&"scout": 1})
	var many := _place_fleet(g2, 1, 2, {&"cruiser": 4})
	var eng2 := CombatStage.resolve(
		g2, many, lone, g2.faction(1), g2.faction(0), _rng(99), _db
	)
	sup.eq(int(eng2.outcome), int(Enums.CombatOutcome.FLEET_DESTROYED),
		"four cruisers destroy one scout")
	sup.eq(lone.ship_count(), 0, "the losing fleet loses every hull")

	# resolve_pair must remove the loser and leave the winner standing.
	var g3 := _galaxy(7200)
	var weak := _place_fleet(g3, 0, 4, {&"scout": 1})
	var strong := _place_fleet(g3, 1, 4, {&"dreadnought": 2})
	var line := CombatStage.resolve_pair(g3, strong.id, weak.id, _rng(5), _db, _defs)
	sup.ok(not line.is_empty(), "resolve_pair produces a news line")
	sup.eq(g3.fleet(weak.id), null, "the destroyed fleet is removed from the galaxy")
	sup.ok(g3.fleet(strong.id) != null, "the winner survives")
	sup.ok(g3.fleet(strong.id).active, "the winner is still active")

	sup.expect_guard("resolve_pair rejects an unknown attacker", func() -> Variant:
		var gg := _galaxy(7300)
		return CombatStage.resolve_pair(gg, 999999, 0, _rng(1), _db, _defs)
	)


# --- invasion -----------------------------------------------------------

func _test_invasion() -> void:
	sup.begin("invasion")

	# Bombardment must strip surface batteries before the ground assault.
	var g := _galaxy(8000)
	var planet := _colonize(g, 1, _unowned_planet(g, 1))
	planet.structures[&"missile_battery"] = 4
	var before := planet.count(&"missile_battery")

	var attacker := _place_fleet(g, 0, _system_of_planet(g, planet.index),
		{&"dreadnought": 6, &"transport": 4})
	var fa: FactionState = g.faction(0)
	var fd: FactionState = g.faction(1)

	var out := InvasionStage.invade(g, attacker, planet, fa, fd, _defs, _db, _rng(31))
	sup.ok(out != null, "an invasion is attempted", "planet %d" % planet.index)
	sup.ok(out.bombardment_damage > 0.0, "bombardment dealt damage",
		"%.1f" % out.bombardment_damage)
	sup.ok(planet.count(&"missile_battery") < before, "bombardment stripped surface batteries",
		"%d -> %d" % [before, planet.count(&"missile_battery")])

	if out.captured:
		sup.eq(planet.owner, 0, "a captured planet changes hands")
		sup.eq(fd.colonies_lost, 1, "the loser books a colony loss")
		sup.eq(fa.colonies_taken, 1, "the winner books a colony capture")
		sup.eq(planet.count(&"garrison"), 0, "the new owner garrisons the surface")
		sup.ok(planet.population < 1.0, "the population takes casualties",
			"%.3f" % planet.population)
	else:
		sup.ok(out.repelled, "an uncaptured planet is reported as repelled")
		sup.eq(planet.owner, 1, "a repelled assault leaves the planet with its owner")

	# An uncolonised planet is never invaded.
	var g2 := _galaxy(8100)
	var lonely := _place_fleet(g2, 0, 0, {&"transport": 3})
	var untouched: PlanetState = g2.planet(g2.systems[0].planet_indices[0])
	var out2 := InvasionStage.invade(
		g2, lonely, untouched, g2.faction(0), g2.faction(1), _defs, _db, _rng(1))
	sup.ok(out2 == null, "an uncolonised planet is not invaded")
	sup.eq(untouched.owner, -1, "the uncolonised planet is untouched")

	# A fleet with neither troops nor guns has no business invading.
	var g3 := _galaxy(8200)
	var body := g3.systems[0].planet_indices[0]
	var enemy := _colonize(g3, 1, body)
	var scouts_only := _place_fleet(g3, 0, _system_of_planet(g3, body), {&"scout": 3})
	var out3 := InvasionStage.invade(
		g3, scouts_only, enemy, g3.faction(0), g3.faction(1), _defs, _db, _rng(2))
	sup.ok(out3 == null, "a fleet with no troops and no guns cannot invade")
	sup.eq(enemy.owner, 1, "the colony survives an unarmed fleet")

	# resolve_all must find a contested system and report it.
	var g4 := _galaxy(8300)
	# The attacker must be parked *on the contested world*, which is the whole
	# redefinition of "contested" in a one-system map.
	var contested := _unowned_planet(g4)
	sup.ok(contested >= 0, "there is a world to contest")
	_colonize(g4, 1, contested)
	_place_fleet(g4, 0, contested, {&"dreadnought": 8, &"transport": 4})
	var lines := InvasionStage.resolve_all(g4, _defs, _db, _rng(4))
	sup.ok(lines.size() >= 1, "resolve_all reports an invasion", "%d lines" % lines.size())


# --- colony simulation --------------------------------------------------

func _test_colony_sim() -> void:
	sup.begin("colony simulation")

	# A fertile, unstarved colony with farms should grow.
	var g := _galaxy(9000)
	# Pick a body nobody owns. Planet 0 is now faction 0's randomly drawn homeworld, so
	# colonising it would re-own an already-populated planet and the growth assertion
	# below would be measuring a colony that was already at its cap.
	var unowned := -1
	for p in g.planets:
		if p.owner < 0 and not p.colonized:
			unowned = p.index
			break
	sup.ok(unowned >= 0, "the system has an unclaimed planet to test on")
	var planet := _colonize(g, 0, unowned)
	# The generator seeds hostile planet types alongside habitable ones, so "first
	# unclaimed body" is not necessarily a place a colony could grow. Pick a world the
	# colony can actually live on, which is the precondition for the growth assertion.
	var habitable := -1
	var best_hab := 0.0
	for p in g.planets:
		if p.owner >= 0 or p.colonized:
			continue
		var h: float = p.habitability()
		if h > best_hab:
			best_hab = h
			habitable = p.index
	sup.ok(habitable >= 0 and best_hab > 0.2,
		"the system has a habitable world to colonise", "%.3f habitability" % best_hab)
	if habitable >= 0 and habitable != unowned:
		planet = _colonize(g, 0, habitable)
	# Size the farm block to the local habitability so the colony actually feeds
	# itself: production scales with habitability, consumption does not.
	planet.structures[&"farm"] = maxi(4, int(ceil(2.0 / maxf(0.05, planet.habitability()))))
	sup.ok(planet.habitability() > 0.0, "the test colony is habitable",
		"%.3f" % planet.habitability())
	var pop_before := planet.population
	var fa: FactionState = g.faction(0)

	var r1 := ColonySim.simulate_colony(g, planet, fa, _defs, _db)
	sup.ok(r1.food_produced > 0.0, "farms produce food", "%.3f" % r1.food_produced)
	sup.ok(not r1.starving, "a fed colony does not starve")
	sup.ok(planet.population > pop_before, "a fed colony grows",
		"%.4f -> %.4f" % [pop_before, planet.population])
	sup.ok(planet.population <= planet.max_population(),
		"population never exceeds the habitability cap", "%.3f" % planet.max_population())

	# Strip the farms so production falls short of consumption. The colony must draw
	# down its reserve, then starve and shrink.
	planet.structures[&"farm"] = 0
	planet.food_stock = 1.0
	var shrank := false
	var starved := false
	for _i in 40:
		var before_pop := planet.population
		var rr := ColonySim.simulate_colony(g, planet, fa, _defs, _db)
		if rr.starving:
			starved = true
		if planet.population < before_pop:
			sup.ok(true, "a starving colony loses population",
				"%.4f -> %.4f" % [before_pop, planet.population])
			shrank = true
			break
	sup.ok(starved, "a colony with no farms reports starvation")
	sup.ok(shrank, "an overpopulated colony eventually starves")
	sup.ok(planet.population >= 0.0, "a starving colony never goes negative",
		"%.4f" % planet.population)

	# Economy: the ledger must equal income minus expenses, and the treasury must move
	# by exactly that net.
	var g2 := _galaxy(9100)
	_colonize(g2, 0, g2.systems[0].planet_indices[0])
	var fb: FactionState = g2.faction(0)
	fb.treasury = 5000.0
	var treasury_before := fb.treasury
	ColonySim.simulate_faction(g2, fb, _defs, _db)
	sup.near(fb.last_net, fb.last_income - fb.last_expenses, 0.0001,
		"last_net is income minus expenses")
	sup.near(fb.treasury, treasury_before + fb.last_net, 0.0001,
		"the treasury moves by exactly the net")
	sup.ok(fb.last_expenses > 0.0, "a colony carries upkeep")

	# The treasury floor must be respected.
	var broke: FactionState = g2.faction(1)
	_colonize(g2, 1, _unowned_planet(g2, 1))
	broke.treasury = float(_db.get("TREASURY_FLOOR")) + 1.0
	ColonySim.simulate_faction(g2, broke, _defs, _db)
	sup.near(broke.treasury, float(_db.get("TREASURY_FLOOR")), 0.001,
		"a bankrupt empire is floored, not deleted")

	# Construction advances and the finished building appears.
	var g3 := _galaxy(9200)
	var p3 := _colonize(g3, 0, _unowned_planet(g3))
	var fc: FactionState = g3.faction(0)
	p3.building_queue[&"factory"] = 1
	var factory_turns := int((_defs_building(&"factory") as Resource).get("build_turns"))
	p3.build_turns_remaining = factory_turns
	var built_after := 0
	for _i in factory_turns:
		ColonySim.simulate_colony(g3, p3, fc, _defs, _db)
		if p3.count(&"factory") == 1:
			built_after = _i + 1
	sup.ok(built_after > 0, "the queued building eventually appears",
		"after %d of %d turns" % [built_after, factory_turns])
	sup.ok(built_after >= factory_turns,
		"construction takes at least the declared build_turns",
		"%d turns for a %d-turn project" % [built_after, factory_turns])
	sup.eq(p3.building_queue.size(), 0, "the construction queue drains")

	# A building past its per-colony cap must not be added.
	var farm_def: Resource = _defs_building(&"farm") as Resource
	sup.ok(farm_def != null, "the farm definition resolves")
	if farm_def != null:
		var cap := int(farm_def.get("max_per_colony"))
		sup.ok(cap > 0, "the farm declares a per-colony cap", "cap=%d" % cap)
		sup.ok(not farm_def.can_add(cap), "a colony at the farm cap cannot add another")
		sup.ok(farm_def.can_add(cap - 1), "a colony below the cap can")


# --- research -----------------------------------------------------------

func _test_research() -> void:
	sup.begin("research")

	var g := _galaxy(10000)
	var f: FactionState = g.faction(0)
	_colonize(g, 0, _unowned_planet(g))

	# Surplus funds research; a deficit does not.
	f.last_income = 100.0
	f.research_allocation = PackedFloat64Array([1.0, 0.0, 0.0, 0.0])
	var granted := ResearchStage.accumulate(f, g, _db)
	sup.ok(granted > 0.0, "a profitable empire funds research", "%.3f" % granted)
	sup.ok(f.tech_points[0] > 0.0, "points land in the weighted field")
	sup.ok(is_zero_approx(f.tech_points[1]), "no points leak into unweighted fields")

	f.last_income = 0.0
	var granted_deficit := ResearchStage.accumulate(f, g, _db)
	sup.near(granted_deficit, 0.0, 0.0001, "a zero-income empire researches nothing")

	# A faction with no colonies cannot research at all.
	var g2 := _galaxy(10100)
	var f2: FactionState = g2.faction(1)
	# Strip its founding colony so the empire genuinely has nothing left to fund from.
	for colony in g2.colonies_of(f2.id):
		colony.owner = -1
		colony.colonized = false
	f2.last_income = 500.0
	var orphan := ResearchStage.accumulate(f2, g2, _db)
	sup.near(orphan, 0.0, 0.0001, "an empire with no colonies cannot research")

	# Prerequisites must be respected.
	var g3 := _galaxy(10200)
	var f3: FactionState = g3.faction(0)
	_colonize(g3, 0, g3.systems[0].planet_indices[0])
	f3.tech_points = PackedFloat64Array([5000.0, 5000.0, 5000.0, 5000.0])
	var completed := ResearchStage.complete_available(f3, _defs)
	sup.ok(completed.size() > 0, "a wealthy empire completes research",
		"%d nodes" % completed.size())
	for id in completed:
		sup.ok(f3.researched.has(id), "completed node is recorded: %s" % id)
	sup.ok(_prereqs_satisfied(f3, completed),
		"every completed node had its prerequisites")

	# With nothing banked, nothing completes.
	var g4 := _galaxy(10300)
	var f4: FactionState = g4.faction(0)
	f4.tech_points = PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	sup.eq(ResearchStage.complete_available(f4, _defs).size(), 0,
		"an empty empire completes nothing")


func _prereqs_satisfied(f: FactionState, completed: Array[StringName]) -> bool:
	for id in completed:
		var node: Resource = _defs_tech(id) as Resource
		if node == null:
			continue
		var prereqs: Array = node.get("prerequisites")
		for pre in prereqs:
			if not f.researched.has(pre) and not completed.has(pre):
				return false
	return true


# --- fog of war ---------------------------------------------------------

func _test_fog_of_war() -> void:
	sup.begin("fog of war")

	var g := _galaxy(11000)
	_place_fleet(g, 0, 0, {&"scout": 1})

	FowStage.update_visibility(g, 0, _db)
	# Visibility is per-faction state held on the galaxy, not on the faction.
	var seen: Dictionary = g.visible_systems.get(0, {}) as Dictionary
	sup.ok(seen.size() > 0, "a faction sees systems near its fleets",
		"%d visible" % seen.size())
	sup.ok(FowStage.can_see(g, 0, 0), "the fleet's own system is visible")

	# With one system, system-level fog has nothing to hide: seeing the star is the
	# precondition for seeing anything at all. The fog that actually matters is at the
	# planet level, and this is where the 50x map rescaling gets tested -- a sensor bubble
	# that was not rescaled would cover one orbit ring and the rest of the system would
	# be permanently dark.
	var seen_planets := 0
	var first_unseen := -1
	for p in g.planets:
		var sys_index := _system_of_planet(g, p.index)
		if seen.has(sys_index) and p.surveyed:
			seen_planets += 1
		elif first_unseen < 0:
			first_unseen = p.index
	sup.ok(seen_planets > 0, "a faction sees planets near its fleets",
		"%d visible planets" % seen_planets)
	sup.ok(first_unseen >= 0,
		"a 50x system leaves planets outside any single sensor bubble",
		"first unseen planet %d of %d" % [first_unseen, g.planets.size()])

	# The bubble must be a minority of the system. If a scout sees everything, scouting
	# is not a mechanic and the whole layer is decorative.
	sup.ok(seen_planets < g.planets.size(),
		"a scout's sensor bubble covers only part of the system",
		"%d of %d planets visible" % [seen_planets, g.planets.size()])

	# Redaction: the wire snapshot must not leak what the faction cannot see.
	var snapshot := FowStage.redact(g, 0)
	sup.ok(snapshot.has("systems"), "the snapshot carries systems")
	sup.ok(snapshot.has("visible"), "the snapshot carries the visible set")

	var entries: Array = snapshot["systems"] as Array
	var by_index := {}
	for entry: Dictionary in entries:
		by_index[int(entry.get("index", -1))] = entry
	sup.eq(by_index.size(), g.systems.size(), "the snapshot has one entry per system")

	# The star's identity is never redacted: it is the frame the whole map is built on,
	# and a map centred on a nameless point has nothing to orient by.
	var star_entry: Dictionary = by_index[0] as Dictionary
	sup.ok(String(star_entry.get("name", "")) != "Unknown",
		"the star keeps its name regardless of visibility")
	sup.eq((star_entry.get("warp_lanes", PackedInt32Array()) as PackedInt32Array).size(), 0,
		"the star still reports no warp lanes")

	# Planet-level redaction: a body the faction has never surveyed must not arrive on
	# the wire with its owner, position or reserves intact. This is the rule the Request
	# D audit was about, and planets being the primary marker makes it load-bearing.
	var snapshot_planets: Array = snapshot.get("planets", []) as Array
	sup.ok(snapshot_planets.size() > 0, "the snapshot carries planets")
	var leaked := 0
	for entry: Dictionary in snapshot_planets:
		var p_index := int(entry.get("index", -1))
		if int(entry.get("owner", -1)) < 0:
			continue
		var p: PlanetState = g.planet(p_index)
		# An owned planet is only a leak if the viewer has no business knowing it.
		if p != null and p.owner != 0 and not p.surveyed:
			leaked += 1
	sup.eq(leaked, 0, "no foreign planet's ownership is redacted away unsurveyed")

	# Surveying is permanent and is recorded on the galaxy.
	FowStage.survey_system(g, 0, 0)
	var survey_log: Dictionary = g.surveyed_systems.get(0, {}) as Dictionary
	sup.ok(survey_log.size() > 0, "the faction keeps a survey log")
	for key in survey_log.keys():
		sup.ok(int(key) >= 0, "survey log keys are planet indices")

	# These are not guards but ordinary negative answers: an unknown faction sees
	# nothing, and an unknown system has nothing to survey.
	sup.ok(not FowStage.can_see(g, 99, 0), "an unknown faction sees nothing")
	sup.ok(not FowStage.can_see(g, 0, 99999), "an unknown system is never visible")
	sup.eq(FowStage.survey_system(g, 0, 99999), 0,
		"surveying an unknown system reports nothing surveyed")


# --- end-to-end soak ----------------------------------------------------

func _test_turn_soak() -> void:
	sup.begin("20-turn soak")

	var g := _galaxy(12000, 45, 4)
	var start_turn := g.turn
	var researched := false
	var reports: Array = []

	for t in 20:
		var orders: Array = []
		# Send the human's idle fleets to a rotating planet, exercising the order path
		# every single turn.
		var target := t % g.planets.size()
		for fleet in g.fleets_of(0):
			if fleet.destination < 0 and MovementStage.issue_move(g, fleet.id, 0, target):
				orders.append(Order.make_move_fleet(0, fleet.id, target))

		var report := TurnResolver.resolve_turn(g, orders, _defs, _db, _rng(12000), 0)
		reports.append(report)
		sup.eq(int(report["turn"]), start_turn + t + 1,
			"turn %d reports the correct turn number" % (t + 1))
		sup.ok(report.has("state_hash"), "turn %d produced a state hash" % (t + 1))

		var tp := g.faction(0).tech_points
		if tp[0] > 0.0 or tp[1] > 0.0 or tp[2] > 0.0 or tp[3] > 0.0:
			researched = true

	sup.eq(g.turn, start_turn + 20, "exactly twenty turns elapsed")
	sup.eq(reports.size(), 20, "twenty reports were collected")

	var f0: FactionState = g.faction(0)
	sup.ok(f0.treasury != float(_db.get("START_TREASURY")),
		"the player economy moved", "treasury %.1f" % f0.treasury)
	sup.ok(researched, "the player accumulated research points")
	sup.ok(g.news_log.size() > 0, "the soak produced news", "%d entries" % g.news_log.size())
	sup.ok(not f0.defeated, "the human player is never auto-eliminated")

	# Every faction's visibility must have been refreshed by the last turn.
	var sightings := 0
	for f in g.factions:
		var set: Dictionary = g.visible_systems.get(f.id, {}) as Dictionary
		sightings += set.size()
	sup.ok(sightings > 0, "fog of war ran for every faction",
		"%d faction-system sightings" % sightings)

	# Turn numbers must be strictly increasing and contiguous.
	var contiguous := true
	for i in 20:
		if int((reports[i] as Dictionary)["turn"]) != start_turn + i + 1:
			contiguous = false
	sup.ok(contiguous, "turn numbers are contiguous and monotonic")

	sup.ok(g.state_hash() != 0, "the final state hashes", str(g.state_hash()))


func _test_economy_conservation() -> void:
	sup.begin("economy conservation")

	# Over a soak, every faction's treasury must move by exactly the sum of its
	# per-turn net. Anything else is a resource leak.
	var g := _galaxy(13000, 40, 3)
	var opened: Dictionary = {}
	for f in g.factions:
		opened[f.id] = {"treasury": f.treasury, "net": 0.0}

	for _t in 15:
		TurnResolver.resolve_turn(g, [] as Array, _defs, _db, _rng(13000), 0)
		for f in g.factions:
			var entry: Dictionary = opened[f.id] as Dictionary
			entry["net"] = float(entry["net"]) + f.last_net

	for f in g.factions:
		var entry2: Dictionary = opened[f.id] as Dictionary
		var expected: float = float(entry2["treasury"]) + float(entry2["net"])
		if expected <= float(_db.get("TREASURY_FLOOR")) + 0.001:
			# Once an empire hits the floor its arithmetic stops being a plain sum,
			# but it must never climb back below it.
			sup.near(f.treasury, float(_db.get("TREASURY_FLOOR")), 0.001,
				"faction %d is pinned at the treasury floor" % f.id)
		else:
			sup.near(f.treasury, expected, 0.05,
				"faction %d treasury is conserved across the soak" % f.id)

	# Resource pools must never go negative, in any faction or any field.
	for f2 in g.factions:
		sup.ok(f2.treasury >= float(_db.get("TREASURY_FLOOR")) - 0.001,
			"faction %d respects the treasury floor" % f2.id, "%.2f" % f2.treasury)
		sup.ok(f2.metals >= 0.0, "faction %d metals stay non-negative" % f2.id)
		sup.ok(f2.rare_elements >= 0.0, "faction %d rare elements stay non-negative" % f2.id)
		for i in 4:
			sup.ok(f2.tech_points[i] >= 0.0,
				"faction %d field %d tech points stay non-negative" % [f2.id, i])
			sup.ok(f2.research_allocation[i] >= 0.0,
				"faction %d field %d allocation stays non-negative" % [f2.id, i])
			sup.ok(f2.research_allocation[i] <= 1.0,
				"faction %d field %d allocation stays within 1.0" % [f2.id, i])

	# Populations must never go negative anywhere.
	for planet in g.planets:
		sup.ok(planet.population >= 0.0, "planet %d population is non-negative" % planet.index,
			"%.3f" % planet.population)


func _test_determinism() -> void:
	sup.begin("determinism")

	# Two identical runs from the same seed, driven by the same orders, must produce a
	# byte-identical state hash.
	var hashes: PackedInt64Array = PackedInt64Array()
	for _run in 2:
		var g := _galaxy(14000, 40, 4)
		var rng := _rng(14000)
		for t in 12:
			var orders: Array = []
			# A deterministic order stream: only the human's scout, walking outward one
			# orbit ring at a time. Warp lanes are gone, so the rotation is over planets.
			for fleet in g.fleets_of(0):
				if t % 3 == 0 and fleet.ships.has(&"scout"):
					var reach: PackedInt32Array = PackedInt32Array()
					for p in g.planets:
						if p.index != fleet.system:
							reach.append(p.index)
					if reach.size() > 0:
						var dest: int = reach[t % reach.size()]
						if MovementStage.issue_move(g, fleet.id, 0, dest):
							orders.append(Order.make_move_fleet(0, fleet.id, dest))
					break
			TurnResolver.resolve_turn(g, orders, _defs, _db, rng, 0)
		hashes.append(g.state_hash())

	sup.eq(hashes.size(), 2, "two runs completed")
	sup.eq(hashes[0], hashes[1],
		"identical seed and orders produce an identical state hash")

	# A different seed must produce a different galaxy, or the seed never reached the RNG.
	sup.ok(_galaxy(14001, 40, 4).state_hash() != _galaxy(14002, 40, 4).state_hash(),
		"different seeds produce different galaxies")

	# Save/load mid-soak must not change where the game ends up.
	var gc := _galaxy(14000, 40, 4)
	var rng2 := _rng(14000)
	for _t in 6:
		TurnResolver.resolve_turn(gc, [] as Array, _defs, _db, rng2, 0)

	var reloaded := GalaxyState.new()
	sup.ok(reloaded.from_json(gc.to_json()), "the galaxy reloads from JSON mid-soak")
	sup.ok(reloaded.rebind_definitions(), "definitions rebind after a load")
	sup.eq(reloaded.state_hash(), gc.state_hash(),
		"a reloaded galaxy hashes identically to the original")

	# Continue both and confirm they stay in lockstep.
	var rng3 := _rng(14000)
	rng3.state = reloaded.rng_state
	for _t in 6:
		TurnResolver.resolve_turn(gc, [] as Array, _defs, _db, rng2, 0)
		TurnResolver.resolve_turn(reloaded, [] as Array, _defs, _db, rng3, 0)
	sup.eq(reloaded.state_hash(), gc.state_hash(),
		"a reloaded galaxy stays in lockstep with the original")
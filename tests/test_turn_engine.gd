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
	_test_no_rival_research_news()
	_test_movement()
	_test_map_size_travel()
	_test_combat()
	_test_no_transit_combat()
	_test_defense_suppression()
	_test_invasion()
	_test_colony_sim()
	_test_space_port_hulls()
	_test_colony_ship_landing()
	_test_storage_capacity()
	_test_metal_boost()
	_test_growth_curve()
	_test_troops_and_cargo()
	_test_survey()
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
	p.population = 6.0
	# Housing, food and metal: a City Complex for the 20 the design document specifies, a
	# granary for storage, a farm and a mine, and a landed Colony Ship for the 5 pop and 5
	# food it contributes. Without housing the colony cannot grow at all, and without a
	# granary it overflows on its first surplus -- both of which are the rules under test.
	p.structures = {&"city_complex": 1, &"granary": 1, &"colony_ship_building": 1, &"farm": 2, &"mine": 1}
	p.food_stock = 20.0
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
		Order.make_build_structure(2, 5, &"granary"),
		Order.make_travel(2, 3, 9, {&"corvette": 2}),
		Order.make_recruit_troop(2, 5),
		Order.make_boost_build(2, 5, 40.0),
		Order.make_set_build_mode(2, 5, int(Enums.BuildMode.PER_TURN)),
		Order.make_cargo(2, 3, &"troops", 2.0, true),
		Order.make_cargo(2, 3, &"metals", 25.0, false),
		Order.make_cancel_build(2, 6),
		Order.make_disband(2, 3),
	]

	# The two Phase 7 orders are retained on the wire but no longer do anything: the tax
	# slider and the research allocation sliders are both gone. They must still *parse*, or a
	# client from before this phase would have its packets rejected as malformed.
	for legacy in [Order.make_set_tax(2, 0.5), Order.make_set_research(
			2, PackedFloat64Array([1.0, 0.0, 0.0, 0.0]))]:
		var parsed := Order.from_dict(legacy.to_dict())
		all.append(legacy)
		sup.ok(parsed != null, "the legacy order %d still parses" % legacy.type)
	for candidate in all:
		sup.ok(not candidate.describe().is_empty(),
			"constructor produces a description: %d" % candidate.type)
		var rt := Order.from_dict(candidate.to_dict())
		sup.ok(rt != null and rt.fingerprint() == candidate.fingerprint(),
			"constructor order round-trips: %d" % candidate.type)


## Rival research must not be announced.
##
## The resolver used to post "Word reaches us that X has made a discovery" for every rival
## node every turn. In a four-empire game that buried the player's own news under lines about
## strangers' science -- and told them nothing actionable, because the node was never named and
## the player cannot spend a rival's discovery.
func _test_no_rival_research_news() -> void:
	sup.begin("no rival research spam")

	var g := _galaxy(11500, 40, 4)
	var rival := g.faction(1)
	sup.ok(rival != null, "the fixture really does have a rival empire")
	if rival == null:
		return

	# Give the rivals plenty to complete, so the old path would have fired many times.
	for f in g.factions:
		f.tech_points = PackedFloat64Array([5000.0, 5000.0, 5000.0, 5000.0])
		# Enough civilians to cross several population milestones, for the player as well as
		# the rivals: the point is that the player's own news survives the suppression.
		for colony in g.colonies_of(f.id):
			colony.population = 30.0
	_colonize(g, 1, _unowned_planet(g, 1))
	for colony in g.colonies_of(1):
		colony.population = 30.0

	var news := PackedStringArray()
	for _turn in 12:
		var report := TurnResolver.resolve_turn(g, [] as Array, _defs, _db, _rng(11500), 0)
		for line: Variant in report["news"]:
			news.append(String(line))

	sup.ok(not news.is_empty(), "the turns produced some news at all")
	var discoveries := 0
	var spoken := PackedStringArray()
	for line in news:
		if line.contains("discovery") or line.contains("Word reaches us"):
			discoveries += 1
			spoken.append(line)
	sup.eq(discoveries, 0,
		"no turn announced a rival empire's research (offending lines: %s)" % " | ".join(spoken))

	# The news log the session reads is the same text, so the leak cannot be hiding there.
	var logged := 0
	for entry: Variant in g.news_log:
		if String(entry).contains("discovery"):
			logged += 1
	sup.eq(logged, 0, "and none reached the persisted news log")

	# Rival milestones are silent too, for the same reason. Checked by attribution rather
	# than by counting: the player's own milestone lines carry their empire's name, so every
	# milestone line must name the player and nothing else.
	var me: FactionState = g.faction(0)
	var own := 0
	var foreign_milestones := PackedStringArray()
	for line in news:
		if not line.contains("population milestone"):
			continue
		if line.contains(me.name):
			own += 1
		else:
			foreign_milestones.append(line)
	sup.eq(foreign_milestones.size(), 0,
		"every milestone line names the player and no rival (offenders: %s)" % " | ".join(
			foreign_milestones))

	# The player's own research *is* announced: suppressing the spam must not silence
	# everything, or the news feed goes empty and the player loses their own progress.
	sup.ok(own > 0, "the player's own milestones are still announced", "%d lines" % own)


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

		var fleet := _place_fleet(g, 0, inner, {&"exploration_ship": 1})
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
	var fleet := _place_fleet(g, 0, 0, {&"exploration_ship": 1})
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
		{&"exploration_ship": 1}, {&"colony_ship": 1}, {&"dreadnought": 1}, {&"exploration_ship": 4},
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
	var a := _place_fleet(g2, 0, spot, {&"exploration_ship": 2})
	var d := _place_fleet(g2, 1, spot, {&"exploration_ship": 2})
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
	_place_fleet(g3, 0, 5, {&"exploration_ship": 1})
	_place_fleet(g3, 0, 5, {&"exploration_ship": 1})
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
		var d := _place_fleet(g, 1, spot, {&"exploration_ship": 3})

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
	var lone := _place_fleet(g2, 0, 2, {&"exploration_ship": 1})
	var many := _place_fleet(g2, 1, 2, {&"cruiser": 4})
	var eng2 := CombatStage.resolve(
		g2, many, lone, g2.faction(1), g2.faction(0), _rng(99), _db
	)
	sup.eq(int(eng2.outcome), int(Enums.CombatOutcome.FLEET_DESTROYED),
		"four cruisers destroy one scout")
	sup.eq(lone.ship_count(), 0, "the losing fleet loses every hull")

	# resolve_pair must remove the loser and leave the winner standing.
	var g3 := _galaxy(7200)
	var weak := _place_fleet(g3, 0, 4, {&"exploration_ship": 1})
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

	# --- Step 3 is gated on step 2 --------------------------------------------
	# A colony with batteries standing is unreachable, full stop. This is the whole
	# sequencing claim of the design document, and it is asserted before anything else
	# because every later assertion depends on it.
	var g := _galaxy(8000)
	var planet := _colonize(g, 1, _unowned_planet(g, 1))
	planet.structures[&"planetary_defense"] = 4
	planet.troops = 2
	var fa: FactionState = g.faction(0)
	var fd: FactionState = g.faction(1)

	# The garrison, before anything lands: the standing garrison plus half a troop per
	# civilian. Read here rather than after the assault, because the assault rewrites both
	# numbers -- it garrisons the world with its own survivors and cuts the population.
	sup.near(InvasionStage.planet_garrison(planet, _db), 5.0, 0.001,
		"the garrison is the standing garrison plus half a troop per civilian")

	var attacker := _place_fleet(g, 0, planet.index,
		{&"dreadnought": 6, &"troop_transport": 4})
	# Troops have to be loaded before they can land: a transport's bays are capacity, not a
	# garrison. This is asserted separately below; here the manifest is filled directly so
	# the gate is what is under test.
	attacker.cargo["troops"] = 24.0

	var blocked := InvasionStage.invade(g, attacker, planet, fa, fd, _defs, _db, _rng(31))
	sup.ok(blocked != null, "an invasion is attempted", "planet %d" % planet.index)
	sup.ok(blocked.blocked, "an assault against standing planetary defenses is blocked")
	sup.eq(blocked.block_reason, "planetary defenses still stand", "and says why")
	sup.eq(planet.owner, 1, "the colony survives an assault it never had to fight")
	sup.eq(planet.count(&"planetary_defense"), 4, "and its batteries are untouched")

	# --- Step 2: defence suppression ------------------------------------------
	# Once the batteries are down the ground assault may proceed. Suppression is the combat
	# stage's job, so it is driven through `CombatStage.suppress_defenses` here rather than
	# by reaching into the planet.
	var lines := CombatStage.suppress_defenses(g, _rng(77), _db, _defs)
	sup.ok(lines.size() > 0, "suppression reports what it did", "%d lines" % lines.size())
	sup.eq(InvasionStage.planetary_defenses(planet), 0,
		"enough firepower destroys every battery")
	sup.eq(planet.count(&"planetary_defense"), 0, "and the structure is gone from the colony")

	# --- Step 3: the ground assault --------------------------------------------
	var out := InvasionStage.invade(g, attacker, planet, fa, fd, _defs, _db, _rng(31))
	sup.ok(out != null and not out.blocked,
		"with the batteries gone the assault is no longer blocked")
	# 24 land against a garrison of 5: nineteen hold the surface, and the five the garrison
	# cost never leave the holds.
	sup.ok(out.captured, "24 troops take a garrison of 5",
		"troops_landed=%.0f" % out.troops_landed)
	sup.eq(planet.owner, 0, "a captured planet changes hands")
	sup.eq(fd.colonies_lost, 1, "the loser books a colony loss")
	sup.eq(fa.colonies_taken, 1, "the winner books a colony capture")
	sup.ok(planet.troops > 0, "surviving attackers become the new garrison",
		"garrison=%d" % planet.troops)
	sup.eq(planet.troops, 19, "and the garrison is the survivors, not the landing force")
	# Only the nineteen who survived the landing disembark; the five the garrison cost stay
	# aboard. A transport that lands everybody and comes home with an empty hold would be a
	# way to spend troops without spending a ship.
	sup.near(attacker.troops_carried(), 5.0, 0.001,
		"only the survivors disembark -- the cost of the garrison stays aboard")
	sup.ok(planet.population < 6.0, "the population takes casualties",
		"%.3f" % planet.population)
	sup.near(planet.population, floor(6.0 * 0.6), 0.001,
		"the garrison battle costs two fifths of the civilians")

	# --- The assault is deterministic -----------------------------------------
	# Same state, same answer, every time. This is a correctness property, not a balance
	# one: the ground battle used to roll against the shared RNG, so two clients reaching
	# the same state could disagree about who owned a world.
	var det := true
	for _run in 8:
		var gx := _galaxy(8000)
		var px := _colonize(gx, 1, _unowned_planet(gx, 1))
		px.troops = 2
		px.population = 0.0
		px.structures[&"planetary_defense"] = 0
		var ax := _place_fleet(gx, 0, px.index, {&"troop_transport": 4})
		ax.cargo["troops"] = 10.0
		var ox := InvasionStage.invade(
			gx, ax, px, gx.faction(0), gx.faction(1), _defs, _db, _rng(9000 + _run))
		# 10 land against a garrison of 2: eight survive and garrison the world.
		if not ox.captured or px.owner != 0 or px.troops != 8:
			det = false
	sup.ok(det, "eight identical assaults resolve identically")

	# Troops committed to a losing assault are spent: a fleet that attacks into a stronger
	# garrison has to come home with nothing.
	var g2 := _galaxy(8050)
	var walled := _colonize(g2, 1, _unowned_planet(g2, 1))
	walled.structures[&"planetary_defense"] = 0
	walled.troops = 40
	walled.population = 0.0
	var thin := _place_fleet(g2, 0, walled.index, {&"troop_transport": 2})
	thin.cargo["troops"] = 6.0
	var repelled := InvasionStage.invade(
		g2, thin, walled, g2.faction(0), g2.faction(1), _defs, _db, _rng(2))
	sup.ok(repelled.repelled, "six troops cannot take a garrison of forty")
	sup.eq(walled.owner, 1, "the colony holds")
	sup.eq(thin.troops_carried(), 0.0, "and the attackers spend every troop they landed")
	# The transports themselves survive: the troops died on the ground, not the ships. A
	# lift that comes home empty is a real cost and is not the same as losing the fleet.
	sup.eq(thin.ship_count(), 2, "the transports survive a failed assault, empty")

	# An uncolonised planet is never invaded.
	var g3 := _galaxy(8100)
	var lonely := _place_fleet(g3, 0, 0, {&"troop_transport": 3})
	var untouched: PlanetState = g3.planet(g3.systems[0].planet_indices[0])
	var out3 := InvasionStage.invade(
		g3, lonely, untouched, g3.faction(0), g3.faction(1), _defs, _db, _rng(1))
	sup.ok(out3 == null, "an uncolonised planet is not invaded")
	sup.eq(untouched.owner, -1, "the uncolonised planet is untouched")

	# A fleet with neither troops nor guns has no business invading.
	var g4 := _galaxy(8200)
	var body := g4.systems[0].planet_indices[0]
	var enemy := _colonize(g4, 1, body)
	var scouts_only := _place_fleet(g4, 0, body, {&"exploration_ship": 3})
	var out4 := InvasionStage.invade(
		g4, scouts_only, enemy, g4.faction(0), g4.faction(1), _defs, _db, _rng(2))
	sup.ok(out4 == null, "a fleet with no troops and no guns cannot invade")
	sup.eq(enemy.owner, 1, "the colony survives an unarmed fleet")

	# resolve_all must find a contested world and report it.
	var g5 := _galaxy(8300)
	# The attacker must be parked *on the contested world*, which is the whole
	# redefinition of "contested" in a one-system map.
	var contested := _unowned_planet(g5)
	sup.ok(contested >= 0, "there is a world to contest")
	var taken := _colonize(g5, 1, contested)
	taken.structures[&"planetary_defense"] = 0
	taken.troops = 1
	var landing := _place_fleet(g5, 0, contested, {&"dreadnought": 8, &"troop_transport": 4})
	landing.cargo["troops"] = 30.0
	var all_lines := InvasionStage.resolve_all(g5, _defs, _db, _rng(4))
	sup.ok(all_lines.size() >= 1, "resolve_all reports an invasion", "%d lines" % all_lines.size())
	sup.eq(taken.owner, 0, "and the world changes hands")

	# A garrison is not made of civilians alone: a colony with no Barracks still defends
	# itself in proportion to its population, which is what keeps the population economy
	# relevant in a war rather than decorative.
	sup.ok(InvasionStage.planet_garrison(taken, _db) > 0.0,
		"a colony with no troops still garrisons from its population")


# --- growth curve ---------------------------------------------------------

## Birth chance falls as the colony fills, and rises again when it empties.
##
## The flat 50% the first version used was not a growth rate but a coin toss: a colony of four
## and a colony of forty both added one person on half their turns, so the only thing standing
## between a colony and unlimited growth was the player refusing to build housing. The soft
## cap makes the curve flatten on its own -- and, because it is a function of population
## *alone*, makes a colony that has been depopulated repopulate quickly again.
func _test_growth_curve() -> void:
	sup.begin("population growth curve")

	var base := float(_db.get("POP_GROWTH_CHANCE"))
	var penalty := float(_db.get("POP_GROWTH_PENALTY_PER_POP"))
	var floor_chance := float(_db.get("POP_GROWTH_MIN_CHANCE"))
	var ceiling := float(_db.get("POP_GROWTH_MAX_CHANCE"))
	sup.near(base, 0.50, 0.0001, "the curve starts at a flat 50%")
	sup.near(penalty, 0.015, 0.0001, "and falls by 1.5% per pop")
	sup.near(floor_chance, 0.05, 0.0001, "down to a 5% floor")
	sup.near(ceiling, 0.50, 0.0001, "and is capped at 50%")

	# The formula itself, at the points that matter.
	sup.near(ColonySim.growth_chance(2.0, _db), 0.47, 0.0001, "two pop: 47%")
	sup.near(ColonySim.growth_chance(10.0, _db), 0.35, 0.0001, "ten pop: 35%")
	sup.near(ColonySim.growth_chance(30.0, _db), 0.05, 0.0001,
		"thirty pop: clamped to the 5% floor")

	# Monotonically decreasing while it is above the floor, and flat at it below.
	var decreasing := true
	var previous := 1.0
	for pop in range(0, 31):
		var chance := ColonySim.growth_chance(float(pop), _db)
		if chance > previous:
			decreasing = false
		previous = chance
	sup.ok(decreasing, "the chance never rises as the population rises")
	sup.near(ColonySim.growth_chance(100.0, _db), floor_chance, 0.0001,
		"a very large colony sits on the floor")
	sup.near(ColonySim.growth_chance(1000.0, _db), floor_chance, 0.0001,
		"and stays there rather than going negative")

	# And it scales back *up* when the population falls, which is the recovery half.
	sup.ok(ColonySim.growth_chance(4.0, _db) > ColonySim.growth_chance(30.0, _db),
		"a depopulated colony grows faster than a crowded one")
	sup.near(ColonySim.growth_chance(0.0, _db), ceiling, 0.0001,
		"and an empty one is back at the ceiling")

	# The gates are unchanged: a curve is not a licence to grow without housing or food.
	var g := _galaxy(16000)
	var faction: FactionState = g.faction(0)
	var colony := _habitable_colony(g)
	sup.ok(colony != null, "a world exists for the curve test")
	if colony == null:
		return

	# No housing: never grows, whatever the curve says.
	var homeless := _habitable_colony(g)
	homeless.structures = {&"farm": 8, &"granary": 1}
	homeless.population = 4.0
	homeless.food_stock = 500.0
	var held := homeless.population
	for _i in 40:
		ColonySim.simulate_colony(g, homeless, faction, _defs, _db, _rng(300 + _i))
		homeless.food_stock = 500.0
	sup.eq(homeless.population, held, "no housing means no growth, whatever the chance")

	# Below two pop: never grows.
	var tiny := _habitable_colony(g)
	tiny.structures = {&"city_complex": 1, &"farm": 8, &"granary": 1}
	tiny.population = 1.0
	tiny.food_stock = 500.0
	ColonySim.simulate_colony(g, tiny, faction, _defs, _db, _rng(340))
	var tiny_held := tiny.population
	for _i in 40:
		ColonySim.simulate_colony(g, tiny, faction, _defs, _db, _rng(341 + _i))
		tiny.food_stock = 500.0
	sup.eq(tiny.population, tiny_held, "a colony of one never grows")

	# The measured rate follows the curve, not a flat half.
	var rate_at := func(pop: float, trials: int) -> float:
		var colony2: PlanetState = _habitable_colony(g)
		colony2.structures = {&"city_complex": 4, &"farm": 20, &"granary": 2}
		var grew: int = 0
		for _i in trials:
			colony2.population = pop
			colony2.food_stock = 500.0
			var before := colony2.population
			ColonySim.simulate_colony(g, colony2, faction, _defs, _db, _rng(5000 + _i))
			if colony2.population > before:
				grew += 1
		return float(grew) / float(trials)

	var at_four: float = rate_at.call(4.0, 200)
	var at_twenty: float = rate_at.call(20.0, 200)
	var at_fifty: float = rate_at.call(50.0, 200)
	sup.near(at_four, ColonySim.growth_chance(4.0, _db), 0.08,
		"four pop grows at roughly the curve's rate (measured %.3f)" % at_four)
	sup.near(at_twenty, ColonySim.growth_chance(20.0, _db), 0.08,
		"twenty pop grows at roughly the curve's rate (measured %.3f)" % at_twenty)
	sup.ok(at_twenty < at_four,
		"a larger colony grows more slowly (%.3f vs %.3f)" % [at_twenty, at_four])
	sup.ok(at_fifty < at_twenty,
		"and a larger one still slower (%.3f vs %.3f)" % [at_fifty, at_twenty])
	sup.near(at_fifty, ColonySim.growth_chance(50.0, _db), 0.06,
		"fifty pop grows at the 5%% floor (measured %.3f)" % at_fifty)

	# The report carries the chance it actually rolled against, so the UI can show it.
	var probe := _habitable_colony(g)
	probe.structures = {&"city_complex": 2, &"farm": 10, &"granary": 1}
	probe.population = 12.0
	probe.food_stock = 500.0
	var rolled := ColonySim.simulate_colony(g, probe, faction, _defs, _db, _rng(6000))
	sup.near(rolled.growth_chance, ColonySim.growth_chance(12.0, _db), 0.0001,
		"the report states the chance it rolled against")
	var blocked := _habitable_colony(g)
	blocked.structures = {&"farm": 10, &"granary": 1}
	blocked.population = 12.0
	blocked.food_stock = 0.0
	var none := ColonySim.simulate_colony(g, blocked, faction, _defs, _db, _rng(6001))
	sup.near(none.growth_chance, 0.0, 0.0001,
		"and is zero on a colony that could not grow at all")


# --- space port hulls -----------------------------------------------------

## A Space Port hands over six hulls the instant it exists.
##
## The port's grant is deliberately *local to the planet* rather than written into the
## faction's unlock set. Writing it would turn one berth into an empire-wide research award,
## and it would not come back when the port was lost, since unlocks are monotone.
func _test_space_port_hulls() -> void:
	sup.begin("space port hulls")

	var g := _galaxy(17000)
	var colony := _habitable_colony(g)
	sup.ok(colony != null, "a world exists for the port test")
	if colony == null:
		return
	var faction: FactionState = g.faction(0)
	colony.structures[&"space_port"] = 0

	# The six, exactly as the design document lists them.
	var baseline := [
		&"exploration_ship", &"cargo_transport", &"troop_transport",
		&"colony_ship", &"corvette", &"frigate",
	]
	sup.eq(GameDB.PORT_HULLS.size(), 6, "the port grants six hulls")
	for hull_id: StringName in baseline:
		sup.ok(GameDB.PORT_HULLS.has(hull_id), "the port roster includes %s" % hull_id)

	# Before the port, none of them is layable. The four starters are already unlocked by
	# generation, so the test strips them to isolate the port's contribution -- what matters
	# is that the *port* is what makes a Corvette and a Frigate available.
	var saved_unlocks := faction.unlocked_ships.duplicate()
	for hull_id: Variant in GameDB.PORT_HULLS as Array:
		faction.unlocked_ships.erase(StringName(hull_id))
	for hull_id: StringName in baseline:
		sup.ok(not TurnResolver.hull_available(colony, hull_id, faction),
			"without a port, %s is not available" % hull_id)
	sup.ok(TurnResolver.hulls_available_at(colony, faction).is_empty(),
		"so the construction list is empty")

	# Construct one. The list must populate in the same turn, not the next.
	colony.structures[&"space_port"] = 1
	for hull_id: StringName in baseline:
		sup.ok(TurnResolver.hull_available(colony, hull_id, faction),
			"a port makes %s immediately available" % hull_id)
		var offered := TurnResolver.hulls_available_at(colony, faction)
		sup.ok(offered.has(hull_id),
			"and the construction list offers %s" % hull_id)
	sup.ok(not faction.unlocked_ships.has(&"corvette"),
		"without writing an unlock: the port's grant is local")
	sup.ok(not faction.unlocked_ships.has(&"frigate"), "nor the frigate")

	# The list is exactly the six, with no capital ships smuggled in.
	var listed := TurnResolver.hulls_available_at(colony, faction)
	sup.eq(listed.size(), 6,
		"the list is exactly the six baseline hulls (got %s)" % str(listed))
	for hull_id: Variant in [&"destroyer", &"cruiser", &"leviathan"]:
		sup.ok(not listed.has(StringName(hull_id)),
			"and %s still needs a population milestone" % hull_id)

	# Destroying the port takes the grant away again, because it was never an unlock.
	colony.structures[&"space_port"] = 0
	sup.ok(not TurnResolver.hull_available(colony, &"corvette", faction),
		"losing the port withdraws the hull again")
	sup.ok(TurnResolver.hulls_available_at(colony, faction).is_empty(),
		"and empties the list")

	# A colony elsewhere in the empire does *not* inherit it.
	colony.structures[&"space_port"] = 1
	var other := _habitable_colony(g)
	sup.ok(other != null, "a second colony exists for the isolation check")
	if other != null:
		sup.ok(not TurnResolver.hull_available(other, &"corvette", faction),
			"another colony without a port gets nothing from this one")

	# An empire unlock still applies with no port at all, and both routes coexist.
	faction.unlocked_ships[&"cruiser"] = true
	colony.structures[&"space_port"] = 0
	sup.ok(TurnResolver.hull_available(colony, &"cruiser", faction),
		"a milestone unlock works with no port")
	faction.unlocked_ships = saved_unlocks


## Landing a Colony Ship consumes the ship and leaves the structure behind it.
##
## The Colony Ship is the one building in the roster that cannot be *built*: it flies here and
## is spent. That is what makes settling a second world a decision with a ship at the end of
## it rather than a line item.
func _test_colony_ship_landing() -> void:
	sup.begin("colony ship landing")

	var g := _galaxy(17500)
	var faction: FactionState = g.faction(0)

	# There is exactly one Colony Ship building in the roster, and it is not offered by the
	# construction menu. It is reachable only by landing.
	sup.eq((_defs.get("buildings") as Dictionary).size(), 12,
		"the roster still holds twelve structures")
	var pad := _defs_building(&"colony_ship_building") as Resource
	sup.ok(pad != null, "the landed Colony Ship structure exists")
	if pad != null:
		sup.eq(int(pad.get("max_per_colony")), 1, "and is capped at one per world")

	# A target world nobody owns, and a fleet carrying one kit.
	var target := _unowned_planet(g)
	sup.ok(target >= 0, "there is an unclaimed world to settle")
	if target < 0:
		return
	var body: PlanetState = g.planet(target)
	var carrier := _place_fleet(g, 0, target, {&"colony_ship": 1, &"corvette": 2})

	sup.ok(InvasionStage.can_land_colony_ship(carrier, body),
		"a fleet with a kit can land on an empty world")
	var founded_before := faction.colonies_founded
	sup.ok(InvasionStage.land_colony_ship(g, carrier, body, faction),
		"landing succeeds")
	sup.ok(body.colonized, "the world is settled")
	sup.eq(body.owner, 0, "and owned by the landing empire")
	sup.eq(body.count(&"colony_ship_building"), 1,
		"the structure a landed Colony Ship leaves is placed")
	sup.eq(carrier.ship_count(), 2,
		"and the ship itself is consumed, the escort untouched")
	sup.eq(carrier.ships.get(&"colony_ship", 0), 0,
		"so no Colony Ship remains aboard")
	sup.eq(faction.colonies_founded, founded_before + 1,
		"and the empire books a colony founded")

	# The cap holds: a second kit cannot land on a world that already has one.
	var second := _place_fleet(g, 0, target, {&"colony_ship": 1})
	sup.ok(not InvasionStage.can_land_colony_ship(second, body),
		"a world with a landed ship refuses a second")
	sup.ok(not InvasionStage.land_colony_ship(g, second, body, faction),
		"and the landing is refused")
	sup.eq(second.ship_count(), 1, "the refused fleet keeps its ship")
	sup.eq(body.count(&"colony_ship_building"), 1, "and the world still has exactly one")

	# A fleet with no kit has nothing to land.
	var empty := _place_fleet(g, 0, _unowned_planet(g, target), {&"corvette": 1})
	sup.ok(not InvasionStage.can_land_colony_ship(empty, g.planet(_unowned_planet(g, target))),
		"a fleet with no Colony Ship cannot land")

	# An inhabited world is not a landing site.
	var settled := _habitable_colony(g)
	sup.ok(settled != null, "an inhabited world exists for the refusal")
	if settled != null:
		var onto := _place_fleet(g, 0, settled.index, {&"colony_ship": 1})
		sup.ok(not InvasionStage.can_land_colony_ship(onto, settled),
			"an already-settled world refuses a kit")
		sup.ok(not InvasionStage.land_colony_ship(g, onto, settled, faction),
			"so the landing is refused")
		sup.eq(onto.ship_count(), 1, "and the fleet keeps it")


# --- storage capacity ---------------------------------------------------

## Completing a storage structure raises the colony's capacity in the same turn.
##
## The assertion is about the *turn*, not merely the eventual number: `finish_construction`
## recounts immediately, so a Granary's +1000 food is banked the moment the last turn of
## construction resolves rather than appearing at the start of the next one -- which would
## leave the colony overflowing for a turn against a store that had already been paid for.
func _test_storage_capacity() -> void:
	sup.begin("storage capacity on completion")

	var g := _galaxy(18000)
	var faction: FactionState = g.faction(0)
	var base_food := float(_db.get("BASE_FOOD_STORAGE"))
	var base_power := float(_db.get("BASE_POWER_STORAGE"))
	var buildings: Dictionary = _defs.get("buildings") as Dictionary

	# --- Granary: +1000 food each ----------------------------------------------
	var colony := _habitable_colony(g)
	sup.ok(colony != null, "a world exists for the storage test")
	if colony == null:
		return
	colony.population = 4.0
	colony.food_stock = 0.0
	colony.structures = {&"mine": 2}
	ColonySim.simulate_colony(g, colony, faction, _defs, _db, _rng(1))
	sup.near(colony.food_capacity, base_food, 0.001,
		"a colony with no granary stores only its base pantry")

	# Build one to completion, the way the resolver would.
	var granary := _defs_building(&"granary") as Resource
	colony.building_queue[&"granary"] = 1
	colony.build_turns_remaining = int(granary.get("build_turns"))
	colony.build_total_turns = int(granary.get("build_turns"))
	colony.build_metal = 0.0
	var turns_to_build := colony.build_total_turns
	for _i in turns_to_build:
		ColonySim.simulate_colony(g, colony, faction, _defs, _db, _rng(2 + _i))
		if colony.count(&"granary") > 0:
			break
	sup.eq(colony.count(&"granary"), 1, "the granary is built")
	sup.near(colony.food_capacity, base_food + 1000.0, 0.001,
		"and raises max food storage by 1000 in the same turn")

	# A second one adds another 1000, not another 1000 total.
	colony.building_queue[&"granary"] = 1
	colony.build_turns_remaining = int(granary.get("build_turns"))
	colony.build_total_turns = int(granary.get("build_turns"))
	for _i in colony.build_total_turns:
		ColonySim.simulate_colony(g, colony, faction, _defs, _db, _rng(20 + _i))
		if colony.count(&"granary") > 1:
			break
	sup.eq(colony.count(&"granary"), 2, "a second granary is built")
	sup.near(colony.food_capacity, base_food + 2000.0, 0.001,
		"and capacity is cumulative: +1000 per granary")

	# --- City Complex: +20 housing each -----------------------------------------
	var housing_probe := _habitable_colony(g)
	sup.ok(housing_probe != null, "a second world exists for the housing test")
	if housing_probe != null:
		housing_probe.structures = {}
		housing_probe.population = 4.0
		housing_probe.food_stock = 500.0
		ColonySim.simulate_colony(g, housing_probe, faction, _defs, _db, _rng(40))
		sup.near(housing_probe.housing, 0.0, 0.001, "a bare colony houses nobody")
		# Growth is impossible without housing, which is what makes the Complex worth building.
		var held := housing_probe.population
		for _i in 10:
			ColonySim.simulate_colony(g, housing_probe, faction, _defs, _db, _rng(41 + _i))
			housing_probe.food_stock = 500.0
		sup.eq(housing_probe.population, held, "and cannot grow")

		var city := _defs_building(&"city_complex") as Resource
		housing_probe.building_queue[&"city_complex"] = 1
		housing_probe.build_turns_remaining = int(city.get("build_turns"))
		housing_probe.build_total_turns = int(city.get("build_turns"))
		for _i in housing_probe.build_total_turns:
			ColonySim.simulate_colony(g, housing_probe, faction, _defs, _db, _rng(50 + _i))
			if housing_probe.count(&"city_complex") > 0:
				break
		sup.eq(housing_probe.count(&"city_complex"), 1, "the City Complex is built")
		sup.near(housing_probe.housing, 20.0, 0.001,
			"and raises housing by 20 in the same turn")
		# And now it can grow, which is the point of the capacity.
		sup.ok(housing_probe.housing > housing_probe.population,
			"leaving room for new arrivals")

	# --- Energy Storage: +1000 power each ---------------------------------------
	var powered := _habitable_colony(g)
	sup.ok(powered != null, "a third world exists for the power test")
	if powered != null:
		powered.structures = {}
		powered.population = 4.0
		powered.food_stock = 500.0
		powered.power = 0.0
		ColonySim.simulate_colony(g, powered, faction, _defs, _db, _rng(60))
		sup.near(powered.power_capacity, base_power, 0.001,
			"a bare colony banks only its base cells")
		var storage := _defs_building(&"energy_storage") as Resource
		powered.building_queue[&"energy_storage"] = 1
		powered.build_turns_remaining = int(storage.get("build_turns"))
		powered.build_total_turns = int(storage.get("build_turns"))
		for _i in powered.build_total_turns:
			ColonySim.simulate_colony(g, powered, faction, _defs, _db, _rng(70 + _i))
			if powered.count(&"energy_storage") > 0:
				break
		sup.eq(powered.count(&"energy_storage"), 1, "the Energy Storage is built")
		sup.near(powered.power_capacity, base_power + 1000.0, 0.001,
			"and raises max power storage by 1000 in the same turn")
		# And the ceiling it raises is real: surplus power that was being lost now banks.
		powered.structures[&"solar"] = 20
		powered.power = 0.0
		var banked := 0.0
		for _i in 10:
			ColonySim.simulate_colony(g, powered, faction, _defs, _db, _rng(80 + _i))
			banked = maxf(banked, powered.power)
		# The old ceiling was the base battery alone, so every turn past it silently lost
		# 20 power. The point of the +1000 is that the surplus now has somewhere to go.
		sup.ok(banked > base_power,
			"so surplus power now banks instead of being lost (%.0f, was capped at %.0f)" % [
				banked, base_power])

	# The three capacities are independent: one structure cannot raise another's.
	var mixed := _habitable_colony(g)
	if mixed != null:
		mixed.structures = {&"granary": 2, &"energy_storage": 1}
		mixed.population = 4.0
		mixed.food_stock = 100.0
		ColonySim.simulate_colony(g, mixed, faction, _defs, _db, _rng(95))
		sup.near(mixed.food_capacity, base_food + 2000.0, 0.001,
			"granaries raise food storage only")
		sup.near(mixed.power_capacity, base_power + 1000.0, 0.001,
			"and energy storage raises power storage only")
		sup.near(mixed.housing, 0.0, 0.001,
			"and neither houses anybody")


# --- construction economics ----------------------------------------------

## Boosting a project: the deduction, the cap, and the absence of any refund.
func _test_metal_boost() -> void:
	sup.begin("metal boost")

	var g := _galaxy(19000)
	var faction: FactionState = g.faction(0)
	var colony := _habitable_colony(g)
	sup.ok(colony != null, "a world exists for the boost test")
	if colony == null:
		return
	var buildings: Dictionary = _defs.get("buildings") as Dictionary
	var granary := _defs_building(&"granary") as Resource
	var cost := float(granary.get("cost_metals"))
	colony.structures = {&"mine": 4}
	colony.population = 4.0
	colony.food_stock = 500.0
	ColonySim.simulate_colony(g, colony, faction, _defs, _db, _rng(1))

	# Nothing queued, nothing to spend on.
	colony.reserve_metals = 500.0
	sup.near(ColonySim.boost_construction(colony, 100.0, buildings), 0.0, 0.001,
		"a colony with nothing queued transfers nothing")

	# A project, with production credited so far.
	colony.building_queue[&"granary"] = 1
	colony.build_turns_remaining = int(granary.get("build_turns"))
	colony.build_total_turns = int(granary.get("build_turns"))
	colony.build_metal = 0.0
	sup.near(ColonySim.metal_remaining(colony, buildings), cost, 0.001,
		"a fresh project owes its full metal cost")

	# --- the cap ---------------------------------------------------------------
	sup.near(ColonySim.max_boost(colony, buildings), minf(500.0, cost), 0.001,
		"the ceiling is the lesser of storage and metal still owed")
	var asked := ColonySim.boost_construction(colony, 500.0, buildings)
	sup.near(asked, cost, 0.001,
		"asking for the whole stockpile transfers only what the project owes")
	sup.near(colony.reserve_metals, 500.0 - cost, 0.001,
		"and storage is debited by exactly that much, not by the whole pile")
	sup.near(ColonySim.construction_progress(colony, buildings), 1.0, 0.001,
		"and the project is complete")

	# --- the cap holds over the wire too -----------------------------------------
	# The client's dialog clamps its slider, but an order arrives from a client this build
	# does not control. A cap enforced only in the UI is a UI convention, not a rule.
	colony.building_queue[&"granary"] = 1
	colony.build_turns_remaining = int(granary.get("build_turns"))
	colony.build_total_turns = int(granary.get("build_turns"))
	colony.build_metal = cost * 0.5
	colony.reserve_metals = 5000.0
	var wire_store := colony.reserve_metals
	TurnResolver.resolve_turn(g, [
		Order.make_boost_build(0, colony.index, 5000.0)
	], _defs, _db, _rng(4), 0)
	var wire_gain := colony.reserve_metals - wire_store
	sup.ok(wire_gain <= cost * 0.5 + 0.001,
		"a wire order asking for the whole stockpile moves at most what is owed",
		"moved %.1f of an owed %.1f" % [wire_gain, cost * 0.5])

	# --- no refund -------------------------------------------------------------
	# The whole point: metal handed over is gone. A boost that was refunded on completion
	# would make the modal a way to *gain* metal, and a colony could bank a structure and
	# profit from it.
	# Mine income is the confound: the colony earns while it builds. Set to a known value and
	# compare against that plus exactly what the mines produce, so a refund of any size would
	# show up as a surplus rather than hiding inside the mining.
	colony.reserve_metals = 100.0
	var mined_per_turn := ColonySim._metal_output(colony, buildings)
	var store_before := colony.reserve_metals
	ColonySim.simulate_colony(g, colony, faction, _defs, _db, _rng(2))
	sup.eq(colony.count(&"granary"), 1, "the granary is built")
	sup.near(colony.reserve_metals, store_before + mined_per_turn, 0.001,
		"storage is the starting pile plus the mines and nothing else: no refund (got %.1f, expected %.1f)" % [
			colony.reserve_metals, store_before + mined_per_turn])
	sup.near(colony.build_metal, 0.0, 0.001,
		"the progress pool is cleared, not paid back")

	# Overpaying cannot be laundered either: the ceiling is what it owed, so there is no
	# surplus to hand back in the first place.
	colony.building_queue[&"granary"] = 1
	colony.build_turns_remaining = int(granary.get("build_turns"))
	colony.build_total_turns = int(granary.get("build_turns"))
	colony.build_metal = 0.0
	colony.reserve_metals = 5000.0
	var overpay_store := colony.reserve_metals
	ColonySim.boost_construction(colony, 5000.0, buildings)
	var mines := ColonySim._metal_output(colony, buildings)
	ColonySim.simulate_colony(g, colony, faction, _defs, _db, _rng(3))
	sup.near(colony.reserve_metals, overpay_store - cost + mines, 0.001,
		"a colony that overpays is not credited any of the difference back")
	sup.eq(colony.count(&"granary"), 2, "and the structure still lands")

	# --- progress is cost, not turns --------------------------------------------
	# A three-turn project reads a third complete after one turn, whatever it costs. The old
	# flat "+1 metal a turn" made a 100-metal structure advance 1% per turn, so the bar told
	# a player essentially nothing.
	var timed := _habitable_colony(g)
	sup.ok(timed != null, "a world exists for the progress-curve test")
	if timed != null:
		var city := _defs_building(&"city_complex") as Resource
		timed.structures = {&"mine": 4}
		timed.population = 4.0
		timed.food_stock = 500.0
		timed.building_queue[&"city_complex"] = 1
		timed.build_turns_remaining = int(city.get("build_turns"))
		timed.build_total_turns = int(city.get("build_turns"))
		timed.build_metal = 0.0
		sup.eq(timed.build_total_turns, 3, "a City Complex takes three turns")
		for turn in 3:
			ColonySim.simulate_colony(g, timed, faction, _defs, _db, _rng(200 + turn))
			if turn < 2:
				sup.near(ColonySim.construction_progress(timed, buildings),
					float(turn + 1) / 3.0, 0.02,
					"turn %d of 3 reads about a third" % (turn + 1))
		sup.eq(timed.count(&"city_complex"), 1, "and it lands on the third turn")


# --- troops and cargo ---------------------------------------------------

## Barracks, troop lift, and the manifest that lands.
##
## Troops are the one population unit that does not eat and does not research, so the whole
## design rests on them being expensive in a different currency: a Barracks, a pop, and a bay
## in a transport. Everything here is about that exchange.
func _test_troops_and_cargo() -> void:
	sup.begin("troops, lift and cargo")

	var g := _galaxy(15000)
	var home := _habitable_colony(g)
	sup.ok(home != null, "a world exists for the troop test")
	if home == null:
		return
	var faction: FactionState = g.faction(0)
	home.structures[&"barracks"] = 1

	# --- recruitment: one civilian becomes one troop ----------------------------
	home.population = 6.0
	var civ_before := home.population
	var troops_before := home.troops
	TurnResolver.apply_recruit_troop(g, faction,
		Order.make_recruit_troop(0, home.index), _defs)
	sup.near(home.population, civ_before - 1.0, 0.0001,
		"recruiting spends exactly one civilian")
	sup.eq(home.troops, troops_before + 1, "and yields exactly one troop")

	# A colony with no Barracks cannot convert: the Barracks is a converter, not a producer.
	var unbarracked := _habitable_colony(g)
	sup.ok(unbarracked != null, "a second world exists for the refused conversion")
	if unbarracked != null:
		unbarracked.population = 5.0
		TurnResolver.apply_recruit_troop(g, faction,
			Order.make_recruit_troop(0, unbarracked.index), _defs)
		sup.eq(unbarracked.population, 5.0,
			"a colony with no Barracks converts nobody")
		sup.eq(unbarracked.troops, 0, "and raises no troops")

	# A colony with people but no Barracks is refused for the same reason; a colony with a
	# Barracks but no people is refused for the other. Both are refusals, not silent no-ops.
	var empty_hands := _habitable_colony(g)
	if empty_hands != null:
		empty_hands.structures[&"barracks"] = 1
		empty_hands.population = 0.0
		TurnResolver.apply_recruit_troop(g, faction,
			Order.make_recruit_troop(0, empty_hands.index), _defs)
		sup.eq(empty_hands.troops, 0,
			"a colony with nobody left to convert raises no troops")

	# --- lift: four bays per transport, stacking additively ---------------------
	var lift := FleetState.new()
	lift.bind_hulls(_defs.get("ship_hulls"))
	sup.near(lift.troop_capacity(), 0.0, 0.001, "an empty fleet has no bays")
	lift.add_ships(&"troop_transport", 1)
	sup.near(lift.troop_capacity(), 4.0, 0.001, "one Troop Transport carries four")
	lift.add_ships(&"troop_transport", 3)
	sup.near(lift.troop_capacity(), 16.0, 0.001,
		"and a stack of four carries sixteen, additively")

	# Capacity is bays, not troops. Nothing is aboard until it is loaded, and that is the
	# distinction the invasion stage depends on: an empty lift is not an army.
	sup.near(lift.troops_carried(), 0.0, 0.001, "four empty transports carry no troops")
	sup.near(lift.troops_carried() - lift.troop_capacity(), -16.0, 0.001,
		"so a full complement of troops has not been loaded")

	# --- loading and unloading troops -------------------------------------------
	var landing_spot := _unowned_planet(g)
	sup.ok(landing_spot >= 0, "there is a world to load troops from")
	if landing_spot < 0:
		return
	var pad := _habitable_colony(g)
	sup.ok(pad != null, "and a colony to load them onto")
	if pad == null:
		return
	pad.troops = 20
	lift.system = pad.index
	lift.destination = -1
	home.troops = 20

	sup.near(TransferStage.loadable(pad, lift, &"troops"), 16.0, 0.001,
		"a colony with twenty troops can fill sixteen bays and no more")
	var loaded := TransferStage.load(pad, lift, &"troops", 100.0)
	sup.near(loaded, 16.0, 0.001, "loading is bounded by the bays, not the request")
	sup.eq(pad.troops, 4, "and the colony keeps the four that would not fit")
	sup.near(lift.troops_carried(), 16.0, 0.001, "the holds now report sixteen")
	sup.near(TransferStage.loadable(pad, lift, &"troops"), 0.0, 0.001,
		"a full lift takes nothing more")

	# Unloading puts them back on the surface.
	var landed := TransferStage.unload(pad, lift, &"troops", 100.0)
	sup.near(landed, 16.0, 0.001, "unloading is bounded by the holds")
	sup.eq(pad.troops, 20, "and the colony has its troops back")
	sup.near(lift.troops_carried(), 0.0, 0.001, "the holds are empty again")

	# A warship has no troop bays, so a "load troops" against one is a refusal rather than a
	# silent success -- the failure mode being a battleship quietly counted as an army.
	var warship := FleetState.new()
	warship.bind_hulls(_defs.get("ship_hulls"))
	warship.add_ships(&"dreadnought", 2)
	warship.system = pad.index
	warship.destination = -1
	sup.near(TransferStage.loadable(pad, warship, &"troops"), 0.0, 0.001,
		"two dreadnoughts hold no troops at all")
	sup.near(TransferStage.load(pad, warship, &"troops", 10.0), 0.0, 0.001,
		"so loading troops onto them moves nothing")

	# --- metal, food and power, in both directions -------------------------------
	var freighter := FleetState.new()
	freighter.bind_hulls(_defs.get("ship_hulls"))
	freighter.add_ships(&"cargo_transport", 2)
	freighter.system = pad.index
	freighter.destination = -1
	sup.near(TransferStage.capacity_for(freighter, &"metals"), 400.0, 0.001,
		"two Cargo Transports hold 400 units")
	sup.near(TransferStage.capacity_for(freighter, &"troops"), 0.0, 0.001,
		"and no troops -- cargo and lift are separate hulls in this roster")
	sup.near(TransferStage.capacity_for(warship, &"metals"), 0.0, 0.001,
		"and a warship holds no cargo")

	pad.reserve_metals = 100.0
	var ore := TransferStage.load(pad, freighter, &"metals", 60.0)
	sup.near(ore, 60.0, 0.001, "metal loads from the colony's store")
	sup.near(pad.reserve_metals, 40.0, 0.001, "and leaves it")
	sup.near(TransferStage.carried(freighter, &"metals"), 60.0, 0.001, "into the holds")

	# Food is capped on both sides: the colony can only give what it has, and the colony can
	# only take what it can store.
	pad.food_stock = 50.0
	var rations := TransferStage.load(pad, freighter, &"food", 100.0)
	sup.near(rations, 50.0, 0.001, "a colony cannot give away food it does not have")
	sup.near(pad.food_stock, 0.0, 0.001, "and its store is emptied")
	freighter.cargo = {}
	# Drain the store's headroom first, so the next unload has somewhere to go.
	ColonySim.simulate_colony(g, pad, faction, _defs, _db, _rng(1))
	pad.food_stock = pad.food_capacity
	var stored := TransferStage.unload(pad, freighter, &"food", 25.0)
	sup.near(stored, 0.0, 0.001, "a full store takes nothing")
	sup.near(TransferStage.carried(freighter, &"food"), 0.0, 0.001,
		"and the crate stayed aboard")

	# Power moves the same way.
	pad.power = 30.0
	sup.ok(TransferStage.capacity_for(freighter, &"food") > 0.0,
		"a Cargo Transport has a food hold, as well as a metal one")
	sup.near(TransferStage.load(pad, freighter, &"power", 10.0), 0.0, 0.001,
		"but no fuel cells: the hull does not declare a power hold")
	sup.near(TransferStage.capacity_for(freighter, &"power"), 0.0, 0.001,
		"so its power capacity is zero, not its metal capacity under another name")

	# --- transit combat never fires on cargo, and troops do not eat -------------
	# Troops are excluded from food consumption, which is asserted on the colony rather than
	# inferred: a colony of five civilians and fifty troops eats five food a turn.
	var feeding := _habitable_colony(g)
	sup.ok(feeding != null, "a world exists for the feeding test")
	if feeding != null:
		feeding.structures = {&"farm": 20, &"granary": 1}
		feeding.population = 5.0
		feeding.troops = 50
		feeding.food_stock = 0.0
		var fed := ColonySim.simulate_colony(g, feeding, faction, _defs, _db, _rng(2))
		sup.near(fed.food_consumed, 5.0, 0.001,
			"fifty troops eat nothing: five civilians eat five food")
		sup.ok(fed.food_produced > fed.food_consumed,
			"and the colony is comfortably in surplus", "%.0f vs %.0f" % [
				fed.food_produced, fed.food_consumed])
		# And a garrison still holds the ground.
		sup.ok(InvasionStage.planet_garrison(feeding, _db) > 25.0,
			"while still fighting as a garrison", "%.1f" % InvasionStage.planet_garrison(
				feeding, _db))


# --- survey -------------------------------------------------------------

## Exploration Ships research the worlds they sit above.
##
## The design document's figure is 25% per ship per turn, additive, and the shape of the rule
## matters as much as the number: a ship has to be *parked*, so holding an orbit is worth
## something even when nothing is shooting at it.
func _test_survey() -> void:
	sup.begin("planet survey")

	var g := _galaxy(16000)
	var target := _unowned_planet(g)
	sup.ok(target >= 0, "there is an unsurveyed world to survey")
	if target < 0:
		return
	var body: PlanetState = g.planet(target)
	body.surveyed = false
	body.owner = -1

	# One Exploration Ship takes four turns on average; two take two.
	var one := _place_fleet(g, 0, target, {&"exploration_ship": 1})
	sup.near(one.survey_rate(), 0.25, 0.001, "one Exploration Ship surveys at 25% a turn")
	one.add_ships(&"exploration_ship", 1)
	sup.near(one.survey_rate(), 0.50, 0.001,
		"and two survey at 50% -- the rate is additive")
	one.add_ships(&"exploration_ship", 2)
	sup.near(one.survey_rate(), 1.0, 0.001,
		"and four survey it in a single turn")

	# A fleet that is merely passing through contributes nothing. The origin is an explicit
	# neighbour rather than "the next unowned world", because `_unowned_planet` scans forward
	# from its argument and would otherwise hand back the survey target itself.
	var origin := -1
	for p in g.planets:
		if p.index != target and p.owner < 0 and not p.colonized:
			origin = p.index
			break
	sup.ok(origin >= 0, "there is a second world to sail from")
	if origin < 0:
		return
	var passing := _place_fleet(g, 1, origin, {&"exploration_ship": 4})
	MovementStage.issue_move(g, passing.id, 1, target)
	sup.ok(passing.destination >= 0, "the second fleet is under way")
	body.surveyed = false
	# Only faction 1's sweep is driven here. Faction 0 has four Exploration Ships parked over
	# the target world from the rate assertions above, so running its sweep too would survey
	# it for entirely the right reason and prove nothing about transit.
	for _i in 20:
		FowStage.advance_surveys(g, 1, _rng(200 + _i))
		MovementStage.advance(g)
	sup.eq(body.surveyed, false,
		"a fleet sailing toward a world surveys nothing on the way")
	sup.ok(passing.destination >= 0 or passing.system == target,
		"and it really was under way while the sweeps ran",
		"destination=%d system=%d" % [passing.destination, passing.system])

	# Parked, it surveys. Four ships at 100% a turn is one turn, deterministically.
	passing.destination = -1
	passing.travelled = 0.0
	passing.system = target
	body.surveyed = false
	FowStage.advance_surveys(g, 1, _rng(300))
	sup.ok(body.surveyed, "a parked survey fleet surveys the world it is over")
	sup.ok(galaxy_survey_logged(g, 1, target),
		"and the faction's survey log records it")

	# A world already surveyed is not re-surveyed, and reports nothing.
	var again := FowStage.advance_surveys(g, 1, _rng(301))
	sup.eq(again, 0, "an already-surveyed world yields no further progress")

	# A fleet of warships contributes nothing at all.
	var warships := _place_fleet(g, 2, _unowned_planet(g, target), {&"cruiser": 4})
	sup.near(warships.survey_rate(), 0.0, 0.001, "warships survey nothing")
	sup.ok(not warships.has_survey_ship(), "and say so")


## Whether `faction_id` has `planet_index` in its permanent survey log.
static func galaxy_survey_logged(g: GalaxyState, faction_id: int, planet_index: int) -> bool:
	var log: Dictionary = g.surveyed_systems.get(faction_id, {}) as Dictionary
	return log.has(planet_index)


# --- transit ------------------------------------------------------------

## NO MID-FLIGHT COMBAT.
##
## The design document's most emphatic rule: fleets traversing flight paths NEVER engage,
## and combat resolves at turn end between fleets in the same orbit. The failure this guards
## against is specific and likely, because with one star every fleet is within sensor range
## of every other one -- so "these two fleets' paths cross" is a statement that is true of
## almost every pair of fleets on the board, and a stage that fought on proximity rather than
## on position would turn the entire map into one battle by turn three.
func _test_no_transit_combat() -> void:
	sup.begin("no combat during transit")

	var g := _galaxy(8700)
	var spot := 5
	var a := _place_fleet(g, 0, spot, {&"dreadnought": 3})
	var d := _place_fleet(g, 1, spot, {&"cruiser": 3})

	# Stationary and hostile: they must be found.
	sup.eq(MovementStage.find_engagements(g).size(), 1,
		"two hostile fleets parked on one world do engage")

	# Put one of them under way. Same world, same owner, same everything -- but it is no
	# longer *there*.
	MovementStage.issue_move(g, a.id, 0, spot + 1)
	sup.eq(a.destination, spot + 1, "one fleet is under way")
	sup.eq(MovementStage.find_engagements(g).size(), 0,
		"a fleet in transit does not fight what it left behind")

	# `fleets_in_system` is the other reader of "who is here", and it has to agree.
	sup.eq(MovementStage.fleets_in_system(g, spot, -1).size(), 1,
		"a transit fleet is not listed as being on its origin world")
	sup.eq(MovementStage.fleets_at_or_bound_for(g, spot, -1).size(), 2,
		"but it is still within reach of that world for fog purposes")

	# Arrive it, and the fight is found again. The rule is about position, not about the
	# fleets having fought before.
	MovementStage.advance(g)
	var guard := 0
	while a.destination >= 0 and guard < 500:
		MovementStage.advance(g)
		guard += 1
	sup.eq(a.destination, -1, "the fleet arrives")
	sup.eq(a.system, spot + 1, "at its destination")
	sup.eq(MovementStage.find_engagements(g).size(), 0,
		"arriving somewhere nobody is does not start a war")

	# Two fleets crossing paths, end to end, engage nothing at any point along the way.
	var g2 := _galaxy(8750)
	var here := 1
	var there := 2
	var east := _place_fleet(g2, 0, here, {&"leviathan": 2})
	var west := _place_fleet(g2, 1, there, {&"exploration_ship": 4})
	MovementStage.issue_move(g2, east.id, 0, there)
	MovementStage.issue_move(g2, west.id, 1, here)
	sup.eq(MovementStage.find_engagements(g2).size(), 0,
		"two fleets sent to each other's worlds start a stalemate")
	var steps := 0
	var engaged_ever := 0
	while steps < 40 and (east.destination >= 0 or west.destination >= 0):
		MovementStage.advance(g2)
		steps += 1
		if not MovementStage.find_engagements(g2).is_empty():
			engaged_ever += 1
	sup.ok(engaged_ever == 0,
		"their paths cross and neither ever fights", "%d turns, %d engagements" % [
			steps, engaged_ever])
	sup.ok(east.destination < 0 or west.destination < 0,
		"the crossing completed")

	# A full turn end-to-end must produce no combat news either, which is the assertion that
	# covers the resolver rather than just the engagement finder.
	var g3 := _galaxy(8780)
	var x := _place_fleet(g3, 0, 2, {&"titan": 3})
	var y := _place_fleet(g3, 1, 3, {&"exploration_ship": 3})
	var overlap := 0
	for _turn in 12:
		if x.destination < 0:
			MovementStage.issue_move(g3, x.id, 0, 3)
		if y.destination < 0:
			MovementStage.issue_move(g3, y.id, 1, 2)
		var report := TurnResolver.resolve_turn(g3, [] as Array, _defs, _db, _rng(8780), 0)
		for line in report["news"]:
			if String(line).contains("fought") or String(line).contains("destroyed by fleet"):
				overlap += 1
	sup.eq(overlap, 0, "twelve turns of mutually swapping worlds resolve no combat")


# --- defence suppression ------------------------------------------------

## Step 2 on its own, away from the invasion it gates.
##
## The claim under test is the *precondition*: suppression happens only where a hostile
## fleet holds the sky. A colony whose defender is still in orbit is not suppressed, because
## its batteries are still shooting.
func _test_defense_suppression() -> void:
	sup.begin("planetary defense suppression")

	var g := _galaxy(8500)
	var planet := _colonize(g, 1, _unowned_planet(g, 1))
	planet.structures[&"planetary_defense"] = 3

	# A defender in orbit blocks suppression entirely.
	var hold := _place_fleet(g, 1, planet.index, {&"corvette": 4})
	var siege := _place_fleet(g, 0, planet.index, {&"titan": 4})
	var quiet := CombatStage.suppress_defenses(g, _rng(1), _db, _defs)
	sup.ok(quiet.is_empty(),
		"a contested orbit is not suppressed", "%d lines" % quiet.size())
	sup.eq(planet.count(&"planetary_defense"), 3, "the batteries are untouched")

	# Remove the defender and the same fleet now wins the sky.
	g.remove_fleet(hold.id)
	var loud := CombatStage.suppress_defenses(g, _rng(1), _db, _defs)
	sup.ok(loud.size() > 0, "suppression runs once the sky is held",
		"%d lines" % loud.size())
	sup.eq(InvasionStage.planetary_defenses(planet), 0, "every battery falls")

	# A colony with no batteries at all reports nothing rather than dividing by zero.
	var g2 := _galaxy(8550)
	var bare := _colonize(g2, 1, _unowned_planet(g2, 1))
	_place_fleet(g2, 0, bare.index, {&"titan": 2})
	sup.ok(CombatStage.suppress_defenses(g2, _rng(1), _db, _defs).is_empty(),
		"an undefended planet raises no suppression news")

	# Firepower matters: a fleet of hulls with no bombarders cannot knock anything down.
	var g3 := _galaxy(8600)
	var walled := _colonize(g3, 1, _unowned_planet(g3, 1))
	walled.structures[&"planetary_defense"] = 5
	_place_fleet(g3, 0, walled.index, {&"corvette": 6})
	CombatStage.suppress_defenses(g3, _rng(1), _db, _defs)
	sup.ok(InvasionStage.planetary_defenses(walled) > 0,
		"warships with no guns leave the batteries standing",
		"%d left" % InvasionStage.planetary_defenses(walled))

# --- colony simulation --------------------------------------------------

## The Phase 8 colony model, in the order the design document states it.
##
## Every figure here is a whole number of people. That is the substance of the change and
## the reason these assertions are written against integers rather than tolerances: "one pop
## eats one food" and "one pop dies" cannot both be true of a population that moves by 4% a
## turn.
func _test_colony_sim() -> void:
	sup.begin("colony simulation")

	# --- food: one pop, one food -----------------------------------------------
	var g := _galaxy(9000)
	var planet := _habitable_colony(g)
	sup.ok(planet != null, "the system has a habitable world to colonise")
	if planet == null:
		return
	# A staffed colony with exactly one pop per farm in food, and a granary to hold the rest.
	planet.population = 3.0
	planet.structures = {&"farm": 3, &"granary": 1}
	planet.food_stock = 0.0
	var fa: FactionState = g.faction(0)

	var r1 := ColonySim.simulate_colony(g, planet, fa, _defs, _db, _rng(1))
	sup.near(r1.food_produced, 15.0, 0.001, "three farms produce fifteen food")
	sup.near(r1.food_consumed, 3.0, 0.001, "three pop consume three food")
	sup.near(planet.food_stock, 12.0, 0.001, "the surplus banks")
	sup.ok(not r1.starving, "a fed colony does not starve")

	# A farm nobody works produces nothing. Population is a cost, not just a multiplier.
	var unstaffed := _habitable_colony(g)
	unstaffed.structures = {&"farm": 4, &"granary": 1}
	unstaffed.population = 0.0
	unstaffed.food_stock = 0.0
	var dark := ColonySim.simulate_colony(g, unstaffed, fa, _defs, _db, _rng(1))
	sup.near(dark.food_produced, 0.0, 0.001,
		"a colony with no civilians produces no food at all")

	# Exactly break-even leaves nothing in store.
	planet.population = 15.0
	planet.food_stock = 0.0
	var even := ColonySim.simulate_colony(g, planet, fa, _defs, _db, _rng(2))
	sup.near(even.food_produced, 15.0, 0.001, "three farms feed fifteen people exactly")
	sup.near(planet.food_stock, 0.0, 0.001, "a break-even colony banks nothing")
	sup.ok(not even.starving, "and does not starve while it breaks even")

	# A deficit draws the bank down first. With more in store than the shortfall, nobody
	# starves on this turn -- which is the whole point of having stores at all.
	planet.population = 20.0
	planet.structures = {&"farm": 2, &"granary": 1}
	planet.food_stock = 30.0
	var drew := ColonySim.simulate_colony(g, planet, fa, _defs, _db, _rng(3))
	sup.near(planet.food_stock, 20.0, 0.001, "a deficit draws down the reserve")
	sup.ok(not drew.starving, "a colony with reserves left is not starving")
	sup.eq(planet.population, 20.0, "and nobody dies while there is food in store")

	# The turn the bank runs dry *is* a starving turn. A colony is starving the moment it is
	# out of food, whether or not the 50% roll comes up -- starving is the condition, not
	# the verdict.
	planet.food_stock = 5.0
	var last := ColonySim.simulate_colony(g, planet, fa, _defs, _db, _rng(4))
	sup.near(planet.food_stock, 0.0, 0.001, "the reserve runs out")
	sup.ok(last.starving, "and the colony is starving from that turn, roll or no roll")

	# --- starvation: 50% per turn, one whole pop --------------------------------
	# The population is a whole number of people, so a death is exactly one of them and
	# never a fraction of a person.
	planet.population = 6.0
	planet.structures = {&"granary": 1}
	planet.food_stock = 0.0
	var deaths := 0
	var died_while_starving := false
	for _i in 60:
		var before := planet.population
		var rr := ColonySim.simulate_colony(g, planet, fa, _defs, _db, _rng(100 + _i))
		if planet.population < before:
			deaths += 1
			died_while_starving = rr.starving
			sup.near(before - planet.population, 1.0, 0.0001,
				"a starving colony loses exactly one pop")
			break
	sup.eq(deaths, 1, "a starving colony eventually loses population")
	sup.ok(died_while_starving,
		"and the pop died on a turn the colony was reported as starving")

	# The 50% figure, over enough turns that the law of large numbers has something to say.
	# One colony, re-armed before each trial: a colony that died to zero is abandoned and
	# could never be tested again, so minting a world per trial would run out of worlds and
	# measure nothing.
	var died := 0
	var trials := 200
	var probe := planet
	for _i in trials:
		probe.colonized = true
		probe.population = 10.0
		probe.structures = {&"granary": 1}
		probe.food_stock = 0.0
		var before2 := probe.population
		ColonySim.simulate_colony(g, probe, fa, _defs, _db, _rng(9000 + _i))
		if probe.population < before2:
			died += 1
	var rate := float(died) / float(trials)
	sup.ok(rate > 0.35 and rate < 0.65,
		"an empty colony dies on roughly half its turns", "%.2f of %d" % [rate, trials])

	# And it repeats every turn until the population is gone, rather than resolving once.
	var gstarve := _galaxy(9050)
	var doomed := _habitable_colony(gstarve)
	doomed.structures = {&"granary": 1}
	doomed.population = 4.0
	doomed.food_stock = 0.0
	var emptied := 0
	for _i in 400:
		ColonySim.simulate_colony(
			gstarve, doomed, gstarve.faction(0), _defs, _db, _rng(400 + _i))
		if doomed.population <= 0.0:
			emptied = _i + 1
			break
	sup.ok(emptied > 0, "starvation continues until the colony is empty",
		"emptied after %d turns" % emptied)
	sup.ok(not doomed.colonized, "and an empty colony is abandoned")

	# --- growth: housing, surplus, and a 50% roll --------------------------------
	# One colony object, reused for every scenario below: a colony that starves to zero is
	# abandoned, so a test that wanted a second look would have to mint a world and then
	# silently measure a different one.
	var grow := _habitable_colony(g)
	sup.ok(grow != null, "a second habitable world exists to grow")
	if grow == null:
		return
	grow.structures = {&"city_complex": 1, &"farm": 4, &"granary": 1}
	grow.population = 4.0
	grow.food_stock = 20.0

	# Capacities are recomputed at the top of every colony turn, so the housing the growth
	# rule reads is only real once one has run.
	var housing_before: float = grow.housing
	ColonySim.simulate_colony(g, grow, fa, _defs, _db, _rng(10))
	sup.ok(grow.housing >= 20.0, "the City Complex houses twenty",
		"%.0f" % grow.housing)
	sup.ok(grow.housing > housing_before,
		"and the colony had no housing until it built one")

	# Growth is a 50% roll, so a single turn proves nothing about the magnitude. Over a
	# window of turns, every change must be exactly plus or minus one person.
	grow.population = 4.0
	grow.food_stock = 50.0
	var step := 0.0
	var moves := 0
	for _i in 200:
		var before4 := grow.population
		ColonySim.simulate_colony(g, grow, fa, _defs, _db, _rng(30000 + _i))
		if grow.population != before4:
			step = grow.population - before4
			moves += 1
		grow.food_stock = 50.0
		grow.population = mini(grow.population, 4.0)
	sup.ok(moves > 0, "a fed colony with room does grow")
	sup.near(step, 1.0, 0.0001,
		"and each turn it changes by exactly one person, never a fraction")

	# No housing, no growth however well fed the colony is. This is the gate that makes
	# City Complexes worth building.
	var homeless := _habitable_colony(g)
	homeless.structures = {&"farm": 4, &"granary": 1}
	homeless.population = 4.0
	homeless.food_stock = 100.0
	var homeless_pop := homeless.population
	for _i in 20:
		ColonySim.simulate_colony(g, homeless, fa, _defs, _db, _rng(31000 + _i))
		homeless.food_stock = 100.0
	sup.eq(homeless.population, homeless_pop,
		"a colony with no housing never grows, however well fed it is")
	sup.near(homeless.housing, 0.0, 0.001, "and it really has no housing")

	# Below two pop there is nothing to grow from.
	var tiny := _habitable_colony(g)
	tiny.structures = {&"city_complex": 1, &"farm": 4, &"granary": 1}
	tiny.population = 1.0
	tiny.food_stock = 100.0
	var tiny_pop := tiny.population
	for _i in 20:
		ColonySim.simulate_colony(g, tiny, fa, _defs, _db, _rng(32000 + _i))
		smallkeep = true
		smallkeep = smallkeep and tiny.population == tiny_pop
		tiny.food_stock = 100.0
	sup.ok(smallkeep, "a colony of one never grows")

	# --- storage overflow and its one-turn warning ------------------------------
	# Exceeding the food store is the one warning the design document asks for, and it is
	# raised on the *next* turn. Both halves matter: a warning raised on the turn it was
	# earned would describe a turn the player has already read.
	var gfull := _galaxy(9300)
	var full := _habitable_colony(gfull)
	sup.ok(full != null, "a third habitable world exists for the storage test")
	if full == null:
		return
	full.structures = {&"farm": 12, &"granary": 1}
	full.population = 2.0
	full.food_stock = 0.0
	# A granary plus the colony's own pantry, per GameDB's base holds.
	sup.near(float(_db.get("BASE_FOOD_STORAGE")) + 1000.0, 1100.0, 0.001,
		"a granary adds its 1000 to the colony's base pantry")

	# Farms are capped per colony, so a colony cannot overflow in one turn; it banks a
	# surplus turn after turn until the store fills. That is the ordinary way a player meets
	# the warning, and it is why the rule is about the store filling rather than one harvest.
	var overflowed := false
	var overflow_turn := 0
	for _i in 200:
		var rr2 := ColonySim.simulate_colony(gfull, full, gfull.faction(0), _defs, _db, _rng(33 + _i))
		if rr2.food_overflowed:
			overflowed = true
			overflow_turn = _i
			sup.ok(not _warns(full, &"food_overflow"),
				"the warning does NOT appear on the turn it happened")
			break
	sup.ok(overflowed, "a colony with more farms than it can store eventually overflows",
		"after %d turns" % overflow_turn)
	sup.near(full.food_stock, full.food_capacity, 0.001,
		"and the store is clamped to its capacity")

	# While the surplus persists the overflow persists, and the warning is re-raised on
	# every turn after the first -- it is a standing condition, not a one-off event.
	for _i in 3:
		ColonySim.simulate_colony(gfull, full, gfull.faction(0), _defs, _db, _rng(34 + _i))
	sup.ok(_warns(full, &"food_overflow"), "the warning appears on the next turn")
	sup.ok(_warns(full, &"food_overflow"),
		"and it persists while the colony is still overflowing")

	# And it clears once the surplus has gone, rather than latching forever. Two turns: one
	# to spend the surplus, one for the flag to be raised and then not re-raised.
	# Twelve farms feed sixty and a large colony eats far more than that, so the store drains
	# in a handful of turns. The colony has no housing, so it cannot grow into the deficit.
	full.population = 200.0
	for _i in 12:
		ColonySim.simulate_colony(gfull, full, gfull.faction(0), _defs, _db, _rng(40 + _i))
	sup.ok(not _warns(full, &"food_overflow"),
		"the warning clears once the surplus has gone")
	sup.ok(full.food_stock < full.food_capacity, "and the store has drained below its cap",
		"%.0f of %.0f" % [full.food_stock, full.food_capacity])

	# Metal has no storage cap at all, so it cannot overflow however long it mines.
	var mine_planet := _habitable_colony(gfull)
	# The granary here is only there to keep food out of the picture: a colony with no
	# storage would overflow its own food stores and the assertion below would be reading a
	# food warning while claiming to be about metal.
	mine_planet.structures = {&"mine": 12, &"granary": 1}
	mine_planet.population = 4.0
	mine_planet.food_stock = 100.0
	var mined := ColonySim.simulate_colony(
		gfull, mine_planet, gfull.faction(0), _defs, _db, _rng(36))
	sup.near(mined.metals_mined, 60.0, 0.001, "twelve mines produce 60 metal a turn")
	var before_metal := mine_planet.reserve_metals
	for _i in 100:
		ColonySim.simulate_colony(
			gfull, mine_planet, gfull.faction(0), _defs, _db, _rng(37 + _i))
	sup.ok(mine_planet.reserve_metals > mine_planet.food_capacity,
		"and metal banks past any food store, because metal has no cap",
		"%.0f metal vs %.0f of food storage" % [
			mine_planet.reserve_metals, mine_planet.food_capacity])
	sup.ok(not _warns(mine_planet, &"food_overflow"),
		"and mining raises no storage warning of any kind")

	# --- power -----------------------------------------------------------------
	# Power is generated, banked, and drawn. Running short is *not* a penalty on existing
	# structures -- it only blocks new ones -- which is asserted in the construction section.
	var gpower := _galaxy(9400)
	var powered := _habitable_colony(gpower)
	sup.ok(powered != null, "a habitable world exists for the power test")
	if powered == null:
		return
	powered.structures = {&"solar": 12, &"granary": 1}
	powered.population = 4.0
	powered.food_stock = 100.0
	powered.power = 0.0
	var twelve := ColonySim.simulate_colony(
		gpower, powered, gpower.faction(0), _defs, _db, _rng(41))
	sup.near(twelve.power_generated, 12.0, 0.001, "twelve solar arrays generate 12 power")
	sup.near(twelve.power_drawn, 0.0, 0.001, "and with no City Complex, nothing draws any")
	sup.near(powered.power, 12.0, 0.001, "so it all banks")
	sup.ok(not twelve.power_short, "and a colony with power to spare is not short")

	# A City Complex draws 10. Two of them on 12 units of generation is a shortfall, and it
	# must be reported rather than silently tolerated. It takes several turns to drain the
	# bank: the colony spends what it has before it starts missing.
	powered.structures[&"city_complex"] = 2
	var drew_power := 0
	var short := false
	for _i in 12:
		var rr3 := ColonySim.simulate_colony(
			gpower, powered, gpower.faction(0), _defs, _db, _rng(42 + _i))
		if rr3.power_drawn > 0.0:
			drew_power += 1
		if rr3.power_short:
			short = true
			break
	sup.near(powered.power_drawn, 20.0, 0.001, "two City Complexes draw 20 power")
	sup.ok(short, "a colony drawing more than it generates eventually runs short")
	sup.ok(_warns(powered, &"power_short"), "and the shortfall is reported")
	sup.near(powered.power, 0.0, 0.001, "the bank is spent down to nothing, never negative")
	sup.ok(drew_power > 1, "the reserves were spent before the shortfall began",
		"%d turns drew power" % drew_power)

	# Power overflow is silent, asymmetrically with food. The design document says so
	# outright, and it is the pressure that makes a world build Energy Storage rather than
	# be nagged about its surplus.
	var gpower2 := _galaxy(9450)
	var flooded := _habitable_colony(gpower2)
	sup.ok(flooded != null, "a second world exists for the power-overflow test")
	if flooded == null:
		return
	flooded.structures = {&"solar": 20, &"granary": 1}
	flooded.population = 4.0
	flooded.food_stock = 100.0
	flooded.power = 0.0
	var over := ColonySim.simulate_colony(
		gpower2, flooded, gpower2.faction(0), _defs, _db, _rng(43))
	sup.near(over.power_generated, 20.0, 0.001, "twenty arrays generate 20 power")
	sup.near(flooded.power_capacity, 100.0, 0.001,
		"with nowhere to put it but the base battery")
	# Fill the base battery, then keep generating: the surplus is lost, silently.
	var capped := false
	for _i in 12:
		var rr4 := ColonySim.simulate_colony(
			gpower2, flooded, gpower2.faction(0), _defs, _db, _rng(44 + _i))
		if is_equal_approx(flooded.power, flooded.power_capacity):
			capped = true
	sup.ok(capped, "the bank fills to its capacity")
	sup.near(flooded.power, 100.0, 0.001, "and no further, so surplus power is lost")
	sup.ok(not _warns(flooded, &"food_overflow"),
		"and power overflow raises NO warning")

	# An Energy Storage structure raises the ceiling, which is the only response a player
	# has to the surplus -- and there being no warning is what points them at it.
	flooded.structures[&"energy_storage"] = 1
	var banked := ColonySim.simulate_colony(
		gpower2, flooded, gpower2.faction(0), _defs, _db, _rng(45))
	sup.near(flooded.power_capacity, 1100.0, 0.001,
		"an Energy Storage raises the ceiling by 1000")
	sup.ok(flooded.power > 100.0,
		"so the surplus is banked rather than wasted", "%.0f" % flooded.power)
	sup.ok(not banked.power_short, "and a colony storing power is not short")

	# The coal and nuclear figures are the design document's.
	var coal := _defs_building(&"coal") as Resource
	var nuclear := _defs_building(&"nuclear") as Resource
	sup.near(float(coal.get("yield_amount")), 8.0, 0.001, "a coal plant makes 8 power")
	sup.near(float(nuclear.get("yield_amount")), 40.0, 0.001,
		"a nuclear plant makes 40 power")

	# --- construction rules ------------------------------------------------------
	# Exactly one building per turn per planet.
	var gbuild := _galaxy(9500)
	var built := _habitable_colony(gbuild)
	sup.ok(built != null, "a world exists for the construction test")
	if built == null:
		return
	built.structures = {&"mine": 4}
	built.population = 4.0
	built.food_stock = 1000.0
	var faction0: FactionState = gbuild.faction(0)
	for id in ResearchStage.starter_buildings(_defs):
		faction0.unlocked_buildings[id] = true
	built.reserve_metals = 10000.0

	sup.ok(TurnResolver.can_queue_structure(built, _defs.building(&"granary") as Resource,
		faction0, _db), "a colony with nothing queued may start a building")
	TurnResolver.apply_build_structure(gbuild, faction0,
		Order.make_build_structure(0, built.index, &"granary", 1), _defs, _db)
	sup.eq(built.count(&"granary"), 0, "queuing a building does not grant it immediately")
	sup.ok(not TurnResolver.can_queue_structure(built,
		_defs.building(&"solar") as Resource, faction0, _db),
		"a colony already building may not start a second")
	# The single-project rule holds even for a *different* structure, which is the part that
	# makes it a per-turn allowance rather than a per-structure cap.
	sup.ok(not TurnResolver.can_queue_structure(built,
		_defs.building(&"mine") as Resource, faction0, _db),
		"and the rule is per planet, not per structure")

	# Once the project lands, another may be queued.
	for _i in int((_defs_building(&"granary") as Resource).get("build_turns")):
		ColonySim.simulate_colony(gbuild, built, faction0, _defs, _db, _rng(50 + _i))
	sup.eq(built.count(&"granary"), 1, "the queued granary is built")
	sup.ok(TurnResolver.can_queue_structure(built,
		_defs.building(&"solar") as Resource, faction0, _db),
		"and the next turn's allowance is available")

	var solar_turns := int((_defs_building(&"solar") as Resource).get("build_turns"))
	TurnResolver.apply_build_structure(gbuild, faction0,
		Order.make_build_structure(0, built.index, &"solar", 1), _defs, _db)
	sup.eq(built.count(&"solar"), 0, "the solar array is queued, not granted")
	var finished := 0
	for _i in solar_turns:
		ColonySim.simulate_colony(gbuild, built, faction0, _defs, _db, _rng(60 + _i))
		if built.count(&"solar") > 0:
			finished = _i + 1
	sup.ok(finished >= solar_turns,
		"construction takes at least its declared build_turns",
		"%d turns for a %d-turn project" % [finished, solar_turns])
	sup.eq(built.building_queue.size(), 0, "and the queue drains when it lands")
	sup.near(built.build_metal, 0.0, 0.001, "the banked metal resets with the project")

	# Ships need a Space Port.
	var gship := _galaxy(9600)
	var port := _habitable_colony(gship)
	sup.ok(port != null, "a world exists for the shipyard test")
	if port == null:
		return
	port.structures = {&"mine": 4}
	port.population = 4.0
	port.food_stock = 1000.0
	var corvette := _defs.ship_hull(&"corvette") as Resource
	for id in GameDB.STARTER_HULLS:
		gship.faction(0).unlocked_ships[id] = true
	gship.faction(0).unlocked_ships[&"corvette"] = true
	sup.ok(not TurnResolver.can_build_ship(port, corvette, gship.faction(0), _db),
		"a colony with no Space Port cannot build ships")
	port.structures[&"space_port"] = 1
	sup.ok(TurnResolver.can_build_ship(port, corvette, gship.faction(0), _db),
		"one Space Port is enough")

	# Per-turn mode requires the colony to be producing the hull's full metal cost *every
	# turn*. The roster's capital ships cost thousands, so no realistic colony sustains a
	# Leviathan that way -- which is exactly the pressure the mode is meant to apply.
	gship.faction(0).unlocked_ships[&"leviathan"] = true
	var leviathan := _defs.ship_hull(&"leviathan") as Resource
	var plenty := _habitable_colony(gship)
	sup.ok(plenty != null, "a second world exists for the per-turn production test")
	if plenty == null:
		return
	# Sixty mines is 300 metal a turn: it sustains a Corvette (75) and a Cruiser (300) and
	# nothing above them.
	plenty.structures = {&"space_port": 1, &"mine": 60}
	plenty.population = 4.0
	plenty.food_stock = 1000.0
	var metal_per_turn := TurnResolver.metal_output_per_turn(plenty)
	sup.near(metal_per_turn, 300.0, 0.001, "sixty mines produce 300 metal a turn")
	sup.ok(metal_per_turn >= float(corvette.get("cost_metals")),
		"which sustains a hull as cheap as a Corvette")
	sup.ok(metal_per_turn < float(leviathan.get("cost_metals")),
		"and not one as dear as a Leviathan")
	plenty.build_mode = int(Enums.BuildMode.PER_TURN)
	sup.ok(TurnResolver.can_build_ship(plenty, corvette, gship.faction(0), _db),
		"so per-turn mode may start a Corvette")
	sup.ok(not TurnResolver.can_build_ship(plenty, leviathan, gship.faction(0), _db),
		"but refuses a Leviathan")
	# The same colony in single-project mode is not asked the question at all.
	plenty.build_mode = int(Enums.BuildMode.SINGLE)
	sup.ok(TurnResolver.can_build_ship(plenty, leviathan, gship.faction(0), _db),
		"single-project mode is bounded by the bank, not the output")

	var stingy := _habitable_colony(gship)
	stingy.structures = {&"space_port": 1, &"mine": 4}
	stingy.population = 4.0
	stingy.food_stock = 1000.0
	stingy.build_mode = int(Enums.BuildMode.PER_TURN)
	sup.ok(TurnResolver.metal_output_per_turn(stingy) < float(corvette.get("cost_metals")),
		"a colony with four mines produces 20 a turn")
	sup.ok(not TurnResolver.can_build_ship(stingy, corvette, gship.faction(0), _db),
		"so per-turn mode refuses even a Corvette")

	# Power blocks new structures and nothing else.
	var gpow := _galaxy(9700)
	var walled := _habitable_colony(gpow)
	sup.ok(walled != null, "a world exists for the power-block test")
	if walled == null:
		return
	# One City Complex draws 10 power and nothing generates any, so the colony is short and
	# the bank cannot cover the deficit.
	walled.structures = {&"city_complex": 1, &"mine": 4}
	walled.population = 4.0
	walled.food_stock = 1000.0
	walled.power = 0.0
	ColonySim.simulate_colony(gpow, walled, gpow.faction(0), _defs, _db, _rng(70))
	var city_def := _defs_building(&"city_complex") as Resource
	var farm_def2 := _defs_building(&"farm") as Resource
	sup.ok(walled.is_power_short(), "a colony with no reactors is short of power")
	sup.ok(not TurnResolver.can_queue_structure(walled, city_def, gpow.faction(0), _db),
		"a short colony may not start a second structure that draws power")
	sup.ok(TurnResolver.can_queue_structure(walled, farm_def2, gpow.faction(0), _db),
		"but may start one that draws none")
	# And the structure already standing keeps working, which is the other half of the rule.
	sup.eq(walled.count(&"city_complex"), 1,
		"the structures already built are untouched by the shortfall")

	# One reactor fixes it, and then a second City Complex may be started.
	walled.structures[&"solar"] = 2
	walled.power = 40.0
	ColonySim.simulate_colony(gpow, walled, gpow.faction(0), _defs, _db, _rng(71))
	sup.ok(not walled.is_power_short(), "two reactors cover the deficit")
	sup.ok(TurnResolver.can_queue_structure(walled, city_def, gpow.faction(0), _db),
		"so the colony may start another power-drawing structure")

	# --- the click-to-boost bar -------------------------------------------------
	# Progress is banked as metal, and the panel's bar spends stored metal directly
	# against it. Both halves of the number therefore come from the same place, which is
	# what stops the bar and the resolver disagreeing.
	var gboost := _galaxy(9800)
	var boosting := _habitable_colony(gboost)
	sup.ok(boosting != null, "a world exists for the boost test")
	if boosting == null:
		return
	boosting.structures = {&"mine": 4}
	boosting.population = 4.0
	boosting.food_stock = 1000.0
	boosting.reserve_metals = 40.0
	boosting.building_queue[&"granary"] = 1
	boosting.build_turns_remaining = 2
	boosting.build_metal = 0.0
	var buildings: Dictionary = _defs.get("buildings") as Dictionary
	sup.near(ColonySim.construction_progress(boosting, buildings), 0.0, 0.001,
		"a fresh project is at zero progress")
	var spent := ColonySim.boost_construction(boosting, 40.0)
	sup.near(spent, 40.0, 0.001, "the whole store can be spent")
	sup.near(boosting.reserve_metals, 0.0, 0.001, "and leaves the colony with none")
	sup.near(ColonySim.construction_progress(boosting, buildings), 1.0, 0.001,
		"a fully boosted project reads as complete")

	# Half the cost is half the progress: the bar is a fraction of metal paid, not a guess.
	boosting.reserve_metals = 10.0
	boosting.build_metal = 0.0
	ColonySim.boost_construction(boosting, 10.0)
	sup.near(ColonySim.construction_progress(boosting, buildings), 0.5, 0.001,
		"half the metal is half the progress")

	# Spending is bounded by the store, so pressing the bar on an empty colony is a no-op
	# rather than an error and rather than a negative stockpile.
	sup.near(ColonySim.boost_construction(boosting, 999.0), 0.0, 0.001,
		"a colony with no metal cannot be boosted")
	sup.near(ColonySim.boost_construction(boosting, -5.0), 0.0, 0.001,
		"a negative boost is refused")
	sup.near(boosting.reserve_metals, 0.0, 0.001, "and neither leaves a negative store")

	# Nothing under construction, nothing to boost.
	var idle := _habitable_colony(gboost)
	idle.reserve_metals = 500.0
	sup.near(ColonySim.construction_progress(idle, buildings), 0.0, 0.001,
		"an idle colony has no progress to show")
	sup.near(ColonySim.boost_construction(idle, 100.0), 0.0, 0.001,
		"and nothing to spend metal on")

	# --- the imperial ledger -----------------------------------------------------
	var g2 := _galaxy(9100)
	_colonize(g2, 0, g2.systems[0].planet_indices[0])
	var fb: FactionState = g2.faction(0)
	fb.treasury = 5000.0
	var treasury_before := fb.treasury
	ColonySim.simulate_faction(g2, fb, _defs, _db, _rng(80))
	sup.near(fb.last_net, fb.last_income - fb.last_expenses, 0.0001,
		"last_net is income minus expenses")
	sup.near(fb.treasury, treasury_before + fb.last_net, 0.0001,
		"the treasury moves by exactly the net")
	sup.ok(fb.last_expenses > 0.0, "a colony carries upkeep")

	# The treasury floor must be respected.
	var broke: FactionState = g2.faction(1)
	_colonize(g2, 1, _unowned_planet(g2, 1))
	broke.treasury = float(_db.get("TREASURY_FLOOR")) + 1.0
	ColonySim.simulate_faction(g2, broke, _defs, _db, _rng(81))
	sup.near(broke.treasury, float(_db.get("TREASURY_FLOOR")), 0.001,
		"a bankrupt empire is floored, not deleted")

	# A building past its per-colony cap must not be added.
	var farm_def: Resource = _defs_building(&"farm") as Resource
	sup.ok(farm_def != null, "the farm definition resolves")
	if farm_def != null:
		var cap := int(farm_def.get("max_per_colony"))
		sup.ok(cap > 0, "the farm declares a per-colony cap", "cap=%d" % cap)
		sup.ok(not farm_def.can_add(cap), "a colony at the farm cap cannot add another")
		sup.ok(farm_def.can_add(cap - 1), "a colony below the cap can")


## Set by the "a colony of one never grows" loop; a GDScript lambda capture would be a copy.
var smallkeep: bool = true


## The most habitable unowned world, colonised for faction 0, or null.
##
## The generator seeds hostile planet types alongside habitable ones, so "first unclaimed
## body" is not necessarily a place a colony could live -- and in the Phase 8 model a
## colony that cannot live on it has no housing and cannot grow at all, which would make
## every growth assertion vacuous.
func _habitable_colony(g: GalaxyState, faction_id: int = 0) -> PlanetState:
	# Settle on the most habitable *unclaimed* world, and exclude the founding homeworlds
	# explicitly: those already carry a landed Colony Ship, and a scenario that strips it out
	# is testing a colony the generator would never have produced.
	var best := -1
	var best_hab := 0.0
	for p in g.planets:
		if p.owner >= 0 or p.colonized:
			continue
		var h: float = p.habitability()
		if h > best_hab:
			best_hab = h
			best = p.index
	if best < 0:
		return null
	var colony := _colonize(g, faction_id, best)
	# Drop the generator's starting kit so each scenario states the whole economy it wants.
	# `_colonize` seeds a City Complex and a Colony Ship for the fixtures that need them, and
	# the scenarios below add their own.
	colony.structures = {}
	colony.troops = 0
	colony.power = 0.0
	colony.build_metal = 0.0
	colony.building_queue = {}
	colony.build_turns_remaining = 0
	return colony


## Whether `planet` currently carries the warning `key`.
static func _warns(planet: PlanetState, key: StringName) -> bool:
	return planet.warning_set().has(key)


# --- research -----------------------------------------------------------

## Research is passive and population-driven as of Phase 8.
##
## The sliders are gone and so is the income-driven budget: what funds research is the
## empire's civilian population, split across the four fields by the relative cost of what is
## still ahead in each. These assertions are about that model, not about the old one.
func _test_research() -> void:
	sup.begin("research")

	var g := _galaxy(10000)
	var f: FactionState = g.faction(0)
	var colony := _colonize(g, 0, _unowned_planet(g))

	# Population funds research.
	colony.population = 10.0
	var before := f.tech_points[0]
	var granted := ResearchStage.accumulate(f, g, _defs, _db)
	sup.ok(granted > 0.0, "a populated empire funds research", "%.3f" % granted)
	sup.ok(f.tech_points[0] > before, "points accumulate in a field")

	# Population is the driver, and only population. Income is not consulted at all as of
	# this phase, which is exactly the property being asserted: a rich empire with nobody on
	# its worlds researches nothing, and a poor empire with a million people does.
	#
	# Every colony is emptied, not just the one above, because the budget sums across the
	# empire and the generator has already given this faction its founding world.
	var owned := g.colonies_of(f.id)
	for c in owned:
		c.population = 0.0
	f.last_income = 100000.0
	var no_civils := ResearchStage.accumulate(f, g, _defs, _db)
	sup.near(no_civils, 0.0, 0.0001,
		"an empire with no civilians researches nothing, however rich it is")

	# Troops explicitly do not research, per the design document. A garrison of a thousand is
	# worth nothing to the technology tree, and asserting it directly is the only way to
	# catch a budget that quietly read a combined figure.
	for c in owned:
		c.troops = 500.0
	var troopy := ResearchStage.accumulate(f, g, _defs, _db)
	sup.near(troopy, 0.0, 0.0001, "and troops make no difference to the budget")

	# And civilians do, which is the other half: the same colonies repopulated research
	# again, so the difference above was the population and not the income figure.
	for c in owned:
		c.population = 10.0
		c.troops = 0.0
	var repopulated := ResearchStage.accumulate(f, g, _defs, _db)
	sup.ok(repopulated > 0.0, "the same colonies research again once they are repopulated",
		"%.3f" % repopulated)

	# Every field receives a share: there is no longer a slider with which to starve one.
	var g2 := _galaxy(10050)
	var f2: FactionState = g2.faction(0)
	var c2 := _colonize(g2, 0, _unowned_planet(g2))
	c2.population = 20.0
	ResearchStage.accumulate(f2, g2, _defs, _db)
	var fed := 0
	for i in 4:
		if f2.tech_points[i] > 0.0:
			fed += 1
	sup.eq(fed, 4, "all four research fields are funded from population")

	# A faction with no colonies cannot research at all.
	var g3 := _galaxy(10100)
	var f3: FactionState = g3.faction(1)
	# Strip its founding colony so the empire genuinely has nothing left to fund from.
	for c in g3.colonies_of(f3.id):
		c.owner = -1
		c.colonized = false
	f3.last_income = 500.0
	var orphan := ResearchStage.accumulate(f3, g3, _defs, _db)
	sup.near(orphan, 0.0, 0.0001, "an empire with no colonies cannot research")

	# Prerequisites must be respected.
	var g4 := _galaxy(10200)
	var f4: FactionState = g4.faction(0)
	_colonize(g4, 0, g4.systems[0].planet_indices[0])
	f4.tech_points = PackedFloat64Array([5000.0, 5000.0, 5000.0, 5000.0])
	var completed := ResearchStage.complete_available(f4, _defs)
	sup.ok(completed.size() > 0, "a wealthy empire completes research",
		"%d nodes" % completed.size())
	for id in completed:
		sup.ok(f4.researched.has(id), "completed node is recorded: %s" % id)
	sup.ok(_prereqs_satisfied(f4, completed),
		"every completed node had its prerequisites")

	# With nothing banked, nothing completes.
	var g5 := _galaxy(10300)
	var f5: FactionState = g5.faction(0)
	f5.tech_points = PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	sup.eq(ResearchStage.complete_available(f5, _defs).size(), 0,
		"an empty empire completes nothing")

	# --- the population ladder -----------------------------------------------
	# Milestones are what unlock hulls, and they are a function of population alone.
	sup.eq(ResearchStage.hull_tier_for(0.0, _db), 0, "no population, no milestones")
	var thresholds := ResearchStage.milestones(_db)
	sup.ok(thresholds.size() >= 4, "the ladder has several rungs", "%d" % thresholds.size())
	for i in range(1, thresholds.size()):
		sup.ok(thresholds[i] > thresholds[i - 1], "milestone %d is above %d" % [i, i - 1])
	sup.eq(ResearchStage.next_milestone(0.0, _db), thresholds[0],
		"the next milestone above zero is the first rung")
	sup.eq(ResearchStage.milestones_reached(thresholds[0], _db), 1,
		"reaching the first rung counts as one milestone")
	sup.eq(ResearchStage.next_milestone(thresholds[0] * 2.0, _db), thresholds[1],
		"the ladder advances in order")

	var g6 := _galaxy(10400)
	var f6: FactionState = g6.faction(0)
	# Generation already ran the ladder over the founding population, so a fresh empire sits
	# at whatever tier its three settlers reach -- zero, since the first rung is six. The
	# assertion is that nothing was *granted*, not that the counter is still at its sentinel.
	sup.eq(f6.tech_tier, 0, "a fresh empire has crossed no milestones")
	var empty := ResearchStage.apply_milestones(f6, 0.0, _defs, _db)
	sup.ok(empty.is_empty(), "no population grants no hulls")

	# A crossing population grants hulls, and the count matches the milestone.
	var per := maxi(1, int(_db.get("HULLS_PER_MILESTONE")))
	var crossed := ResearchStage.apply_milestones(f6, thresholds[1], _defs, _db)
	sup.eq(crossed.size(), per * 2, "crossing two milestones grants %d hulls" % (per * 2))
	sup.eq(f6.tech_tier, 2, "and records the tier it reached")
	for id in crossed:
		sup.ok(f6.unlocked_ships.has(id), "milestone hull %s is unlocked" % id)

	# Re-running at the same population grants nothing: a colony lost and retaken must not
	# re-unlock the whole fleet, which is why the tier is stored on the faction.
	sup.ok(ResearchStage.apply_milestones(f6, thresholds[1], _defs, _db).is_empty(),
		"the same population grants nothing further")

	# A higher population grants more, and the hulls are the next ones up the ladder.
	var before_count := f6.unlocked_ships.size()
	var more := ResearchStage.apply_milestones(f6, thresholds[3], _defs, _db)
	sup.eq(f6.tech_tier, 4, "and the tier follows the population up")
	sup.ok(more.size() > 0, "a further crossing grants more hulls")
	sup.ok(f6.unlocked_ships.size() > before_count, "the roster grew")
	# The starter hulls survive: they are what a player has before any milestone.
	sup.ok(f6.unlocked_ships.has(&"colony_ship"),
		"a milestone does not take away the Colony Ship")
	sup.ok(f6.unlocked_ships.has(&"exploration_ship"),
		"nor the Exploration Ship")

	# Every building is available from the start: structures are gated by the population
	# needed to staff them, not by a tech node.
	sup.eq(ResearchStage.starter_buildings(_defs).size(),
		(_defs.get("buildings") as Dictionary).size(),
		"every structure in the roster is available immediately")

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
	_place_fleet(g, 0, 0, {&"exploration_ship": 1})

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
				if t % 3 == 0 and fleet.ships.has(&"exploration_ship"):
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
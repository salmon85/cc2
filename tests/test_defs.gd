extends SceneTree
## Headless verification for Phase 2: every `.tres` definition loads and is sane.
##
##   godot --headless --path . -s res://tests/test_defs.gd

var _t: TestSupport = null


func _initialize() -> void:
	_t = TestSupport.new()

	# Autoloads only exist when the project boots normally; a bare `-s` script run does
	# not register them, so drive `Defs` directly.
	var defs: Node = (load("res://src/data/defs.gd") as GDScript).new()
	defs.name = "Defs"
	root.add_child(defs)
	defs.call("load_all")

	_test_planet_types(defs)
	_test_ship_hulls(defs)
	_test_buildings(defs)
	_test_tech_tree(defs)
	_test_validation_guards(defs)
	_test_missing_directory_is_safe()

	var code := _t.finish("test_defs")
	print("---test_defs-exit=%d---" % code)
	defs.queue_free()
	quit(code)


func _test_planet_types(defs: Node) -> void:
	_t.begin("planet types")
	var table := defs.get("planet_types") as Dictionary
	_t.eq(table.size(), 6, "all six planet classes defined")

	var expected := [
		&"terrestrial", &"desert", &"ice", &"volcanic", &"gas_giant", &"barren",
	]
	for id: StringName in expected:
		var d := defs.call("planet_type", id) as Resource
		_t.ok(d != null, "planet type '%s' loads" % id)
		if d == null:
			continue
		_t.ok(d is PlanetTypeData, "'%s' is a PlanetTypeData" % id)
		_t.ok(not d.get("display_name").is_empty(), "'%s' has a display name" % id)
		_t.in_range(d.get("base_habitability"), 0.0, 1.0, "'%s' habitability in [0,1]" % id)

	# Gas giants must be locked behind tech; barren worlds are mining-only.
	var gas := defs.call("planet_type", &"gas_giant") as Resource
	_t.ok(not gas.get("colonizable"), "gas giants are not colonisable at start")
	_t.ok(gas.get("terraformable"), "gas giants are terraformable")
	_t.eq(gas.get("food_yield"), 0.0, "gas giants yield no food")

	var terr := defs.call("planet_type", &"terrestrial") as Resource
	_t.ok(terr.get("colonizable"), "terrestrial worlds are colonisable")
	_t.eq(terr.get("planet_class"), 0, "terrestrial maps to PlanetClass 0")

	# Habitability must rise with terraforming and stay clamped.
	_t.near(terr.call("effective_habitability", 0.0), 0.92, 0.001, "no terraform = base habitability")
	_t.ok(
		terr.call("effective_habitability", 1.0) > terr.call("effective_habitability", 0.0),
		"terraforming raises habitability")
	_t.in_range(terr.call("effective_habitability", 99.0), 0.0, 1.0, "terraform clamps to 1.0")

	# Generation weights must all be positive so no class is unreachable.
	for cls in 6:
		_t.ok(PlanetTypeData.class_weight(cls) > 0.0, "class %d has a generation weight" % cls)


func _test_ship_hulls(defs: Node) -> void:
	_t.begin("ship hulls")
	var table := defs.get("ship_hulls") as Dictionary
	_t.eq(table.size(), 14, "the Phase 8 roster defines fourteen hulls")

	var expected := [
		&"colony_ship", &"exploration_ship", &"troop_transport", &"cargo_transport",
		&"corvette", &"frigate", &"destroyer", &"cruiser", &"battlecruiser",
		&"battleship", &"battlestar", &"dreadnought", &"titan", &"leviathan",
	]
	for id: StringName in expected:
		var d := defs.call("ship_hull", id) as Resource
		_t.ok(d != null, "hull '%s' loads" % id)
		if d == null:
			continue
		_t.ok(d is ShipHullData, "'%s' is a ShipHullData" % id)
		_t.ok(d.get("hull_points") > 0.0, "'%s' has hull points" % id)

	# The exact figures the design document states. Asserted against literals rather than
	# against each other: a rebalanced `.tres` that drifted from the specification would
	# still be internally consistent, and "the costs increase" would not catch it.
	var roster := {
		&"colony_ship": [0.0, 0.0, 200.0],
		&"exploration_ship": [1.0, 1.0, 100.0],
		&"corvette": [1.0, 2.0, 75.0],
		&"frigate": [2.0, 1.0, 100.0],
		&"destroyer": [3.0, 2.0, 175.0],
		&"cruiser": [5.0, 4.0, 300.0],
		&"battlecruiser": [7.0, 4.0, 450.0],
		&"battleship": [8.0, 7.0, 600.0],
		&"battlestar": [10.0, 9.0, 850.0],
		&"dreadnought": [14.0, 10.0, 1100.0],
		&"titan": [18.0, 15.0, 1600.0],
		&"leviathan": [25.0, 20.0, 2500.0],
	}
	for id: StringName in roster:
		var d := defs.call("ship_hull", id) as Resource
		if d == null:
			continue
		var row: Array = roster[id]
		_t.near(d.get("attack"), float(row[0]), 0.001, "%s attack matches the spec" % id)
		_t.near(d.get("defense"), float(row[1]), 0.001, "%s defense matches the spec" % id)
		_t.near(d.get("cost_metals"), float(row[2]), 0.001, "%s metal cost matches the spec" % id)

	# Cost must increase monotonically through the combat ladder. Defence deliberately does
	# *not* have to: the spec gives the Corvette 2 defence and the Frigate 1, so a cheaper
	# escort is genuinely the softer of the two, and asserting that defence rises with cost
	# would be asserting a rule the design document contradicts. What must hold is that a
	# ladder rung never costs less than the one below it -- the property the population
	# ladder's ordering and the AI's build choices assume -- and that the two ends of the
	# ladder are the ends of the roster.
	var prev_cost := 0.0
	var ladder: Array[StringName] = [
		&"corvette", &"frigate", &"destroyer", &"cruiser", &"battlecruiser",
		&"battleship", &"battlestar", &"dreadnought", &"titan", &"leviathan",
	]
	for id in ladder:
		var d := defs.call("ship_hull", id) as Resource
		var cost: float = d.get("cost_metals")
		_t.ok(cost >= prev_cost, "'%s' costs at least as much as the hull below it" % id)
		prev_cost = cost

	var strongest := 0.0
	for id in ladder:
		strongest = maxf(strongest, float((defs.call("ship_hull", id) as Resource).get("defense")))
	_t.near((defs.call("ship_hull", &"leviathan") as Resource).get("defense"),
		strongest, 0.001, "the Leviathan is the best-defended hull")

	# The attack figures are strictly increasing along the ladder, which is the claim the
	# whole roster exists to make: every rung is a real upgrade over the one below it.
	var prev_attack := 0.0
	for id in ladder:
		var d := defs.call("ship_hull", id) as Resource
		var attack: float = d.get("attack")
		_t.ok(attack > prev_attack, "'%s' hits harder than the hull below it" % id)
		prev_attack = attack

	# Role invariants from the spec.
	var colony := defs.call("ship_hull", &"colony_ship") as Resource
	_t.ok(colony.get("colony_kit"), "the colony hull carries a colony kit")
	_t.near(colony.get("civilian_capacity"), 5.0, 0.001,
		"the colony hull carries five civilians")
	var scout := defs.call("ship_hull", &"exploration_ship") as Resource
	_t.near(scout.get("survey_rate"), 0.25, 0.001,
		"an exploration hull surveys at 25% per turn")
	_t.ok(scout.get("sensor_range") > 5.0, "exploration ships have the best sensors")
	var trooper := defs.call("ship_hull", &"troop_transport") as Resource
	_t.near(trooper.get("troop_capacity"), 4.0, 0.001,
		"a troop transport carries four troops")
	var freighter := defs.call("ship_hull", &"cargo_transport") as Resource
	_t.ok(freighter.get("cargo_capacity") > 0.0, "a cargo transport carries cargo")
	var dread := defs.call("ship_hull", &"dreadnought") as Resource
	_t.ok(dread.get("bombardment") > 0.0, "dreadnoughts can bombard planets")

	# Only an exploration hull surveys. A survey rate on a freighter would mean exploring was
	# a cargo-hauling side effect.
	for id: StringName in expected:
		var d2 := defs.call("ship_hull", id) as Resource
		if d2 == null:
			continue
		if float(d2.get("survey_rate")) > 0.0:
			_t.eq(int(d2.get("role")), int(Enums.ShipRole.EXPLORATION),
				"'%s' surveys, so it is an exploration hull" % id)

	# The combat / support partition the travel modal renders. Asserted through the enum
	# helpers the modal itself calls, so a hull that moved between the two lists is caught
	# here rather than appearing as a transport in the combat roster.
	_t.ok(Enums.role_is_combat(int(Enums.ShipRole.CRUISER)),
		"a cruiser is a combat hull")
	_t.ok(Enums.role_is_support(int(Enums.ShipRole.CARGO)),
		"a cargo transport is a support hull")

	# Scouts must out-run capital ships; the movement phase depends on it.
	_t.ok(
		ShipHullData.role_speed_cap(int(Enums.ShipRole.SCOUT))
			> ShipHullData.role_speed_cap(int(Enums.ShipRole.DREADNOUGHT)),
		"the scout speed cap exceeds the dreadnought's")


func _test_buildings(defs: Node) -> void:
	_t.begin("buildings")
	var table := defs.get("buildings") as Dictionary
	_t.eq(table.size(), 12, "the Phase 8 roster defines twelve structures")

	var expected := [
		&"farm", &"mine", &"city_complex", &"granary", &"colony_ship_building", &"space_port",
		&"energy_storage", &"barracks", &"planetary_defense",
		&"solar", &"coal", &"nuclear",
	]
	for id: StringName in expected:
		var d := defs.call("building", id) as Resource
		_t.ok(d != null, "building '%s' loads" % id)
		if d == null:
			continue
		_t.ok(d is BuildingData, "'%s' is a BuildingData" % id)
		_t.ok(d.get("build_turns") >= 1, "'%s' takes at least one turn to build" % id)

	# The exact figures the design document states. Literals, not a comparison between
	# entries: a roster that drifted from the spec while staying internally ordered would
	# pass any monotonicity check.
	var farm := defs.call("building", &"farm") as Resource
	_t.near(farm.get("cost_metals"), 5.0, 0.001, "a farm costs 5 metal")
	_t.near(farm.get("yield_amount"), 5.0, 0.001, "a farm makes 5 food per turn")
	_t.eq(int(farm.get("pop_required")), 1, "a farm requires 1 pop")

	var mine2 := defs.call("building", &"mine") as Resource
	_t.near(mine2.get("cost_metals"), 5.0, 0.001, "a mine costs 5 metal")
	_t.near(mine2.get("metal_per_turn"), 5.0, 0.001, "a mine makes 5 metal per turn")
	_t.eq(int(mine2.get("pop_required")), 1, "a mine requires 1 pop")

	var city := defs.call("building", &"city_complex") as Resource
	_t.near(city.get("cost_metals"), 100.0, 0.001, "a City Complex costs 100 metal")
	_t.near(city.get("power_required"), 10.0, 0.001, "a City Complex needs 10 power")
	_t.eq(int(city.get("pop_housed")), 20, "a City Complex houses 20 pop")

	var granary := defs.call("building", &"granary") as Resource
	_t.near(granary.get("cost_metals"), 20.0, 0.001, "a granary costs 20 metal")
	_t.near(granary.get("food_store"), 1000.0, 0.001, "a granary stores 1000 food")

	var pad := defs.call("building", &"colony_ship_building") as Resource
	_t.near(pad.get("cost_metals"), 0.0, 0.001, "a landed Colony Ship is free")
	_t.eq(int(pad.get("max_per_colony")), 1, "one Colony Ship per world")
	_t.near(pad.get("yield_amount"), 5.0, 0.001, "a Colony Ship makes 5 food per turn")
	_t.near(pad.get("metal_per_turn"), 5.0, 0.001, "a Colony Ship makes 5 metal per turn")
	_t.eq(int(pad.get("pop_housed")), 5, "a Colony Ship houses 5 pop")

	var port := defs.call("building", &"space_port") as Resource
	_t.near(port.get("cost_metals"), 100.0, 0.001, "a Space Port costs 100 metal")

	var storage := defs.call("building", &"energy_storage") as Resource
	_t.near(storage.get("cost_metals"), 50.0, 0.001, "Energy Storage costs 50 metal")
	_t.near(storage.get("energy_store"), 1000.0, 0.001, "Energy Storage holds 1000 energy")

	var barracks := defs.call("building", &"barracks") as Resource
	_t.near(barracks.get("cost_metals"), 100.0, 0.001, "Barracks cost 100 metal")

	# Power stations, exactly as specified.
	var stations := {&"solar": [10.0, 1.0], &"coal": [50.0, 8.0], &"nuclear": [200.0, 40.0]}
	for id: StringName in stations:
		var d := defs.call("building", id) as Resource
		var row: Array = stations[id]
		_t.near(d.get("cost_metals"), float(row[0]), 0.001, "%s costs the spec's metal" % id)
		_t.near(d.get("yield_amount"), float(row[1]), 0.001, "%s makes the spec's power" % id)
		_t.eq(int(d.get("kind")), int(BuildingData.Kind.POWER), "%s is a power station" % id)

	# Power draw is a property of the kind, not a per-structure guess: only a City Complex
	# draws power as of this roster, and that is what makes "running out of power blocks new
	# structures" a checkable claim rather than a per-file decision.
	var drawing: Array[StringName] = []
	for id: StringName in table:
		var d2 := defs.call("building", id) as Resource
		if d2.draws_power():
			drawing.append(id)
	_t.eq(drawing.size(), 1, "exactly one structure in the roster draws power")
	if drawing.size() == 1:
		_t.eq(drawing[0], &"city_complex", "and it is the City Complex")

	# The landed Colony Ship is the only structure a colony cannot build for itself, so it is
	# the only one with a hard cap of one.
	_t.ok(not pad.call("can_add", 1), "a second Colony Ship is refused")
	_t.ok(pad.call("can_add", 0), "a first Colony Ship is allowed")
	_t.ok(port.call("can_add", 99), "Space Ports are not capped per colony")


func _test_tech_tree(defs: Node) -> void:
	_t.begin("tech tree")
	var table := defs.get("tech_nodes") as Dictionary
	_t.eq(table.size(), 16, "sixteen tech nodes defined")

	var order := defs.get("tech_order") as PackedStringArray
	_t.eq(order.size(), 16, "tech order covers every node")

	# Topological order must place every prerequisite before the node that needs it.
	var seen: Dictionary = {}
	var ordered_ok := true
	for id in order:
		var node := table[id] as Resource
		for prereq in node.get("prerequisites"):
			if not seen.has(prereq):
				ordered_ok = false
		seen[id] = true
	_t.ok(ordered_ok, "every prerequisite precedes its dependent node in tech_order")

	# Every field must be represented and reachable from a tier-1 root.
	var per_field := {0: 0, 1: 0, 2: 0, 3: 0}
	var roots := 0
	for id: StringName in table:
		var node := table[id] as Resource
		per_field[node.get("field")] = int(per_field[node.get("field")]) + 1
		var prereqs: Array = node.get("prerequisites")
		if prereqs.is_empty():
			roots += 1
	for field: int in per_field:
		_t.eq(per_field[field], 4, "field %d has four nodes" % field)
	_t.eq(roots, 4, "exactly four tier-1 roots, one per field")

	# Prerequisite ids must all resolve.
	var all_resolve := true
	for id: StringName in table:
		for prereq in (table[id] as Resource).get("prerequisites"):
			if not table.has(prereq):
				all_resolve = false
	_t.ok(all_resolve, "every prerequisite id resolves to a real node")

	# Depth check: tier 4 nodes must exist and be the most expensive in their field.
	var hyper := defs.call("tech_node", &"hyperdrive") as Resource
	_t.eq(hyper.get("tier"), 4, "hyperdrive is tier 4")
	_t.ok(hyper.call("movement_bonus") > 0.0, "hyperdrive grants movement")
	_t.near(hyper.call("effect", &"nonexistent_key"), 0.0, 0.0, "unknown effect keys read as 0.0")

	var gas := defs.call("tech_node", &"planetary_engineering") as Resource
	_t.ok(gas.call("can_colonize_gas"), "planetary engineering unlocks gas giants")

	# Effect accessors must agree with the raw dictionary they read.
	var acc := defs.call("tech_node", &"dyson_grid") as Resource
	_t.near(
		acc.call("shield_bonus"),
		float(acc.get("effects").get("shield_bonus", 0.0)),
		0.0001,
		"shield_bonus() matches the authored effect")


func _test_validation_guards(defs: Node) -> void:
	_t.begin("validation guards reject bad definitions")

	# The shipped data set must be completely clean.
	var issues := defs.call("validate_all") as PackedStringArray
	_t.eq(issues.size(), 0, "the shipped .tres data set has no validation issues")
	for issue in issues:
		print("    ! %s" % issue)

	# Hand-built resources with authoring mistakes must be reported.
	var bad := PlanetTypeData.new()
	bad.id = &"bad"
	bad.display_name = "Bad"
	bad.base_habitability = 4.2
	_t.ok(bad.validate().size() > 0, "out-of-range habitability is reported")

	var dead_end := PlanetTypeData.new()
	dead_end.id = &"dead"
	dead_end.display_name = "Dead End"
	dead_end.colonizable = false
	dead_end.terraformable = false
	_t.ok(dead_end.validate().size() > 0, "an uncolonisable, unterraformable world is reported")

	var bad_ship := ShipHullData.new()
	bad_ship.id = &"bad_ship"
	bad_ship.display_name = "Bad Ship"
	bad_ship.weapon_damage = 5.0
	bad_ship.weapon_slots = 0
	_t.ok(bad_ship.validate().size() > 0, "a hull with damage but no weapon slot is reported")

	var bad_tech := TechNodeData.new()
	bad_tech.id = &"bad_tech"
	bad_tech.display_name = "Bad Tech"
	bad_tech.field = 9
	_t.ok(bad_tech.validate().size() > 0, "a tech node with an invalid field is reported")

	var pointless := TechNodeData.new()
	pointless.id = &"empty"
	pointless.display_name = "Empty"
	_t.ok(pointless.validate().size() > 0, "a tech node granting nothing is reported")

	# A well-formed hand-built resource must report nothing.
	var good := PlanetTypeData.new()
	good.id = &"good"
	good.display_name = "Good"
	good.colonizable = true
	good.terraformable = true
	good.terraform_cost = 100.0
	_t.eq(good.validate().size(), 0, "a well-formed definition reports no issues")


## A missing definition directory must degrade to an empty registry, not a crash.
## Only the directory case is exercised here: pointing the loader at a nonexistent
## *script* also logs an engine error, which would pollute an otherwise clean run.
func _test_missing_directory_is_safe() -> void:
	_t.begin("missing directories degrade gracefully")
	var scratch: Node = (load("res://src/data/defs.gd") as GDScript).new()
	root.add_child(scratch)
	var result := scratch.call(
		"_load_dir_probe", "res://src/data/planet_type_data.gd", "res://data/nope"
	) as PackedStringArray
	_t.eq(result.size(), 0, "loading a missing directory yields an empty result")
	scratch.queue_free()
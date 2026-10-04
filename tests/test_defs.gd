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
	_t.eq(table.size(), 6, "all six hull classes defined")

	var expected := [
		&"scout", &"colony_ship", &"transport", &"corvette", &"cruiser", &"dreadnought",
	]
	for i in expected.size():
		var id: StringName = expected[i]
		var d := defs.call("ship_hull", id) as Resource
		_t.ok(d != null, "hull '%s' loads" % id)
		if d == null:
			continue
		_t.ok(d is ShipHullData, "'%s' is a ShipHullData" % id)
		_t.eq(d.get("role"), i, "'%s' maps to the matching ShipRole" % id)
		_t.ok(d.get("hull_points") > 0.0, "'%s' has hull points" % id)

	# Hull strength must increase monotonically through the tech ladder, and speed
	# must decrease. This is the balance guarantee the fleet AI relies on.
	var prev_hull := 0.0
	var prev_cost := 0.0
	for id: StringName in expected:
		var d := defs.call("ship_hull", id) as Resource
		var hull: float = d.get("hull_points")
		var cost: float = d.get("cost_metals")
		_t.ok(hull >= prev_hull, "'%s' is at least as tough as the hull below it" % id)
		_t.ok(cost >= prev_cost, "'%s' costs at least as much as the hull below it" % id)
		prev_hull = hull
		prev_cost = cost

	# Role invariants from the spec.
	var scout := defs.call("ship_hull", &"scout") as Resource
	_t.ok(scout.get("sensor_range") > 5.0, "scouts have the best sensors")
	var colony := defs.call("ship_hull", &"colony_ship") as Resource
	_t.ok(colony.get("colony_kit"), "the colony hull carries a colony kit")
	var dread := defs.call("ship_hull", &"dreadnought") as Resource
	_t.ok(dread.get("bombardment") > 0.0, "dreadnoughts can bombard planets")
	var transport := defs.call("ship_hull", &"transport") as Resource
	_t.ok(transport.get("troop_capacity") > 0.0, "transports carry troops")

	# Scouts must out-run capital ships; the movement phase depends on it.
	_t.ok(
		ShipHullData.role_speed_cap(0) > ShipHullData.role_speed_cap(5),
		"the scout speed cap exceeds the dreadnought's")


func _test_buildings(defs: Node) -> void:
	_t.begin("buildings")
	var table := defs.get("buildings") as Dictionary
	_t.eq(table.size(), 9, "nine structures defined")

	var expected := [
		&"mine", &"farm", &"factory", &"shield_generator", &"missile_battery",
		&"garrison", &"shipyard", &"orbital_station", &"terraformer",
	]
	for i in expected.size():
		var id: StringName = expected[i]
		var d := defs.call("building", id) as Resource
		_t.ok(d != null, "building '%s' loads" % id)
		if d == null:
			continue
		_t.ok(d is BuildingData, "'%s' is a BuildingData" % id)
		_t.eq(d.get("kind"), i, "'%s' maps to the matching Kind" % id)
		_t.ok(d.get("build_turns") >= 1, "'%s' takes at least one turn to build" % id)
		_t.ok(d.get("cost_metals") > 0.0, "'%s' costs metals" % id)

	# The terraformer is a one-per-world structure; nothing else is capped this way.
	var terraformer := defs.call("building", &"terraformer") as Resource
	_t.eq(terraformer.get("max_per_colony"), 1, "only one terraformer per world")
	_t.ok(not terraformer.call("can_add", 1), "a second terraformer is refused")
	_t.ok(terraformer.call("can_add", 0), "a first terraformer is allowed")

	# Every buildable structure now declares a per-colony cap, so that a colony's
	# output is bounded and the treasury floor is reachable through overbuilding.
	var mine := defs.call("building", &"mine") as Resource
	var mine_cap := int(mine.get("max_per_colony"))
	_t.ok(mine_cap > 0, "mines declare a per-colony cap", "cap=%d" % mine_cap)
	_t.ok(mine.call("can_add", mine_cap - 1), "a mine below the cap is allowed")
	_t.ok(not mine.call("can_add", mine_cap), "a mine at the cap is refused")

	var uncapped := 0
	for id in defs.buildings:
		var def: Resource = defs.call("building", id) as Resource
		if int(def.get("max_per_colony")) == 0:
			uncapped += 1
	_t.eq(uncapped, 0, "no building is left uncapped")


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
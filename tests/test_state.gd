extends SceneTree
## Headless verification for Phase 2: state graph serialisation round-trip fidelity.
##
##   godot --headless --path . -s res://tests/test_state.gd
##
## The authoritative galaxy must survive JSON round-trips byte-for-byte, because that is
## what save games and network snapshots both rely on.

const DefsScript := preload("res://src/data/defs.gd")

var _t: TestSupport = null
var _defs: Node = null


func _initialize() -> void:
	_t = TestSupport.new()
	# A bare `-s` run registers the autoload but never calls load_all() on it. Load it
	# so code that resolves `Defs` from the scene tree (e.g. GalaxyState.rebind) works
	# exactly as it does in a real session, instead of the test using a private copy.
	_defs = root.get_node_or_null("Defs")
	if _defs == null:
		_defs = DefsScript.new()
		_defs.name = "Defs"
		root.add_child(_defs)
	_defs.call("load_all")

	_test_planet_state_roundtrip()
	_test_system_state_roundtrip()
	_test_fleet_state_roundtrip()
	_test_faction_state_roundtrip()
	_test_galaxy_json_roundtrip(_defs)
	_test_fingerprint_stability()
	_test_malformed_payloads_are_rejected()

	var code := _t.finish("test_state")
	print("---test_state-exit=%d---" % code)
	_defs.queue_free()
	quit(code)


# --- Builders ------------------------------------------------------------------

func _make_planet() -> PlanetState:
	var p := PlanetState.new()
	p.index = 7
	p.type_id = &"terrestrial"
	p.orbit = 2
	p.owner = 1
	p.colonized = true
	p.population = 4.25
	p.structures = {&"mine": 3, &"farm": 5, &"shipyard": 1}
	p.reserve_metals = 120.5
	p.reserve_rare = 44.25
	p.reserve_energy = 88.0
	p.terraform_progress = 0.25
	p.building_queue = {&"factory": 1}
	p.build_turns_remaining = 3
	p.shipyard_progress = 12.5
	p.ship_queue = [{"hull": &"scout", "turns": 2}]
	p.food_stock = 9.5
	p.surveyed = true
	p.bind_type(_defs.call("planet_type", &"terrestrial"))
	return p


func _make_system() -> SystemState:
	var s := SystemState.new()
	s.index = 3
	s.name = "Rigel"
	s.star_class = 5
	s.position = Vector2(12.5, -4.25)
	s.planet_indices = PackedInt32Array([7, 8, 9])
	s.warp_lanes = PackedInt32Array([1, 4, 5])
	s.owner = 1
	s.strategic_value = 0.8
	return s


func _make_fleet(defs: Node) -> FleetState:
	var f := FleetState.new()
	f.owner = 1
	f.system = 3
	f.destination = -1
	f.travelled = 0.0
	f.morale = 0.85
	f.cargo = {"metals": 12.0, "troops": 1.0}
	f.ships = {&"cruiser": 2, &"scout": 1}
	f.name = "First Expedition"
	f.bind_hulls(defs.get("ship_hulls"))
	f.id = 5
	return f


func _make_galaxy(defs: Node) -> GalaxyState:
	var g := GalaxyState.new()
	g.turn = 12
	g.seed_value = 4242
	g.rng_state = 99
	# Handing the fleet its id via add_fleet() advances the counter to 10.
	g.next_fleet_id = 9

	var p := _make_planet()
	var s := _make_system()
	g.planets.append(p)
	g.systems.append(s)

	var f := _make_fleet(defs)
	g.add_fleet(f)

	var fac := FactionState.new()
	fac.id = 1
	fac.name = "Terran Dominion"
	fac.treasury = 543.25
	fac.metals = 100.0
	fac.rare_elements = 50.0
	fac.energy = 25.0
	fac.tax_rate = 0.4
	fac.researched = {&"hyperdrive": true, &"hydroponics": true}
	fac.unlocked_ships = {&"scout": true}
	fac.unlocked_buildings = {&"farm": true}
	fac.tech_points = PackedFloat64Array([10.0, 20.0, 30.0, 40.0])
	fac.research_allocation = PackedFloat64Array([0.1, 0.2, 0.3, 0.4])
	fac.systems = PackedInt32Array([3])
	fac.last_income = 80.0
	fac.last_expenses = 30.0
	fac.last_net = 50.0
	fac.ai_target_system = 3
	fac.ai_mood = 0.65
	g.factions.append(fac)

	g.claim_system(1, 3)
	g.visible_systems = {1: {3: true, 4: true}}
	g.surveyed_systems = {1: {3: true}}
	g.add_news("Terran Dominion founded at Rigel.")
	return g


# --- Tests ---------------------------------------------------------------------

func _test_planet_state_roundtrip() -> void:
	_t.begin("PlanetState round-trip")
	var original := _make_planet()
	var restored := PlanetState.new()
	_t.ok(restored.from_dict(original.to_dict()), "from_dict accepts a valid payload")
	_t.eq(restored.fingerprint(), original.fingerprint(), "planet fingerprint survives the round-trip")
	_t.eq(restored.population, 4.25, "population preserved")
	_t.eq(int(restored.structures[&"farm"]), 5, "structure counts preserved")
	_t.near(restored.terraform_progress, 0.25, 0.0, "terraform progress preserved")
	_t.ok(restored.surveyed, "survey flag preserved")
	_t.ok(restored.from_dict(original.to_dict()), "re-applying a payload is idempotent")
	# Types are not serialised; the caller rebinds them. Prove the id survives so the
	# rebind has something to resolve.
	_t.eq(restored.type_id, &"terrestrial", "the type id survives the round-trip")

	# Gas giants must remain locked.
	var gas := PlanetState.new()
	gas.index = 0
	gas.type_id = &"gas_giant"
	gas.bind_type(_defs.call("planet_type", &"gas_giant"))
	_t.ok(not gas.is_colonizable(), "gas giants are not colonisable at start")
	_t.eq(gas.max_population(), 0.0, "gas giants have zero max population")


func _test_system_state_roundtrip() -> void:
	_t.begin("SystemState round-trip")
	var original := _make_system()
	var restored := SystemState.new()
	_t.ok(restored.from_dict(original.to_dict()), "from_dict accepts a valid payload")
	_t.eq(restored.fingerprint(), original.fingerprint(), "system fingerprint survives the round-trip")
	_t.eq(restored.name, "Rigel", "name preserved")
	_t.near(restored.position.x, 12.5, 0.0, "position x preserved")
	_t.near(restored.position.y, -4.25, 0.0, "position y preserved")
	_t.eq(restored.body_count(), 3, "body count preserved")

	# Warp lanes are a set; add must not duplicate or self-link.
	var s := _make_system()
	s.add_warp_lane(9)
	s.add_warp_lane(9)
	s.add_warp_lane(3)
	_t.eq(s.warp_lanes.count(9), 1, "add_warp_lane ignores duplicates")
	_t.ok(not s.has_warp_lane_to(3), "a system cannot warp-lane to itself")
	_t.near(original.distance_to(restored), 0.0, 0.0001, "distance to an identical copy is zero")


func _test_fleet_state_roundtrip() -> void:
	_t.begin("FleetState round-trip")
	var original := _make_fleet(_defs)
	var restored := FleetState.new()
	restored.bind_hulls(_defs.get("ship_hulls"))
	_t.ok(restored.from_dict(original.to_dict()), "from_dict accepts a valid payload")
	_t.eq(restored.fingerprint(), original.fingerprint(), "fleet fingerprint survives the round-trip")
	_t.eq(restored.ship_count(), 3, "ship count preserved")
	_t.near(restored.base_hull_points(), 2 * 34.0 + 6.0, 0.001, "hull points recompute correctly")
	_t.near(restored.morale, 0.85, 0.0, "morale preserved")

	# Composition queries the resolver depends on.
	_t.ok(restored.add_ships(&"scout", 2), "adding ships succeeds")
	_t.eq(restored.ship_count(), 5, "ships added")
	_t.ok(not restored.add_ships(&"nonexistent_hull", 1), "adding an unknown hull is rejected")
	_t.eq(restored.ship_count(), 5, "the rejected add changed nothing")
	_t.eq(restored.remove_ships(&"scout", 99), 3, "removal is capped at the ships held")
	_t.eq(restored.ship_count(), 2, "remaining ships correct")

	# Cargo cannot exceed capacity. A fresh cruiser+scout fleet carries 24 units of
	# capacity (20 + 4); loading 60 must report no free space.
	var cargoed := _make_fleet(_defs)
	cargoed.cargo = {"metals": 60.0}
	_t.near(cargoed.cargo_capacity(), 44.0, 0.001, "cargo capacity sums the member hulls")
	_t.near(cargoed.free_cargo(), 0.0, 0.001, "an overloaded fleet has no free cargo space")
	cargoed.cargo = {"metals": 10.0}
	_t.near(cargoed.free_cargo(), 34.0, 0.001, "free cargo tracks the load")
	cargoed.cargo = {"metals": -5.0}
	_t.near(cargoed.free_cargo(), 44.0, 0.001, "a negative load cannot inflate capacity")


func _test_faction_state_roundtrip() -> void:
	_t.begin("FactionState round-trip")
	var original := FactionState.new()
	original.id = 2
	original.name = "Free Traders"
	original.treasury = 100.5
	original.researched = {&"hyperdrive": true}
	original.tech_points = PackedFloat64Array([1.0, 2.0, 3.0, 4.0])
	original.research_allocation = PackedFloat64Array([1.0, 1.0, 1.0, 1.0])

	var restored := FactionState.new()
	_t.ok(restored.from_dict(original.to_dict()), "from_dict accepts a valid payload")
	_t.eq(restored.fingerprint(), original.fingerprint(), "faction fingerprint survives the round-trip")
	_t.near(restored.treasury, 100.5, 0.0, "treasury preserved")
	_t.ok(restored.researched.has(&"hyperdrive"), "researched tech preserved")
	_t.near(restored.total_tech_points(), 10.0, 0.001, "tech points total preserved")

	# Allocation must stay normalised across the wire.
	restored.normalize_allocation()
	_t.near(
		restored.research_allocation[0] + restored.research_allocation[1]
			+ restored.research_allocation[2] + restored.research_allocation[3],
		1.0, 0.0001, "research allocation renormalises to sum 1.0")

	# A zero vector must not divide by zero.
	var zeroed := FactionState.new()
	zeroed.research_allocation = PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	zeroed.normalize_allocation()
	_t.near(zeroed.research_allocation[0], 0.25, 0.0001, "a zero allocation becomes an even split")

	# Liveness.
	var alive := FactionState.new()
	alive.systems = PackedInt32Array([1, 2])
	_t.ok(alive.is_alive(), "a faction with systems is alive")
	var dead := FactionState.new()
	dead.defeated = true
	_t.ok(not dead.is_alive(), "a defeated faction is not alive")


func _test_galaxy_json_roundtrip(defs: Node) -> void:
	_t.begin("GalaxyState JSON round-trip")
	var original := _make_galaxy(_defs)
	var text := original.to_json()
	_t.ok(text.length() > 0, "to_json produced output")

	var restored := GalaxyState.new()
	_t.ok(restored.from_json(text), "from_json accepts valid output")
	_t.ok(restored.call("rebind_definitions", defs), "definitions rebind after load")
	_t.eq(restored.fingerprint(), original.fingerprint(), "galaxy fingerprint survives JSON round-trip")
	_t.eq(restored.turn, 12, "turn preserved")
	_t.eq(restored.seed_value, 4242, "seed preserved")
	_t.eq(restored.systems.size(), 1, "system count preserved")
	_t.eq(restored.planets.size(), 1, "planet count preserved")
	_t.eq(restored.fleets.size(), 1, "fleet count preserved")
	_t.eq(restored.factions.size(), 1, "faction count preserved")
	_t.eq(restored.next_fleet_id, 10, "the fleet id counter survives")
	_t.eq(restored.news_log.size(), 1, "the news log survives")
	_t.ok(restored.visible_systems.has(1), "fog-of-war set survives")
	_t.eq(int((restored.visible_systems[1] as Dictionary).size()), 2, "visible system entries preserved")

	# A second round-trip must be a fixed point.
	var third := GalaxyState.new()
	_t.ok(third.from_json(restored.to_json()), "second round-trip succeeds")
	third.call("rebind_definitions", defs)
	_t.eq(third.fingerprint(), original.fingerprint(), "round-trip is a fixed point")

	# The rebound planet must derive the same economy numbers as before the round-trip.
	# Terrestrial base habitability 0.92 plus terraforming 0.25 * 0.4 = 1.0 exactly,
	# so max population saturates at the cap.
	var reloaded_planet: PlanetState = restored.planets[0]
	_t.ok(reloaded_planet.type_data() != null, "a restored planet re-resolves its type definition")
	_t.ok(reloaded_planet.is_colonizable(), "a restored terrestrial body is colonisable again")
	_t.near(reloaded_planet.habitability(), 1.0, 0.001, "terraformed habitability recomputes")
	_t.near(reloaded_planet.max_population(), 20.0, 0.01, "max population recomputes after rebind")

	# The fleet must re-resolve its hulls, or combat totals silently become zero.
	var reloaded_fleet: FleetState = restored.fleets.values()[0] as FleetState
	_t.near(reloaded_fleet.base_hull_points(), 2 * 34.0 + 6.0, 0.001, "hull points survive the rebind")

	# Faction tech effects must resolve without the autoload being present.
	var reloaded_faction: FactionState = restored.factions[0]
	_t.near(reloaded_faction.tech_effect(&"movement"), 4.0, 0.001, "hyperdrive's movement resolves")
	_t.near(reloaded_faction.tech_effect(&"food_bonus"), 0.25, 0.001, "hydroponics' food bonus resolves")
	_t.near(
		reloaded_faction.tech_effect(&"shield_bonus"), 0.0, 0.001,
		"unresearched fields contribute nothing")

	# JSON must contain no Godot-only constructs that would break other clients.
	var parsed: Variant = JSON.parse_string(text)
	_t.ok(parsed is Dictionary, "the payload parses as a JSON object")
	_t.ok(not text.contains("Object("), "no engine object references leak into the JSON")
	_t.ok(not text.contains("Resource("), "no resource references leak into the JSON")


func _test_fingerprint_stability() -> void:
	_t.begin("fingerprint stability")
	var a := _make_galaxy(_defs)
	var b := _make_galaxy(_defs)
	_t.eq(a.fingerprint(), b.fingerprint(), "identically built galaxies fingerprint the same")
	_t.eq(a.state_hash(), b.state_hash(), "and produce the same state hash")

	# Fingerprints must be order-independent where the underlying data is a set.
	var c := _make_galaxy(_defs)
	var f: FleetState = c.fleets.values()[0] as FleetState
	f.ships = {&"scout": 1, &"cruiser": 2}
	_t.eq(c.fingerprint(), a.fingerprint(), "ship composition order does not change the fingerprint")

	# A real change must move the hash.
	var d := _make_galaxy(_defs)
	(d.planets[0] as PlanetState).population += 0.5
	_t.ok(d.state_hash() != a.state_hash(), "a population change moves the state hash")


func _test_malformed_payloads_are_rejected() -> void:
	_t.begin("malformed payloads are rejected")

	var g := GalaxyState.new()
	_t.expect_guard("a payload with no systems is rejected", func() -> Variant:
		return g.from_dict({"planets": []})
	)
	_t.expect_guard("a payload with no planets is rejected", func() -> Variant:
		return g.from_dict({"systems": []})
	)
	_t.expect_guard("a wrong save version is rejected", func() -> Variant:
		return g.from_dict({"version": 999, "systems": [], "planets": []})
	)
	_t.expect_guard("non-JSON text is rejected", func() -> Variant:
		return g.from_json("this is not json")
	)

	# A rejected load must leave the galaxy untouched rather than half-built.
	_t.eq(g.systems.size(), 0, "the galaxy is still empty after failed loads")
	_t.eq(g.planets.size(), 0, "no planets were partially restored")

	var bad_planet := PlanetState.new()
	_t.expect_guard("a planet payload with no index is rejected", func() -> Variant:
		return bad_planet.from_dict({"type_id": &"desert"})
	)
	var bad_system := SystemState.new()
	_t.expect_guard("a system payload with no position is rejected", func() -> Variant:
		return bad_system.from_dict({"index": 1})
	)
	var bad_fleet := FleetState.new()
	_t.expect_guard("a fleet payload with no ships is rejected", func() -> Variant:
		return bad_fleet.from_dict({"id": 1})
	)
	var bad_faction := FactionState.new()
	_t.expect_guard("a faction payload with no id is rejected", func() -> Variant:
		return bad_faction.from_dict({"name": "Nobody"})
	)

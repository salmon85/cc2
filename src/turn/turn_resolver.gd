extends RefCounted
class_name TurnResolver
## Orchestrates the five turn-resolution stages in the order fixed by GAME_SPEC.md:
##
##   1. Movement       orders execute, fleets arrive, engagements are found
##   2. Combat         each engagement resolves to a winner, then survivors invade
##   3. Colony Sim     economy runs for every colony, upkeeps are paid
##   4. Research       tech points accumulate and nodes complete
##   5. Fog of War     each faction's visibility is recomputed
##
## The resolver owns no mutable state of its own. Everything it needs lives on the
## `GalaxyState` handed to `resolve_turn`, which keeps single-player, dedicated server and
## client runs running byte-identical code paths.

## The five stages, in resolution order. Invasion is folded into the combat stage because
## it acts on the fleets combat leaves behind. Exposed so tests can assert the order
## without reaching into internals.
const STAGE_ORDER: Array[String] = [
	"movement", "combat", "invasion", "colony_sim", "research", "fow",
]


## Resolve exactly one turn.
##
## `orders` are the player/AI orders submitted this turn. Returns a report dictionary
## describing what happened, suitable for logging or sending to a client.
static func resolve_turn(
	galaxy: GalaxyState,
	orders: Array,
	defs: Node,
	db: Node,
	rng: RandomNumberGenerator,
	player_faction: int = 0,
) -> Dictionary:
	var report := {
		"turn": galaxy.turn + 1,
		"news": PackedStringArray(),
		"combat": [],
		"captures": 0,
		"eliminated": PackedInt32Array(),
	}

	# --- 1. Movement -------------------------------------------------------
	var moved := MovementStage.advance(galaxy)
	report["moved_fleets"] = moved

	# Fleet orders first: movement is the stage that honours them, so applying them
	# here keeps "orders execute, then fleets move" the documented order.
	for order in orders:
		_apply_order(galaxy, order, defs, db)
		report["news"].append(order.describe())

	# --- 2. Combat ---------------------------------------------------------
	for pair in MovementStage.find_engagements(galaxy):
		var line := CombatStage.resolve_pair(galaxy, pair[0], pair[1], rng, db, defs)
		if not line.is_empty():
			report["news"].append(line)

	# Survivors of the space battle press the attack on the ground.
	var invasions := InvasionStage.resolve_all(galaxy, defs, db, rng)
	for line in invasions:
		report["captures"] += 1
		report["news"].append(line)

	# --- 3. Colony Simulation ----------------------------------------------
	var income := 0.0
	for f in galaxy.factions:
		if f.defeated:
			continue
		income += ColonySim.simulate_faction(galaxy, f, defs, db)

	# --- 4. Research -------------------------------------------------------
	# Every surviving faction accumulates from its own surplus, then buys whatever it
	# can now afford. Research is not a player-only subsystem in this game: AI empires
	# must advance their tech tree too, or they never become a threat.
	var research_total := 0.0
	for researching in galaxy.factions:
		if researching.defeated:
			continue
		research_total += ResearchStage.accumulate(researching, galaxy, db)
		for completed in ResearchStage.complete_available(researching, defs):
			var line := ResearchStage.describe_completion(researching, completed, defs)
			if researching.id == player_faction:
				report["news"].append(line)
			else:
				# The player learns of foreign progress only as a rumour.
				report["news"].append(
					"Word reaches us that %s has made a discovery." % researching.name)
	report["research_granted"] = research_total

	# --- 5. Fog of War -----------------------------------------------------
	for f in galaxy.factions:
		FowStage.update_visibility(galaxy, f.id, db)

	# --- Turn bookkeeping ---------------------------------------------------
	galaxy.turn += 1
	var eliminated := _check_elimination(galaxy)
	report["eliminated"] = eliminated
	for id in eliminated:
		var f: FactionState = galaxy.faction(int(id)) as FactionState
		if f != null:
			report["news"].append("%s has been destroyed." % f.name)

	for line in report["news"]:
		galaxy.add_news(String(line))

	# Persist the RNG so a reloaded game continues the same stream.
	galaxy.rng_state = rng.state
	report["state_hash"] = galaxy.state_hash()
	report["total_income"] = income
	return report


## Apply one order to the galaxy. Unknown or illegal orders are ignored by the
## individual stages rather than raising: the caller decides whether to surface them.
static func _apply_order(
	galaxy: GalaxyState, order: Order, defs: Node, db: Node
) -> void:
	if order == null:
		return
	var faction: FactionState = galaxy.faction(order.faction) as FactionState
	if faction == null or faction.defeated:
		return

	match order.type:
		Enums.OrderType.MOVE_FLEET:
			var fleet: FleetState = galaxy.fleet(order.fleet) as FleetState
			if fleet != null and fleet.owner == order.faction:
				MovementStage.issue_move(galaxy, order.fleet, order.faction, order.target_planet)
		Enums.OrderType.BUILD_SHIP:
			_apply_build_ship(galaxy, faction, order, defs, db)
		Enums.OrderType.BUILD_STRUCTURE:
			_apply_build_structure(galaxy, faction, order, defs, db)
		Enums.OrderType.SET_TAX:
			if order.payload.has("rate"):
				faction.tax_rate = clampf(float(order.payload["rate"]), 0.0, 1.0)
		Enums.OrderType.SET_RESEARCH:
			if order.payload.has("allocation") and order.payload["allocation"] is Array:
				var raw: Array = order.payload["allocation"]
				for field in range(mini(raw.size(), 4)):
					faction.research_allocation[field] = clampf(float(raw[field]), 0.0, 1.0)
		Enums.OrderType.CANCEL_BUILD:
			var planet: PlanetState = galaxy.planet(order.target_planet) as PlanetState
			if planet != null and planet.owner == order.faction:
				planet.building_queue.clear()
				planet.build_turns_remaining = 0
		_:
			pass


static func _apply_build_ship(
	galaxy: GalaxyState, faction: FactionState, order: Order, defs: Node, db: Node
) -> void:
	var planet: PlanetState = galaxy.planet(order.target_planet) as PlanetState
	if planet == null or planet.owner != order.faction:
		return
	var hull_id := StringName(str(order.payload.get("hull", "")))
	var hull: Resource = defs.ship_hull(hull_id) as Resource
	if hull == null:
		return
	if not faction.unlocked_ships.has(hull_id):
		return
	if planet.shipyard_progress < 1.0:
		return
	planet.ship_queue.append({"hull": String(hull_id), "turns": int(hull.get("build_turns"))})
	planet.build_turns_remaining = int(hull.get("build_turns"))


static func _apply_build_structure(
	galaxy: GalaxyState, faction: FactionState, order: Order, defs: Node, db: Node
) -> void:
	var planet: PlanetState = galaxy.planet(order.target_planet) as PlanetState
	if planet == null or planet.owner != order.faction:
		return
	var building_id := StringName(str(order.payload.get("building", "")))
	var building: Resource = defs.building(building_id) as Resource
	if building == null:
		return
	if not faction.unlocked_buildings.has(building_id):
		return
	var existing := planet.count(building_id)
	if not building.can_add(existing):
		return
	# Queue it rather than granting it now: the structure appears only once
	# ColonySim has worked through build_turns_remaining.
	planet.building_queue[building_id] = int(planet.building_queue.get(building_id, 0)) + 1
	planet.build_turns_remaining = int(building.get("build_turns"))


## Mark factions with neither fleets nor colonies as defeated. Returns their ids.
static func _check_elimination(galaxy: GalaxyState) -> PackedInt32Array:
	var eliminated := PackedInt32Array()
	for faction in galaxy.factions:
		if faction.defeated:
			continue
		if faction.id == 0:
			continue  # the human player is never auto-eliminated
		var alive := false
		for fleet in galaxy.fleets_of(faction.id):
			if fleet.active:
				alive = true
				break
		if not alive and galaxy.colonies_of(faction.id).is_empty():
			faction.defeated = true
			eliminated.append(faction.id)
	return eliminated
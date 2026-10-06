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
	"movement", "combat", "suppress_defenses", "invasion", "colony_sim", "research", "fow",
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

	# --- 2. Orbital combat --------------------------------------------------
	#   1. Space engagement      fleets in the same orbit fight
	#   2. Defence suppression    the winner knocks the planetary batteries down
	#   3. Ground assault         troops land against the garrison
	#
	# The three run in that order and cannot be reordered by a caller, which is the whole
	# sequencing claim of the design document. Nothing in step 3 runs until step 2 has
	# finished, so a colony with batteries still standing is genuinely unreachable rather
	# than merely expensive.
	for pair in MovementStage.find_engagements(galaxy):
		var line := CombatStage.resolve_pair(galaxy, pair[0], pair[1], rng, db, defs)
		if not line.is_empty():
			report["news"].append(line)

	var suppressed := CombatStage.suppress_defenses(galaxy, rng, db, defs)
	for line in suppressed:
		report["news"].append(line)

	var invasions := InvasionStage.resolve_all(galaxy, defs, db, rng)
	for line in invasions:
		report["captures"] += 1
		report["news"].append(line)

	# --- 4. Colony Simulation ----------------------------------------------
	# The authoritative stream is passed through: the 50% starvation and growth rolls are
	# the first genuinely random colony outcomes, and they must replay identically from a
	# save or a network snapshot.
	var income := 0.0
	for f in galaxy.factions:
		if f.defeated:
			continue
		income += ColonySim.simulate_faction(galaxy, f, defs, db, rng)

# --- 5. Research -------------------------------------------------------
	# Research is passive and population-driven as of Phase 8: no sliders, no budget the
	# player divides. Each faction's civilians produce points, those points complete nodes,
	# and crossing a population milestone unlocks hulls. AI empires advance identically, or
	# they would never become a threat and the population ladder would mean nothing to a
	# player fighting one.
	var research_total := 0.0
	for researching in galaxy.factions:
		if researching.defeated:
			continue
		researching.last_research_granted = ResearchStage.accumulate(
			researching, galaxy, defs, db)
		research_total += researching.last_research_granted
		for completed in ResearchStage.complete_available(researching, defs):
			var line := ResearchStage.describe_completion(researching, completed, defs)
			if researching.id == player_faction:
				report["news"].append(line)
			# A foreign empire's research is deliberately *not* announced. It used to post
			# "Word reaches us that X has made a discovery" once per node per empire per turn,
			# which in a four-empire game buried the player's own news under lines about
			# strangers' science -- and told them nothing actionable, since the node is not
			# even named. A rival's technology is learned by meeting their fleet.
		var milestone_hulls := ResearchStage.apply_milestones(
			researching, _civilian_pop(galaxy, researching.id), defs, db)
		# Only the player's own unlocks are announced, for the same reason rival research is
		# not: a line about an empire crossing a population threshold tells the player nothing
		# they can act on, and four empires crossing several thresholds a turn fills the feed
		# with it. A rival's fleet size is learned by meeting the fleet.
		if researching.id == player_faction:
			for hull_id in milestone_hulls:
				report["news"].append("%s has reached a population milestone: %s is now buildable." % [
					researching.name, Enums.ship_role_name(_role_of(defs, hull_id))])
	report["research_granted"] = research_total

# --- 6. Fog of War -----------------------------------------------------
	# Surveys first: a world a parked Exploration Ship just surveyed should be known by the
	# time visibility is recomputed, or a survey completed this turn would not be drawable
	# until the next.
	for f in galaxy.factions:
		if f.defeated:
			continue
		FowStage.advance_surveys(galaxy, f.id, rng)
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
		Enums.OrderType.TRAVEL:
			_apply_travel(galaxy, faction, order)
		Enums.OrderType.BUILD_SHIP:
			_apply_build_ship(galaxy, faction, order, defs, db)
		Enums.OrderType.BUILD_STRUCTURE:
			_apply_build_structure(galaxy, faction, order, defs, db)
		Enums.OrderType.RECRUIT_TROOP:
			_apply_recruit_troop(galaxy, faction, order, defs)
		Enums.OrderType.BOOST_BUILD:
			_apply_boost_build(galaxy, faction, order, defs)
		Enums.OrderType.SET_BUILD_MODE:
			var mode_planet: PlanetState = galaxy.planet(order.target_planet) as PlanetState
			if mode_planet != null and mode_planet.owner == order.faction:
				mode_planet.build_mode = int(order.payload.get("mode", 0))
		Enums.OrderType.LOAD_CARGO:
			_apply_cargo(galaxy, faction, order, true)
		Enums.OrderType.UNLOAD_CARGO:
			_apply_cargo(galaxy, faction, order, false)
		Enums.OrderType.CANCEL_BUILD:
			var planet: PlanetState = galaxy.planet(order.target_planet) as PlanetState
			if planet != null and planet.owner == order.faction:
				planet.building_queue.clear()
				planet.build_turns_remaining = 0
				planet.build_metal = 0.0
		_:
			# SET_TAX and SET_RESEARCH were Phase 7 orders and are now inert: the tax slider
			# and the research allocation sliders are both gone from the UI, and research is
			# driven by population. They are still accepted on the wire so a client from
			# before this phase does not crash the resolver -- it just does nothing.
			pass


## Move a chosen set of ships from their current world to a destination.
##
## The Phase 8 travel order carries an explicit ship manifest rather than naming a whole
## fleet, because the travel modal lets a player send "the two corvettes and the troop
## transport" and leave the dreadnought behind. The manifest is a `{hull_id: count}` map,
## clamped to what the fleet actually holds.
static func _apply_travel(
	galaxy: GalaxyState, faction: FactionState, order: Order
) -> void:
	var fleet: FleetState = galaxy.fleet(order.fleet) as FleetState
	if fleet == null or fleet.owner != order.faction or not fleet.active:
		return
	if fleet.destination >= 0:
		return
	var dest: PlanetState = galaxy.planet(order.target_planet)
	if dest == null or dest.index == fleet.system:
		return

	var manifest: Dictionary = order.payload.get("ships", {}) as Dictionary
	if manifest.is_empty():
		# An empty manifest means the whole fleet, which is what a plain move order means.
		MovementStage.issue_move(galaxy, order.fleet, order.faction, order.target_planet)
		return

	# A partial manifest splits the fleet: the ships named travel, the rest stay. The
	# remainder becomes a new fleet rather than being silently left behind in the old one,
	# so the player can still order it somewhere.
	var travelling := FleetState.new()
	travelling.bind_hulls(fleet.hulls())
	travelling.owner = fleet.owner
	travelling.name = fleet.name
	for key: Variant in manifest:
		var hull_id := StringName(str(key))
		var want := int(manifest[key])
		var have := int(fleet.ships.get(hull_id, 0))
		var taken := mini(want, have)
		if taken <= 0:
			continue
		fleet.remove_ships(hull_id, taken)
		travelling.ships[hull_id] = taken
	if travelling.ship_count() <= 0:
		return
	galaxy.add_fleet(travelling)
	MovementStage.issue_move(galaxy, travelling.id, order.faction, order.target_planet)
	if fleet.ship_count() <= 0:
		galaxy.remove_fleet(fleet.id)


## Convert one civilian into one troop. The Barracks is the only place this can happen, and
## the pop is spent whether or not the barracks is fed power -- a Barracks is a staffed
## facility, and refusing the conversion on a power shortage would leave a player with metal
## in the bank and nothing to spend it on.
static func _apply_recruit_troop(
	galaxy: GalaxyState, faction: FactionState, order: Order, defs: Node
) -> void:
	var planet: PlanetState = galaxy.planet(order.target_planet) as PlanetState
	if planet == null or planet.owner != order.faction or not planet.colonized:
		return
	var buildings := defs.get("buildings") as Dictionary
	if planet.count(&"barracks") <= 0:
		return
	if planet.population < 1.0:
		return
	planet.population -= 1.0
	planet.troops += 1


## Spend stored metal against the construction in progress.
##
## The building table is passed so the transfer is capped by what the project still owes.
## The client's dialog already clamps the slider, but an order arrives over the wire from a
## client this build does not control, and the cap has to hold for that too -- otherwise the
## cap is a UI convention rather than a rule.
static func _apply_boost_build(
	galaxy: GalaxyState, faction: FactionState, order: Order, defs: Node
) -> void:
	var planet: PlanetState = galaxy.planet(order.target_planet) as PlanetState
	if planet == null or planet.owner != order.faction:
		return
	var buildings := {} as Dictionary
	if defs != null:
		buildings = defs.get("buildings") as Dictionary
	ColonySim.boost_construction(
		planet, float(order.payload.get("metals", 0.0)), buildings)


## Move food, metal, power or troops between a world and a fleet parked over it.
static func _apply_cargo(
	galaxy: GalaxyState, faction: FactionState, order: Order, loading: bool
) -> void:
	var fleet: FleetState = galaxy.fleet(order.fleet) as FleetState
	if fleet == null or fleet.owner != order.faction or not fleet.active:
		return
	if fleet.destination >= 0 or fleet.system < 0:
		return
	var planet: PlanetState = galaxy.planet(fleet.system)
	if planet == null or planet.owner != faction.id:
		return
	var kind := StringName(str(order.payload.get("kind", "")))
	var amount := float(order.payload.get("amount", 0.0))
	if loading:
		TransferStage.load(planet, fleet, kind, amount)
	else:
		TransferStage.unload(planet, fleet, kind, amount)


## Queue a hull for construction on `planet`.
##
## Three rules, and all three are refusals rather than penalties:
##   - at least one Space Port, per the design document ("At least 1 required to build ships")
##   - `PER_TURN` mode requires the colony to be producing at least the hull's full metal
##     cost every turn, which is the whole condition the mode exists to express
##   - a colony short of power cannot start a power-drawing structure, which is the one
##     consequence running out of power has
static func can_build_ship(
	planet: PlanetState, hull: Resource, faction: FactionState, db: Node
) -> bool:
	if planet == null or hull == null:
		return false
	# "At least 1 required to build ships", per the design document.
	if planet.count(&"space_port") <= 0:
		return false
	# Per-turn mode asks the colony to sustain the hull every turn, so it must be producing
	# at least the full metal cost every turn -- not merely have the metal banked once.
	if planet.build_mode == Enums.BuildMode.PER_TURN:
		if metal_output_per_turn(planet) < float(hull.get("cost_metals")):
			return false
	return true


## The colony's metal output this turn, which is what `PER_TURN` mode is measured against
## and what the planet detail panel shows as the per-turn delta.
##
## Read from the structure table rather than from `reserve_metals`. The stockpile is a balance
## that a colony can top up once and then coast on, which would let a player switch on
## per-turn mode for one turn, queue a fleet, and switch it off again -- the mode would be a
## way of skipping the production requirement rather than a statement about the colony.
##
## With a `buildings` table, staffing is honoured: a mine nobody is working produces nothing.
## The panel passes the table so the number it shows is the number the turn will credit; the
## build gate passes nothing so it cannot be tripped by a definition that failed to load.
static func metal_output_per_turn(
	planet: PlanetState, buildings: Dictionary = {}
) -> float:
	if planet == null:
		return 0.0
	var total := 0.0
	var hands := int(floor(planet.population))
	for building_id: StringName in planet.structures:
		if building_id != &"mine":
			continue
		var count := int(planet.structures[building_id])
		if count <= 0:
			continue
		var per_mine := MINES_PER_STRUCTURE
		if not buildings.is_empty():
			var def: Resource = buildings.get(building_id, null) as Resource
			if def == null:
				continue
			if int(def.get("pop_required")) > 0 and hands <= 0:
				continue
			per_mine = float(def.get("metal_per_turn"))
			if int(def.get("pop_required")) > 0:
				hands -= mini(count, hands)
		total += float(count) * per_mine
	return total


## A Mine makes the design document's fixed 5 metal a turn.
const MINES_PER_STRUCTURE := 5.0


## Whether `planet` may start `building` this turn, and why not if it may not.
##
## The client and the resolver both ask this, which is the point: a build button that looks
## affordable while the resolver quietly drops the order is the defect this replaces. The
## rules, in order, are the one-project-per-turn limit and the power requirement -- the only
## two that can *block* rather than merely price a structure.
static func can_queue_structure(
	planet: PlanetState, building: Resource, faction: FactionState, db: Node
) -> bool:
	if planet == null or building == null:
		return false
	if not planet.building_queue.is_empty():
		return false
	if building.draws_power():
		if not planet.can_supply_power(float(building.get("power_required"))):
			return false
	return true


## Apply a structure order. Public so a test can drive the queue without a full turn.
static func apply_build_structure(
	galaxy: GalaxyState, faction: FactionState, order: Order, defs: Node, db: Node
) -> void:
	_apply_build_structure(galaxy, faction, order, defs, db)


## Apply a troop-recruitment order. Public for the same reason as `apply_build_structure`.
static func apply_recruit_troop(
	galaxy: GalaxyState, faction: FactionState, order: Order, defs: Node
) -> void:
	_apply_recruit_troop(galaxy, faction, order, defs)


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
	if not hull_available(planet, hull_id, faction):
		return
	if not can_build_ship(planet, hull, faction, db):
		return
	planet.ship_queue.append({"hull": String(hull_id), "turns": int(hull.get("build_turns"))})


## Whether `hull_id` can be laid down at `planet` at all, ignoring what it costs.
##
## Two routes to a hull, and they are deliberately different in scope:
##
##   - the empire's own unlocks (population milestones), which apply everywhere; and
##   - a Space Port on *this* world, which hands over the six baseline hulls.
##
## The port route is checked against the planet rather than written into
## `faction.unlocked_ships`. Writing it would grant the hull to every world the empire owns,
## which turns a single berth into an empire-wide research award — and it would not come back
## when the port was lost, since unlocks are monotone.
static func hull_available(
	planet: PlanetState, hull_id: StringName, faction: FactionState
) -> bool:
	if planet == null or faction == null:
		return false
	if faction.unlocked_ships.has(hull_id):
		return true
	return planet.count(&"space_port") > 0 and GameDB.PORT_HULLS.has(hull_id)


## Every hull id layable at `planet`, in `GameDB.HULL_LADDER` order then the remaining
## starters, so a caller rendering a menu lists the same set in the same order.
static func hulls_available_at(planet: PlanetState, faction: FactionState) -> Array[StringName]:
	var out: Array[StringName] = []
	var ladder: Array = GameDB.HULL_LADDER as Array
	for hull_id: Variant in ladder:
		var id := StringName(hull_id)
		if hull_available(planet, id, faction):
			out.append(id)
	for hull_id: Variant in GameDB.PORT_HULLS as Array:
		var id2 := StringName(hull_id)
		if not out.has(id2) and hull_available(planet, id2, faction):
			out.append(id2)
	for hull_id: Variant in GameDB.STARTER_HULLS as Array:
		var id3 := StringName(hull_id)
		if not out.has(id3) and hull_available(planet, id3, faction):
			out.append(id3)
	return out


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
	# Power is the one gate: a colony that cannot feed the structure cannot start it, and
	# nothing else about the existing structures changes when it runs short.
	if building.draws_power():
		var needed := float(building.get("power_required"))
		if not planet.can_supply_power(needed):
			return
	# Exactly one building per turn per planet. The queue is therefore a single slot: a
	# second order for the same planet is refused rather than stacked.
	if not planet.building_queue.is_empty():
		return
	# Queue it rather than granting it now: the structure appears only once
	# ColonySim has worked through build_turns_remaining.
	planet.building_queue[building_id] = int(planet.building_queue.get(building_id, 0)) + 1
	planet.build_turns_remaining = int(building.get("build_turns"))
	# Captured because `build_turns_remaining` counts down, and the per-turn contribution is
	# `cost / total_turns`. Recomputing the denominator each turn would hand every remaining
	# turn an equal share of the whole cost and finish the project in half the time.
	planet.build_total_turns = int(building.get("build_turns"))
	planet.build_metal = 0.0


## Civilian pop across every colony `faction_id` holds. Troops are excluded: the design
## document says troops "do not consume food and do not produce research", so a garrison
## must not be able to level technology.
static func _civilian_pop(galaxy: GalaxyState, faction_id: int) -> float:
	var total := 0.0
	for colony in galaxy.colonies_of(faction_id):
		total += colony.population
	return total


## `Enums.ShipRole` of a hull id, or a neutral role for an unknown id.
##
## Returns the `int` the enum is defined as: every caller reads it straight out of a
## `Resource`, and GDScript has no cast from a `Variant` to an enum by call syntax.
static func _role_of(defs: Node, hull_id: StringName) -> int:
	if defs == null:
		return int(Enums.ShipRole.CARGO)
	var hull: Resource = defs.call("ship_hull", hull_id) as Resource
	if hull == null:
		return int(Enums.ShipRole.CARGO)
	return int(hull.get("role"))


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
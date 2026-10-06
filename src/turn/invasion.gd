extends RefCounted
class_name InvasionStage
## Ground invasion, run after orbital combat and defence suppression whenever a hostile
## fleet sits over an enemy colony it has won the sky over.
##
## Sequence, exactly as the design document sets it out:
##
##   1. Space engagement      the defending fleet is destroyed or absent
##   2. Defence suppression   the attacking ships destroy the planetary batteries
##   3. Ground assault        troops land against the garrison, deterministically
##
## Only step 3 lives here. Steps 1 and 2 are the combat stage's, because a ground battle
## that could be resolved before the batteries fell would mean the batteries did not matter.

## Outcome of one invasion attempt.
class Outcome extends RefCounted:
	var planet_index: int = -1
	var attacker: int = -1
	var captured: bool = false
	var batteries_destroyed: int = 0
	var defender_batteries: int = 0
	var troops_landed: float = 0.0
	var troops_lost: float = 0.0
	var garrison_lost: float = 0.0
	var repelled: bool = false
	var blocked: bool = false
	var block_reason: String = ""


## Attempt to take `planet` with `fleet`.
##
## Returns null when there is nothing to do: no colony, no fleet over it, or a fleet that
## carries no troops and no guns. Returns an `Outcome` with `blocked` set when the assault
## was legal in principle but not yet possible -- planetary batteries still standing, which
## is the whole point of step 2.
static func invade(
	galaxy: GalaxyState,
	fleet: FleetState,
	planet: PlanetState,
	attacker_faction: FactionState,
	defender_faction: FactionState,
	defs: Node,
	db: Node,
	rng: RandomNumberGenerator,
) -> Outcome:
	var result := Outcome.new()
	if planet == null:
		return null
	result.planet_index = planet.index
	result.attacker = fleet.owner

	if not planet.colonized or planet.owner == fleet.owner:
		return null

	# What can be *landed*, which is the troops in the holds -- not the fleet's troop capacity.
	# Four empty Troop Transports have sixteen bays and are worth nothing; the same four
	# loaded with sixteen troops are an army. Reading capacity here was the Phase 7 bug, and
	# it made an empty lift take a world.
	var troops := fleet.troops_carried()
	var guns := fleet.bombardment_power() \
		* (1.0 + attacker_faction.tech_effect(&"bombardment_bonus"))
	if troops <= 0.0 and guns <= 0.0:
		return null

	# --- Step 3 precondition: orbital supremacy --------------------------------
	# A colony is only reachable once every planetary battery has been destroyed. This is
	# the check that makes defence suppression matter: a fleet that has merely *survived*
	# the space fight has still to knock the guns down before anything can land.
	var batteries := planetary_defenses(planet)
	result.defender_batteries = batteries
	if batteries > 0:
		result.blocked = true
		result.block_reason = "planetary defenses still stand"
		return result

	# --- Ground assault ---------------------------------------------------------
	var garrison := planet_garrison(planet, db)
	result.troops_landed = troops
	result.garrison_lost = garrison

	# Deterministic by design. The design document says invading troops "land and engage
	# garrison deterministically", and a roll here would be a genuine correctness problem
	# rather than a balance one: the assault acts on both the fleet's troop manifest and
	# the planet's garrison, so a client that resolved the invasion locally from its own
	# RNG could disagree with the server about who owns a world. Arithmetic cannot.
	#
	# Troops are consumed until the garrison is gone. Whoever has troops left over holds the
	# surface, so an attacker who brings exactly the garrison loses everything and is
	# repelled — the exchange rate is one for one and no technology widens it.
	var surviving := troops - garrison
	if surviving <= 0.0:
		result.repelled = true
		result.troops_lost = troops
		_consume_troops(fleet, troops)
		return result

	result.captured = true
	result.troops_lost = garrison
	_land_troops(fleet, surviving)
	_transfer_colony(galaxy, planet, fleet.owner, attacker_faction, defender_faction)
	# Surviving attackers become the new garrison. A captured world with nobody on it would
	# fall to the next invader that flew past it, which is not what taking a world means.
	planet.troops = int(maxf(1.0, surviving))
	_consume_transports(fleet, 0)

	return result


## Planetary batteries standing on `planet`.
##
## Counted directly rather than through the definition table: the number is what gates the
## invasion, and a colony that has none must read as zero whether or not the definition
## loaded. Reading through `Defs` and getting a null would make an undefended colony look
## defended, which is the worst possible failure of this particular check.
static func planetary_defenses(planet: PlanetState) -> int:
	return planet.count(&"planetary_defense")


## Troops defending `planet`: its standing garrison, plus one for every half-pop of civilians
## that never bothered to build Barracks.
##
## The civilian component is what keeps population relevant in a war. Without it a colony
## with a million people and no Barracks would have no garrison at all, and one troop ship
## would take a world nobody had defended — which would make the entire population economy
## irrelevant to every conflict in the game.
static func planet_garrison(planet: PlanetState, db: Node) -> float:
	var per_pop := float(db.get("GARRISON_TROOPS_PER_POP"))
	return float(planet.troops) + planet.population * per_pop


## Spend `amount` metal against the batteries above `planet`.
##
## Called by the combat stage in step 2, and only once the defending fleet is gone: a colony
## whose sky is still held cannot have its guns knocked out from under it by ships that are
## still being shot at. Returns the number of batteries destroyed.
static func suppress_defenses(
	planet: PlanetState, buildings: Dictionary, firepower: float, rng: RandomNumberGenerator
) -> int:
	var batteries := planetary_defenses(planet)
	if batteries <= 0 or firepower <= 0.0:
		return 0
	var defence: Resource = buildings.get(&"planetary_defense", null) as Resource
	var strength := 1.0 if defence == null else float(defence.get("yield_amount"))

	# Each battery survives the suppression with probability (1 - firepower/strength), which
	# is proportional rather than deterministic: this is orbital bombardment against fixed
	# emplacements, it happens *after* the space fight has already been decided, and it
	# cannot desynchronise a client because the winning fleet is already resolved by then.
	var power: float = clampf(firepower / maxf(1.0, strength), 0.0, 1.0)
	var survivors := 0
	for _i in batteries:
		if rng.randf() >= power:
			survivors += 1
	var destroyed := batteries - survivors
	if survivors <= 0:
		planet.structures.erase(&"planetary_defense")
	else:
		planet.structures[&"planetary_defense"] = survivors
	return destroyed


## Remove `amount` troops from the fleet's troop manifest, lifting whole transports as they
## are emptied.
##
## The manifest is the *carried* troops (`cargo["troops"]`), not the fleet's troop capacity.
## A transport with four bays is worth four troops regardless of how many it actually
## carries, so consuming the manifest first and destroying hulls only once it runs dry is
## what keeps a fleet from losing ships it never filled.
static func _consume_troops(fleet: FleetState, amount: float) -> void:
	if amount <= 0.0:
		return
	var carried := float(fleet.cargo.get("troops", 0.0))
	var from_cargo := minf(carried, amount)
	fleet.cargo["troops"] = carried - from_cargo
	var remaining := amount - from_cargo
	if remaining <= 0.0:
		return
	# Nothing left in the holds, so the lift itself is what is spent.
	_consume_transports(fleet, remaining)


## Empty `amount` troops from the fleet's holds into the world it is over.
static func _land_troops(fleet: FleetState, amount: float) -> void:
	if amount <= 0.0:
		return
	var carried := float(fleet.cargo.get("troops", 0.0))
	if carried <= 0.0:
		return
	var landed := minf(carried, amount)
	fleet.cargo["troops"] = carried - landed


## Spend `losses` worth of troop transport, cheapest first.
static func _consume_transports(fleet: FleetState, losses: float) -> void:
	if losses <= 0.0:
		return
	var remaining := losses
	for key: StringName in fleet.ships.keys():
		if remaining <= 0.0:
			break
		var def: Resource = fleet.hulls().get(key, null) as Resource
		if def == null or float(def.get("troop_capacity")) <= 0.0:
			continue
		var per_ship := float(def.get("troop_capacity"))
		var lost := mini(int(fleet.ships[key]), int(ceil(remaining / maxf(1.0, per_ship))))
		if lost > 0:
			fleet.remove_ships(key, lost)
			remaining -= float(lost) * per_ship
	if fleet.ships.is_empty():
		fleet.active = false


static func _transfer_colony(
	galaxy: GalaxyState, planet: PlanetState, new_owner: int,
	attacker: FactionState, defender: FactionState
) -> void:
	# A captured world starts with the attacker's garrison rather than the defender's; the
	# garrison number itself is set by the caller from the survivors.
	planet.troops = 0
	planet.owner = new_owner
	# Casualties on the surface, and an order that has to be rebuilt.
	planet.population = maxf(0.0, floor(planet.population * 0.6))

	# The system itself only changes hands if this was its last colony. Do this after
	# reassigning the owner, so we ask "does the new owner still hold anything here".
	var system_index := _system_of(galaxy, planet)
	if system_index >= 0:
		var system: SystemState = galaxy.system(system_index)
		if system != null and _has_colony(galaxy, system_index, planet.owner):
			galaxy.claim_system(planet.owner, system_index)

	# The losing empire is credited with the loss, and both sides settle their dead.
	if defender != null:
		defender.colonies_lost += 1
		attacker.colonies_taken += 1


## Consume a Colony Ship parked over `planet`, leaving the structure a landed ship leaves.
##
## The Colony Ship is the only building in the roster that cannot be *built*: it flies here
## and is spent on arrival. That is what makes settling a second world a decision with a ship
## at the end of it rather than a line item.
##
## Returns false and changes nothing when the world cannot take one: it already has one (the
## cap is 1), it is already a colony, or the fleet carries no Colony Ship. The caller reports
## which.
static func land_colony_ship(
	galaxy: GalaxyState, fleet: FleetState, planet: PlanetState, faction: FactionState
) -> bool:
	if planet == null or fleet == null or faction == null:
		return false
	if not fleet.has_colony_ship():
		return false
	# One per world. The ship stays in orbit and the player is told why.
	if planet.count(&"colony_ship_building") > 0:
		return false
	# An inhabited world is not a landing site: there is nobody to settle.
	if planet.colonized:
		return false

	if fleet.remove_ships(&"colony_ship", 1) <= 0:
		return false
	planet.structures[&"colony_ship_building"] = 1
	planet.owner = faction.id
	planet.colonized = true
	planet.surveyed = true
	faction.colonies_founded += 1
	return true


## Whether a Colony Ship parked over `planet` could be landed there right now.
##
## A question rather than an action, so a menu can grey out the entry instead of offering a
## button that silently refuses.
static func can_land_colony_ship(fleet: FleetState, planet: PlanetState) -> bool:
	if planet == null or fleet == null:
		return false
	if not fleet.has_colony_ship():
		return false
	if planet.colonized:
		return false
	return planet.count(&"colony_ship_building") <= 0


static func _has_colony(galaxy: GalaxyState, system_index: int, faction_id: int) -> bool:
	var system: SystemState = galaxy.system(system_index)
	if system == null:
		return false
	for planet_index in system.planet_indices:
		var p: PlanetState = galaxy.planet(planet_index)
		if p != null and p.owner == faction_id and p.colonized:
			return true
	return false


static func _system_of(galaxy: GalaxyState, planet: PlanetState) -> int:
	for system in galaxy.systems:
		if system.planet_indices.has(planet.index):
			return system.index
	return -1


## Scan every contested planet and attempt an invasion on each hostile colony.
##
## Returns news lines.
##
## "Contested" means a hostile fleet is *parked on the world*, not merely in the same system.
## That distinction matters more now than it did: with the whole map under one star,
## "somewhere in this system" spanned every body on the board, and a fleet on the far side
## of a 12000-parsec field would have taken a colony by being in the same room as it.
static func resolve_all(
	galaxy: GalaxyState, defs: Node, db: Node, rng: RandomNumberGenerator
) -> PackedStringArray:
	var lines := PackedStringArray()
	var planet_indices := PackedInt32Array()
	for p in galaxy.planets:
		planet_indices.append(p.index)
	planet_indices.sort()

	for planet_index in planet_indices:
		var planet: PlanetState = galaxy.planet(planet_index)
		if planet == null or not planet.colonized:
			continue
		# An undefended colony is still worth taking: the absence of a defender is not a
		# reason to skip the invasion.
		for fleet in MovementStage.fleets_in_system(galaxy, planet_index, -1):
			if not fleet.active or fleet.owner == planet.owner:
				continue
			var attacker: FactionState = galaxy.faction(fleet.owner)
			var defender: FactionState = galaxy.faction(planet.owner)
			if attacker == null or defender == null:
				continue
			var outcome := invade(galaxy, fleet, planet, attacker, defender, defs, db, rng)
			if outcome == null:
				continue
			if outcome.captured:
				lines.append("%s captured planet %d from %s (%d troops landed)" % [
					attacker.name, planet.index, defender.name,
					int(outcome.troops_landed - outcome.troops_lost)])
			elif outcome.blocked:
				lines.append("%s cannot land on planet %d: %s" % [
					attacker.name, planet.index, outcome.block_reason])
			else:
				lines.append("%s repelled the assault on planet %d" % [
					defender.name, planet.index])
	return lines
extends RefCounted
class_name InvasionStage
## Planetary invasion, run after space combat whenever a hostile fleet sits in a system
## that holds an enemy colony.
##
## Sequence: orbital bombardment strips surface batteries, then transports land ground
## divisions against the garrison.

## Outcome of one invasion attempt.
class Outcome extends RefCounted:
	var planet_index: int = -1
	var attacker: int = -1
	var captured: bool = false
	var batteries_destroyed: int = 0
	var bombardment_damage: float = 0.0
	var ground_losses: float = 0.0
	var defender_losses: float = 0.0
	var repelled: bool = false


## Attempt to take `planet` with `fleet`.
##
## Returns null when there is nothing to do (no colony, no fleet in reach, or the fleet
## carries neither troops nor a bombarder). Otherwise returns the Outcome and applies it.
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
	result.planet_index = planet.index
	result.attacker = fleet.owner

	if planet == null or not planet.colonized or planet.owner == fleet.owner:
		return null

	# A fleet needs either the muscle to flatten the defences or the troops to take the
	# ground; a lone transport with neither has no business here.
	var troops := fleet.troop_capacity()
	var guns := fleet.bombardment_power() * (1.0 + attacker_faction.tech_effect(&"bombardment_bonus"))
	if troops <= 0.0 and guns <= 0.0:
		return null

	var buildings := defs.get("buildings") as Dictionary

	# --- Orbital bombardment ----------------------------------------------
	# Strips surface batteries first, as the design document describes.
	if guns > 0.0:
		var per_round := float(db.get("BOMBARDMENT_DAMAGE_PER_ROUND"))
		var rounds := int(clampf(guns / maxf(1.0, per_round), 1.0, 6.0))
		result.bombardment_damage = guns * rounds * 0.5
		_strip_batteries(planet, buildings, result, rng)

	# --- Ground assault ------------------------------------------------------
	var defense := _ground_defense(planet, buildings, defender_faction)
	var garrison := planet.population * 1.5
	defense += garrison

	var assault: float = troops * float(db.get("GROUND_ATTACKER_MORALE_MULT"))
	assault *= 1.0 + attacker_faction.tech_effect(&"accuracy_bonus")
	defense *= float(db.get("GROUND_DEFENDER_MORALE_MULT"))

	if defense <= 0.0:
		defense = 1.0

	# Total force decides the battle; the RNG decides how decisively.
	var ratio := assault / (assault + defense)
	var victory_roll := rng.randf() * 0.4 + ratio * 0.6

	if victory_roll > 0.5 and assault > 0.0:
		result.captured = true
		result.ground_losses = assault * (1.0 - ratio) * 0.5
		result.defender_losses = defense * ratio * 0.5
		_transfer_colony(galaxy, planet, fleet.owner, attacker_faction, defender_faction)
	else:
		result.repelled = true
		result.ground_losses = assault * 0.5
		result.defender_losses = defense * (1.0 - ratio) * 0.3

	# Transports are expended either way.
	_consume_transports(fleet, result.ground_losses)

	return result


## Bombardment removes batteries in proportion to the firepower brought to bear.
static func _strip_batteries(
	planet: PlanetState, buildings: Dictionary, result: Outcome, rng: RandomNumberGenerator
) -> void:
	var batteries := planet.count(&"missile_battery")
	if batteries <= 0:
		return
	var defence: Resource = buildings.get(&"missile_battery", null) as Resource
	var strength := 1.0 if defence == null else float(defence.get("yield_amount"))

	# Each battery survives the bombardment with probability (1 - firepower/strength).
	var power: float = clampf(result.bombardment_damage / maxf(1.0, strength * 8.0), 0.0, 1.0)
	var survivors := 0
	for _i in batteries:
		if rng.randf() >= power:
			survivors += 1
	var destroyed := batteries - survivors
	result.batteries_destroyed = destroyed
	planet.structures[&"missile_battery"] = survivors
	if survivors == 0:
		planet.structures.erase(&"missile_battery")


## Total ground defence strength: batteries that survived, plus the garrison.
static func _ground_defense(
	planet: PlanetState, buildings: Dictionary, defender_faction: FactionState
) -> float:
	var total := 0.0
	var battery: Resource = buildings.get(&"missile_battery", null) as Resource
	if battery != null:
		total += planet.count(&"missile_battery") * float(battery.get("yield_amount"))
	var garrison_def: Resource = buildings.get(&"garrison", null) as Resource
	if garrison_def != null:
		total += planet.count(&"garrison") * float(garrison_def.get("yield_amount"))
	return total


static func _transfer_colony(
	galaxy: GalaxyState, planet: PlanetState, new_owner: int,
	attacker: FactionState, defender: FactionState
) -> void:
	# Strip the surface of its garrisons; a captured world starts compliant.
	planet.structures.erase(&"garrison")
	planet.owner = new_owner
	# Casualties on both sides and a collapse of order on the surface.
	planet.population *= 0.6

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


## Spend transports carrying the casualties.
static func _consume_transports(fleet: FleetState, losses: float) -> void:
	if losses <= 0.0:
		return
	# Convert troop losses into whole transports lost, cheapest first.
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


## Scan every contested planet and attempt an invasion on each hostile colony.
## Returns news lines.
##
## Contested means a fleet is *parked on the world*, not merely in the same system. That
## distinction did not exist before: with one star, "somewhere in this system" spanned the
## entire map, and a fleet on the far side of a 12000-parsec system would have landed on a
## colony by being in the same room as it. Sitting on a planet is now the price of taking
## it, which is what makes a fleet's final approach a decision.
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
		# Note that an undefended colony is still worth taking: the absence of a defender
		# is not a reason to skip the invasion.
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
				lines.append("%s captured planet %d from %s (%d batteries destroyed)" % [
					attacker.name, planet.index, defender.name, outcome.batteries_destroyed])
			else:
				lines.append("%s repelled the assault on planet %d" % [
					defender.name, planet.index])
	return lines
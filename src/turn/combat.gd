extends RefCounted
class_name CombatStage
## Stage 2 of turn resolution: fleet-versus-fleet engagements.
##
## Resolution follows the classic CC2 sequence the design document describes:
##
##   long-range missile volleys -> medium beam exchange -> point defence / torpedo
##   interception -> dogfighting -> retreat check
##
## Each phase is a bounded exchange so a fight cannot run forever, and every roll comes
## from the single authoritative stream so a replay is exact.

## One engagement's result.
class Engagement extends RefCounted:
	var attacker_id: int = -1
	var defender_id: int = -1
	var outcome: int = 0  # Enums.CombatOutcome
	var rounds: int = 0
	var attacker_losses: int = 0
	var defender_losses: int = 0
	var attacker_retreated: bool = false
	var defender_retreated: bool = false

	## One-line summary for the turn report.
	func describe() -> String:
		var verb := "engaged"
		match outcome:
			1: verb = "exchanged fire with"
			2: verb = "destroyed"
			3: verb = "drove off"
			4: verb = "fled from"
		return "%d v %d: %s over %d round(s), %d/%d lost%s" % [
			attacker_id, defender_id, verb, rounds,
			attacker_losses, defender_losses,
			" (retreat)" if attacker_retreated or defender_retreated else "",
		]


## Effective combat stats for a fleet, after tech multipliers and fleet morale.
class Stats extends RefCounted:
	var hull: float = 0.0
	var shields: float = 0.0
	var weapon: float = 0.0
	var accuracy: float = 0.0
	var morale: float = 1.0


## Build the combat profile of `fleet` for `faction`, applying researched bonuses.
static func stats_for(fleet: FleetState, faction: FactionState) -> Stats:
	var s := Stats.new()
	var hull_mult := faction.stat_multiplier(&"hull_bonus")
	var shield_mult := faction.stat_multiplier(&"shield_bonus")
	var weapon_mult := faction.stat_multiplier(&"weapon_bonus")
	var acc_bonus := faction.tech_effect(&"accuracy_bonus")

	s.hull = fleet.base_hull_points() * hull_mult
	s.shields = fleet.base_shield_points() * shield_mult
	s.weapon = fleet.base_weapon_damage() * weapon_mult
	s.accuracy = clampf(fleet.base_accuracy() + acc_bonus, 0.0, 0.95)
	s.morale = fleet.morale
	return s


## Resolve one engagement between two fleets.
##
## `rng` is the authoritative stream. Returns null when the pairing is not a real
## conflict (same owner, or a fleet that is no longer active).
static func resolve(
	galaxy: GalaxyState,
	attacker: FleetState,
	defender: FleetState,
	faction_a: FactionState,
	faction_d: FactionState,
	rng: RandomNumberGenerator,
	db: Node,
) -> Engagement:
	var result := Engagement.new()
	result.attacker_id = attacker.id
	result.defender_id = defender.id

	if attacker.owner == defender.owner:
		return null
	if not attacker.active or not defender.active:
		return null

	var a := stats_for(attacker, faction_a)
	var d := stats_for(defender, faction_d)

	var a_ships := attacker.ship_count()
	var d_ships := defender.ship_count()

	var max_rounds := int(db.get("MAX_COMBAT_ROUNDS"))
	for _round in max_rounds:
		if not attacker.active or not defender.active:
			break
		result.rounds += 1

		# Phase 1: long-range missile volleys. High accuracy, partial damage.
		_exchange(a, d, rng, float(db.get("MISSILE_ACCURACY")), 0.35, result, true)
		if not attacker.active or not defender.active:
			break

		# Phase 2: medium beam exchange. Full damage, lower accuracy.
		_exchange(a, d, rng, float(db.get("BEAM_ACCURACY")), 1.0, result, false)
		if not attacker.active or not defender.active:
			break

		# Phase 3: point defence intercepts part of the incoming fire.
		var pd := float(db.get("POINT_DEFENSE_ACCURACY"))
		_exchange(a, d, rng, pd, 0.75, result, true)

		# Phase 4: dogfighting. Both sides take losses; morale erodes.
		var dog := float(db.get("DOGFIGHT_ACCURACY"))
		_exchange(a, d, rng, dog, 0.5, result, false)

		# Phase 5: retreat check. A broken side disengages.
		if _check_retreat(attacker, a, rng, float(db.get("FLEET_MORALE_BREAK_THRESHOLD"))):
			result.attacker_retreated = true
			result.outcome = 4
			break
		if _check_retreat(defender, d, rng, float(db.get("FLEET_MORALE_BREAK_THRESHOLD"))):
			result.defender_retreated = true
			result.outcome = 4
			break

	# Commit the accumulated hull damage back onto the real fleets. Without this the
	# engagement would be a no-op: `a` and `d` are working copies.
	_apply_damage(attacker, a, rng)
	_apply_damage(defender, d, rng)

	result.attacker_losses = maxi(0, a_ships - attacker.ship_count())
	result.defender_losses = maxi(0, d_ships - defender.ship_count())

	if result.outcome == 0:
		if not attacker.active:
			result.outcome = 2  # FLEET_DESTROYED
		elif not defender.active:
			result.outcome = 2
		else:
			result.outcome = 1  # ATTRITION

	return result


## One directed volley from `from_stats` into `to_stats`.
##
## `intercept` selects the point-defence phase, where the defender answers with its own
## (weaker) fire and absorbs part of the volley.
static func _exchange(
	a: Stats, d: Stats, rng: RandomNumberGenerator, accuracy: float,
	damage_scale: float, result: Engagement, intercept: bool
) -> void:
	# Attacker fires at the defender.
	var shots := maxf(1.0, a.weapon * accuracy * damage_scale)
	var defender_shield := d.shields
	var to_hull := maxf(0.0, shots - defender_shield)
	if to_hull > 0.0:
		d.shields = maxf(0.0, defender_shield - shots)
		d.hull -= to_hull
	else:
		d.shields = maxf(0.0, defender_shield - shots)

	# Interception: the defender answers, but at reduced weight.
	if intercept:
		var counter := maxf(0.0, d.weapon * accuracy * 0.4)
		var attacker_shield := a.shields
		var to_attacker := maxf(0.0, counter - attacker_shield)
		if to_attacker > 0.0:
			a.shields = maxf(0.0, attacker_shield - counter)
			a.hull -= to_attacker
		else:
			a.shields = maxf(0.0, attacker_shield - counter)


## Whether `fleet` breaks and runs. Uses the authoritative stream so retreats replay.
static func _check_retreat(
	fleet: FleetState, stats: Stats, rng: RandomNumberGenerator, threshold: float
) -> bool:
	if fleet.morale > threshold:
		return false
	return rng.randf() < 0.5


## Write the damage accumulated in a working `Stats` back onto the real fleet.
##
## `apply_damage` rolls per-ship survival, so this both destroys ships and erodes morale.
## A fleet whose hull reaches zero is marked inactive and removed by the caller.
static func _apply_damage(fleet: FleetState, stats: Stats, rng: RandomNumberGenerator) -> void:
	var max_hull := maxf(1.0, stats.hull + stats.shields)
	var missing := clampf(-stats.hull, 0.0, max_hull)
	if missing <= 0.0:
		return
	var fraction: float = missing / max_hull

	for key: StringName in fleet.ships.keys():
		var def: Resource = fleet.hulls().get(key, null) as Resource
		if def == null:
			continue
		var held := int(fleet.ships[key])
		if held <= 0:
			continue
		# Each ship independently survives with probability (1 - fraction).
		var survivors := 0
		for _i in held:
			if rng.randf() >= fraction:
				survivors += 1
		if survivors <= 0:
			fleet.ships.erase(key)
		elif survivors < held:
			fleet.ships[key] = survivors

	# Morale erodes with cumulative damage and recovers slowly otherwise.
	fleet.morale = clampf(fleet.morale - fraction * 0.6, 0.0, 1.0)
	if fleet.ships.is_empty():
		fleet.active = false


## Resolve a whole engagement pair, applying the outcome to the galaxy and returning a
## news line, or "" when nothing happened.
static func resolve_pair(
	galaxy: GalaxyState,
	attacker_id: int,
	defender_id: int,
	rng: RandomNumberGenerator,
	db: Node,
	defs: Node
) -> String:
	var attacker: FleetState = galaxy.fleet(attacker_id)
	var defender: FleetState = galaxy.fleet(defender_id)
	if attacker == null or defender == null:
		return ""
	var fa: FactionState = galaxy.faction(attacker.owner)
	var fd: FactionState = galaxy.faction(defender.owner)
	if fa == null or fd == null:
		return ""

	var engagement := resolve(galaxy, attacker, defender, fa, fd, rng, db)
	if engagement == null:
		return ""

	# Remove whichever fleet was destroyed; a retreating one survives but is no longer
	# contesting the system.
	if not attacker.active:
		galaxy.remove_fleet(attacker.id)
	elif engagement.attacker_retreated:
		_retreat(attacker)
	if not defender.active:
		galaxy.remove_fleet(defender.id)
	elif engagement.defender_retreated:
		_retreat(defender)

	if not attacker.active:
		return "Fleet %d was destroyed by fleet %d after %d round(s) (%d ships lost)" % [
			attacker.id, defender.id, engagement.rounds, engagement.attacker_losses]
	if not defender.active:
		return "Fleet %d was destroyed by fleet %d after %d round(s) (%d ships lost)" % [
			defender.id, attacker.id, engagement.rounds, engagement.defender_losses]
	return "Fleets %d and %d fought for %d round(s): %d and %d ships lost" % [
		attacker.id, defender.id, engagement.rounds,
		engagement.attacker_losses, engagement.defender_losses]


## Step 2 of the orbital sequence: knock the planetary batteries down.
##
## Runs for every world a hostile fleet now holds the sky over. The precondition is orbital
## supremacy, and it is checked here rather than assumed: a planet with a defending fleet
## still in orbit is *not* suppressed, because a colony whose sky is contested cannot have
## its guns destroyed by ships that are still being shot at.
##
## Firepower is the total bombardment the winning fleets bring to bear, scaled by the
## attacker's research bonus, divided among the planets they are actually over — a fleet
## parked over one world does not flatten batteries on the far side of the map.
##
## Returns news lines, one per world whose batteries were touched.
static func suppress_defenses(
	galaxy: GalaxyState, rng: RandomNumberGenerator, db: Node, defs: Node
) -> PackedStringArray:
	var lines := PackedStringArray()
	var buildings := defs.get("buildings") as Dictionary

	var indices := PackedInt32Array()
	for p in galaxy.planets:
		indices.append(p.index)
	indices.sort()

	for planet_index in indices:
		var planet: PlanetState = galaxy.planet(planet_index)
		if planet == null or not planet.colonized:
			continue
		if InvasionStage.planetary_defenses(planet) <= 0:
			continue

		# Orbital supremacy, checked rather than assumed: a fleet belonging to the colony's
		# owner, still parked in its orbit, is shooting back. A colony whose sky is contested
		# is not suppressed no matter how much firepower is aimed at it.
		var defended := false
		var attackers: Array[FleetState] = []
		var firepower := 0.0
		for f in MovementStage.fleets_in_system(galaxy, planet_index, -1):
			if f.owner == planet.owner:
				defended = true
				continue
			attackers.append(f)
			var faction: FactionState = galaxy.faction(f.owner)
			var bonus := 1.0
			if faction != null:
				bonus += faction.tech_effect(&"bombardment_bonus")
			firepower += f.bombardment_power() * bonus
		if attackers.is_empty() or defended:
			continue

		var attacker: FactionState = galaxy.faction(attackers[0].owner)
		var defender: FactionState = galaxy.faction(planet.owner)
		if attacker == null:
			continue
		var destroyed := InvasionStage.suppress_defenses(
			planet, buildings, firepower, rng)
		if destroyed > 0:
			var left := InvasionStage.planetary_defenses(planet)
			lines.append(
				"%s suppressed the planetary defenses of planet %d (%d destroyed, %d left)" % [
					attacker.name, planet_index, destroyed, left])
		if defender != null and InvasionStage.planetary_defenses(planet) == 0:
			lines.append("Planet %d is defenceless: its batteries are gone." % planet_index)
	return lines


## Break contact: the fleet stops contesting the system and loses its move.
static func _retreat(fleet: FleetState) -> void:
	fleet.morale = minf(fleet.morale, GameDB.FLEET_MORALE_BREAK_THRESHOLD)
	fleet.destination = -1
	fleet.travelled = 0.0
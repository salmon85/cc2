extends RefCounted
class_name MovementStage
## Stage 1 of turn resolution: fleets travel, and arriving fleets are handed to whoever
## holds the destination.
##
## Travel is on the authoritative RNG-free path — distance arithmetic only — so movement
## replays identically on every client without transmitting a single float.

## Maximum parsecs a faction's fleets can cover this turn.
static func movement_allowance(faction: FactionState) -> float:
	var base := GameDB.BASE_MOVEMENT + faction.tech_effect(&"movement")
	return clampf(base, 0.0, GameDB.MAX_MOVEMENT)


## Speed of a fleet: the slowest hull, scaled by drive research.
static func fleet_speed(fleet: FleetState, faction: FactionState) -> float:
	var slowest := fleet.base_speed()
	if slowest <= 0.0:
		return 0.0
	# Drive research lifts the slowest hull toward the role cap, not above it.
	var cap := ShipHullData.role_speed_cap(_dominant_role(fleet))
	return minf(slowest + faction.tech_effect(&"movement"), cap)


## Role of the slowest member hull, which is what governs both speed and legal orders.
static func _dominant_role(fleet: FleetState) -> int:
	var worst := 5
	var slowest := INF
	for key: StringName in fleet.ships:
		var def: Resource = fleet.hulls().get(key, null) as Resource
		if def == null:
			continue
		var speed := float(def.get("base_speed"))
		if speed < slowest:
			slowest = speed
			worst = int(def.get("role"))
	return worst


## Issue a move order. Returns false (and changes nothing) when the order is illegal.
##
## The target is a *planet*, not a system. There is one system, so a system target is
## either "where you already are" or "the star", and neither is a move a player would
## recognise as movement. Sending a fleet to a planet is the only legible order left.
static func issue_move(
	galaxy: GalaxyState, fleet_id: int, faction_id: int, target_planet: int
) -> bool:
	var f: FleetState = galaxy.fleet(fleet_id)
	if f == null or not f.active:
		return false
	if f.owner != faction_id:
		return false
	if f.system < 0 or f.destination >= 0:
		return false  # already in transit
	var dest: PlanetState = galaxy.planet(target_planet)
	if dest == null or dest.index == f.system:
		return false

	f.destination = dest.index
	f.travelled = 0.0
	return true


## Advance every travelling fleet by one turn.
##
## Returns the ids of fleets that arrived, in ascending id order so the caller can hand
## them to the combat stage deterministically.
static func advance(galaxy: GalaxyState) -> PackedInt32Array:
	var arrivals := PackedInt32Array()
	var ids := galaxy.fleets.keys()
	ids.sort()

	for id: int in ids:
		var f: FleetState = galaxy.fleets[id] as FleetState
		if f == null or not f.active or f.destination < 0:
			continue

		var owner_state: FactionState = galaxy.faction(f.owner)
		if owner_state == null:
			# Ownerless fleet (should not happen): park it rather than crash.
			f.destination = -1
			continue

		var speed := fleet_speed(f, owner_state)
		var from: PlanetState = galaxy.planet(f.system)
		var to: PlanetState = galaxy.planet(f.destination)
		if from == null or to == null:
			f.destination = -1
			f.travelled = 0.0
			continue

		var distance := orbit_distance(from, to)

		f.travelled += speed
		if f.travelled + 0.0001 >= distance:
			f.system = to.index
			f.destination = -1
			f.travelled = 0.0
			arrivals.append(f.id)

	return arrivals


## Straight-line distance between two planets' orbits, in parsecs.
##
## Because every planet sits on a ring around one star, the distance between two worlds is
## the chord between their orbit points -- the star is in the way geometrically but not
## tactically, so the two bodies are treated as directly reachable.
static func orbit_distance(from: PlanetState, to: PlanetState) -> float:
	return from.position.distance_to(to.position)


## Every active fleet sitting on `planet_index`. Pass -1 for `faction_id` to get them all.
static func fleets_in_system(
	galaxy: GalaxyState, planet_index: int, faction_id: int
) -> Array[FleetState]:
	var out: Array[FleetState] = []
	var ids := galaxy.fleets.keys()
	ids.sort()
	for id: int in ids:
		var f: FleetState = galaxy.fleets[id] as FleetState
		if f == null or not f.active or f.system != planet_index:
			continue
		if faction_id >= 0 and f.owner != faction_id:
			continue
		out.append(f)
	return out


## Every active fleet that is somewhere on the map, in stable id order.
##
## Replaces the old per-system sweep: with one system and no neighbours, "the fleets in
## this system" would have meant "all the fleets", which is the same answer for every
## caller and hides the grouping that combat and invasion actually need.
static func fleets_in_orbit(galaxy: GalaxyState, faction_id: int = -1) -> Array[FleetState]:
	var out: Array[FleetState] = []
	var ids := galaxy.fleets.keys()
	ids.sort()
	for id: int in ids:
		var f: FleetState = galaxy.fleets[id] as FleetState
		if f == null or not f.active or f.system < 0:
			continue
		if faction_id >= 0 and f.owner != faction_id:
			continue
		out.append(f)
	return out


## Pair fleets sharing a planet into engagements, deterministically.
##
## Returns an array of `[attacker_id, defender_id]` pairs. Both sides alternate so no
## faction gets to strike first purely by iteration order.
##
## Sharing an *orbit* is what counts, not sharing a neighbourhood: two fleets pass each other
## 400 parsecs apart and do not fight, which is what stops the whole map becoming one
## battle the moment two empires expand.
static func find_engagements(galaxy: GalaxyState) -> Array:
	var pairs: Array = []
	var by_system: Dictionary = {}

	var ids := galaxy.fleets.keys()
	ids.sort()
	for id: int in ids:
		var f: FleetState = galaxy.fleets[id] as FleetState
		if f == null or not f.active or f.system < 0:
			continue
		if not by_system.has(f.system):
			by_system[f.system] = [] as Array[FleetState]
		(by_system[f.system] as Array).append(f)

	var system_indices := by_system.keys()
	system_indices.sort()
	for sys_index: int in system_indices:
		var fleets: Array = by_system[sys_index]
		# Group by owner, then pair each faction against the others in a stable order.
		var by_owner: Dictionary = {}
		for f: FleetState in fleets:
			if not by_owner.has(f.owner):
				by_owner[f.owner] = [] as Array[FleetState]
			(by_owner[f.owner] as Array).append(f)
		if by_owner.size() < 2:
			continue

		var owners := by_owner.keys()
		owners.sort()
		for i in owners.size():
			for j in range(i + 1, owners.size()):
				for a: FleetState in by_owner[owners[i]]:
					for d: FleetState in by_owner[owners[j]]:
						pairs.append([a.id, d.id])
	return pairs
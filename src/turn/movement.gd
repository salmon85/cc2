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
static func issue_move(
	galaxy: GalaxyState, fleet_id: int, faction_id: int, target_system: int
) -> bool:
	var f: FleetState = galaxy.fleet(fleet_id)
	if f == null or not f.active:
		return false
	if f.owner != faction_id:
		return false
	if f.system < 0 or f.destination >= 0:
		return false  # already in transit
	var dest: SystemState = galaxy.system(target_system)
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
		var from: SystemState = galaxy.system(f.system)
		var to: SystemState = galaxy.system(f.destination)
		if from == null or to == null:
			f.destination = -1
			continue

		# A direct warp lane collapses the distance to a token hop, which is why a
		# mature network moves fleets across the map in a single turn.
		var distance: float = GameDB.WARP_LANE_TRAVEL if from.has_warp_lane_to(to.index) \
			else from.distance_to(to)

		f.travelled += speed
		if f.travelled + 0.0001 >= distance:
			f.system = to.index
			f.destination = -1
			f.travelled = 0.0
			arrivals.append(f.id)

	return arrivals


## Every active fleet sitting in `system_index`. Pass -1 for `faction_id` to get them all.
static func fleets_in_system(
	galaxy: GalaxyState, system_index: int, faction_id: int
) -> Array[FleetState]:
	var out: Array[FleetState] = []
	var ids := galaxy.fleets.keys()
	ids.sort()
	for id: int in ids:
		var f: FleetState = galaxy.fleets[id] as FleetState
		if f == null or not f.active or f.system != system_index:
			continue
		if faction_id >= 0 and f.owner != faction_id:
			continue
		out.append(f)
	return out


## Pair fleets sharing a system into engagements, deterministically.
##
## Returns an array of `[attacker_id, defender_id]` pairs. Both sides alternate so no
## faction gets to strike first purely by iteration order.
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
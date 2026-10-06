extends RefCounted
class_name FowStage
## Stage 5 of turn resolution: sensor sweeps and fog-of-war updates.
##
## A faction sees a system when any of its colonies, orbital stations or fleets is within
## sensor range of it. Results are cached per faction in `GalaxyState.visible_systems`,
## which is what the client renders and what makes scouting a real strategic cost.

## Recompute visible systems for one faction and store the result.
## Returns the set of visible system indices.
static func update_visibility(galaxy: GalaxyState, faction_id: int, db: Node) -> Dictionary:
	# Visibility accumulates rather than being recomputed from scratch. A sensor bubble
	# only ever *adds* knowledge, and rebuilding the set each turn would retroactively
	# blind a faction whose scout has since moved on -- the map would flicker back to
	# darkness the moment a fleet left a system.
	var previous := galaxy.visible_systems.get(faction_id, {}) as Dictionary
	var visible: Dictionary = previous.duplicate()
	var faction: FactionState = galaxy.faction(faction_id)
	if faction == null:
		return visible

	# Sensor reach is quoted at the `extreme` span and scaled to the game's own, so a
	# scout covers the same *proportion* of the system at every map size. Otherwise a
	# `tiny` map would be fully visible from the homeworld and scouting would stop being
	# a decision, while on an `extreme` map one scout would light up a single orbit ring.
	var span := MovementStage.map_factor(galaxy)

	# Colonies and stations project the local bubble.
	var sensor_bonus := faction.tech_effect(&"sensor_range")
	for planet in galaxy.colonies_of(faction_id):
		var system: SystemState = galaxy.system(_system_of(galaxy, planet))
		if system == null:
			continue
		var reach: float = float(db.get("COLONY_SENSOR_RANGE")) * span + sensor_bonus
		_reveal_within(galaxy, system, reach, visible)
		visible[system.index] = true

	# Fleets carry their own sensors: a scout finds systems no colony can.
	for fleet in galaxy.fleets_of(faction_id):
		if fleet.system < 0:
			continue
		var system: SystemState = galaxy.system(_system_of(galaxy, galaxy.planet(fleet.system)))
		if system == null:
			continue
		var reach: float = maxf(
			fleet.base_sensor_range(), float(db.get("FLEET_SENSOR_RANGE"))) * span
		reach += sensor_bonus
		_reveal_within(galaxy, system, reach, visible)
		visible[system.index] = true

	galaxy.visible_systems[faction_id] = visible
	return visible


## Advance the survey of every world a faction's Exploration Ships are sitting over.
##
## The Phase 8 roster makes surveying a *research* activity rather than a side effect of
## being seen: an Exploration Ship contributes 25% per turn, additively across the fleet, so
## two of them survey a world in two turns and one takes four. A fleet that merely sails past
## a world contributes nothing -- it has to be parked over it -- which is what makes holding
## an orbit worth something beyond winning it.
##
## Returns the number of worlds newly surveyed.
static func advance_surveys(galaxy: GalaxyState, faction_id: int, rng: RandomNumberGenerator) -> int:
	var faction: FactionState = galaxy.faction(faction_id)
	if faction == null or rng == null:
		return 0
	var newly := 0
	var surveyed: Dictionary = galaxy.surveyed_systems.get(faction_id, {}) as Dictionary

	for fleet in galaxy.fleets_of(faction_id):
		# Under way is not surveying. The hulls are packed and the instruments are on the
		# drive; the rate a parked ship earns is zero.
		if fleet.destination >= 0 or fleet.system < 0:
			continue
		var rate := fleet.survey_rate()
		if rate <= 0.0:
			continue
		var planet: PlanetState = galaxy.planet(fleet.system)
		if planet == null or planet.surveyed:
			continue
		if rng.randf() >= rate:
			continue
		planet.surveyed = true
		surveyed[planet.index] = true
		newly += 1

	if newly > 0:
		galaxy.surveyed_systems[faction_id] = surveyed
	return newly


## Mark systems within `reach` parsecs of `origin` as visible.
static func _reveal_within(
	galaxy: GalaxyState, origin: SystemState, reach: float, visible: Dictionary
) -> void:
	for other in galaxy.systems:
		if origin.distance_to(other) <= reach:
			visible[other.index] = true


## Survey every planet in a visible system, so the client can show orbital detail.
static func survey_system(galaxy: GalaxyState, faction_id: int, system_index: int) -> int:
	var system: SystemState = galaxy.system(system_index)
	if system == null:
		return 0
	var surveyed: Dictionary = galaxy.surveyed_systems.get(faction_id, {}) as Dictionary
	var newly := 0
	for planet_index in system.planet_indices:
		var planet: PlanetState = galaxy.planet(planet_index)
		if planet == null or planet.surveyed:
			continue
		planet.surveyed = true
		surveyed[planet_index] = true
		newly += 1
	galaxy.surveyed_systems[faction_id] = surveyed
	return newly


## Which system a planet belongs to, or -1.
static func _system_of(galaxy: GalaxyState, planet: PlanetState) -> int:
	if planet == null:
		return -1
	for system in galaxy.systems:
		if system.planet_indices.has(planet.index):
			return system.index
	return -1


## The system a planet index belongs to, or -1.
static func system_of_planet(galaxy: GalaxyState, planet_index: int) -> int:
	return _system_of(galaxy, galaxy.planet(planet_index))


## Systems `faction_id` can currently see.
static func visible_systems(galaxy: GalaxyState, faction_id: int) -> PackedInt32Array:
	var set := galaxy.visible_systems.get(faction_id, {}) as Dictionary
	var out := PackedInt32Array()
	for key: int in set:
		out.append(key)
	out.sort()
	return out


## Whether `faction_id` can currently see `system_index`.
static func can_see(galaxy: GalaxyState, faction_id: int, system_index: int) -> bool:
	var set := galaxy.visible_systems.get(faction_id, {}) as Dictionary
	return set.has(system_index)


## Redact a galaxy snapshot down to what `faction_id` is entitled to see.
##
## This is the single place that enforces fog of war on the wire: the server sends each
## client a copy, so a cheating client cannot see fleets or bodies it has not scouted.
static func redact(galaxy: GalaxyState, faction_id: int) -> Dictionary:
	var snapshot := galaxy.to_dict()
	var visible := visible_systems(galaxy, faction_id)
	var allowed: Dictionary = {}
	for index in visible:
		allowed[index] = true

	var system_entries: Array = snapshot.get("systems", []) as Array
	for entry: Dictionary in system_entries:
		if not allowed.has(int(entry.get("index", -1))):
			# Hide existence: name, position and neighbours are all strategic information.
			entry["name"] = "Unknown"
			entry["position"] = [0.0, 0.0]
			entry["warp_lanes"] = PackedInt32Array()
			entry["planet_indices"] = PackedInt32Array()
			entry["owner"] = -1
			entry["strategic_value"] = 0.0

	var fleet_entries: Array = snapshot.get("fleets", []) as Array
	var kept: Array = []
	for entry: Dictionary in fleet_entries:
		var at := int(entry.get("system", -1))
		var owner := int(entry.get("owner", -1))
		if owner == faction_id or (at >= 0 and allowed.has(at)):
			kept.append(entry)
		elif owner != faction_id:
			# Visible contact: position and strength, but not cargo or identity.
			kept.append({
				"id": entry.get("id", -1),
				"owner": owner,
				"system": at if allowed.has(at) else -1,
				"destination": -1,
				"travelled": 0.0,
				"morale": 0.0,
				"cargo": {},
				"ships": entry.get("ships", {}),
				"name": "Unknown Contact",
				"active": true,
			})
	snapshot["fleets"] = kept

	# Tell the client exactly what it is allowed to draw. Without this the receiving
	# side has to infer visibility from the redacted payload, which cannot tell an
	# empty system apart from a hidden one.
	snapshot["visible"] = visible
	snapshot["faction"] = faction_id
	return snapshot
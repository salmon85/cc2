extends RefCounted
class_name GalaxyState
## The complete authoritative game state: the star map, the planets, the fleets, the
## factions and the turn counter.
##
## This is the single object the server owns, the client mirrors, and the save file
## serialises. Everything in it is plain data so it survives `JSON.stringify` without
## custom handling.

const SAVE_VERSION := 1

## Galactic charter date. Each resolution increments it by one.
var turn: int = 0

## Seed the galaxy was generated from. Replaying from this reproduces the map exactly.
var seed_value: int = 0

## `SystemState` list, indexed by `SystemState.index`.
var systems: Array[SystemState] = []

## `PlanetState` list, indexed by `PlanetState.index`.
var planets: Array[PlanetState] = []

## `FleetState` list, keyed by `FleetState.id`.
var fleets: Dictionary = {}

## `FactionState` list, indexed by `FactionState.id`.
var factions: Array[FactionState] = []

## Systems currently visible to each faction, as a set of system indices. Fog of war.
var visible_systems: Dictionary = {}

## Systems each faction has permanently surveyed (scouted bodies).
var surveyed_systems: Dictionary = {}

## The rolling turn report. Bounded so a long game cannot grow without limit.
## Untyped because it round-trips through JSON; always append `String` values.
var news_log: Array = []

## RNG stream position, snapshotted so a replay can rewind exactly.
var rng_state: int = 0

## Next fleet id to hand out.
var next_fleet_id: int = 1

## Half-extent of the system's playable disk, in parsecs.
##
## Serialised because it is part of the *layout*, not a rendering preference: it decides
## where fleets may travel and how long that takes, so a save that dropped it would reload
## onto a map the state does not agree with. Defaults to the `extreme` span, which is what
## every save written before map sizes existed used.
var map_radius: float = 0.0

## The span in force, never zero.
func radius() -> float:
	return map_radius if map_radius > 0.0 else GalaxyGenerator.GALAXY_RADIUS

const MAX_NEWS_ENTRIES := 400


# --- Lookup helpers ------------------------------------------------------------

func system(index: int) -> SystemState:
	if index < 0 or index >= systems.size():
		return null
	return systems[index]


func planet(index: int) -> PlanetState:
	if index < 0 or index >= planets.size():
		return null
	return planets[index]


func faction(index: int) -> FactionState:
	if index < 0 or index >= factions.size():
		return null
	return factions[index]


func fleet(id: int) -> FleetState:
	return fleets.get(id, null) as FleetState


## All fleets owned by `faction_id`, in stable id order.
func fleets_of(faction_id: int) -> Array[FleetState]:
	var out: Array[FleetState] = []
	var ids := fleets.keys()
	ids.sort()
	for id in ids:
		var f: FleetState = fleets[id] as FleetState
		if f != null and f.owner == faction_id and f.active:
			out.append(f)
	return out


## Every colonised body owned by `faction_id`.
func colonies_of(faction_id: int) -> Array[PlanetState]:
	var out: Array[PlanetState] = []
	for p in planets:
		if p.owner == faction_id and p.colonized:
			out.append(p)
	return out


## The lowest-id fleet of `faction_id` parked over `planet_index`, or null.
##
## "Orbits as fleet sources": a colony's Space Port delivers finished hulls into a fleet
## stationed over that world, and this is the query that finds it. Stationary only -- a fleet
## with a `destination` is in transit and belongs to no orbit until it arrives -- and
## lowest-id rather than newest, so the garrison a colony has had since it was founded is the
## one new ships join rather than the fleet that happened to arrive last.
func orbital_fleet(planet_index: int, faction_id: int) -> FleetState:
	var ids := fleets.keys()
	ids.sort()
	for id: int in ids:
		var f: FleetState = fleets[id] as FleetState
		if f != null and f.active and f.owner == faction_id \
				and f.destination < 0 and f.system == planet_index:
			return f
	return null


## Every fleet of `faction_id` parked over `planet_index`, in id order.
##
## The travel flow asks for a *source location*, not for a specific fleet: a player who
## clicks a world means "the ships I have there". Collapsing several fleets into one at
## source-pick time would throw ships away, so the query returns them all and the manifest
## modal lists the union.
func fleets_in_orbit_at(planet_index: int, faction_id: int) -> Array[FleetState]:
	var out: Array[FleetState] = []
	var ids := fleets.keys()
	ids.sort()
	for id: int in ids:
		var f: FleetState = fleets[id] as FleetState
		if f != null and f.active and f.owner == faction_id \
				and f.destination < 0 and f.system == planet_index:
			out.append(f)
	return out


## Whether `faction_id` has completed the given tech node.
func has_tech(faction_id: int, tech_id: StringName) -> bool:
	var f: FactionState = faction(faction_id)
	return f != null and f.researched.has(tech_id)


## Systems still in play for `faction_id`.
func systems_of(faction_id: int) -> PackedInt32Array:
	var f: FactionState = faction(faction_id)
	if f == null:
		return PackedInt32Array()
	return f.systems


# --- Mutation -----------------------------------------------------------------

## Register a new fleet and give it a unique id.
func add_fleet(f: FleetState) -> FleetState:
	f.id = next_fleet_id
	next_fleet_id += 1
	fleets[f.id] = f
	var owner_state: FactionState = faction(f.owner)
	if owner_state != null and not owner_state.fleets.has(f.id):
		owner_state.fleets.append(f.id)
	return f


## Drop a destroyed fleet and detach it from its owner.
func remove_fleet(id: int) -> void:
	var f: FleetState = fleets.get(id, null) as FleetState
	if f == null:
		return
	var owner_state: FactionState = faction(f.owner)
	if owner_state != null:
		owner_state.fleets.erase(id)
	fleets.erase(id)


## Append a line to the turn report, trimming the oldest entries past the cap.
func add_news(line: String) -> void:
	news_log.append(line)
	while news_log.size() > MAX_NEWS_ENTRIES:
		news_log.pop_front()


## News entries as a typed array, for UI code.
func news_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for entry: Variant in news_log:
		out.append(str(entry))
	return out


## Give a faction control of a system, maintaining its `systems` index.
func claim_system(faction_id: int, system_index: int) -> void:
	var s: SystemState = system(system_index)
	if s == null:
		return
	if s.owner != faction_id and s.owner != -1:
		release_system(system_index)
	s.owner = faction_id
	var f: FactionState = faction(faction_id)
	if f != null and not f.systems.has(system_index):
		f.systems.append(system_index)


## Drop a system's previous owner, then take it.
func release_system(system_index: int) -> void:
	var s: SystemState = system(system_index)
	if s == null or s.owner == -1:
		return
	var prev: FactionState = faction(s.owner)
	if prev != null:
		prev.systems.erase(system_index)
	s.owner = -1


# --- Serialisation ------------------------------------------------------------

func to_dict() -> Dictionary:
	var system_dicts: Array = []
	for s in systems:
		system_dicts.append(s.to_dict())
	var planet_dicts: Array = []
	for p in planets:
		planet_dicts.append(p.to_dict())
	var fleet_dicts: Array = []
	var fleet_ids := fleets.keys()
	fleet_ids.sort()
	for id in fleet_ids:
		fleet_dicts.append((fleets[id] as FleetState).to_dict())
	var faction_dicts: Array = []
	for f in factions:
		faction_dicts.append(f.to_dict())

	return {
		"version": SAVE_VERSION,
		"turn": turn,
		"seed": seed_value,
		"systems": system_dicts,
		"planets": planet_dicts,
		"fleets": fleet_dicts,
		"factions": faction_dicts,
		"visible_systems": _serialize_sets(visible_systems),
		"surveyed_systems": _serialize_sets(surveyed_systems),
		"news_log": news_log,
		"rng_state": rng_state,
		"next_fleet_id": next_fleet_id,
		"map_radius": map_radius,
	}


## Rebuild a galaxy from `to_dict()` output. Returns false when the payload is unusable.
func from_dict(data: Dictionary) -> bool:
	if not data.has("systems") or not data.has("planets"):
		push_error("[GalaxyState] payload missing systems or planets")
		return false
	if int(data.get("version", 0)) != SAVE_VERSION:
		push_error("[GalaxyState] save version %d is not supported" % int(data.get("version", 0)))
		return false

	turn = int(data.get("turn", 0))
	seed_value = int(data.get("seed", 0))
	# Accept either form: a decimal string (what to_json writes, which is exact) or a
	# bare number (hand-written saves and older payloads).
	var raw_state: Variant = data.get("rng_state", 0)
	rng_state = int(raw_state) if not (raw_state is String) else int(str(raw_state))
	next_fleet_id = int(data.get("next_fleet_id", 1))
	# Absent in every save written before map sizes existed, so fall back rather than
	# leaving it zero: a zero radius would collapse every orbit onto the star.
	map_radius = float(data.get("map_radius", GalaxyGenerator.GALAXY_RADIUS))
	# JSON hands back an untyped/Packed array here, so rebuild it element-wise.
	news_log = PackedStringArray()
	for entry: Variant in data.get("news_log", []):
		news_log.append(str(entry))

	systems.clear()
	for entry: Dictionary in data["systems"]:
		var s := SystemState.new()
		if not s.from_dict(entry):
			return false
		systems.append(s)

	planets.clear()
	for entry: Dictionary in data["planets"]:
		var p := PlanetState.new()
		if not p.from_dict(entry):
			return false
		planets.append(p)

	fleets.clear()
	for entry: Dictionary in data.get("fleets", []):
		var f := FleetState.new()
		if not f.from_dict(entry):
			return false
		fleets[f.id] = f

	factions.clear()
	for entry: Dictionary in data.get("factions", []):
		var f := FactionState.new()
		if not f.from_dict(entry):
			return false
		factions.append(f)

	visible_systems = _deserialize_sets(data.get("visible_systems", {}))
	surveyed_systems = _deserialize_sets(data.get("surveyed_systems", {}))
	# Best-effort rebind: the `Defs` autoload is absent in bare `-s` test runs, and a
	# caller that owns a registry can rebind explicitly afterwards.
	if _resolve_defs() != null:
		rebind_definitions()
	return true


## Re-attach the cached `Resource` definitions to every state object after a load.
##
## The `.tres` definitions are deliberately *not* serialised: they are immutable data
## that ships with the game, so saves store only ids and re-resolve them at load time.
## This is also what lets a balance change apply retroactively to old saves.
func rebind_definitions(defs: Node = null) -> bool:
	var registry: Node = defs if defs != null else _resolve_defs()
	if registry == null:
		push_error("[GalaxyState] rebind_definitions: definition registry unavailable")
		return false

	var planet_types := registry.get("planet_types") as Dictionary
	var hulls := registry.get("ship_hulls") as Dictionary
	var tech := registry.get("tech_nodes") as Dictionary
	# Bound onto every body alongside its type, so `get_max_food` and friends need no registry
	# handed to them and a panel cannot accidentally ask without one.
	var buildings := registry.get("buildings") as Dictionary
	var complete := true

	for p in planets:
		var type_res := planet_types.get(p.type_id, null) as Resource
		if type_res == null:
			push_error("[GalaxyState] planet %d references unknown type '%s'" % [p.index, p.type_id])
			complete = false
		p.bind_type(type_res)
		p.bind_buildings(buildings)

	for id: int in fleets:
		(fleets[id] as FleetState).bind_hulls(hulls)

	for f in factions:
		f.bind_tech(tech)

	return complete


## Locate the `Defs` autoload without hard-referencing it, so this file stays usable in
## unit tests that construct a galaxy without booting the full project.
func _resolve_defs() -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null("Defs")


static func _serialize_sets(sets: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key: int in sets:
		var values: Array = (sets[key] as Dictionary).keys()
		values.sort()
		out[str(key)] = values
	return out


static func _deserialize_sets(raw: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key: Variant in raw:
		var set: Dictionary = {}
		for v in (raw[key] as Array):
			set[int(v)] = true
		out[int(key)] = set
	return out


## Full ordering-independent fingerprint of the galaxy. Two states that hash the same are
## behaviourally identical, which is exactly what the determinism replay test asserts.
func fingerprint() -> String:
	var parts := PackedStringArray()
	parts.append("t%d s%d" % [turn, seed_value])
	for s in systems:
		parts.append(s.fingerprint())
	for p in planets:
		parts.append(p.fingerprint())
	var fleet_ids := fleets.keys()
	fleet_ids.sort()
	for id in fleet_ids:
		parts.append((fleets[id] as FleetState).fingerprint())
	for f in factions:
		parts.append(f.fingerprint())
	return "\n".join(parts)


## Stable 64-bit hash of the fingerprint, for compact comparisons in logs and tests.
func state_hash() -> int:
	return abs(fingerprint().hash())


## JSON text form, for save files and network snapshots.
##
## `rng_state` is written as a decimal string: JSON has no 64-bit integer type, so a raw
## number would round-trip through a double and silently corrupt the RNG stream. A
## string survives exactly, which is what determinism across a save/load requires.
func to_json() -> String:
	var payload := to_dict()
	payload["rng_state"] = str(rng_state)
	return JSON.stringify(payload)


## Parse `to_json()` output. Returns false and leaves the galaxy untouched on failure.
func from_json(text: String) -> bool:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_error("[GalaxyState] from_json: payload is not an object")
		return false
	return from_dict(parsed)


## An independent copy of this galaxy.
##
## Needed wherever two parties must hold "the same" state without sharing objects -- a
## server and a client replica, or a baseline to diff a replay against. This goes through
## the serialisation form on purpose rather than a member-wise clone: it proves the copy
## is genuinely reconstructable from the wire, which is what the network path depends on.
func duplicate_state() -> GalaxyState:
	var copy := GalaxyState.new()
	if not copy.from_dict(to_dict()):
		push_error("[GalaxyState] duplicate_state: self did not round-trip")
		return null
	return copy
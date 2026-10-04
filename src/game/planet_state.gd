extends RefCounted
class_name PlanetState
## Live state of a single planetary body inside one star system.
##
## Pure data plus the derived queries the turn resolver needs. Deliberately free of any
## engine node references so the whole galaxy can be serialised to JSON for saves and
## replicated over the wire.

## Index into `GalaxyState.systems`.
var index: int = -1

## `PlanetTypeData.id` this body was generated as.
var type_id: StringName = &"terrestrial"

## Orbital slot within the system (0..5), purely for display ordering.
var orbit: int = 0

## Owning faction, or -1 when unclaimed.
var owner: int = -1

## Colonised flag. An owned but uncolonised body is a captured outpost.
var colonized: bool = false

## Population in millions.
var population: float = 0.0

## Structure counts keyed by `BuildingData.id`.
var structures: Dictionary = {}

## Local stockpile.
var reserve_metals: float = 0.0
var reserve_rare: float = 0.0
var reserve_energy: float = 0.0

## Cumulative terraforming progress, 0..1.
var terraform_progress: float = 0.0

## Structures currently under construction keyed by `BuildingData.id`.
var building_queue: Dictionary = {}

## Turns remaining on the construction in `building_queue`.
var build_turns_remaining: int = 0

## Production points banked toward the next ship in the yard.
var shipyard_progress: float = 0.0
## Hulls queued for construction, oldest first. Stored untyped because it round-trips
## through JSON, which does not preserve element types; `_coerce_ship_queue` re-types it.
var ship_queue: Array = []

## Food banked for the colony, in units. A surplus carries over; a deficit runs it down.
var food_stock: float = 0.0

## Whether the owner has surveyed this body (drives fog of war).
var surveyed: bool = false

## Cached `PlanetTypeData`, refreshed by the generator; never serialised.
var _type: Resource = null


func bind_type(type_data: Resource) -> void:
	_type = type_data


func type_data() -> Resource:
	return _type


## Roll the uncolonised reserves this body starts with. Called by the generator.
func seed_reserves(type_data: Resource) -> void:
	reserve_metals = type_data.get("base_reserve_metals")
	reserve_rare = type_data.get("base_reserve_rare")
	reserve_energy = type_data.get("base_reserve_energy")


## Habitability after terraforming. Falls back to the cached type.
func habitability() -> float:
	if _type == null:
		return 0.0
	return _type.call("effective_habitability", terraform_progress)


## Maximum sustainable population, millions. Zero when uninhabitable.
func max_population() -> float:
	var hab := habitability()
	if hab <= 0.01:
		return 0.0
	return hab * 20.0


## Total structures of a kind.
func count(kind_id: StringName) -> int:
	return int(structures.get(kind_id, 0))


## Structures of a `BuildingData.Kind`.
func count_by_kind(kind: int, registry: Dictionary) -> int:
	var total := 0
	for key: StringName in structures:
		var def: Resource = registry.get(key, null) as Resource
		if def != null and int(def.get("kind")) == kind:
			total += int(structures[key])
	return total


## True when this body is a valid settlement target for a faction.
func is_colonizable() -> bool:
	if _type == null:
		return false
	if not _type.get("colonizable"):
		return false
	return max_population() > 0.0


## Serialise to a plain dictionary for saves and network replication.
func to_dict() -> Dictionary:
	return {
		"index": index,
		"type_id": String(type_id),
		"orbit": orbit,
		"owner": owner,
		"colonized": colonized,
		"population": population,
		"structures": structures.duplicate(true),
		"reserve_metals": reserve_metals,
		"reserve_rare": reserve_rare,
		"reserve_energy": reserve_energy,
		"terraform_progress": terraform_progress,
		"building_queue": building_queue.duplicate(true),
		"build_turns_remaining": build_turns_remaining,
		"shipyard_progress": shipyard_progress,
		"ship_queue": ship_queue.duplicate(true),
		"food_stock": food_stock,
		"surveyed": surveyed,
	}


## Restore from `to_dict()` output. Returns false when required fields are missing.
func from_dict(data: Dictionary) -> bool:
	if not data.has("index") or not data.has("type_id"):
		push_error("[PlanetState] dictionary missing required fields")
		return false
	index = int(data["index"])
	type_id = StringName(str(data["type_id"]))
	orbit = int(data.get("orbit", 0))
	owner = int(data.get("owner", -1))
	colonized = bool(data.get("colonized", false))
	population = float(data.get("population", 0.0))
	structures = data.get("structures", {}).duplicate(true)
	reserve_metals = float(data.get("reserve_metals", 0.0))
	reserve_rare = float(data.get("reserve_rare", 0.0))
	reserve_energy = float(data.get("reserve_energy", 0.0))
	terraform_progress = float(data.get("terraform_progress", 0.0))
	building_queue = data.get("building_queue", {}).duplicate(true)
	build_turns_remaining = int(data.get("build_turns_remaining", 0))
	shipyard_progress = float(data.get("shipyard_progress", 0.0))
	ship_queue = _coerce_ship_queue(data.get("ship_queue", []))
	food_stock = float(data.get("food_stock", 0.0))
	surveyed = bool(data.get("surveyed", false))
	return true


## JSON round-trips drop element types, so re-type the queue and drop anything that is
## not a dictionary. A malformed entry is discarded rather than poisoning the build queue.
static func _coerce_ship_queue(raw: Array) -> Array:
	var out: Array = []
	for entry: Variant in raw:
		if entry is Dictionary:
			out.append((entry as Dictionary).duplicate(true))
	return out


## Ordering-independent fingerprint, used by determinism tests.
##
## Keys are sorted and stringified before formatting: Godot preserves dictionary
## insertion order and renders `StringName` keys with an `&` prefix, so a JSON round-trip
## (which retypes every key to `String`) would otherwise hash an identical planet
## differently from the in-memory original.
func fingerprint() -> String:
	return "%d:%s:%d:%d:%s:%.4f:%s:%.2f:%.2f:%.2f:%.4f:%s:%.4f:%.4f:%d" % [
		index, String(type_id), orbit, owner, str(colonized), population,
		_sorted_keys(structures), reserve_metals, reserve_rare, reserve_energy,
		terraform_progress, _sorted_keys(building_queue), shipyard_progress,
		food_stock, build_turns_remaining,
	]


## Sorted, plain-String rendering of a dictionary's keys. See `KeyText.sorted_keys`.
static func _sorted_keys(source: Dictionary) -> String:
	return KeyText.sorted_keys(source)
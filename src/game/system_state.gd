extends RefCounted
class_name SystemState
## Live state of a star system and the bodies orbiting it.

## Index into `GalaxyState.systems`.
var index: int = -1

## Display name, e.g. "Rigel".
var name: String = ""

## `Enums.StarClass`.
var star_class: int = 2

## Position on the sector grid, in parsecs. Drives every distance calculation.
var position: Vector2 = Vector2.ZERO

## Indices into `GalaxyState.planets`, 1..6 entries as the spec requires.
var planet_indices: PackedInt32Array = PackedInt32Array()

## Warp-lane adjacency, as system indices. Symmetric across the whole galaxy.
var warp_lanes: PackedInt32Array = PackedInt32Array()

## Owning faction, or -1 when unclaimed.
var owner: int = -1

## Wreckage and strategic value, 0..1. Drives AI target selection.
var strategic_value: float = 0.5

## Cached `PlanetTypeData` per local planet slot; never serialised.
var _planet_types: Array[Resource] = []


## Record the class of each body in this system. Called by the generator.
func bind_planet_types(types: Array[Resource]) -> void:
	_planet_types = []
	for t in types:
		_planet_types.append(t)


## Number of bodies in the system.
func body_count() -> int:
	return planet_indices.size()


## Great-circle distance to another system, in parsecs.
func distance_to(other: SystemState) -> float:
	return position.distance_to(other.position)


## True when a direct warp lane links the two systems.
func has_warp_lane_to(other_index: int) -> bool:
	return warp_lanes.has(other_index)


## Add a lane. Duplicates are ignored so the generator can be safely re-run.
func add_warp_lane(other_index: int) -> void:
	if other_index != index and not warp_lanes.has(other_index):
		warp_lanes.append(other_index)


func to_dict() -> Dictionary:
	return {
		"index": index,
		"name": name,
		"star_class": star_class,
		"position": [position.x, position.y],
		"planet_indices": planet_indices,
		"warp_lanes": warp_lanes,
		"owner": owner,
		"strategic_value": strategic_value,
	}


func from_dict(data: Dictionary) -> bool:
	if not data.has("index") or not data.has("position"):
		push_error("[SystemState] dictionary missing required fields")
		return false
	index = int(data["index"])
	name = str(data.get("name", "Unnamed"))
	star_class = int(data.get("star_class", 2))
	var pos: Array = data["position"]
	position = Vector2(float(pos[0]), float(pos[1]))
	planet_indices = PackedInt32Array(data.get("planet_indices", []))
	warp_lanes = PackedInt32Array(data.get("warp_lanes", []))
	owner = int(data.get("owner", -1))
	strategic_value = float(data.get("strategic_value", 0.5))
	return true


## Ordering-independent fingerprint, used by determinism tests.
func fingerprint() -> String:
	var lanes := PackedInt32Array(warp_lanes)
	lanes.sort()
	return "%d:%s:%d:(%.3f,%.3f):%s:%s:%d:%.4f" % [
		index, name, star_class, position.x, position.y,
		str(planet_indices), str(lanes), owner, strategic_value,
	]
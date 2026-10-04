extends RefCounted
class_name FleetState
## Live state of a fleet: a group of hulls travelling and fighting together.

## Stable identity across turns and saves.
var id: int = -1

## Owning faction.
var owner: int = -1

## System the fleet currently occupies, or -1 while in transit.
var system: int = -1

## Transit progress toward `destination`, in parsecs of the remaining distance.
## `travelled` accumulates; the fleet arrives when it covers the full route.
var destination: int = -1
var travelled: float = 0.0

## Fleet morale, 0..1. Breaking morale forces a retreat.
var morale: float = 1.0

## Cargo manifest: `{"metals": x, "rare": x, "energy": x, "troops": x}`.
var cargo: Dictionary = {}

## Composition keyed by `ShipHullData.id` → ship count.
var ships: Dictionary = {}

## Display name.
var name: String = ""

## Cached `ShipHullData` per hull id; never serialised.
var _hulls: Dictionary = {}

## False once the fleet has been destroyed; a destroyed fleet is removed from the galaxy.
var active: bool = true


func bind_hulls(hulls: Dictionary) -> void:
	_hulls = hulls


## The hull definitions this fleet was bound to, keyed by `ShipHullData.id`.
func hulls() -> Dictionary:
	return _hulls


## Total number of individual ships.
func ship_count() -> int:
	var total := 0
	for key: StringName in ships:
		total += int(ships[key])
	return total


## Total hull points, before any tech bonuses.
func base_hull_points() -> float:
	var total := 0.0
	for key: StringName in ships:
		var def: Resource = _hulls.get(key, null) as Resource
		if def != null:
			total += float(def.get("hull_points")) * int(ships[key])
	return total


## Total shield points, before any tech bonuses.
func base_shield_points() -> float:
	var total := 0.0
	for key: StringName in ships:
		var def: Resource = _hulls.get(key, null) as Resource
		if def != null:
			total += float(def.get("shield_points")) * int(ships[key])
	return total


## Total weapon damage, before any tech bonuses.
func base_weapon_damage() -> float:
	var total := 0.0
	for key: StringName in ships:
		var def: Resource = _hulls.get(key, null) as Resource
		if def != null:
			total += float(def.get("weapon_damage")) * int(ships[key])
	return total


## Blend of the member hulls' accuracies, weighted by hull count.
func base_accuracy() -> float:
	var total_count := 0.0
	var weighted := 0.0
	for key: StringName in ships:
		var def: Resource = _hulls.get(key, null) as Resource
		if def != null:
			var n := float(int(ships[key]))
			weighted += float(def.get("weapon_accuracy")) * n
			total_count += n
	if total_count <= 0.0:
		return 0.0
	return weighted / total_count


## Slowest member hull sets the fleet speed, before drive research.
func base_speed() -> float:
	var slowest := INF
	for key: StringName in ships:
		var def: Resource = _hulls.get(key, null) as Resource
		if def != null:
			slowest = minf(slowest, float(def.get("base_speed")))
	if slowest == INF:
		return 0.0
	return slowest


## Best sensor range among the members, before research.
func base_sensor_range() -> float:
	var best := 0.0
	for key: StringName in ships:
		var def: Resource = _hulls.get(key, null) as Resource
		if def != null:
			best = maxf(best, float(def.get("sensor_range")))
	return best


## Total bombardment strength. Zero means this fleet cannot lay siege to a planet.
func bombardment_power() -> float:
	var total := 0.0
	for key: StringName in ships:
		var def: Resource = _hulls.get(key, null) as Resource
		if def != null:
			total += float(def.get("bombardment")) * int(ships[key])
	return total


## Total troop lift available for an invasion.
func troop_capacity() -> float:
	var total := 0.0
	for key: StringName in ships:
		var def: Resource = _hulls.get(key, null) as Resource
		if def != null:
			total += float(def.get("troop_capacity")) * int(ships[key])
	return total


## Total cargo capacity.
func cargo_capacity() -> float:
	var total := 0.0
	for key: StringName in ships:
		var def: Resource = _hulls.get(key, null) as Resource
		if def != null:
			total += float(def.get("cargo_capacity")) * int(ships[key])
	return total


## Cargo currently loaded. A negative manifest entry (corrupt save, buggy order) is
## clamped to zero rather than being allowed to inflate the fleet's free capacity.
func cargo_load() -> float:
	var total := 0.0
	for key: String in cargo:
		total += maxf(0.0, float(cargo[key]))
	return total


## Free cargo space.
func free_cargo() -> float:
	return maxf(0.0, cargo_capacity() - cargo_load())


## Add `count` ships of hull `hull_id`. Returns false for an unknown hull.
func add_ships(hull_id: StringName, count: int) -> bool:
	if not _hulls.has(hull_id):
		push_error("[FleetState] unknown hull id '%s'" % hull_id)
		return false
	if count <= 0:
		return false
	ships[hull_id] = int(ships.get(hull_id, 0)) + count
	return true


## Remove up to `count` ships of hull `hull_id`. Returns the number actually removed.
func remove_ships(hull_id: StringName, count: int) -> int:
	var have := int(ships.get(hull_id, 0))
	var taken: int = mini(have, maxi(0, count))
	if taken <= 0:
		return 0
	var left := have - taken
	if left > 0:
		ships[hull_id] = left
	else:
		ships.erase(hull_id)
	return taken


## Whether the fleet holds any colony kit.
func has_colony_ship() -> bool:
	var def: Resource = _hulls.get(&"colony_ship", null) as Resource
	return def != null and def.get("colony_kit") and int(ships.get(&"colony_ship", 0)) > 0


## Damage `amount` hull points, cheapest hulls first, and mark the fleet dead when empty.
## Returns true if the fleet survived.
func apply_damage(amount: float, rng: RandomNumberGenerator) -> bool:
	var remaining := amount
	# Prefer absorbing shields before chewing through hulls.
	var shields := base_shield_points()
	if shields > 0.0 and remaining > 0.0:
		var absorbed: float = minf(shields, remaining)
		remaining -= absorbed

	if remaining <= 0.0:
		morale = maxf(0.0, morale - amount / maxf(1.0, base_hull_points() + shields) * 0.25)
		return true

	# Shred hulls proportionally so mixed fleets degrade realistically.
	var total_hull := base_hull_points()
	if total_hull <= 0.0:
		active = false
		return false
	var fraction: float = clampf(remaining / total_hull, 0.0, 1.0)

	for key: StringName in ships.keys():
		var def: Resource = _hulls.get(key, null) as Resource
		if def == null:
			continue
		var per_ship := float(def.get("hull_points"))
		if per_ship <= 0.0:
			continue
		# Each ship's survival roll uses the supplied RNG so damage stays deterministic.
		var loss_roll := rng.randf()
		var ship_loss := 0.0
		if loss_roll < fraction:
			# Fully destroyed ships, plus partial attrition on one survivor.
			ship_loss = float(int(ships[key]))
			var extra := rng.randf() * 1.0
			if extra > fraction - loss_roll:
				ship_loss = maxf(0.0, ship_loss - 1.0 + extra)
		ship_loss = minf(ship_loss, float(int(ships[key])))
		var keep := float(int(ships[key])) - ship_loss
		if keep <= 0.0:
			ships.erase(key)
		else:
			ships[key] = int(keep)

	morale = clampf(morale - remaining / (total_hull + base_shield_points() + 1.0), 0.0, 1.0)
	if ships.is_empty():
		active = false
		return false
	return true


func to_dict() -> Dictionary:
	return {
		"id": id,
		"owner": owner,
		"system": system,
		"destination": destination,
		"travelled": travelled,
		"morale": morale,
		"cargo": cargo.duplicate(true),
		"ships": ships.duplicate(true),
		"name": name,
		"active": active,
	}


func from_dict(data: Dictionary) -> bool:
	if not data.has("id") or not data.has("ships"):
		push_error("[FleetState] dictionary missing required fields")
		return false
	id = int(data["id"])
	owner = int(data.get("owner", 0))
	system = int(data.get("system", -1))
	destination = int(data.get("destination", -1))
	travelled = float(data.get("travelled", 0.0))
	morale = float(data.get("morale", 1.0))
	cargo = data.get("cargo", {}).duplicate(true)
	ships = data.get("ships", {}).duplicate(true)
	name = str(data.get("name", "Fleet"))
	active = bool(data.get("active", true))
	return true


## Ordering-independent fingerprint, used by determinism tests.
##
## Keys are sorted and stringified because a JSON round-trip retypes `StringName` keys
## to `String`, which would otherwise hash an identical fleet differently.
func fingerprint() -> String:
	var hull_ids := PackedStringArray()
	for key: Variant in ships:
		hull_ids.append(KeyText.key(key))
	hull_ids.sort()
	var parts := PackedStringArray()
	for hull_id in hull_ids:
		parts.append("%s=%d" % [hull_id, int(ships.get(hull_id, 0))])
	return "%d:%d:%d:%d:%.3f:%.3f:%s:%s" % [
		id, owner, system, destination, travelled, morale, str(parts), name,
	]
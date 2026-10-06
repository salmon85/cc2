extends RefCounted
class_name FactionState
## Live state of one empire: treasury, research, technologies and owned assets.

## Stable identity across turns, saves and the network.
var id: int = -1

@export var name: String = ""

## `Enums.FactionKind`.
var kind: int = 1

## 0..1 imperial tax slider, set each turn.
var tax_rate: float = 0.35

## Research budget split across the four fields. Always normalised to sum 1.0.
var research_allocation: PackedFloat64Array = PackedFloat64Array([0.25, 0.25, 0.25, 0.25])

## Treasury in credits. May go negative, down to a floor.
var treasury: float = 0.0

## Empire-wide stockpiles.
var metals: float = 0.0
var rare_elements: float = 0.0
var energy: float = 0.0

## Tech points accumulated per field.
## 64-bit on purpose: research accumulates every turn, and 32-bit floats lose
## precision fast enough to break save/load determinism over a long game.
var tech_points: PackedFloat64Array = PackedFloat64Array([0.0, 0.0, 0.0, 0.0])

## Completed `TechNodeData.id` values.
var researched: Dictionary = {}

## Ids of ships this faction may currently build.
var unlocked_ships: Dictionary = {}

## Ids of buildings this faction may currently construct.
var unlocked_buildings: Dictionary = {}

## Fleet ids owned, and system indices held.
var fleets: PackedInt32Array = PackedInt32Array()
var systems: PackedInt32Array = PackedInt32Array()

## Whether the faction has been eliminated.
var defeated: bool = false

## Rolling economic ledger for the turn report.
var last_income: float = 0.0
var last_expenses: float = 0.0
var last_net: float = 0.0
var last_production: float = 0.0

## Science points granted last turn.
##
## Recorded rather than recomputed so the header can show a real delta. `total_tech_points()`
## alone is a balance the player can only watch after the fact; the delta is what tells them
## whether their population is keeping pace with their technology.
var last_research_granted: float = 0.0

## Lifetime colonial ledger. Used by the AI to weigh aggression and by the news
## feed to summarise a war's progress.
var colonies_taken: int = 0
var colonies_lost: int = 0
var colonies_founded: int = 0

## Highest population milestone this empire has unlocked hulls for.
##
## Stored rather than recomputed from current population every turn, because a faction that
## loses a colony and then takes another back would otherwise re-unlock its entire fleet
## each time it crossed a threshold it had already paid for. `-1` means "nothing past the
## starting roster", which is what generation leaves it at.
var tech_tier: int = -1

## AI scratch space: what the faction is currently focused on. Not gameplay-affecting.
var ai_target_system: int = -1
var ai_mood: float = 0.5


func _init() -> void:
	research_allocation.resize(4)
	tech_points.resize(4)
	research_allocation = PackedFloat64Array([0.25, 0.25, 0.25, 0.25])
	tech_points = PackedFloat64Array([0.0, 0.0, 0.0, 0.0])


## Total tech across all four fields.
func total_tech_points() -> float:
	var total := 0.0
	for p in tech_points:
		total += p
	return total


## Renormalise the research allocation so it sums to 1.0. Safe on a zero vector.
func normalize_allocation() -> void:
	research_allocation.resize(4)
	var total := 0.0
	for i in 4:
		research_allocation[i] = maxf(0.0, research_allocation[i])
		total += research_allocation[i]
	if total <= 0.0:
		for i in 4:
			research_allocation[i] = 0.25
		return
	for i in 4:
		research_allocation[i] /= total


## Cached `TechNodeData` resources for everything this faction has researched.
## Populated by `GalaxyState.rebind_definitions()`; never serialised.
var _tech_cache: Dictionary = {}


## Attach the already-researched tech definitions so `tech_effect()` works without a
## registry lookup per call. Missing ids are simply skipped.
func bind_tech(nodes: Dictionary) -> void:
	_tech_cache = {}
	for id: StringName in researched:
		var node := nodes.get(id, null) as Resource
		if node != null:
			_tech_cache[id] = node


## Cache one node as researched, so `tech_effect()` sees it on the very next turn.
##
## `researched[best] = true` on its own is not enough, and the gap was invisible for a long
## time. `_tech_cache` is what every bonus reads, and it was only ever populated by
## `GalaxyState.rebind_definitions` -- which happens on a load and at generation, and nowhere
## else. So a node completed during turn 12 granted its unlocks immediately but its *effects*
## only from the next galaxy reload: a save/reload run had the food bonus a turn earlier than
## an uninterrupted one, and two runs of the same seed produced different games.
##
## With the founding colony no longer carrying a farm surplus, the colony bank stopped
## saturating at its pantry cap and the one-turn difference became visible as a real
## divergence rather than being absorbed by a clamp. The cache is a mirror of `researched`,
## so it has to be written wherever `researched` is.
func cache_tech_node(id: StringName, node: Resource) -> void:
	if id == &"" or node == null:
		return
	_tech_cache[id] = node


## Sum of a `TechNodeData` effect across everything this faction has researched.
func tech_effect(key: StringName) -> float:
	var total := 0.0
	for id: StringName in _tech_cache:
		total += float((_tech_cache[id] as Resource).call("effect", key))
	return total


## Bonus fraction for a hull stat, e.g. hull_bonus or weapon_bonus.
func stat_multiplier(key: StringName) -> float:
	return 1.0 + tech_effect(key)


## Additive stat bonus, e.g. movement or sensor_range.
func stat_addition(key: StringName) -> float:
	return tech_effect(key)


## Extra weapon slots unlocked by research.
func weapon_slots_bonus() -> int:
	return int(round(tech_effect(&"max_ship_slots")))


## Extra shield slots unlocked by research.
func shield_slots_bonus() -> int:
	return int(round(tech_effect(&"max_shield_slots")))


## Whether gas giants may now be settled.
func can_colonize_gas() -> bool:
	return tech_effect(&"can_colonize_gas") > 0.0


## Number of systems this faction controls.
func system_count() -> int:
	return systems.size()


## Whether the faction still has anything worth playing for.
func is_alive() -> bool:
	return not defeated and (not systems.is_empty() or not fleets.is_empty())


func to_dict() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"kind": kind,
		"tax_rate": tax_rate,
		"research_allocation": Array(research_allocation),
		"treasury": treasury,
		"metals": metals,
		"rare_elements": rare_elements,
		"energy": energy,
		"tech_points": Array(tech_points),
		"researched": researched.keys(),
		"unlocked_ships": unlocked_ships.keys(),
		"unlocked_buildings": unlocked_buildings.keys(),
		"fleets": fleets,
		"systems": systems,
		"defeated": defeated,
		"last_income": last_income,
		"last_expenses": last_expenses,
		"last_net": last_net,
		"last_production": last_production,
		"last_research_granted": last_research_granted,
		"colonies_taken": colonies_taken,
		"colonies_lost": colonies_lost,
		"colonies_founded": colonies_founded,
		"tech_tier": tech_tier,
		"ai_target_system": ai_target_system,
		"ai_mood": ai_mood,
	}


func from_dict(data: Dictionary) -> bool:
	if not data.has("id"):
		push_error("[FactionState] dictionary missing required fields")
		return false
	id = int(data["id"])
	name = str(data.get("name", "Empire"))
	kind = int(data.get("kind", 1))
	tax_rate = float(data.get("tax_rate", 0.35))
	research_allocation = _coerce_floats(
		data.get("research_allocation", []), [0.25, 0.25, 0.25, 0.25])
	treasury = float(data.get("treasury", 0.0))
	metals = float(data.get("metals", 0.0))
	rare_elements = float(data.get("rare_elements", 0.0))
	energy = float(data.get("energy", 0.0))
	tech_points = _coerce_floats(data.get("tech_points", []), [0.0, 0.0, 0.0, 0.0])
	researched = _key_set(data.get("researched", []))
	unlocked_ships = _key_set(data.get("unlocked_ships", []))
	unlocked_buildings = _key_set(data.get("unlocked_buildings", []))
	fleets = PackedInt32Array(data.get("fleets", []))
	systems = PackedInt32Array(data.get("systems", []))
	defeated = bool(data.get("defeated", false))
	last_income = float(data.get("last_income", 0.0))
	last_expenses = float(data.get("last_expenses", 0.0))
	last_net = float(data.get("last_net", 0.0))
	last_production = float(data.get("last_production", 0.0))
	last_research_granted = float(data.get("last_research_granted", 0.0))
	colonies_taken = int(data.get("colonies_taken", 0))
	colonies_lost = int(data.get("colonies_lost", 0))
	colonies_founded = int(data.get("colonies_founded", 0))
	# Absent from saves written before the population ladder existed, where the whole
	# progression was point-driven instead. -1 means "re-evaluate from scratch this turn",
	# which is exactly right for a save that carries no record of what was unlocked.
	tech_tier = int(data.get("tech_tier", -1))
	ai_target_system = int(data.get("ai_target_system", -1))
	ai_mood = float(data.get("ai_mood", 0.5))
	research_allocation.resize(4)
	tech_points.resize(4)
	return true


static func _key_set(values: Array) -> Dictionary:
	var out: Dictionary = {}
	for v in values:
		out[StringName(str(v))] = true
	return out


## Coerce a deserialised array into a 4-wide `PackedFloat64Array`.
##
## JSON round-trips lose element types: a float array can come back as a
## `PackedStringArray` of decimal strings. Reading them element-by-element as floats
## handles both shapes, and the result is padded or trimmed to exactly four entries so a
## truncated or over-long payload cannot desynchronise the slider indices.
static func _coerce_floats(raw: Array, defaults: Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for i in 4:
		if i < raw.size():
			out.append(float(raw[i]))
		else:
			out.append(float(defaults[i]))
	return out


## Ordering-independent fingerprint, used by determinism tests.
##
## Keysets are sorted and stringified because a JSON round-trip retypes `StringName` keys
## to `String`, which would otherwise hash an identical faction differently.
func fingerprint() -> String:
	var systems_sorted := PackedInt32Array(systems)
	systems_sorted.sort()
	return "%d:%s:%d:%.4f:%s:%.3f:%.2f:%.2f:%.2f:%s:%s:%s:%s:%s:%d" % [
		id, name, kind, tax_rate, str(Array(research_allocation)), treasury,
		metals, rare_elements, energy, _sorted_keys(researched),
		_sorted_keys(unlocked_ships), _sorted_keys(unlocked_buildings),
		str(systems_sorted), str(defeated), tech_tier,
	]


## Sorted, plain-String rendering of a dictionary's keys. See `KeyText.sorted_keys`.
static func _sorted_keys(source: Dictionary) -> String:
	return KeyText.sorted_keys(source)
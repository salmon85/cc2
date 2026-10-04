extends Resource
class_name TechNodeData
## One researchable node in the imperial technology tree.
##
## Tech is spent from a single per-turn point pool that the player divides across four
## fields with sliders. Completing a node costs a fixed number of points accumulated in
## *that field only*, then permanently applies `effects` to the faction.

## Stable identifier referenced by saves and prerequisite lists.
@export var id: StringName = &""

@export var display_name: String = ""

## Which research field funds this node. See `Enums.TechField`.
@export var field: int = 0

## Tech points that must accumulate in `field` before this completes.
@export var cost: float = 40.0

## Ids that must be completed first. Empty means it is a tier-1 node.
@export var prerequisites: Array[StringName] = []

## Tier depth, purely for the tech-tree UI grouping. Computed, but authored so the UI can
## lay the tree out without walking the graph.
@export var tier: int = 1

## One-line description shown in the research screen.
@export var description: String = ""

## Cumulative modifier granted on completion. Recognised keys (all additive):
##   movement          parsecs/turn added to fleet speed
##   sensor_range      parsecs added to sensor range
##   max_ship_slots    +1 weapon slot on every hull
##   max_shield_slots  +1 shield slot on every hull
##   hull_bonus        fraction added to all hull points (0.10 = +10%)
##   shield_bonus      fraction added to all shield points
##   weapon_bonus      fraction added to all weapon damage
##   accuracy_bonus    added to weapon accuracy, capped at 0.95
##   energy_bonus      fraction added to planetary shield output
##   food_bonus        fraction added to agricultural output
##   mining_bonus      fraction added to mine output
##   research_bonus    fraction added to research point yield
##   construction_bonus fraction added to construction speed (shorter build queues)
##   bombardment_bonus fraction added to orbital bombardment damage
##   colonization_cost fraction *removed* from colony ship cost
##   terraform_power   added to terraforming speed
##   can_colonize_gas  1 when gas giants become colonisable
@export var effects: Dictionary = {}

## Ships unlocked by completing this node. Referenced by `ShipHullData.id`.
@export var unlocks_ships: Array[StringName] = []

## Buildings unlocked by completing this node. Referenced by `BuildingData.id`.
@export var unlocks_buildings: Array[StringName] = []


## Report any authoring mistake as a list of issues.
##
## Returns an empty array when the definition is well formed. `Defs.validate_all()`
## turns any returned issues into `push_error` calls at boot; tests assert on the
## return value directly, since Godot does not surface `push_error` to GDScript.
func validate() -> PackedStringArray:
	var issues := PackedStringArray()
	if id == &"":
		issues.append("empty id")
	if display_name.is_empty():
		issues.append("empty display_name")
	if field < 0 or field > 3:
		issues.append("field %d out of range [0, 3]" % field)
	if cost <= 0.0:
		issues.append("cost must be positive")
	if tier < 1:
		issues.append("tier must be >= 1")
	if effects.is_empty() and unlocks_ships.is_empty() and unlocks_buildings.is_empty():
		issues.append("node grants nothing at all")
	for prereq in prerequisites:
		if prereq == id:
			issues.append("node lists itself as a prerequisite")
	return issues


## Effect values with a 0.0 default, so callers never index a missing key.
func effect(key: StringName) -> float:
	return float(effects.get(key, 0.0))


## Convenience accessors used by the resolver ---------------------------------------

func movement_bonus() -> float:
	return effect(&"movement")


func sensor_bonus() -> float:
	return effect(&"sensor_range")


func hull_bonus() -> float:
	return effect(&"hull_bonus")


func shield_bonus() -> float:
	return effect(&"shield_bonus")


func weapon_bonus() -> float:
	return effect(&"weapon_bonus")


func accuracy_bonus() -> float:
	return effect(&"accuracy_bonus")


func food_bonus() -> float:
	return effect(&"food_bonus")


func mining_bonus() -> float:
	return effect(&"mining_bonus")


func research_bonus() -> float:
	return effect(&"research_bonus")


func energy_bonus() -> float:
	return effect(&"energy_bonus")


func construction_bonus() -> float:
	return effect(&"construction_bonus")


func bombardment_bonus() -> float:
	return effect(&"bombardment_bonus")


func terraform_power() -> float:
	return effect(&"terraform_power")


func colonization_cost_reduction() -> float:
	return effect(&"colonization_cost")


func weapon_slot_bonus() -> int:
	return int(effect(&"max_ship_slots"))


func shield_slot_bonus() -> int:
	return int(effect(&"max_shield_slots"))


func can_colonize_gas() -> bool:
	return effect(&"can_colonize_gas") > 0.0
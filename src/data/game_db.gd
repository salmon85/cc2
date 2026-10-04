extends Node
## Shared tuning constants autoload.
##
## Every balance number that more than one subsystem reads lives here so the economy has a
## single place to be tuned and the turn resolver never hard-codes a magic number.

## Galactic charter (turn) numbers.
const TURNS_PER_YEAR := 4

## Starting imperial resources handed to each faction.
const START_TREASURY := 1000.0
const START_METALS := 400.0
const START_RARE_ELEMENTS := 150.0
const START_ENERGY := 300.0
const START_TECH_POINTS := 0.0

## Population is measured in millions of colonists.
const START_POPULATION := 3.0

## Growth and consumption.
const BASE_FOOD_PER_MILLION := 1.0
const FOOD_SURPLUS_GROWTH := 0.04
const STARVATION_DECAY := 0.22
const MAX_POP_GROWTH_RATE := 0.15

## Economy.
const MIN_TAX_RATE := 0.0
const MAX_TAX_RATE := 1.0
const DEFAULT_TAX_RATE := 0.35
const BASE_ECONOMY_SIZE := 1.0
const ECONOMY_PER_POPULATION := 0.06
const ECONOMY_PER_STRUCTURE := 0.04

## Morale is 0..100.
const BASE_MORALE := 70.0
const MORALE_PER_TAX_POINT_ABOVE_HALF := -2.2
const MORALE_PER_TAX_POINT_BELOW_HALF := 0.8
const MORALE_PER_STARVATION := -18.0
const MORALE_FROM_FOOD_SURPLUS := 6.0
const REBELLION_MORALE_THRESHOLD := 25.0

## Research.
const RESEARCH_BUDGET_SHARE := 0.30
const TP_PER_FIELD_PER_TP := 1.0

## Movement: parsecs per turn at drive level 0, before propulsion research.
const BASE_MOVEMENT := 1.0
const MOVEMENT_PER_DRIVE_LEVEL := 0.75
const MAX_MOVEMENT := 12.0
## Warp lanes are traversed in a single turn regardless of drive level.
const WARP_LANE_TRAVEL := 0.25

## Sensor ranges in parsecs.
const SCOUT_SENSOR_RANGE := 6.0
const FLEET_SENSOR_RANGE := 3.0
const COLONY_SENSOR_RANGE := 2.0

## Combat.
const SHIELD_ABSORPTION_PER_POINT := 1.0
const BEAM_ACCURACY := 0.75
const MISSILE_ACCURACY := 0.85
const POINT_DEFENSE_ACCURACY := 0.60
const DOGFIGHT_ACCURACY := 0.70
const MAX_COMBAT_ROUNDS := 6
const RETREAT_SALVAGE := 0.5
const FLEET_MORALE_BREAK_THRESHOLD := 0.35

## Invasion.
const BOMBARDMENT_DAMAGE_PER_ROUND := 12.0
const GROUND_ATTACKER_MORALE_MULT := 1.15
const GROUND_DEFENDER_MORALE_MULT := 1.0
const COLONIZATION_COST := 120.0

## Global economy balance.
const TREASURY_FLOOR := -500.0
const MAINTENANCE_PER_COLONY := 4.0
const SHIP_UPKEEP_PER_HULL_POINT := 0.5
const STRUCTURE_UPKEEP := 1.0

## Convenience: the four research fields in slider order.
const TECH_FIELD_ORDER: Array[int] = [
	0, 1, 2, 3,
]


## Build the default research slider allocation (evenly spread).
static func default_research_allocation() -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(4)
	for i in 4:
		out[i] = 0.25
	return out
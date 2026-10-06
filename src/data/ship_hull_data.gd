extends Resource
class_name ShipHullData
## Authored definition of a ship class.
##
## One `.tres` per hull in `res://data/ships/`. Weapon and shield *components* are not
## authored here: hulls define the capacity, and the `tech_nodes` tree supplies the
## components that fill those slots, exactly as the design document describes.

## Stable identifier used by saves, build queues and the AI.
@export var id: StringName = &""

@export var display_name: String = ""

## Functional role, gates which orders the hull may receive.
@export var role: int = 0

## Build cost paid from a colony's shipyard, in metals / rare elements / energy.
@export var cost_metals: float = 10.0
@export var cost_rare: float = 0.0
@export var cost_energy: float = 5.0

## Attack, as the Phase 8 roster states it: damage this hull puts into an opposing hull per
## exchange. `weapon_damage` is what the combat stage actually reads; `attack` is the
## authored figure the design document gives, kept as a named field so a balance pass is an
## edit to a `.tres` rather than a reverse-engineering exercise.
@export var attack: float = 0.0

## Defence, likewise authored. `shield_points` is the derived combat figure.
@export var defense: float = 0.0

## Structural stats.
@export var hull_points: float = 10.0
@export var shield_points: float = 0.0

## Base speed in parsecs/turn before propulsion research. `role` caps how fast it can go.
@export var base_speed: float = 2.0

## Offense: total weapon output and how it is delivered.
@export var weapon_damage: float = 0.0
@export var weapon_accuracy: float = 0.75
## How many weapon components the hull accepts.
@export var weapon_slots: int = 1
## Shields absorb damage before the hull takes it.
@export var shield_slots: int = 0

## Capacities.
@export var cargo_capacity: float = 0.0
## Ground troops this hull can land in an invasion.
@export var troop_capacity: float = 0.0
## Civilians this hull can carry. The Colony Ship holds 5; nothing else lifts people.
@export var civilian_capacity: float = 0.0
## Colonisation kit. A colony hull either carries one or self-destructs to drop one.
@export var colony_kit: bool = false

## Chance per turn, per ship in orbit, of advancing the survey of the world it sits above.
## Additive across a fleet: two Exploration Ships survey at 50%. Only ships with a positive
## rate contribute, so a mixed fleet's rate is the sum of its scouts'.
@export var survey_rate: float = 0.0

## What this hull lifts, for the travel modal's cargo readout and for `TransferStage`.
enum CargoKind {
	NONE,      ## Carries nothing.
	METALS,    ## Ore and ingots.
	FOOD,      ## Rations.
	POWER,     ## Fuel cells and reactor output.
	TROOPS,    ## Military troops.
	CIVILIANS, ## Settlers.
}

## Every kind this hull can carry. A list rather than a single kind because the design
## document's Cargo Transport carries food *and* metal: one "cargo kind" per hull would force
## the choice into the data and leave half of what the hull is described as carrying out of
## the model. The first entry is the one the travel modal shows.
@export var cargo_kinds: Array[int] = []


## The kinds this hull can carry, with the troop and civilian capacities folded in.
##
## A single function rather than a lookup at each call site, because the failure it prevents
## is quiet: a hull authored for metal asked to carry food would read as having no room, and
## the cargo order would simply move nothing.
func carries(kind: int) -> bool:
	if cargo_kinds.has(kind):
		return true
	# Troops and civilians ride in bays, not in the general hold, so a hull with a bay count
	# but no declared kind still lifts them.
	if kind == CargoKind.TROOPS:
		return troop_capacity > 0.0
	if kind == CargoKind.CIVILIANS:
		return civilian_capacity > 0.0
	return false


## The label the travel modal prints for this hull: its first declared kind, or nothing.
func cargo_label() -> String:
	return "" if cargo_kinds.is_empty() else int(cargo_kinds[0])

## Sensor range in parsecs.
@export var sensor_range: float = 3.0

## Bombardment strength against planetary surface defences. 0 means it cannot siege.
@export var bombardment: float = 0.0

## Monthly/turn upkeep drawn from the treasury.
@export var upkeep: float = 1.0

## Cosmetic sprite key.
@export var sprite_variant: int = 0


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
	if role < 0 or role > int(Enums.ShipRole.TROOP):
		issues.append("role %d out of range" % role)
	if hull_points <= 0.0:
		issues.append("hull_points must be positive")
	if base_speed <= 0.0:
		issues.append("base_speed must be positive")
	if weapon_slots < 0:
		issues.append("weapon_slots is negative")
	if weapon_damage > 0.0 and weapon_slots <= 0:
		issues.append("weapon_damage set but no weapon_slots to mount it in")
	if cost_metals < 0.0 or cost_rare < 0.0 or cost_energy < 0.0:
		issues.append("negative build cost")
	if role == int(Enums.ShipRole.SCOUT) and sensor_range < 1.0:
		issues.append("a scout with sensor_range < 1 is useless")
	if role == int(Enums.ShipRole.COLONY) and not colony_kit:
		issues.append("a colony hull needs colony_kit")
	if Enums.role_is_support(role) and cargo_capacity <= 0.0 and troop_capacity <= 0.0 \
			and civilian_capacity <= 0.0:
		issues.append("a support hull that lifts nothing is useless")
	for kind in cargo_kinds:
		if kind < 0 or kind > CargoKind.CIVILIANS:
			issues.append("cargo kind %d is out of range" % kind)
	if survey_rate < 0.0:
		issues.append("survey_rate is negative")
	if survey_rate > 0.0 and role != int(Enums.ShipRole.EXPLORATION):
		issues.append("only an exploration hull surveys")
	return issues


## Maximum speed cap imposed by the hull's role, before drive research.
##
## These are parsecs per turn, and the system is 12000 parsecs across, so every cap is
## fifty times the old galactic value. This matters more than it looks: `fleet_speed` clamps
## to the role cap, so leaving a scout capped at 12 parsecs against a 6000-parsec orbit means
## the fastest ship in the game takes five hundred turns to cross the map and the whole
## fleet-movement layer silently stops working.
const SPEED_SCALE := 50.0


static func role_speed_cap(role: int) -> float:
	var base: float = 3.0
	match role:
		0: base = 12.0  # Scout: the fastest thing in the game.
		1: base = 2.0   # Colony ship: crawl.
		2: base = 3.0   # Transport
		3: base = 5.0   # Corvette
		4: base = 3.5   # Cruiser
		5: base = 2.5   # Dreadnought
		6: base = 10.0  # Exploration ship: fast and fragile.
		7: base = 5.0   # Frigate
		8: base = 4.5   # Destroyer
		9: base = 3.5   # Battlecruiser
		10: base = 3.0  # Battleship
		11: base = 2.8  # Battlestar
		12: base = 2.5  # Titan
		13: base = 2.4  # Leviathan
		14: base = 3.0  # Cargo transport
		15: base = 3.0  # Troop transport
	return base * SPEED_SCALE


## True when this hull may receive the given order type.
static func role_may_receive_order(role: int, order_type: int) -> bool:
	match order_type:
		1: return true                                   # MOVE_FLEET: everyone moves.
		2: return role == 5 and true                      # SIEGE_STAR: capital ships.
		3: return role == 1                               # COLONIZE
		_: return false
extends Resource
class_name BuildingData
## One constructable structure, placed on a colony.
##
## One `.tres` per structure in `res://data/buildings/`.

## Stable identifier referenced by saves and build queues.
@export var id: StringName = &""

@export var display_name: String = ""

## What kind of structure this is, which decides where it may be built and how the
## colony simulation consumes it.
enum Kind {
	MINE,       ## Extracts planetary reserves into the stockpile.
	FARM,       ## Produces food from the local biome.
	FACTORY,    ## Converts metals into production points and enables shipyards.
	SHIELD,     ## Planetary deflector; must be fed energy.
	BATTERY,    ## Surface missile battery; participates in invasion defence.
	GARRISON,   ## Ground troops; the garrison side of an invasion.
	SHIPYARD,   ## Unlocks hull construction for this colony.
	ORBITAL,    ## Station: sensor range and trade income.
	TERRAFORMER,## Raises habitability over time.
}

@export var kind: int = 0

## Build cost paid from the colony's stockpile.
@export var cost_metals: float = 20.0
@export var cost_rare: float = 0.0
@export var cost_energy: float = 0.0

## Turn upkeep paid from the imperial treasury.
@export var upkeep: float = 1.0

## Turns of construction. Structures must finish before they do anything.
@export var build_turns: int = 1

## Per-turn yield, interpreted by `kind`:
##   MINE        metals/rare/energy extracted per pop point
##   FARM        food produced per farm level
##   FACTORY     production points contributed per turn
##   SHIELD      shield points output (scaled by the planet's energy reserve)
##   BATTERY     surface defence strength
##   GARRISON    ground defence strength
##   SHIPYARD    enables the ship build queue
##   ORBITAL     sensor range and flat income
##   TERRAFORMER habitability gained per turn
@export var yield_amount: float = 1.0

## Secondary yield, used for mines (rare) and orbitals (sensor range).
@export var yield_secondary: float = 0.0

## Tertiary yield, used for mines (energy).
@export var yield_tertiary: float = 0.0

## Placement rule.
@export var requires_colony: bool = true
## Colonies may hold at most this many of this structure (0 = unlimited).
@export var max_per_colony: int = 0
## Farms are limited by available land, not by a flat count.
@export var consumes_land: bool = false

## Human-readable effect line for the build menu.
@export var description: String = ""


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
	if kind < 0 or kind > 8:
		issues.append("kind %d out of range" % kind)
	if build_turns < 1:
		issues.append("build_turns must be >= 1")
	if cost_metals < 0.0 or cost_rare < 0.0 or cost_energy < 0.0:
		issues.append("negative build cost")
	if upkeep < 0.0:
		issues.append("negative upkeep")
	if max_per_colony < 0:
		issues.append("max_per_colony is negative")
	if kind == Kind.SHIPYARD and yield_amount <= 0.0:
		issues.append("a shipyard should record a positive yield_amount (build slots)")
	return issues


## Whether `count` copies of this structure can still be added to a colony.
func can_add(count: int) -> bool:
	return max_per_colony == 0 or count < max_per_colony
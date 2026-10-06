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
	CITY,       ## Houses `pop_housed` civilians.
	GRANARY,    ## Adds `food_store` to the colony's food capacity.
	POWER,      ## Generates `yield_amount` power per turn.
	BARRACKS,   ## Converts 1 civilian pop into 1 military troop.
	COLONY_PAD, ## A landed colony ship: housing, food, metal and power.
	STORAGE,    ## Adds `energy_store` to the colony's power storage capacity.
}

## Kinds whose effect is a storage capacity: food for a granary, energy for a battery bank.
const FOOD_STORAGE_KINDS: Array[int] = [Kind.GRANARY]
const ENERGY_STORAGE_KINDS: Array[int] = [Kind.STORAGE]


## Kinds that draw power every turn. Running short blocks new power-hungry construction but
## never shuts an existing structure down.
const POWER_DRAWING_KINDS: Array[int] = [Kind.CITY]

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

## Civilians this structure must be staffed with before it produces anything.
##
## Phase 8 makes population a real cost rather than a multiplier: a farm that nobody works
## feeds nobody, and `ColonySim` reads a structure's output as zero until this many pop
## are available. It is per *structure*, not per turn of work.
@export var pop_required: int = 0

## Civilians this structure houses. City Complexes (20) and a landed Colony Ship (5) are
## the only two sources of population headroom, and the only thing that gates growth.
@export var pop_housed: int = 0

## Power drawn per turn. Only structures in `POWER_DRAWING_KINDS` are counted, so a
## POWER station's output is never netted against its own draw.
@export var power_required: float = 0.0

## Food this structure adds to the colony's storage capacity. Granaries are the only
## source: a colony with none overflows the moment it has a surplus.
@export var food_store: float = 0.0

## Energy this structure adds to the colony's power storage capacity.
@export var energy_store: float = 0.0

## Metals this structure adds per turn, for a `MINE`. Separate from `yield_amount` because
## the Phase 8 roster states mine output as an absolute per-turn figure rather than a
## per-population multiplier, and the old per-pop scaling is what made a mine's output
## depend on a population value that no longer means what it used to.
@export var metal_per_turn: float = 0.0

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
	if kind < 0 or kind > Kind.STORAGE:
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
	if pop_required < 0 or pop_housed < 0:
		issues.append("negative population requirement or housing")
	if power_required < 0.0 or food_store < 0.0 or energy_store < 0.0:
		issues.append("negative power draw or storage capacity")
	if kind == Kind.POWER and yield_amount <= 0.0:
		issues.append("a power station must record a positive yield_amount")
	if kind == Kind.CITY and pop_housed <= 0:
		issues.append("a City Complex houses nobody")
	return issues


## Whether `count` copies of this structure can still be added to a colony.
func can_add(count: int) -> bool:
	return max_per_colony == 0 or count < max_per_colony


## Whether this structure adds to the colony's food storage capacity.
func is_food_storage() -> bool:
	return kind == Kind.GRANARY


## Whether this structure must be fed power before it counts as built.
func draws_power() -> bool:
	return POWER_DRAWING_KINDS.has(kind) and power_required > 0.0
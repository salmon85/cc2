extends Resource
class_name PlanetTypeData
## Authored definition of a planetary body class.
##
## One `.tres` per class in `res://data/planet_types/`. Everything the generator needs to
## roll a planet and the economy needs to run one lives here, so re-balancing a world type
## is an edit to a data file, not to code.

## Stable identifier, referenced by saves and by the generator. Never change after release.
@export var id: StringName = &""

## Display name shown in the system view.
@export var display_name: String = ""

## Which `Enums.PlanetClass` this describes.
@export var planet_class: int = 0

## Base habitability, 0..1. Multiplies max sustainable population and growth rate.
@export var base_habitability: float = 0.5

## Whether a colony ship may settle here without terraforming.
@export var colonizable: bool = true

## Can this class be terraformed into something habitable, and at what cost?
@export var terraformable: bool = false
@export var terraform_cost: float = 0.0

## Resource distribution rolled at generation, in units per population point.
@export var metals_per_pop: float = 0.5
@export var rare_per_pop: float = 0.2
@export var energy_per_pop: float = 0.3

## Starting reserves sitting in the planet's ground stockpile before any colony exists.
@export var base_reserve_metals: float = 120.0
@export var base_reserve_rare: float = 40.0
@export var base_reserve_energy: float = 60.0

## Food the biome yields per unit of agricultural output.
@export var food_yield: float = 1.0

## Sensor radius in parsecs while uncolonised. Colonies extend this.
@export var native_sensor_range: float = 3.0

## Cosmetic: sprite variant key and map colour.
@export var sprite_variant: int = 0
@export var map_color: Color = Color(0.4, 0.7, 0.9)


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
	if base_habitability < 0.0 or base_habitability > 1.0:
		issues.append("base_habitability %f outside [0, 1]" % base_habitability)
	if planet_class < 0 or planet_class > 5:
		issues.append("planet_class %d out of range" % planet_class)
	if food_yield < 0.0:
		issues.append("food_yield is negative")
	if base_reserve_metals < 0.0 or base_reserve_rare < 0.0 or base_reserve_energy < 0.0:
		issues.append("negative base reserves")
	if terraformable and terraform_cost <= 0.0:
		issues.append("terraformable but terraform_cost is zero")
	if not colonizable and not terraformable:
		issues.append("neither colonizable nor terraformable (dead-end world)")
	return issues


## Habitability after any terraforming the player has paid for. Clamped to [0, 1].
func effective_habitability(terraform_progress: float) -> float:
	var bonus: float = clampf(terraform_progress, 0.0, 1.0) * 0.4
	return clampf(base_habitability + bonus, 0.0, 1.0)


## Weight this class should get when rolling an uncolonised body. Gas giants and barren
## rocks are deliberately rare so habitable worlds stay worth racing for.
static func class_weight(cls: int) -> float:
	match cls:
		0: return 34.0  # Terrestrial
		1: return 18.0  # Desert
		2: return 14.0  # Ice
		3: return 8.0   # Volcanic
		4: return 6.0   # Gas Giant
		5: return 20.0  # Barren
	return 1.0
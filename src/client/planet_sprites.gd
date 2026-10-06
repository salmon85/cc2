extends RefCounted
class_name PlanetSprites
## The authored planet and star sprites, loaded once and shared.
##
## Static rather than an autoload: the map view draws inside a `SubViewport` whose tree is
## built in code, and a sprite table that needed a live node would have to be resolved before
## anything could draw. The textures are immutable engine resources, so a process-wide cache
## is the whole of the state there is.
##
## Every accessor returns `null` rather than asserting. A missing or un-imported `.png` must
## not take the map with it -- `GalaxyMapView` falls back to the procedural bodies, which is
## what the board looked like before these sprites existed and is a far better failure than a
## blank field or a hard stop on the first frame.

## The central star. Drawn where the corona was.
const STAR_SPRITE := "Black_hole"

## The worlds, in the order a planet's variant indexes into them.
##
## Order is fixed and not alphabetical for no reason beyond being fixed: a planet's sprite is
## chosen by `variant % size`, so reshuffling this list would silently repaint a saved game's
## entire galaxy.
const PLANET_SPRITES: Array[String] = ["Baren", "Ice", "Lava", "Terran"]

## File extension, appended to every name above. Kept here so a re-export as `.webp` is one
## edit rather than a find-and-replace across the sprite list.
const EXTENSION := ".png"

## Loaded textures, indexed to match `PLANET_SPRITES`. Null until first asked for.
static var _planets: Array[Texture2D] = []
static var _star: Texture2D = null


## The central star's texture, or null if it is not available.
static func star() -> Texture2D:
	if _star == null:
		_star = _load(STAR_SPRITE)
	return _star


## A world's texture, chosen by its variant. Returns null if unavailable.
##
## `variant` is the per-planet integer the generator already rolls and the save file already
## carries, which is what makes the assignment *stable*: the same world shows the same sprite
## on every redraw, in every session, and before and after a save/load. Rolling a fresh
## number here would repaint the whole galaxy on each frame.
static func planet(variant: int) -> Texture2D:
	_planets.resize(PLANET_SPRITES.size())
	var index := posmod(variant, PLANET_SPRITES.size())
	if _planets[index] == null:
		_planets[index] = _load(PLANET_SPRITES[index])
	return _planets[index]


## Whether every sprite named above actually loaded. For a test to assert rather than infer.
static func complete() -> bool:
	if star() == null:
		return false
	for i in PLANET_SPRITES.size():
		if planet(i) == null:
			return false
	return true


static func _load(sprite_name: String) -> Texture2D:
	var path := AssetPaths.graphics_path(sprite_name + EXTENSION)
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D
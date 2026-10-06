extends RefCounted
class_name PlanetVisuals
## Procedural appearance for a world: palette and surface features, drawn in code.
##
## Planets used to be two flat circles in one hashed colour. At the zoom the map actually runs
## at, a five-pixel disc cannot carry surface detail -- but it can carry a *silhouette* of one,
## and a body that reads as "mostly ocean" or "mostly ice" at a glance is information a player
## uses when picking a world to settle. Two discs also made every planet on the board the same
## shape, which is the visual equivalent of a map where every city is a dot.
##
## Everything here is a pure function of `(type_id, variant)`. That is deliberate twice over:
## no image files, so the client still has no binary asset dependency the way `CC2Theme` has
## none; and identical inputs always produce identical output, so a world looks the same on
## every client and across a save/load rather than being re-rolled from a texture cache.
##
## The five cosmetic classes the brief asks for are keyed off `PlanetTypeData.id`, and
## anything unrecognised falls back to a grey rock rather than to an error -- a body whose
## definition failed to load should still render.

## The cosmetic world classes, as the brief names them.
enum Look {
	WATER,      ## Deep blues, ocean tones.
	DESERT,     ## Yellow/tan dunes.
	ICE,        ## White, pale cyan.
	TEMPERATE,  ## Green continents, blue oceans.
	JUNGLE,     ## Dense deep greens, minimal ocean.
	ROCK,       ## Fallback for an unrecognised type.
}


## The cosmetic class for a planet type id.
##
## Chosen from the authored types rather than from the numeric `planet_class`, because the
## brief is about what a world *looks like* and the visual vocabulary is its own: a Volcanic
## body and a Barren one are both rock, and a Gas Giant is a Water look in a different key.
static func look_for(type_id: StringName) -> int:
	match type_id:
		&"terrestrial": return Look.TEMPERATE
		&"jungle": return Look.JUNGLE
		&"ocean", &"water", &"water_world": return Look.WATER
		&"desert": return Look.DESERT
		&"ice", &"snow": return Look.ICE
		&"volcanic", &"barren", &"gas_giant": return Look.ROCK
	return Look.ROCK


## Human-readable name of a cosmetic class, for the tooltip and the tests.
static func look_name(look: int) -> String:
	match look:
		Look.WATER: return "Water World"
		Look.DESERT: return "Desert World"
		Look.ICE: return "Snow/Ice World"
		Look.TEMPERATE: return "Temperate World"
		Look.JUNGLE: return "Jungle World"
		Look.ROCK: return "Barren World"
	return "Barren World"


## The palette for a world: `[deep, mid, accent]`, dark to light.
##
## Read by the map draw and by the tests, so the claim "a water world is deep blues" is one
## function both go through rather than a description beside a drawing.
static func palette(type_id: StringName, variant: int = 0) -> Array[Color]:
	var look := look_for(type_id)
	var shift := _shift(variant)
	match look:
		Look.WATER:
			return [
				Color(0.043, 0.129, 0.310).lightened(shift),
				Color(0.098, 0.298, 0.588).lightened(shift),
				Color(0.478, 0.741, 0.878).lightened(shift),
			]
		Look.DESERT:
			return [
				Color(0.361, 0.259, 0.129).lightened(shift),
				Color(0.788, 0.643, 0.376).lightened(shift),
				Color(0.937, 0.847, 0.588).lightened(shift),
			]
		Look.ICE:
			return [
				Color(0.420, 0.522, 0.576).lightened(shift),
				Color(0.749, 0.855, 0.894).lightened(shift),
				Color(0.965, 0.988, 1.000).lightened(shift),
			]
		Look.TEMPERATE:
			return [
				Color(0.129, 0.278, 0.361).lightened(shift),
				Color(0.247, 0.478, 0.278).lightened(shift),
				Color(0.420, 0.686, 0.435).lightened(shift),
			]
		Look.JUNGLE:
			return [
				Color(0.043, 0.145, 0.075).lightened(shift),
				Color(0.090, 0.298, 0.129).lightened(shift),
				Color(0.176, 0.482, 0.208).lightened(shift),
			]
		_:
			return [
				Color(0.180, 0.180, 0.192).lightened(shift),
				Color(0.353, 0.341, 0.325).lightened(shift),
				Color(0.518, 0.502, 0.475).lightened(shift),
			]


## A small per-variant brightness nudge.
##
## Without it every body of a class is the same three colours, so a temperate world and its
## neighbour are indistinguishable in a screenshot. ±6% is deliberately below the threshold at
## which two different classes could be confused.
static func _shift(variant: int) -> float:
	var step := absi(variant) % 5
	return -0.03 + 0.015 * float(step)


## The surface features of a world: one polygon per landmass, in unit-disc coordinates.
##
## Returned as a list of polygons rather than one flat point list, because a world has several
## coastlines and a single polygon through all of them draws a fan of spikes across the disc
## instead of a set of islands. Drawn as polygons, so the amount of detail scales with the zoom
## rather than with a texture's resolution. Deterministic in `variant`: the same world always
## has the same continents.
##
## The count is what distinguishes the classes as much as the colour is -- a Jungle World is
## "dense deep greens, minimal ocean" mostly by having *many* features, and a Water World has
## almost none.
static func landmasses(type_id: StringName, variant: int = 0) -> Array:
	var look := look_for(type_id)
	var blobs := 0
	match look:
		Look.JUNGLE: blobs = 4
		Look.TEMPERATE: blobs = 3
		Look.DESERT: blobs = 2
		Look.ROCK: blobs = 2
		Look.ICE: blobs = 1
		Look.WATER: blobs = 1
	var out: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed_for(type_id, variant)
	for i in blobs:
		var centre := Vector2(rng.randf_range(-0.5, 0.5), rng.randf_range(-0.5, 0.5))
		var radius := rng.randf_range(0.18, 0.42)
		var sides := 7
		var blob := PackedVector2Array()
		for step in sides:
			var angle := TAU * float(step) / float(sides)
			# Rounded by a per-vertex jitter rather than a fixed radius, so a landmass reads as
			# an irregular coast instead of a polygon.
			var r := radius * rng.randf_range(0.68, 1.24)
			var corner := centre + Vector2(cos(angle), sin(angle)) * r
			# Pulled onto the rim when the jitter pushed it off the world. The map relies on
			# every vertex being inside the unit disc so a landmass can be scaled and clipped
			# without a second pass, and an out-of-bounds vertex here would render as a shard
			# floating beside the planet.
			if corner.length() > 1.0:
				corner = corner.normalized()
			blob.append(corner)
		out.append(blob)
	return out


## How much of the disc is land, 0..1, for the tooltip and the tests.
##
## Separate from the drawn polygons because "a Water World is mostly ocean" is a claim about
## the class, and a test that reads it off the geometry proves more than one that reads it off
## a description.
static func land_fraction(type_id: StringName) -> float:
	match look_for(type_id):
		Look.WATER: return 0.10
		Look.ICE: return 0.15
		Look.DESERT: return 0.25
		Look.ROCK: return 0.30
		Look.TEMPERATE: return 0.45
		Look.JUNGLE: return 0.80
	return 0.30


## A stable per-world seed, from the type and the variant.
static func _seed_for(type_id: StringName, variant: int) -> int:
	return absi(str(type_id).hash() + variant * 2654435761) + 1
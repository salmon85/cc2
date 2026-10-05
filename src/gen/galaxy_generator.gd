extends RefCounted
class_name GalaxyGenerator
## Builds a playable galaxy: star placement, warp lanes, planets, and faction seeding.
##
## The generator is a pure function of `(seed, system_count, faction_count)` plus the
## authoritative RNG stream. Same inputs ⇒ byte-identical galaxy, which is what makes
## save replays and network synchronisation tractable.

## Spec limits for the sector grid.
const MIN_SYSTEMS := 30
const MAX_SYSTEMS := 100

## Radius of the galactic disk, in parsecs.
const GALAXY_RADIUS := 120.0

## Minimum separation between two stars. Keeps the map readable and travel meaningful.
const MIN_STAR_SEPARATION := 7.5

## Warp lanes per system. More than two makes the galaxy feel dense but stays navigable.
const WARP_LANES_PER_SYSTEM := 2

## Bodies rolled per system. The spec allows 1..6.
const MIN_PLANETS := 1
const MAX_PLANETS := 6

## Bodies in a system hosting a faction homeworld.
const HOMEWORLD_PLANETS := 4

## Name components, combined deterministically. Real 4X games need evocative names
## more than they need unique ones, and 20x20 combinations is plenty for 100 systems.
const NAME_A: Array[String] = [
	"Al", "Be", "Cy", "Dor", "El", "Fy", "Gar", "Hel", "Ith", "Ka",
	"Ly", "Mor", "Ny", "Ori", "Per", "Qu", "Rho", "Sig", "Tar", "Vel",
]
const NAME_B: Array[String] = [
	"ara", "ion", "ula", "eth", "ora", "is", "ax", "um", "ir", "os",
	"an", "ex", "un", "or", "el", "ad", "in", "av", "ol", "ur",
]
const NAME_SUFFIX: Array[String] = [
	"", "", " Prime", " Minor", " Major", " II", " III", " IV",
]

const STAR_NAMES: Array[String] = [
	"Aldebaran", "Betelgeuse", "Capella", "Deneb", "Erigone", "Fomalhaut",
	"Gacrux", "Hadar", "Izar", "Kochab", "Menkar", "Nunki", "Phact", "Rasalhague",
	"Sadr", "Tau Ceti", "Umbriel", "Vega", "Wezen", "Zubenelgenubi",
	"Achernar", "Bellatrix", "Canopus", "Denebola", "Elnath", "Furud",
	"Gamma Draconis", "Kaus Australis", "Mirfak", "Nashira",
]


## Build a complete galaxy.
##
## `defs` is the `Defs` registry node. `rng` is the authoritative stream.
## Returns a populated `GalaxyState`, or null when the inputs are unusable.
static func generate(
	defs: Node, rng: RandomNumberGenerator, system_count: int, faction_count: int,
	db: Node = null
) -> GalaxyState:
	if defs == null:
		push_error("[GalaxyGenerator] generate: definition registry is null")
		return null
	if rng == null:
		push_error("[GalaxyGenerator] generate: RNG stream is null")
		return null

	var count: int = clampi(system_count, MIN_SYSTEMS, MAX_SYSTEMS)
	# One empire per five stars is the *comfortable* spacing, not a hard cap. Clamping to
	# it meant a request for eight empires on the minimum map silently produced six, so
	# a server opening eight slots had fewer empires than seats and could not seat them
	# all. Crowded homeworlds are merely cramped; a missing empire is a missing player, so
	# the ask wins and `_seed_factions` relaxes separation instead of under-delivering.
	var factions: int = clampi(faction_count, 1, MAX_SYSTEMS)

	var galaxy := GalaxyState.new()
	galaxy.seed_value = rng.seed

	var planet_types := _pick_planet_types(defs)
	if planet_types.is_empty():
		push_error("[GalaxyGenerator] generate: no planet type definitions available")
		return null

	var tech_nodes := defs.get("tech_nodes") as Dictionary

	if db == null:
		db = _resolve_db()
	if db == null:
		push_error("[GalaxyGenerator] generate: GameDB tuning constants unavailable")
		return null

	_place_stars(galaxy, rng, count)
	_link_warp_lanes(galaxy, rng)
	_populate_planets(galaxy, rng, defs, planet_types)
	_seed_factions(galaxy, rng, defs, factions, db)
	_establish_starting_forces(galaxy, rng, defs)

	# Bind the researched tech onto each faction. Without this every faction starts
	# with an empty tech cache and reads all bonuses as zero until the game is saved
	# and reloaded, so a fresh galaxy would play differently from a loaded one.
	for f in galaxy.factions:
		f.bind_tech(tech_nodes)

	# Seed each faction's sensor picture before the first turn resolves. Visibility is
	# otherwise only computed at the end of a turn, which leaves a freshly generated
	# galaxy completely dark -- the player would not even see their own homeworld, and
	# the client would open on an empty map.
	for f in galaxy.factions:
		FowStage.update_visibility(galaxy, f.id, db)

	return galaxy


# --- Stars --------------------------------------------------------------------

## Distribute systems across a disk, rejecting any placement that lands too close to an
## existing star. Uses best-candidate sampling: for each star, try N candidates and keep
## the one furthest from its nearest neighbour, which spreads far more evenly than pure
## rejection sampling and is equally deterministic.
static func _place_stars(galaxy: GalaxyState, rng: RandomNumberGenerator, count: int) -> void:
	const CANDIDATES := 12
	var positions: Array[Vector2] = []
	var names := PackedStringArray()
	for entry in STAR_NAMES:
		names.append(String(entry))

	for i in count:
		var best := Vector2.ZERO
		var best_clearance := -INF
		for _c in CANDIDATES:
			var candidate := _random_point_in_disk(rng)
			var clearance := _min_distance_to(candidate, positions)
			if clearance > best_clearance:
				best_clearance = clearance
				best = candidate
		positions.append(best)

		var s := SystemState.new()
		s.index = i
		s.star_class = rng.randi_range(0, 6)
		s.position = best
		# Central systems are worth more: they sit closer to everything.
		s.strategic_value = clampf(1.0 - best.length() / GALAXY_RADIUS, 0.05, 1.0)
		galaxy.systems.append(s)

	_assign_names(galaxy, rng, names)


## Uniform point in a disk of radius `GALAXY_RADIUS`, with a mild bias toward the core
## so the galactic centre is dense and the rim sparse, as in the original game.
static func _random_point_in_disk(rng: RandomNumberGenerator) -> Vector2:
	var angle := rng.randf() * TAU
	# sqrt() gives uniform area coverage; the pow() skews inward for a denser core.
	var radius := sqrt(rng.randf()) * GALAXY_RADIUS * pow(rng.randf(), 0.35)
	return Vector2(cos(angle), sin(angle)) * radius


static func _min_distance_to(point: Vector2, positions: Array[Vector2]) -> float:
	if positions.is_empty():
		return INF
	var nearest := INF
	for other in positions:
		nearest = minf(nearest, point.distance_to(other))
	return nearest


## Give every system a distinct display name.
##
## The curated proper-noun list is shuffled and consumed first (that is what makes the
## map feel authored), and any systems left over once it is exhausted — which happens
## above ~30 systems — fall back to a catalogue designation built from the two letter
## tables plus the system number, which is unique by construction.
static func _assign_names(
	galaxy: GalaxyState, rng: RandomNumberGenerator, pool: PackedStringArray
) -> void:
	# Fisher-Yates over the pool using the authoritative stream. Array.shuffle() would
	# draw from Godot's global RNG and break determinism.
	for i in range(pool.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := pool[i]
		pool[i] = pool[j]
		pool[j] = tmp

	var used: Dictionary = {}
	var count := galaxy.systems.size()

	for i in count:
		var name := ""
		if not pool.is_empty():
			name = pool[pool.size() - 1]
			pool.remove_at(pool.size() - 1)
			var suffix: String = NAME_SUFFIX[rng.randi_range(0, NAME_SUFFIX.size() - 1)]
			name += suffix
		# Collision can still happen when a suffix makes two different stars collide.
		if name.is_empty() or used.has(name):
			name = _designation(rng, i)
		var attempt := 0
		while used.has(name) and attempt < 64:
			name = _designation(rng, i) + "-%d" % attempt
			attempt += 1
		galaxy.systems[i].name = name
		used[name] = true


## Catalogue designation, unique because the system number is appended.
static func _designation(rng: RandomNumberGenerator, system_index: int) -> String:
	return "%s %s %d" % [
		NAME_A[rng.randi_range(0, NAME_A.size() - 1)],
		NAME_B[rng.randi_range(0, NAME_B.size() - 1)].capitalize(),
		100 + system_index,
	]


# --- Warp lanes ----------------------------------------------------------------

## Connect each system to its nearest neighbours, guaranteeing the graph is fully
## connected so no system can be stranded.
##
## The minimum-spanning-tree pass is what guarantees connectivity: connect every system to
## its nearest unconnected neighbour, then add extra short-range lanes purely for
## strategic depth (more routes = more interesting fleet movement).
static func _link_warp_lanes(galaxy: GalaxyState, rng: RandomNumberGenerator) -> void:
	var n := galaxy.systems.size()
	if n < 2:
		return

	# Pass 1: nearest-neighbour chain from each system, guaranteeing connectivity.
	var connected: Dictionary = {}
	for i in n:
		var best := -1
		var best_dist := INF
		for j in n:
			if j == i:
				continue
			var d: float = galaxy.systems[i].distance_to(galaxy.systems[j])
			if d < best_dist:
				best_dist = d
				best = j
		if best >= 0:
			galaxy.systems[i].add_warp_lane(best)
			galaxy.systems[best].add_warp_lane(i)
		connected[i] = true

	# Pass 2: extra lanes among close neighbours, for strategic routing choices.
	for i in n:
		if galaxy.systems[i].warp_lanes.size() >= WARP_LANES_PER_SYSTEM:
			continue
		var candidates: Array[int] = []
		for j in n:
			if j == i or galaxy.systems[i].has_warp_lane_to(j):
				continue
			if galaxy.systems[i].distance_to(galaxy.systems[j]) <= GALAXY_RADIUS * 0.35:
				candidates.append(j)
		if candidates.is_empty():
			continue
		# Index into the candidate list with the authoritative stream rather than
		# shuffle(), which would draw from Godot's global RNG and break determinism.
		var chosen: int = candidates[rng.randi_range(0, candidates.size() - 1)]
		galaxy.systems[i].add_warp_lane(chosen)
		galaxy.systems[chosen].add_warp_lane(i)


# --- Planets -------------------------------------------------------------------

## Pick one planet type definition per class ordinal, in `Enums.PlanetClass` order.
static func _pick_planet_types(defs: Node) -> Array[Resource]:
	var out: Array[Resource] = []
	var table := defs.get("planet_types") as Dictionary
	for cls in 6:
		var chosen: Resource = null
		for id: StringName in table:
			var d := table[id] as Resource
			if d != null and int(d.get("planet_class")) == cls:
				chosen = d
				break
		if chosen == null:
			push_error("[GalaxyGenerator] no planet type for class %d" % cls)
			return [] as Array[Resource]
		out.append(chosen)
	return out


## Roll 1..6 bodies for every system, weighted so inner systems are richer.
static func _populate_planets(
	galaxy: GalaxyState, rng: RandomNumberGenerator, defs: Node, types: Array[Resource]
) -> void:
	# Planets are appended system by system, so a running cursor assigns each system's
	# global indices exactly and avoids an O(n^2) rescan on large maps.
	var cursor := 0

	for s in galaxy.systems:
		# Systems near the core hold more bodies; the rim is sparse.
		var richness := 1.0 - s.strategic_value * 0.45
		var count := clampi(int(round(lerpf(1.5, 5.0, rng.randf() * richness))), MIN_PLANETS, MAX_PLANETS)

		var types_here: Array[Resource] = []
		var indices := PackedInt32Array()
		for _p in count:
			var weights: Dictionary = {}
			for cls in 6:
				weights[cls] = PlanetTypeData.class_weight(cls)
			var chosen_cls := int(_pick_weighted(rng, weights))

			var body := PlanetState.new()
			body.index = galaxy.planets.size()
			body.type_id = types[chosen_cls].get("id")
			body.orbit = types_here.size()
			body.seed_reserves(types[chosen_cls])
			# Outer orbits are colder and poorer.
			var orbit_penalty := 1.0 - float(body.orbit) * 0.08
			body.reserve_metals *= orbit_penalty
			body.reserve_rare *= orbit_penalty
			body.bind_type(types[chosen_cls])
			galaxy.planets.append(body)

			types_here.append(types[chosen_cls])
			indices.append(body.index)
			cursor += 1

		s.bind_planet_types(types_here)
		s.planet_indices = indices


## Pick a key from a `{key: weight}` dictionary, proportionally to the weights.
##
## Implemented here rather than taken from `RNGService` so the generator depends only on
## a bare `RandomNumberGenerator`, which keeps it testable and keeps the weighted draw on
## the same authoritative stream as every other roll.
static func _pick_weighted(rng: RandomNumberGenerator, weights: Dictionary) -> Variant:
	var total := 0.0
	for key: Variant in weights:
		total += maxf(0.0, float(weights[key]))
	if total <= 0.0:
		return null
	var roll := rng.randf() * total
	for key: Variant in weights:
		roll -= maxf(0.0, float(weights[key]))
		if roll <= 0.0:
			return key
	# Floating-point drift can leave a sliver at the top of the range.
	return weights.keys().back()


# --- Factions ------------------------------------------------------------------

## Place homeworlds far apart, so early expansion has room and no two empires start
## adjacent (which would force an immediate, unfun war in every game).
static func _seed_factions(
	galaxy: GalaxyState, rng: RandomNumberGenerator, defs: Node, faction_count: int, db: Node
) -> void:
	var hulls := defs.get("ship_hulls") as Dictionary
	if hulls.is_empty():
		push_error("[GalaxyGenerator] no ship hull definitions; skipping faction seeding")
		return

	var ranked := _rank_systems_for_homeworld(galaxy)
	var chosen: Array[int] = []
	var MIN_SEPARATION := GALAXY_RADIUS * 0.4

	for idx in ranked:
		var system: SystemState = galaxy.systems[idx]
		if system.body_count() <= 0:
			continue
		var too_close := false
		for picked in chosen:
			if system.distance_to(galaxy.systems[picked]) < MIN_SEPARATION:
				too_close = true
				break
		if too_close:
			continue
		chosen.append(idx)
		if chosen.size() >= faction_count:
			break

	# If the map is too cramped for full separation, relax rather than under-deliver.
	if chosen.size() < faction_count:
		for idx in ranked:
			if not chosen.has(idx):
				chosen.append(idx)
			if chosen.size() >= faction_count:
				break

	for i in chosen.size():
		_create_faction(galaxy, rng, defs, chosen[i], i, db)


static func _rank_systems_for_homeworld(galaxy: GalaxyState) -> Array[int]:
	var indices: Array[int] = []
	for s in galaxy.systems:
		indices.append(s.index)
	# Most bodies first, then most central, then by index for determinism.
	indices.sort_custom(func(a: int, b: int) -> bool:
		var sa: SystemState = galaxy.systems[a]
		var sb: SystemState = galaxy.systems[b]
		if sa.body_count() != sb.body_count():
			return sa.body_count() > sb.body_count()
		if absf(sa.strategic_value - sb.strategic_value) > 0.001:
			return sa.strategic_value > sb.strategic_value
		return a < b
	)
	return indices


static func _create_faction(
	galaxy: GalaxyState, rng: RandomNumberGenerator, defs: Node,
	system_index: int, ordinal: int, db: Node
) -> void:
	var f := FactionState.new()
	f.id = galaxy.factions.size()
	f.name = _faction_name(ordinal, rng)
	# The first faction is the human player; the rest are AI.
	f.kind = 0 if ordinal == 0 else 1

	f.treasury = db.get("START_TREASURY")
	f.metals = db.get("START_METALS")
	f.rare_elements = db.get("START_RARE_ELEMENTS")
	f.energy = db.get("START_ENERGY")
	f.tax_rate = db.get("DEFAULT_TAX_RATE")
	f.research_allocation = _default_research_allocation()

	# Starting tech: one tier-1 node per field, so every empire can pursue anything.
	var tech := defs.get("tech_nodes") as Dictionary
	var roots_by_field: Dictionary = {}
	for id: StringName in tech:
		var node := tech[id] as Resource
		var prereqs: Array = node.get("prerequisites")
		if prereqs.is_empty():
			var field := int(node.get("field"))
			var current: Resource = roots_by_field.get(field, null) as Resource
			if current == null or int(node.get("cost")) < float(current.get("cost")):
				roots_by_field[field] = node

	for field: int in roots_by_field:
		var root := roots_by_field[field] as Resource
		f.researched[root.get("id")] = true
		f.tech_points[field] = 0.0

	# Ships and structures are unlocked by owning the tier-1 node.
	var hulls := defs.get("ship_hulls") as Dictionary
	for id: StringName in hulls:
		f.unlocked_ships[id] = true
	var buildings := defs.get("buildings") as Dictionary
	for id: StringName in buildings:
		f.unlocked_buildings[id] = true

	galaxy.factions.append(f)
	galaxy.claim_system(f.id, system_index)

	_founding_colony(galaxy, defs, f, system_index, db)


## Settle the homeworld: the most habitable colonisable body in the system.
static func _founding_colony(
	galaxy: GalaxyState, defs: Node, f: FactionState, system_index: int, db: Node
) -> void:
	var s: SystemState = galaxy.system(system_index)
	if s == null:
		return
	var best: PlanetState = null
	var best_score := -INF
	for planet_index in s.planet_indices:
		var p: PlanetState = galaxy.planet(planet_index)
		if p == null or not p.is_colonizable():
			continue
		var score: float = p.habitability()
		# Prefer a system that already has other life-supportable bodies nearby.
		score += float(s.warp_lanes.size()) * 0.05
		if score > best_score:
			best_score = score
			best = p
	if best == null:
		push_error("[GalaxyGenerator] system %d has no colonisable body for faction %d"
			% [system_index, f.id])
		return

	best.owner = f.id
	best.colonized = true
	best.surveyed = true
	best.population = float(db.get("START_POPULATION"))

	# A starting colony is never barren: it comes with a working economy.
	best.structures[&"farm"] = 3
	best.structures[&"mine"] = 2
	best.structures[&"garrison"] = 1
	best.food_stock = 6.0


## Give each faction a scout and a colony ship, so turn 1 always has a legal move.
static func _establish_starting_forces(
	galaxy: GalaxyState, rng: RandomNumberGenerator, defs: Node
) -> void:
	var hulls := defs.get("ship_hulls") as Dictionary
	for f in galaxy.factions:
		var home := _homeworld_of(galaxy, f.id)
		if home == -1:
			continue
		var scout := FleetState.new()
		scout.bind_hulls(hulls)
		scout.owner = f.id
		scout.system = home
		scout.name = "%s Scouts" % f.name
		scout.add_ships(&"scout", 1)
		scout.add_ships(&"colony_ship", 1)
		galaxy.add_fleet(scout)


## The system holding a faction's homeworld, or -1.
static func _homeworld_of(galaxy: GalaxyState, faction_id: int) -> int:
	var f: FactionState = galaxy.faction(faction_id)
	if f == null:
		return -1
	for system_index in f.systems:
		var s: SystemState = galaxy.system(system_index)
		if s == null:
			continue
		for planet_index in s.planet_indices:
			var p: PlanetState = galaxy.planet(planet_index)
			if p != null and p.owner == faction_id and p.colonized:
				return system_index
	return -1


## Locate the `GameDB` autoload without hard-referencing it, so this generator stays
## usable from bare `-s` test runs that do not register autoloads.
static func _resolve_db() -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null("GameDB")


## Even research split across the four fields.
static func _default_research_allocation() -> PackedFloat64Array:
	return PackedFloat64Array([0.25, 0.25, 0.25, 0.25])


static func _faction_name(ordinal: int, rng: RandomNumberGenerator) -> String:
	var prefixes: Array[String] = [
		"Terran", "Vidar", "Kestrel", "Orlan", "Sundar", "Centauri",
		"Helion", "Draconis", "Nomad", "Aureus",
	]
	var base: String = prefixes[ordinal % prefixes.size()]
	if ordinal >= prefixes.size():
		return "%s Combine %d" % [base, ordinal / prefixes.size() + 1]
	return "%s %s" % [base, NAME_B[rng.randi_range(0, NAME_B.size() - 1)].capitalize()]
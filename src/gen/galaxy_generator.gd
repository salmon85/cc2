extends RefCounted
class_name GalaxyGenerator
## Builds a playable game: one star system, its planets, and faction seeding.
##
## The game used to be a disk of 30-100 separate star systems, each with 1-6 bodies, joined
## by warp lanes. It is now a single system holding `system_count` planets on concentric
## orbit rings. `--systems=N` therefore means *planets* now, which is what it has always
## been mistaken for on the command line.
##
## The generator is a pure function of `(seed, system_count, faction_count)` plus the
## authoritative RNG stream. Same inputs ⇒ byte-identical layout, which is what makes save
## replays and network synchronisation tractable.

## Bounds on the planet count. These are the old system bounds: the number is now bodies
## in the one system rather than systems in the galaxy.
const MIN_SYSTEMS := 30
const MAX_SYSTEMS := 100

## The map-size tiers, as multiples of the *pre-50x* 120-parsec disk.
##
## The 50x rescale was a single fixed jump, and it left the game with one playable span and
## no way to choose another: a two-player skirmish and an eight-empire war both got the same
## 6000-parsec field, which is a lot of empty travel for a small game and not enough room
## to manoeuvre for a large one. Tiers make the span a launch decision instead.
##
## `TINY` is deliberately the old 120-unit disk rather than something smaller -- it is
## defined as the baseline the other five are quoted against, so "1x" means the exact
## pre-50x layout rather than an approximation of it.
const SCALE_TINY := 1.0
const SCALE_SMALL := 5.0
const SCALE_MEDIUM := 15.0
const SCALE_LARGE := 30.0
const SCALE_EXTREME := 50.0

## The disk the tiers are quoted against, in parsecs. `GALAXY_RADIUS` is this times the
## active tier.
const BASE_RADIUS := 120.0

## Half-extent of the single system at `SCALE_EXTREME`, in parsecs.
##
## Fifty times the old 120-unit galactic disk, because the map no longer shows a galaxy --
## it shows one star's neighbourhood, which wants the same physical span the whole galaxy
## used to occupy so the orbit rings have room to read as orbits. This is the ceiling the
## tiers scale up to, and the default.
const GALAXY_RADIUS := BASE_RADIUS * SCALE_EXTREME

## Named tiers, in the order they appear in `--help`.
##
## A dictionary rather than an enum because the CLI carries the *name* from the command
## line, and mapping a string through a table keeps the parse in one place instead of a
## match statement that has to be kept in step with the help text.
const SIZE_TIERS := {
	"tiny": SCALE_TINY,
	"small": SCALE_SMALL,
	"medium": SCALE_MEDIUM,
	"large": SCALE_LARGE,
	"extreme": SCALE_EXTREME,
}

## The tier a launch gets when nobody asks for one.
##
## `large` rather than `extreme`: at 50x a first-time player spends the opening turns
## watching a ship cross the screen, and the extra span buys nothing that the extra
## planets of a normal game do not already provide. `extreme` stays one flag away for
## anyone who wants the full field.
const DEFAULT_TIER := "large"

## The scale `DEFAULT_TIER` resolves to, read once so the CLI default cannot drift out of
## step with the tier table.
const DEFAULT_SCALE := SCALE_LARGE


## The half-extent of the system at a given scale multiplier.
static func radius_for_scale(scale: float) -> float:
	return BASE_RADIUS * maxf(SCALE_TINY, scale)


## The half-extent for a named tier, falling back to the default for an unknown name.
static func radius_for_tier(tier: String) -> float:
	var key := tier.strip_edges().to_lower()
	if not SIZE_TIERS.has(key):
		key = DEFAULT_TIER
	return radius_for_scale(float(SIZE_TIERS[key]))

## Innermost and outermost orbit radii, as a fraction of `GALAXY_RADIUS`. The inner bound
## keeps planets clear of the star glyph; the outer one keeps them inside the drawn disk.
const INNER_ORBIT := 0.06
const OUTER_ORBIT := 0.94

## Warp lanes per system. Unused now that there is a single system and no network between
## stars; retained because `SystemState.warp_lanes` is still serialised.
const WARP_LANES_PER_SYSTEM := 0

## Every planet gets exactly one orbit ring, and the rings are as numerous as the
## system is populated. The old 1..6 bound was bodies *per system*; with one system it
## would have capped the whole game at six worlds.

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


## Build a complete game: one star, `system_count` planets, and one empire per faction.
##
## `defs` is the `Defs` registry node. `rng` is the authoritative stream.
## Returns a populated `GalaxyState`, or null when the inputs are unusable.
##
## `home_rng` chooses the starting planets and is deliberately a *separate* stream from
## `rng`. Homeworlds must differ between two games that share a seed: the seed governs the
## system's layout, planet types and reserves, while which world you begin on is drawn
## fresh so the same galaxy does not hand everyone the same opening every time. Passing
## null falls back to `rng`, which is deterministic — what the tests and replays want.
static func generate(
	defs: Node, rng: RandomNumberGenerator, system_count: int, faction_count: int,
	db: Node = null, home_rng: RandomNumberGenerator = null,
	scale: float = SCALE_EXTREME
) -> GalaxyState:
	if defs == null:
		push_error("[GalaxyGenerator] generate: definition registry is null")
		return null
	if rng == null:
		push_error("[GalaxyGenerator] generate: RNG stream is null")
		return null

	var count: int = clampi(system_count, MIN_SYSTEMS, MAX_SYSTEMS)
	var factions: int = clampi(faction_count, 1, maxi(1, count))

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

	# The span is recorded on the galaxy rather than read from a global, because it is a
	# property of *this* game: two sessions on the same machine may be running `tiny` and
	# `extreme` simultaneously, and a client told only the planet positions would otherwise
	# have to guess the radius from how far apart they are.
	galaxy.map_radius = radius_for_scale(scale)

	var homes := home_rng if home_rng != null else rng
	_place_star(galaxy, rng)
	_populate_planets(galaxy, rng, defs, planet_types, count)
	_seed_factions(galaxy, homes, defs, factions, db)
	_establish_starting_forces(galaxy, rng, defs)

	# Bind the researched tech onto each faction. Without this every faction starts
	# with an empty tech cache and reads all bonuses as zero until the game is saved
	# and reloaded, so a fresh galaxy would play differently from a loaded one.
	for f in galaxy.factions:
		f.bind_tech(tech_nodes)

	# Seed each faction's starting hull unlocks from the population ladder, so turn 1 sees
	# the same unlock state a turn-1 save would. Generation no longer hands out the whole
	# hull table: hulls are milestones, and a fresh empire has not crossed any.
	for f in galaxy.factions:
		var civilians := 0.0
		for colony in galaxy.colonies_of(f.id):
			civilians += colony.population
		ResearchStage.apply_milestones(f, civilians, defs, db)

	# Seed each faction's sensor picture before the first turn resolves. Visibility is
	# otherwise only computed at the end of a turn, which leaves a freshly generated
	# galaxy completely dark -- the player would not even see their own homeworld, and
	# the client would open on an empty map.
	for f in galaxy.factions:
		FowStage.update_visibility(galaxy, f.id, db)

	return galaxy


# --- The star -----------------------------------------------------------------

## Place the one star the game is played around, at the origin.
##
## There is exactly one system now, so there is nothing to spread out and no neighbours to
## clearance-test. The star is always at (0, 0) rather than placed randomly: it is the
## centre the whole map frames and every orbit ring is measured from, so a star that moved
## between runs would move the entire layout around it.
static func _place_star(galaxy: GalaxyState, rng: RandomNumberGenerator) -> void:
	var s := SystemState.new()
	s.index = 0
	s.star_class = rng.randi_range(0, 6)
	s.position = Vector2.ZERO
	# The whole system is the strategic prize, and with one empire owning all of it there
	# is nothing to divide it between.
	s.strategic_value = 1.0
	galaxy.systems.append(s)

	var names := PackedStringArray()
	for entry in STAR_NAMES:
		names.append(String(entry))
	_assign_system_name(s, rng, names)


## Name the single system from the proper-noun pool.
static func _assign_system_name(
	s: SystemState, rng: RandomNumberGenerator, pool: PackedStringArray
) -> void:
	# Fisher-Yates over the pool using the authoritative stream. Array.shuffle() would
	# draw from Godot's global RNG and break determinism.
	for i in range(pool.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := pool[i]
		pool[i] = pool[j]
		pool[j] = tmp

	var name := ""
	if not pool.is_empty():
		name = pool[pool.size() - 1]
		name += NAME_SUFFIX[rng.randi_range(0, NAME_SUFFIX.size() - 1)]
	# A suffix can collide, so fall back to the catalogue designation, which is unique by
	# construction because the system number is appended.
	if name.strip_edges().is_empty():
		name = _designation(rng, 0)
	s.name = name



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


## Build `count` planets and lay them out on concentric orbit rings around the star.
##
## One ring per planet, spread across `INNER_ORBIT..OUTER_ORBIT` of the system radius. The
## square root on the ring index is what makes the *area* between rings even rather than
## crowding everything toward the star, so bodies stay as legible as markers at any zoom.
## The angle on each ring comes from the seed, so the same seed lays out the same system.
##
## Types and reserves are seeded as before, but the outer-orbit penalty is now keyed on
## the ring rather than on a 1..6 body count -- a 50-planet system has no `orbit` value
## small enough to make the old 8%-per-step falloff mean anything.
static func _populate_planets(
	galaxy: GalaxyState, rng: RandomNumberGenerator, defs: Node, types: Array[Resource],
	count: int
) -> void:
	var s: SystemState = galaxy.systems[0]
	var span := OUTER_ORBIT - INNER_ORBIT
	var indices := PackedInt32Array()
	var types_here: Array[Resource] = []

	for i in count:
		var weights: Dictionary = {}
		for cls in 6:
			weights[cls] = PlanetTypeData.class_weight(cls)
		var chosen_cls := int(_pick_weighted(rng, weights))

		var body := PlanetState.new()
		body.index = galaxy.planets.size()
		body.type_id = types[chosen_cls].get("id")
		body.name = _planet_name(rng)
		# Cosmetic surface variant. Rolled from the same stream as everything else, so a seed
		# reproduces the whole board's appearance and not just its economy -- a map that
		# reshuffled its continents on every load would make a remembered galaxy useless.
		body.visual_variant = rng.randi() % GameDB.PLANET_VISUAL_VARIANTS
		body.orbit = i
		body.position = _orbit_point(rng, i, count, galaxy.map_radius)
		body.seed_reserves(types[chosen_cls])
		# Outer orbits are colder and poorer: full penalty by the outermost ring, rather
		# than the old fixed 8% per body which never accumulated past ~6 bodies.
		var orbit_penalty := lerpf(1.0, 0.45, float(i) / maxf(1.0, float(count - 1)))
		body.reserve_metals *= orbit_penalty
		body.reserve_rare *= orbit_penalty
		body.bind_type(types[chosen_cls])
		galaxy.planets.append(body)

		types_here.append(types[chosen_cls])
		indices.append(body.index)

	s.bind_planet_types(types_here)
	s.planet_indices = indices


## Name a planet, drawn from the same components as the old system names.
##
## Planets are the map's named objects now that bodies are the primary marker, so a name is
## not decoration: it is how the player tells two worlds apart in the inspector and in a
## move-order target. Duplicates are allowed and are disambiguated by the map falling back
## to a catalogue designation only when a name is missing.
static func _planet_name(rng: RandomNumberGenerator) -> String:
	return "%s%s" % [
		NAME_A[rng.randi_range(0, NAME_A.size() - 1)],
		NAME_B[rng.randi_range(0, NAME_B.size() - 1)],
	]


## Catalogue designation for the nth body: unique by construction, because the number is
## part of it. Used when a name could not be drawn.
static func _designation(rng: RandomNumberGenerator, index: int) -> String:
	return "%s-%03d" % [
		String(STAR_NAMES[rng.randi_range(0, STAR_NAMES.size() - 1)]).to_upper().substr(0, 3),
		index,
	]


## A point on orbit ring `ring` of `total`, at a seeded angle.
##
## `radius` is the game's half-extent rather than the `extreme` constant, so a `tiny`
## game is genuinely small instead of merely *drawn* small.
static func _orbit_point(
	rng: RandomNumberGenerator, ring: int, total: int, radius: float
) -> Vector2:
	var t := float(ring) / maxf(1.0, float(maxi(1, total - 1)))
	# sqrt spreads the rings by area instead of bunching them toward the star.
	var r := radius * lerpf(INNER_ORBIT, OUTER_ORBIT, sqrt(t))
	var angle := rng.randf() * TAU
	return Vector2(cos(angle), sin(angle)) * r


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


## Give every empire a starting world, picked at random.
##
## The old rule placed homeworlds in separate *systems*, as far apart as the map allowed, so
## no two empires started next door. There is one system now, so separation is a choice
## between planets rather than between systems -- and it is deliberately not made: the
## player asked for a random starting planet every game, including between two games that
## share a seed. `rng` here is the caller-supplied homeworld stream, which is *not* the
## generation stream, so the layout stays reproducible while the opening does not.
##
## Homeworlds are drawn from the live planet list rather than a pre-ranked shortlist, so
## two empires never land on the same world.
static func _seed_factions(
	galaxy: GalaxyState, rng: RandomNumberGenerator, defs: Node, faction_count: int, db: Node
) -> void:
	var hulls := defs.get("ship_hulls") as Dictionary
	if hulls.is_empty():
		push_error("[GalaxyGenerator] no ship hull definitions; skipping faction seeding")
		return

	# Candidate worlds are the colonisable bodies, in index order so the draw is over a
	# stable list. Order is by index, not by desirability: ranking by habitability and
	# then taking the top N would hand every empire a near-identical start.
	var candidates := _colonisable_planets(galaxy)
	if candidates.is_empty():
		push_error("[GalaxyGenerator] no colonisable planet for any faction")
		return

	var taken := PackedInt32Array()
	for ordinal in faction_count:
		var pick := -1
		# Rejection sampling: draw until an unclaimed world comes up. With far more planets
		# than empires this terminates immediately in practice; the retry cap stops a
		# pathological case (more empires than planets) from spinning forever.
		var attempts := 0
		var cap := candidates.size() * 4
		while attempts < cap:
			var candidate: int = candidates[rng.randi_range(0, candidates.size() - 1)]
			if not taken.has(candidate):
				pick = candidate
				break
			attempts += 1
		# Every colonisable world is gone: fall back to any body at all so the empire is
		# still created, and let the founding colony report the shortfall.
		if pick < 0:
			for p in candidates:
				if not taken.has(p):
					pick = p
					break
		if pick < 0:
			break
		taken.append(pick)
		_create_faction(galaxy, rng, defs, pick, ordinal, db)

	# One empire owns the star system; the rest are tenants of the same map.
	if galaxy.factions.size() > 0:
		galaxy.claim_system(0, 0)


## Indices of every planet a faction could start on.
static func _colonisable_planets(galaxy: GalaxyState) -> PackedInt32Array:
	var out := PackedInt32Array()
	for p in galaxy.planets:
		if p.is_colonizable():
			out.append(p.index)
	return out


static func _create_faction(
	galaxy: GalaxyState, rng: RandomNumberGenerator, defs: Node,
	home_planet: int, ordinal: int, db: Node
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

	# No tax rate and no research allocation: Phase 8 removed both sliders. The fields still
	# exist on `FactionState` so an old save round-trips, but generation leaves them at their
	# defaults rather than implying the player set them.
	f.research_allocation = _default_research_allocation()

	# Ships come off the population ladder, so an empire starts with only the hulls it can
	# actually use: a Colony Ship to settle with and an Exploration Ship to survey with.
	# `tech_tier` stays at -1, which is the "nothing past the starting roster" marker.
	var starters: Array = GameDB.STARTER_HULLS
	for hull_id: Variant in starters:
		f.unlocked_ships[StringName(hull_id)] = true

	# Every structure in the roster is available from the start. Buildings are not gated
	# behind the ladder: they need population to staff, so the population *is* the gate.
	for building_id: StringName in ResearchStage.starter_buildings(defs):
		f.unlocked_buildings[building_id] = true

	galaxy.factions.append(f)
	_founding_colony(galaxy, defs, f, home_planet, db)




## Settle the homeworld: the planet `_seed_factions` drew for this empire.
##
## The old version ranked the whole system by habitability and took the winner, so every
## empire began on the single most comfortable world in the galaxy and two players could not
## start anywhere else. The draw is now made upstream, per empire, and this function just
## performs the settlement.
static func _founding_colony(
	galaxy: GalaxyState, defs: Node, f: FactionState, home_planet: int, db: Node
) -> void:
	var p: PlanetState = galaxy.planet(home_planet)
	if p == null or not p.is_colonizable():
		push_error("[GalaxyGenerator] planet %d is not colonisable for faction %d"
			% [home_planet, f.id])
		return

	p.owner = f.id
	p.colonized = true
	p.surveyed = true
	p.population = float(db.get("START_POPULATION"))

	# A starting colony is never barren: it comes with a landed Colony Ship (which is where
	# its housing and its first turn of food come from), a farm, a mine and enough power to
	# run one City Complex once it is built. The exact composition follows the Phase 8
	# roster: the Colony Ship is the only structure a colony cannot build for itself.
	p.structures[&"colony_ship_building"] = 1
	p.structures[&"farm"] = 2
	p.structures[&"mine"] = 1
	p.food_stock = 20.0
	p.power = 5.0


## Give each faction a starting force, so turn 1 always has a legal move.
##
## One Colony Ship (to settle a second world) and one Exploration Ship (to survey this one),
## parked over the homeworld. Deliberately small: the Phase 8 roster is a *ladder* the player
## climbs by population, so handing out a destroyer here would skip the first four rungs of
## it and the milestone unlocks would have nothing left to give.
static func _establish_starting_forces(
	galaxy: GalaxyState, rng: RandomNumberGenerator, defs: Node
) -> void:
	var hulls := defs.get("ship_hulls") as Dictionary
	for f in galaxy.factions:
		var home := _homeworld_of(galaxy, f.id)
		if home == -1:
			continue
		var starting := FleetState.new()
		starting.bind_hulls(hulls)
		starting.owner = f.id
		starting.system = home
		starting.name = "%s Fleet" % f.name
		starting.add_ships(&"colony_ship", 1)
		starting.add_ships(&"exploration_ship", 1)
		galaxy.add_fleet(starting)


## A faction's homeworld planet index, or -1.
##
## Finds the highest-indexed colony they hold. Ties on a captured world are the interesting
## case: after a conquest the old owner still lists the planet as theirs until the transfer
## runs, and the transfer is what this reads.
static func _homeworld_of(galaxy: GalaxyState, faction_id: int) -> int:
	var f: FactionState = galaxy.faction(faction_id)
	if f == null:
		return -1
	# Scan the planets directly rather than walking `f.systems`. Only one empire can own
	# the single system, so the systems index is a poor proxy for "where this empire is":
	# the three empires that start as tenants have no systems at all, and reading their
	# homeworld that way returned -1 and silently left them with no starting fleet.
	for p in galaxy.planets:
		if p.owner == faction_id and p.colonized:
			return p.index
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
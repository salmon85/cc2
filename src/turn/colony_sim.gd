extends RefCounted
class_name ColonySim
## Stage 3 of turn resolution: colony growth, food, mining, power and construction.
##
## Runs per-colony and accumulates into the faction ledger. Every number here is derived
## from authored `.tres` data and `GameDB` constants — none of it is hard-coded per class.
##
## The Phase 8 model is integral rather than fractional. Population is a whole number of
## people: each one eats exactly one food a turn, a starving colony loses exactly one at a
## time on a 50% roll, and a growing colony gains exactly one. The fractional model this
## replaced scaled population by a percentage every turn, which cannot express "one person
## starves" and made every food figure a function of a population value that was not a
## count of anything.

## One colony's turn report, surfaced by the imperial summary screen.
class Report extends RefCounted:
	var food_produced: float = 0.0
	var food_consumed: float = 0.0
	var starving: bool = false
	var population_delta: float = 0.0
	var troops_delta: float = 0.0
	var metals_mined: float = 0.0
	var rare_mined: float = 0.0
	var energy_mined: float = 0.0
	var power_generated: float = 0.0
	var power_drawn: float = 0.0
	var production: float = 0.0
	var tax_income: float = 0.0
	var upkeep: float = 0.0
	var morale_delta: float = 0.0
	var food_overflowed: bool = false
	var food_starved: bool = false
	var power_short: bool = false
	var houses_added: int = 0
	var troops_raised: int = 0
	## The birth chance this turn actually rolled against, 0 when the colony could not grow.
	## Recorded rather than recomputed so a test can read the curve the resolver used rather
	## than re-deriving it and agreeing with itself.
	var growth_chance: float = 0.0


## The per-turn chance of one pop being born at `population`.
##
## The soft cap: `POP_GROWTH_CHANCE - population * penalty`, clamped. Pure arithmetic and
## exported so the UI can print the same number the roll used — a growth rate a player cannot
## see is a growth rate they cannot plan around.
##
## It is deliberately a function of population alone. Housing, food and the two-pop minimum
## are gates applied by the caller, not part of the curve: a colony that has not met them
## does not roll at all, and folding them in here would make a well-fed colony in small
## housing look like a crowded one.
static func growth_chance(population: float, db: Node) -> float:
	var base := float(db.get("POP_GROWTH_CHANCE"))
	var penalty := float(db.get("POP_GROWTH_PENALTY_PER_POP"))
	var floor_chance := float(db.get("POP_GROWTH_MIN_CHANCE"))
	var ceiling := float(db.get("POP_GROWTH_MAX_CHANCE"))
	return clampf(base - population * penalty, floor_chance, ceiling)


## What a colony's single build slot is currently holding.
##
## A colony works one structure and then, once that slot is free, its hulls one at a time --
## but to the player both are "the thing I clicked Build on", and the metal dialog, the
## progress bar and the refund rule have to behave identically for both. Naming the kind once
## here is what stops the building half and the ship half from drifting into two rules.
enum ProjectKind {
	NONE,
	STRUCTURE,
	SHIP,
}


## Which kind of project the colony's build slot holds, buildings first.
static func project_kind(planet: PlanetState) -> int:
	if planet == null:
		return ProjectKind.NONE
	if not planet.building_queue.is_empty():
		return ProjectKind.STRUCTURE
	if not planet.ship_queue.is_empty():
		return ProjectKind.SHIP
	return ProjectKind.NONE


## The hull id of the ship under construction, or `&""`.
static func queued_hull_id(planet: PlanetState) -> StringName:
	if planet == null or planet.ship_queue.is_empty():
		return &""
	var job: Dictionary = planet.ship_queue[0] as Dictionary
	return StringName(str(job.get("hull", "")))


## Metal assigned to whatever the colony is building: `build_metal` for a structure, the
## head job's `metal` for a hull.
##
## One accessor because two readers deriving this separately is how the progress bar ends up
## reporting a hull's metal paid while the refund rule is still looking at `build_metal`.
static func project_paid(planet: PlanetState) -> float:
	if planet == null:
		return 0.0
	if not planet.building_queue.is_empty():
		return planet.build_metal
	if not planet.ship_queue.is_empty():
		var job: Dictionary = planet.ship_queue[0] as Dictionary
		return maxf(0.0, float(job.get("metal", 0.0)))
	return 0.0


## Write metal assigned to the current project. See `project_paid`.
static func set_project_paid(planet: PlanetState, value: float) -> void:
	if planet == null:
		return
	var paid := maxf(0.0, value)
	if not planet.building_queue.is_empty():
		planet.build_metal = paid
		return
	if not planet.ship_queue.is_empty():
		var job: Dictionary = planet.ship_queue[0] as Dictionary
		job["metal"] = paid


## The head ship job, or an empty dictionary when nothing is in the yard.
##
## Empty rather than null: the declared return type is `Dictionary`, and a caller testing
## `job.is_empty()` is testing the same thing whether the yard is empty or the entry is
## malformed.
static func queued_ship_job(planet: PlanetState) -> Dictionary:
	if planet == null or planet.ship_queue.is_empty():
		return {} as Dictionary
	return planet.ship_queue[0] as Dictionary


## The metal cost of the project in the build slot: the queued structures, or the hull at the
## head of the ship queue.
##
## `hulls` is optional so a caller holding only the building table still gets the right
## answer for a structure, and a definite zero for a hull rather than a crash.
static func project_cost(planet: PlanetState, buildings: Dictionary, hulls: Dictionary = {}) -> float:
	var kind := project_kind(planet)
	if kind == ProjectKind.STRUCTURE:
		return queued_cost(planet, buildings)
	if kind == ProjectKind.SHIP:
		var job := queued_ship_job(planet)
		if job.is_empty():
			return 0.0
		var hull: Resource = hulls.get(StringName(str(job.get("hull", ""))), null) as Resource
		if hull == null:
			return 0.0
		return float(hull.get("cost_metals"))
	return 0.0


## Metal still owed on the current project, floored at zero.
static func project_remaining(
	planet: PlanetState, buildings: Dictionary, hulls: Dictionary = {}
) -> float:
	return maxf(0.0, project_cost(planet, buildings, hulls) - project_paid(planet))


## Completion progress for the colony's current project, 0..1, for either kind.
static func project_progress(
	planet: PlanetState, buildings: Dictionary, hulls: Dictionary = {}
) -> float:
	var cost := project_cost(planet, buildings, hulls)
	if cost <= 0.0:
		return 0.0
	return clampf(project_paid(planet) / cost, 0.0, 1.0)


## The most metal that could usefully move *into* the project right now.
static func max_assignment(
	planet: PlanetState, buildings: Dictionary, hulls: Dictionary = {}
) -> float:
	return maxf(0.0, minf(planet.reserve_metals, project_remaining(planet, buildings, hulls)))


## The most metal that could usefully move *out* of the project right now.
##
## Bounded by the banked metal alone, and never by storage: metal coming *back* has nowhere
## to be refused, so the only limit is how much the player ever put in.
static func max_refund(planet: PlanetState) -> float:
	return project_paid(planet)


## Simulate one colony. Mutates `planet` and returns its report.
##
## `faction` supplies tech bonuses; `defs` is the registry; `db` holds the tuning constants.
static func simulate_colony(
	galaxy: GalaxyState,
	planet: PlanetState,
	faction: FactionState,
	defs: Node,
	db: Node,
	rng: RandomNumberGenerator = null,
) -> Report:
	var report := Report.new()
	if planet == null or not planet.colonized:
		return report

	var buildings := defs.get("buildings") as Dictionary
	var hulls := defs.get("ship_hulls") as Dictionary

	# Warnings describe the turn that just resolved, so the list is rebuilt every turn rather
	# than accumulated. Without this a colony that starved once would carry the warning for
	# ever, and the food-overflow warning in particular is *meant* to come and go: it is a
	# standing condition, not a fact about the world.
	planet.warnings.clear()

	# --- Derived capacities ----------------------------------------------------
	# Recomputed from the structure table every turn and cached on the planet, so the UI
	# and the build-order guards read the same numbers the economy just used rather than
	# each re-deriving them (and getting a different answer when a structure finishes
	# mid-turn).
	_recount_capacity(planet, buildings, db)

	# --- Food ------------------------------------------------------------------
	var food_bonus := 1.0 + faction.tech_effect(&"food_bonus")
	var food_produced := _food_output(planet, buildings) * food_bonus
	var food_consumed := planet.population * float(db.get("FOOD_PER_POP"))

	report.food_produced = food_produced
	report.food_consumed = food_consumed

	# A surplus banks, a deficit draws the bank down. The bank is hard-capped, and the
	# overflow is reported *next* turn rather than this one -- see `_bank_food`.
	var net := food_produced - food_consumed
	_bank_food(planet, net, db, report)

	# --- Population ------------------------------------------------------------
	# Housing is the gate. A colony with no City Complex and no landed Colony Ship has
	# nowhere for a new person to live, so it cannot grow however well it is fed.
	var room := planet.housing - planet.population
	var can_grow := (
		net > 0.0
		and planet.food_stock > 0.0
		and room >= 1.0
		and planet.population >= float(db.get("MIN_POP_FOR_GROWTH"))
	)
	if can_grow and rng != null:
		var chance := growth_chance(planet.population, db)
		report.growth_chance = chance
		if rng.randf() < chance:
			# Growth is allowed to overshoot next turn's consumption: the design document
			# is explicit that a colony may take a pop it cannot yet afford to feed, which
			# is what makes a food shortage a decision rather than a delayed sentence.
			planet.population += 1.0
			report.population_delta = 1.0
			report.houses_added = 1

	# --- Starvation ------------------------------------------------------------
	# Only once the bank is dry. Each turn with an empty bank and a shortfall, one pop
	# dies on a 50% roll, repeating until the colony reaches equilibrium or empties.
	if net < 0.0 and planet.food_stock <= 0.0:
		report.starving = true
		report.food_starved = true
		_add_warning(planet, &"starving")
		if planet.population > 0.0:
			var chance := float(db.get("STARVATION_DEATH_CHANCE"))
			if rng != null and rng.randf() < chance:
				planet.population = maxf(0.0, planet.population - 1.0)
				report.population_delta -= 1.0

	# --- Power -----------------------------------------------------------------
	_power_turn(planet, buildings, report)

	# --- Mining ----------------------------------------------------------------
	var mining_bonus := 1.0 + faction.tech_effect(&"mining_bonus")
	var metal_per_turn := _metal_output(planet, buildings) * mining_bonus
	report.metals_mined = metal_per_turn
	# The old mine yield scaled with population, which made output depend on a value that
	# is now a count of people rather than a growth multiplier. The Phase 8 roster states
	# mine output as an absolute per-turn figure, and this is where it is applied.
	planet.reserve_metals += report.metals_mined

	# --- Upkeep ----------------------------------------------------------------
	# Structures only. There is no income line any more: the tax slider went with the
	# research sliders in Phase 8, and a colony's upkeep is the only thing that moves the
	# treasury any more.
	report.tax_income = 0.0
	report.upkeep = float(db.get("MAINTENANCE_PER_COLONY"))
	for building_id: StringName in planet.structures:
		var count := int(planet.structures[building_id])
		var def: Resource = buildings.get(building_id, null) as Resource
		if def != null:
			report.upkeep += float(def.get("upkeep")) * count

	report.morale_delta = 0.0

	# A colony with no people left is abandoned.
	if planet.population <= 0.0 and planet.troops <= 0:
		planet.colonized = false
		report.starving = true

	# --- Construction ----------------------------------------------------------
	_advance_construction(galaxy, planet, faction, buildings, hulls, db)

	return report


## Recompute food capacity, power capacity, power budget and housing from the structures.
##
## Every colony has a small hold of its own before it builds any storage -- the landed
## Colony Ship's own pantry and its own cells. Without a floor, a brand-new colony would have
## zero food capacity and zero power capacity and would therefore overflow its very first
## meal and lose its first reactor's output, which is the opposite of what starting
## infrastructure is for.
static func _recount_capacity(planet: PlanetState, buildings: Dictionary, db: Node) -> void:
	var caps := capacity_for(planet, buildings, db)
	planet.food_capacity = float(caps.get("food", 0.0))
	planet.power_capacity = float(caps.get("power", 0.0))
	planet.power_generated = float(caps.get("power_out", 0.0))
	planet.power_drawn = float(caps.get("power_in", 0.0))
	planet.housing = float(caps.get("housing", 0.0))


## Storage capacities, power budget and housing implied by `planet.structures`.
##
## The same arithmetic `_recount_capacity` writes onto the planet, returned rather than
## applied, so the panel and a test can ask what a structure is *worth* before it is built.
##
## This matters because "each granary adds 1000 food, each Energy Storage adds 1000 power
## and each City Complex adds 20 housing" is a claim about per-copy contribution, and the only
## way to check it is to read the number a copy of the structure produces rather than the
## total after some unknown number of them. Three separate tallies would be three chances to
## answer a different question from the one asked.
##
## Returns `food`, `power`, `power_out`, `power_in` and `housing`.
static func capacity_for(planet: PlanetState, buildings: Dictionary, db: Node) -> Dictionary:
	var food_cap := float(db.get("BASE_FOOD_STORAGE"))
	var power_cap := float(db.get("BASE_POWER_STORAGE"))
	var power_out := 0.0
	var power_in := 0.0
	var houses := 0.0
	if planet == null:
		return {
			"food": food_cap, "power": power_cap,
			"power_out": power_out, "power_in": power_in, "housing": houses,
		}
	for building_id: StringName in planet.structures:
		var def: Resource = buildings.get(building_id, null) as Resource
		if def == null:
			continue
		var count := int(planet.structures[building_id])
		if count <= 0:
			continue
		if def.is_food_storage():
			food_cap += float(def.get("food_store")) * count
		if def.get("kind") == BuildingData.Kind.STORAGE:
			power_cap += float(def.get("energy_store")) * count
		if def.get("kind") == BuildingData.Kind.POWER:
			power_out += float(def.get("yield_amount")) * count
		if def.draws_power():
			power_in += float(def.get("power_required")) * count
		houses += float(def.get("pop_housed")) * count
	return {
		"food": food_cap,
		"power": power_cap,
		"power_out": power_out,
		"power_in": power_in,
		"housing": houses,
	}


## Bank a surplus, or draw the bank down against a deficit.
##
## The overflow warning is raised on the *following* turn, which is what the design document
## asks for and is also the only version that means anything to a player: the turn in which
## the food was produced has already been reported, so a warning about it is a note in the
## next turn's news. `pending_food_overflow` is the flag that carries it across the turn
## boundary; it is deliberately not serialised, so a save taken mid-turn loses it rather
## than manufacturing a warning for a colony that has since been given a granary.
static func _bank_food(
	planet: PlanetState, net: float, db: Node, report: Report
) -> void:
	# Raise last turn's warning, if one was earned.
	if planet.get_meta("pending_food_overflow", false):
		_add_warning(planet, &"food_overflow")
		planet.set_meta("pending_food_overflow", false)

	planet.food_stock += net
	if planet.food_stock < 0.0:
		planet.food_stock = 0.0

	if planet.food_stock > planet.food_capacity:
		report.food_overflowed = true
		planet.set_meta("pending_food_overflow", true)
		planet.food_stock = planet.food_capacity


## Regenerate power, pay the structures that draw it, and record whether the colony is short.
##
## Overflow is silent, deliberately and asymmetrically: the design document warns on food
## overflow and explicitly does *not* warn on power overflow. Silently losing surplus power
## is the correct pressure -- a world that over-generates should be rewarded for building
## more Energy Storage rather than nagged into it.
static func _power_turn(
	planet: PlanetState, buildings: Dictionary, report: Report
) -> void:
	planet.power += planet.power_generated
	if planet.power > planet.power_capacity:
		planet.power = planet.power_capacity
	planet.power -= planet.power_drawn
	report.power_generated = planet.power_generated
	report.power_drawn = planet.power_drawn
	if planet.power < 0.0:
		planet.power = 0.0
		report.power_short = true
		_add_warning(planet, &"power_short")


static func _add_warning(planet: PlanetState, key: StringName) -> void:
	for existing: Variant in planet.warnings:
		if StringName(str(existing)) == key:
			return
	planet.warnings.append(key)


# --- Definition helpers --------------------------------------------------------

## Food produced this turn, once staffing is accounted for.
##
## A structure with a `pop_required` only produces while the colony has the civilians to
## staff it. That is the whole of what "requires 1 pop" means for a farm: unstaffed, it
## feeds nobody, and a colony that has spent its people on mines and barracks has to choose
## which of the two it can afford to feed.
static func _food_output(planet: PlanetState, buildings: Dictionary) -> float:
	var total := 0.0
	for building_id: StringName in planet.structures:
		var count := int(planet.structures[building_id])
		if count <= 0:
			# A key left at zero is not a structure. The Phase 8 tests strip farms by writing
			# a zero rather than erasing the key, and a zero-count entry that still produced
			# food would be a colony feeding itself from buildings it does not have.
			continue
		var def: Resource = buildings.get(building_id, null) as Resource
		if def == null:
			continue
		if float(def.get("yield_amount")) <= 0.0:
			continue
		total += count * _staffed(planet, def) * float(def.get("yield_amount"))
	return total


static func _metal_output(planet: PlanetState, buildings: Dictionary) -> float:
	var total := 0.0
	for building_id: StringName in planet.structures:
		var count := int(planet.structures[building_id])
		if count <= 0:
			continue
		var def: Resource = buildings.get(building_id, null) as Resource
		if def == null:
			continue
		if float(def.get("metal_per_turn")) <= 0.0:
			continue
		total += count * _staffed(planet, def) * float(def.get("metal_per_turn"))
	return total


## Whether one copy of `def` is staffed and therefore working.
##
## `pop_required` is a threshold rather than a per-structure reservation: a farm works if the
## colony has at least one civilian to work it. That is what "requires 1 pop" buys a player —
## a colony that has spent its people on Barracks conversions cannot also staff every farm it
## has ever built, and which of the two it can afford is a decision. Making it a *reservation*
## instead would let one colonist work five farms at once, which is exactly the double
## counting the removed per-population multiplier did.
static func _staffed(planet: PlanetState, def: Resource) -> int:
	if int(def.get("pop_required")) <= 0:
		return 1
	return 1 if planet.population >= 1.0 else 0


## Advance the construction and shipyard queues by one turn.
##
## Both queues spend the colony's *actual* metal, a slice of the project's cost each turn.
##
## The slice is `cost / build_turns`, spread evenly: turn N of a T-turn project reads as N/T
## whatever the structure costs. That divisor used to be absent -- the contribution was a flat
## `+1.0` metal -- so a 100-metal City Complex advanced 1% a turn while a 10-metal Solar Array
## advanced 10%, and a three-turn project read as 3% after one turn no matter what was being
## built.
##
## The metal is *moved*, not tallied: it leaves `reserve_metals` and lands in the project's
## assigned pool (`build_metal`, or the head ship job's `metal`). It used to be pure
## accounting -- credited straight to the pool with nothing ever leaving storage -- which made
## the pool a number about the project rather than a quantity of metal, and made the refund
## control in the metal dialog meaningless: there was no metal in there to give back.
##
## A colony that cannot cover the whole slice contributes what it has and the project simply
## takes longer. Nothing is refused and nothing is owed: there is no upfront gate on queueing
## at all, so a colony with an empty bank can commit to a project and pay for it out of the
## mines over the turns that follow.
static func _advance_construction(
	galaxy: GalaxyState, planet: PlanetState, faction: FactionState,
	buildings: Dictionary, hulls: Dictionary, db: Node
) -> void:
	if not planet.building_queue.is_empty():
		_advance_structure(planet, buildings, db)
		return
	if planet.count(&"space_port") <= 0:
		return
	if planet.ship_queue.is_empty():
		return
	_advance_ship(galaxy, planet, faction, hulls)


## One turn of the structure under construction.
static func _advance_structure(
	planet: PlanetState, buildings: Dictionary, db: Node
) -> void:
	var cost := queued_cost(planet, buildings)
	if cost <= 0.0:
		# A queue of ids whose definitions all failed to load. Leaving it in place would
		# block every later build behind an unreadable entry, so drop it.
		planet.building_queue.clear()
		planet.build_turns_remaining = 0
		planet.build_total_turns = 0
		planet.build_metal = 0.0
		return
	var total_turns := maxi(1, planet.build_total_turns)
	planet.build_metal += _draw_metal(planet, cost / float(total_turns), cost)
	planet.build_turns_remaining -= 1
	# Completion is decided by the metal, not the clock. A player who pushes metal in through
	# the dialog finishes early; one whose colony simply produces enough finishes on
	# schedule; neither is held to the turn counter.
	if planet.build_metal >= cost - 0.001:
		finish_construction(planet, buildings, db)


## One turn of the hull at the head of the shipyard queue.
static func _advance_ship(
	galaxy: GalaxyState, planet: PlanetState, faction: FactionState, hulls: Dictionary
) -> void:
	var job := queued_ship_job(planet)
	if job.is_empty():
		return
	var hull_id := StringName(str(job.get("hull", "")))
	var hull: Resource = hulls.get(hull_id, null) as Resource
	if hull == null:
		planet.ship_queue.pop_front()
		return
	var cost := float(hull.get("cost_metals"))
	var total_turns := maxi(1, int(job.get("turns", 1)))
	job["metal"] = float(job.get("metal", 0.0)) + _draw_metal(planet, cost / float(total_turns), cost)
	if float(job.get("metal", 0.0)) >= cost - 0.001:
		planet.shipyard_progress = float(job.get("metal", 0.0))
		planet.ship_queue.pop_front()
		# The hull exists in orbit the moment it is paid for. It used to leave the yard and
		# vanish: `ship_queue.pop_front()` was the end of the line, so a ship the player had
		# spent several turns and a hundred metal on simply stopped existing, and nothing
		# ever put it in a fleet.
		deliver_ships(galaxy, planet, faction, hull_id, 1, hulls)
	else:
		planet.shipyard_progress = float(job.get("metal", 0.0))


## Move up to `slice` metal out of storage toward the current project, never more than `cost`
## in total. Returns what actually moved.
##
## Only the *debit* happens here; the caller credits the project pool, because the two halves
## are written to different fields for a structure and for a hull and only the caller knows
## which. Crediting both was how a three-turn project reached two thirds on its first turn.
static func _draw_metal(planet: PlanetState, slice: float, cost: float) -> float:
	var owed := maxf(0.0, cost - project_paid(planet))
	var moved := clampf(minf(slice, planet.reserve_metals), 0.0, owed)
	if moved <= 0.0:
		return 0.0
	planet.reserve_metals -= moved
	return moved


## Put a finished hull into the orbital fleet over `planet`, creating that fleet if the colony
## has none yet.
##
## "Orbits as fleet sources" is the whole point: a ship a colony paid for has to be somewhere
## the player can see and order. Returning it to a shared pool of unplaced hulls -- or dropping
## it, which is what used to happen -- makes building a ship a payment into a void.
##
## Returns the fleet the ship went into, or null when `galaxy` is missing.
static func deliver_ships(
	galaxy: GalaxyState, planet: PlanetState, faction: FactionState,
	hull_id: StringName, count: int, hulls: Dictionary
) -> FleetState:
	if galaxy == null or planet == null or faction == null or count <= 0:
		return null
	var orbiter := galaxy.orbital_fleet(planet.index, faction.id)
	if orbiter == null:
		orbiter = FleetState.new()
		orbiter.bind_hulls(hulls)
		orbiter.owner = faction.id
		orbiter.system = planet.index
		orbiter.name = "%s Orbital" % _world_name(galaxy, planet.index)
		galaxy.add_fleet(orbiter)
	orbiter.add_ships(hull_id, count)
	return orbiter


## A world in this model has one name, and it may be empty on a body nobody generated a name
## for. The fallback is the catalogue designation the map already shows, so an orbital fleet's
## name can never be the one string that leaks a world the map is hiding.
static func _world_name(galaxy: GalaxyState, planet_index: int) -> String:
	var p := galaxy.planet(planet_index)
	if p == null:
		return "Orbital"
	if p.name != "":
		return p.name
	return "P-%d" % (planet_index + 1)


# --- Imperium ------------------------------------------------------------------

## Roll the imperial ledger: production, tax income, construction spending and upkeep all
## flow through here so the treasury is updated in exactly one place.
static func simulate_faction(
	galaxy: GalaxyState,
	faction: FactionState,
	defs: Node,
	db: Node,
	rng: RandomNumberGenerator = null
) -> float:
	var total_income := 0.0
	var total_production := 0.0
	var total_upkeep := 0.0

	for planet in galaxy.colonies_of(faction.id):
		var report := simulate_colony(galaxy, planet, faction, defs, db, rng)
		total_upkeep += report.upkeep

	for f in galaxy.fleets_of(faction.id):
		for key: StringName in f.ships:
			var hull: Resource = f.hulls().get(key, null) as Resource
			if hull == null:
				continue
			var count := int(f.ships[key])
			total_upkeep += float(hull.get("upkeep")) * count
			# A fielded hull also represents industrial capacity.
			total_production += float(hull.get("cost_metals")) * 0.01 * count

	var expenses := total_upkeep
	faction.last_income = total_income
	faction.last_expenses = expenses
	faction.last_production = total_production
	faction.last_net = total_income - expenses

	# The treasury is floored so a bankrupt empire is crippled, not deleted.
	faction.treasury = maxf(
		float(db.get("TREASURY_FLOOR")), faction.treasury + faction.last_net)

	return faction.last_net


## The total metal cost of everything in `planet.building_queue`.
##
## The single definition of "how much is this project worth", read by the progress bar, the
## per-turn contribution and the boost modal's ceiling. One function because three readers
## deriving it separately is three chances for the bar to disagree with the resolver.
static func queued_cost(planet: PlanetState, buildings: Dictionary) -> float:
	if planet == null or planet.building_queue.is_empty():
		return 0.0
	var cost := 0.0
	for building_id: StringName in planet.building_queue:
		var def: Resource = buildings.get(building_id, null) as Resource
		if def == null:
			continue
		cost += float(def.get("cost_metals")) * int(planet.building_queue[building_id])
	return cost


## Metal still owed on the current project, floored at zero.
static func metal_remaining(planet: PlanetState, buildings: Dictionary) -> float:
	return maxf(0.0, queued_cost(planet, buildings) - planet.build_metal)


## Add `amount` metal against whatever the colony is building. Returns the amount actually
## transferred. Works identically for a structure and a hull.
##
## The mechanic behind the metal dialog. Clamped three ways: to what was asked for, to what the
## colony has in store, and to what the project still owes. The third clamp is the one that
## matters — a player who opens the dialog on a hull that needs 20 metal more must not be able
## to pour a colony's entire 500-metal stockpile into it and watch 480 vanish into a ship worth
## 20.
static func boost_construction(
	planet: PlanetState, amount: float, buildings: Dictionary = {}, hulls: Dictionary = {}
) -> float:
	if planet == null or amount <= 0.0:
		return 0.0
	# Nothing queued, nothing to spend metal on. Returning zero rather than banking the metal
	# silently is what lets the construction bar tell the player why a press did nothing.
	if project_kind(planet) == ProjectKind.NONE:
		return 0.0
	var ceiling := planet.reserve_metals
	if not buildings.is_empty():
		ceiling = minf(ceiling, project_remaining(planet, buildings, hulls))
	var available := minf(amount, maxf(0.0, ceiling))
	if available <= 0.0:
		return 0.0
	# Debited here, credited here. The metal leaves storage exactly once and is never
	# returned when the project lands -- `finish_construction` zeroes the pool rather than
	# paying the surplus back, so a boosted project cannot be laundered into a profit.
	planet.reserve_metals -= available
	set_project_paid(planet, project_paid(planet) + available)
	return available


## Take `amount` metal back *out* of the project and return it to the colony's storage.
##
## The other half of the metal dialog, and the reason the assigned pool has to hold real metal
## rather than a tally: there is nothing to refund if nothing was ever taken out.
##
## Bounded by what is banked against the project and by nothing else. In particular it is *not*
## bounded by the colony's storage -- there is no storage cap on metal -- and the floor is zero
## banked metal rather than "whatever was left", so a player can always pull a project's
## allocation all the way back out and start it again from an empty bar.
static func refund_construction(planet: PlanetState, amount: float) -> float:
	if planet == null or amount <= 0.0:
		return 0.0
	var banked := project_paid(planet)
	var returned := minf(amount, banked)
	if returned <= 0.0:
		return 0.0
	planet.reserve_metals += returned
	set_project_paid(planet, banked - returned)
	return returned


## Land the queued project: move it from the queue into the colony's structures.
##
## `build_metal` is zeroed, not paid back. This is the refund rule in one place: the metal a
## colony spent — whether earned turn by turn or pushed in by hand — is consumed by the
## structure it built. Overflow from a late boost is simply lost, because the alternative is a
## button that pays the player for overpaying.
static func finish_construction(
	planet: PlanetState, buildings: Dictionary, db: Node
) -> void:
	for building_id: StringName in planet.building_queue:
		var count := int(planet.building_queue[building_id])
		planet.structures[building_id] = int(planet.structures.get(building_id, 0)) + count
	planet.building_queue.clear()
	planet.build_turns_remaining = 0
	planet.build_total_turns = 0
	planet.build_metal = 0.0
	# Recount immediately: the structures that just landed change capacity, housing and the
	# power budget, and everything after this point in the turn should see the new numbers
	# rather than the previous turn's. This is what makes a Granary's +1000 food, a City
	# Complex's +20 housing and an Energy Storage's +1000 energy appear the moment the
	# project completes rather than at the start of the following turn.
	_recount_capacity(planet, buildings, db)


## Completion progress for the *building* queue, 0..1.
##
## Kept as a named reader of `project_progress` so existing callers that only ever had a
## structure in the slot keep a function whose name says so, while the rule itself lives in one
## place and covers hulls too.
static func construction_progress(planet: PlanetState, buildings: Dictionary) -> float:
	return project_progress(planet, buildings)


## The most metal a boost could usefully transfer right now: what the colony holds, capped by
## what the project still owes.
##
## This is the ceiling the metal dialog's "add" slider is clamped to, so a player cannot be
## offered a transfer larger than the project can absorb.
static func max_boost(
	planet: PlanetState, buildings: Dictionary, hulls: Dictionary = {}
) -> float:
	if planet == null or project_kind(planet) == ProjectKind.NONE:
		return 0.0
	return maxf(0.0, minf(planet.reserve_metals, project_remaining(planet, buildings, hulls)))
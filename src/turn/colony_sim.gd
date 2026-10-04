extends RefCounted
class_name ColonySim
## Stage 3 of turn resolution: colony growth, food, production, mining, tax and morale.
##
## Runs per-colony and accumulates into the faction ledger. Every number here is derived
## from authored `.tres` data and `GameDB` constants — none of it is hard-coded per class.

## One colony's turn report, surfaced by the imperial summary screen.
class Report extends RefCounted:
	var food_produced: float = 0.0
	var food_consumed: float = 0.0
	var starving: bool = false
	var population_delta: float = 0.0
	var metals_mined: float = 0.0
	var rare_mined: float = 0.0
	var energy_mined: float = 0.0
	var production: float = 0.0
	var tax_income: float = 0.0
	var upkeep: float = 0.0
	var morale_delta: float = 0.0


## Simulate one colony. Mutates `planet` and returns its report.
##
## `faction` supplies tech bonuses and the current tax rate; `defs` is the registry.
static func simulate_colony(
	galaxy: GalaxyState,
	planet: PlanetState,
	faction: FactionState,
	defs: Node,
	db: Node,
) -> Report:
	var report := Report.new()
	if planet == null or not planet.colonized:
		return report

	var buildings := defs.get("buildings") as Dictionary
	var type_data := planet.type_data()

	# --- Food ---------------------------------------------------------------
	var farms := planet.count(&"farm")
	var food_bonus := 1.0 + faction.tech_effect(&"food_bonus")
	var yield_per_farm: float = float(_def_yield(buildings, &"farm"))
	var food_produced := farms * yield_per_farm * planet.habitability() * food_bonus
	var food_consumed := planet.population * float(db.get("BASE_FOOD_PER_MILLION"))

	report.food_produced = food_produced
	report.food_consumed = food_consumed

	# Farms can draw on the local biome only; there is no interstellar food. Note the
	# reserve moves by the *net* every turn regardless of sign: a colony that produces
	# nothing still has to eat, and gating the whole update on production would let a
	# farmless colony feed itself forever.
	planet.food_stock = clampf(
		planet.food_stock + food_produced - food_consumed, -50.0, 200.0)

	# --- Population growth ---------------------------------------------------
	var max_pop := planet.max_population()
	if max_pop <= 0.0:
		# A world nobody can live on still has reserves to tap and structures to
		# finish, so skip only the growth step rather than abandoning the colony.
		planet.population = 0.0
		_economy_and_upkeep(planet, faction, buildings, db, report)
		_terraform(planet, buildings)
		_advance_construction(planet, buildings, faction, db)
		return report

	var food_surplus := food_produced - food_consumed
	if planet.food_stock >= 0.0 and food_surplus >= 0.0:
		var headroom := maxf(0.0, max_pop - planet.population)
		var rate: float = float(db.get("FOOD_SURPLUS_GROWTH")) * planet.habitability()
		rate = minf(rate, float(db.get("MAX_POP_GROWTH_RATE")))
		var delta: float = minf(planet.population * rate, headroom)
		planet.population += delta
		report.population_delta = delta
	elif planet.food_stock < 0.0:
		# Starvation. Drain the stock first, then shrink the population.
		planet.food_stock += food_surplus
		if planet.food_stock < 0.0:
			var decay: float = float(db.get("STARVATION_DECAY"))
			report.population_delta = -planet.population * decay
			planet.population = maxf(0.0, planet.population + report.population_delta)
			report.starving = true

	planet.population = clampf(planet.population, 0.0, maxf(max_pop, planet.population))

	# A colony with no people is abandoned.
	if planet.population <= 0.01:
		planet.colonized = false
		report.starving = true

	_economy_and_upkeep(planet, faction, buildings, db, report)

	_terraform(planet, buildings)

	# --- Construction queues ------------------------------------------------
	_advance_construction(planet, buildings, faction, db)

	return report



## Mining, factory output, tax income and building upkeep. Split out so that a world
## with zero habitability still pays its way instead of short-circuiting the colony.
static func _economy_and_upkeep(
	planet: PlanetState, faction: FactionState, buildings: Dictionary,
	db: Node, report: Report
) -> void:
	# --- Mining -------------------------------------------------------------
	var mines := planet.count(&"mine")
	var mining_bonus := 1.0 + faction.tech_effect(&"mining_bonus")
	var metal_yield: float = float(_def_yield(buildings, &"mine"))
	var rare_yield: float = float(_def_secondary(buildings, &"mine"))
	var energy_yield: float = float(_def_tertiary(buildings, &"mine"))
	var per_mine := planet.population * mining_bonus

	report.metals_mined = mines * metal_yield * per_mine
	report.rare_mined = mines * rare_yield * per_mine
	report.energy_mined = mines * energy_yield * per_mine

	planet.reserve_metals += report.metals_mined
	planet.reserve_rare += report.rare_mined
	planet.reserve_energy += report.energy_mined

	# --- Production ---------------------------------------------------------
	var factories := planet.count(&"factory")
	var production_bonus := 1.0 + faction.tech_effect(&"construction_bonus")
	var factory_yield: float = float(_def_yield(buildings, &"factory"))
	report.production = factories * factory_yield * production_bonus

	# --- Tax and economy ----------------------------------------------------
	var structure_count := planet.structures.size()
	var economy: float = float(db.get("BASE_ECONOMY_SIZE"))
	economy += planet.population * float(db.get("ECONOMY_PER_POPULATION"))
	economy += float(structure_count) * float(db.get("ECONOMY_PER_STRUCTURE"))

	var tax := clampf(faction.tax_rate, 0.0, 1.0)
	report.tax_income = economy * tax

	# Morale is derived rather than stored, so there is no per-turn delta to record
	# here; _morale() recomputes it on demand from the tax rate and food position.
	report.morale_delta = 0.0

	# --- Upkeep -------------------------------------------------------------
	report.upkeep = float(db.get("MAINTENANCE_PER_COLONY"))
	for building_id: StringName in planet.structures:
		var count := int(planet.structures[building_id])
		var def: Resource = buildings.get(building_id, null) as Resource
		if def != null:
			report.upkeep += float(def.get("upkeep")) * count


## Terraformers slowly make a hostile world more hospitable.
static func _terraform(planet: PlanetState, buildings: Dictionary) -> void:
	var terraformers := planet.count(&"terraformer")
	if terraformers <= 0:
		return
	var power: float = float(_def_yield(buildings, &"terraformer"))
	planet.terraform_progress = clampf(
		planet.terraform_progress + power * terraformers, 0.0, 1.0)


## Morale is a derived 0..100 value, not stored state, so it cannot drift out of sync
## with the tax rate and food situation that drive it.
static func _morale(planet: PlanetState, faction: FactionState, db: Node) -> float:
	var value := float(db.get("BASE_MORALE"))
	var tax := clampf(faction.tax_rate, 0.0, 1.0)
	var slope := float(db.get("MORALE_PER_TAX_POINT_ABOVE_HALF"))
	if tax > 0.5:
		value += (tax - 0.5) * slope * 2.0
	else:
		value += (0.5 - tax) * float(db.get("MORALE_PER_TAX_POINT_BELOW_HALF")) * 2.0

	var surplus := planet.food_stock
	if surplus > 0.0:
		value += float(db.get("MORALE_FROM_FOOD_SURPLUS"))
	if planet.structures.is_empty():
		value -= 5.0
	return clampf(value, 0.0, 100.0)


## Advance the construction and shipyard queues by one turn.
static func _advance_construction(
	planet: PlanetState, buildings: Dictionary, faction: FactionState, db: Node
) -> void:
	# Production banks against the current structure build first.
	if not planet.building_queue.is_empty():
		planet.build_turns_remaining -= 1
		if planet.build_turns_remaining <= 0:
			for building_id: StringName in planet.building_queue:
				var count := int(planet.building_queue[building_id])
				planet.structures[building_id] = int(planet.structures.get(building_id, 0)) + count
			planet.building_queue.clear()
			planet.build_turns_remaining = 0
		return

	# Otherwise output feeds the shipyard, if the colony has one.
	if planet.count(&"shipyard") <= 0:
		return
	if planet.ship_queue.is_empty():
		return
	var job: Dictionary = planet.ship_queue[0] as Dictionary
	job["progress"] = float(job.get("progress", 0.0)) + _shipyard_output(planet, db)
	if float(job.get("progress", 0.0)) >= 1.0:
		planet.shipyard_progress += float(job.get("progress", 0.0))
		planet.ship_queue.pop_front()


static func _shipyard_output(planet: PlanetState, db: Node) -> float:
	var factories := planet.count(&"factory")
	var yards := planet.count(&"shipyard")
	var base := float(db.get("ECONOMY_PER_STRUCTURE"))
	return 0.15 + factories * base * 0.5 + yards * base


# --- Definition helpers --------------------------------------------------------

static func _def_yield(buildings: Dictionary, building_id: StringName) -> float:
	var def: Resource = buildings.get(building_id, null) as Resource
	return 0.0 if def == null else float(def.get("yield_amount"))


static func _def_secondary(buildings: Dictionary, building_id: StringName) -> float:
	var def: Resource = buildings.get(building_id, null) as Resource
	return 0.0 if def == null else float(def.get("yield_secondary"))


static func _def_tertiary(buildings: Dictionary, building_id: StringName) -> float:
	var def: Resource = buildings.get(building_id, null) as Resource
	return 0.0 if def == null else float(def.get("yield_tertiary"))


# --- Imperium ------------------------------------------------------------------

## Roll the imperial ledger: production, tax income, construction spending and upkeep
## all flow through here so the treasury is updated in exactly one place.
static func simulate_faction(
	galaxy: GalaxyState,
	faction: FactionState,
	defs: Node,
	db: Node
) -> float:
	var total_income := 0.0
	var total_production := 0.0
	var total_upkeep := 0.0

	for planet in galaxy.colonies_of(faction.id):
		var report := simulate_colony(galaxy, planet, faction, defs, db)
		total_income += report.tax_income
		total_production += report.production
		total_upkeep += report.upkeep

	# Fleet upkeep scales with the hulls actually fielded.
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
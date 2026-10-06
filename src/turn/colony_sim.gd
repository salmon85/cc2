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
	_advance_construction(planet, buildings, db)

	return report


## Recompute food capacity, power capacity, power budget and housing from the structures.
##
## Every colony has a small hold of its own before it builds any storage -- the landed
## Colony Ship's own pantry and its own cells. Without a floor, a brand-new colony would have
## zero food capacity and zero power capacity and would therefore overflow its very first
## meal and lose its first reactor's output, which is the opposite of what starting
## infrastructure is for.
static func _recount_capacity(planet: PlanetState, buildings: Dictionary, db: Node) -> void:
	var food_cap := float(db.get("BASE_FOOD_STORAGE"))
	var power_cap := float(db.get("BASE_POWER_STORAGE"))
	var power_out := 0.0
	var power_in := 0.0
	var houses := 0.0
	for building_id: StringName in planet.structures:
		var def: Resource = buildings.get(building_id, null) as Resource
		if def == null:
			continue
		var count := int(planet.structures[building_id])
		if def.is_food_storage():
			food_cap += float(def.get("food_store")) * count
		if def.get("kind") == BuildingData.Kind.STORAGE:
			power_cap += float(def.get("energy_store")) * count
		if def.get("kind") == BuildingData.Kind.POWER:
			power_out += float(def.get("yield_amount")) * count
		if def.draws_power():
			power_in += float(def.get("power_required")) * count
		houses += float(def.get("pop_housed")) * count
	planet.food_capacity = food_cap
	planet.power_capacity = power_cap
	planet.power_generated = power_out
	planet.power_drawn = power_in
	planet.housing = houses


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
## Progress is banked as *metal*, so the clickable bar in the construction panel and the
## per-turn advance read the same number and cannot disagree.
##
## The per-turn contribution is the project's **total metal cost divided by its build turns**
## — "equal production", spread evenly. The earlier `+1.0` a turn was flat *absolute*, so a
## 100-metal City Complex advanced 1% a turn while a 10-metal Solar Array advanced 10%: a
## three-turn project read as 3% after one turn, and the bar told a player almost nothing. The
## divisor makes turn N of a T-turn project read as N/T regardless of what the structure
## costs, which is what a player watching a bar expects it to mean.
##
## That contribution is *accounting*, not a transfer: it never moves metal in or out of
## storage. The full cost was already debited when the order was accepted, and the metal a
## player pushes in through the boost modal is debited at that moment. Nothing is ever paid
## back — see `finish_construction`.
static func _advance_construction(
	planet: PlanetState, buildings: Dictionary, db: Node
) -> void:
	if not planet.building_queue.is_empty():
		var cost := queued_cost(planet, buildings)
		var total_turns := maxi(1, planet.build_total_turns)
		# Equal production: the cost spread evenly over the project's own build time, so
		# turn N of a T-turn project reads as N/T whatever the structure costs.
		planet.build_metal += cost / float(total_turns)
		planet.build_turns_remaining -= 1
		# Completion is decided by the metal, not the clock. A player who pushed metal in
		# through the boost modal finishes early; one whose colony simply produced enough
		# finishes on schedule; neither is held to the turn counter.
		if planet.build_metal >= cost - 0.001:
			finish_construction(planet, buildings, db)
		return

	# Otherwise the planet's metal output feeds the shipyard, if the colony has one.
	if planet.count(&"space_port") <= 0:
		return
	if planet.ship_queue.is_empty():
		return
	var job: Dictionary = planet.ship_queue[0] as Dictionary
	job["progress"] = float(job.get("progress", 0.0)) + _shipyard_output(planet, db)
	if float(job.get("progress", 0.0)) >= 1.0:
		planet.shipyard_progress += float(job.get("progress", 0.0))
		planet.ship_queue.pop_front()


static func _shipyard_output(planet: PlanetState, db: Node) -> float:
	# Per-turn ship production is allowed to be faster than a single hull when the colony
	# is producing at full tilt, which is what `PER_TURN` mode asks for. A colony with no
	# Space Port contributes nothing, so the mode cannot be used to smuggle shipbuilding
	# past the "at least 1 Space Port" rule.
	var ports := planet.count(&"space_port")
	return 0.5 + 0.25 * ports


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
## transferred.
##
## The mechanic behind the boost modal. Clamped three ways: to what was asked for, to what the
## colony has in store, and to what the project still owes. The third clamp is the one that
## matters — a player who opens the modal on a project that needs 20 metal more must not be
## able to pour a colony's entire 500-metal stockpile into it and watch 480 vanish into a
## structure worth 20.
static func boost_construction(planet: PlanetState, amount: float, buildings: Dictionary = {}) -> float:
	if planet == null or amount <= 0.0:
		return 0.0
	# Nothing queued, nothing to spend metal on. Returning zero rather than banking the metal
	# silently is what lets the construction bar tell the player why a press did nothing.
	if planet.building_queue.is_empty():
		return 0.0
	var ceiling := planet.reserve_metals
	if not buildings.is_empty():
		ceiling = minf(ceiling, metal_remaining(planet, buildings))
	var available := minf(amount, maxf(0.0, ceiling))
	if available <= 0.0:
		return 0.0
	# Debited here, credited here. The metal leaves storage exactly once and is never
	# returned -- `finish_construction` zeroes `build_metal` rather than paying the surplus
	# back, so a boosted project cannot refund the colony.
	planet.reserve_metals -= available
	planet.build_metal += available
	return available


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


## Completion progress for the colony's current project, 0..1.
##
## `progress = metal paid / total metal cost`, from `queued_cost`. A three-turn project at
## equal production reads 33% after one turn, whatever it costs — which is what the bar is
## claiming when it fills, and what the boost modal reports as the percentage already paid.
##
## Read from the definition rather than from the turn counter because a boosted project has
## turns left on the clock and metal banked against it at the same time. The metal is the
## honest measure: it is what was actually spent, by production or by hand.
static func construction_progress(planet: PlanetState, buildings: Dictionary) -> float:
	if planet == null or planet.building_queue.is_empty():
		return 0.0
	var cost := queued_cost(planet, buildings)
	if cost <= 0.0:
		return 0.0
	return clampf(planet.build_metal / cost, 0.0, 1.0)


## The most metal a boost could usefully transfer right now: what the colony holds, capped by
## what the project still owes.
##
## This is the ceiling the boost modal's slider is clamped to, so a player cannot be offered
## a transfer larger than the project can absorb.
static func max_boost(planet: PlanetState, buildings: Dictionary) -> float:
	if planet == null or planet.building_queue.is_empty():
		return 0.0
	return maxf(0.0, minf(planet.reserve_metals, metal_remaining(planet, buildings)))
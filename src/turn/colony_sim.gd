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


## Recount every capacity and re-seed the worker assignment from the structure table.
##
## Public, and called the moment a structure lands *or* is scrapped, because a capacity that
## is correct only at the start of the next turn is wrong for the whole of this one: a
## Granary's +1000 food has to be bankable the turn it is paid for, and a scrapped City
## Complex's +20 housing has to stop counting immediately. Waiting for the next colony pass
## left the panel quoting a colony that no longer existed for a full turn.
static func recount_capacity(planet: PlanetState, buildings: Dictionary, db: Node) -> void:
	_recount_capacity(planet, buildings, db)
	reconcile_workers(planet)


## Bring the worker assignment back in line with the structures that exist and the people
## available to work them.
##
## Three rules, applied in this order, and each of them is a case the model can actually reach:
##   - an assignment to a structure that is gone is dropped;
##   - an assignment larger than the number standing is trimmed to it;
##   - the total is trimmed to the civilian population, taking from the largest assignments
##     first so the loss is not concentrated on whichever hash-ordered key came first.
##
## Called after every construction event and at the top of every colony turn, so a colony can
## never be running more workers than it has people -- which would otherwise let food and metal
## scale off the population entirely.
static func reconcile_workers(planet: PlanetState) -> void:
	if planet == null:
		return
	var cleaned: Dictionary = {}
	for id: StringName in planet.worker_assignment:
		var standing := int(planet.structures.get(id, 0))
		if standing <= 0:
			continue
		var assigned := int(planet.worker_assignment[id])
		if assigned > 0:
			cleaned[id] = mini(assigned, standing)
	# Trim to the population, largest assignment first.
	var population := int(floor(planet.population))
	var total := 0
	for id: StringName in cleaned:
		total += int(cleaned[id])
	while total > population:
		var worst: StringName = &""
		var worst_count := 0
		for id: StringName in cleaned:
			if int(cleaned[id]) > worst_count:
				worst_count = int(cleaned[id])
				worst = id
		if worst == &"":
			break
		cleaned[worst] = worst_count - 1
		total -= 1
		if worst_count - 1 <= 0:
			cleaned.erase(worst)
	planet.worker_assignment = cleaned


## Civilians posted to `building_id`, or 0.
static func workers_on(planet: PlanetState, building_id: StringName) -> int:
	if planet == null:
		return 0
	return int(planet.worker_assignment.get(building_id, 0))


## Total civilians currently posted to a job somewhere on this colony.
static func workers_assigned(planet: PlanetState) -> int:
	if planet == null:
		return 0
	var total := 0
	for id: StringName in planet.worker_assignment:
		total += int(planet.worker_assignment[id])
	return total


## Civilians with no job, who therefore do nothing but research.
static func idle_workers(planet: PlanetState) -> int:
	if planet == null:
		return 0
	return maxi(0, int(floor(planet.population)) - workers_assigned(planet))


## Structures that can be staffed, and want to be.
##
## A colony-ship landing, a solar array and a granary are all standing structures that nobody
## staffs. This is the roster a `+` on the panel walks, so the two agree by construction.
const STAFFABLE: Array[StringName] = [&"farm", &"mine"]


## Post one more civilian to `building_id`. Returns whether anybody was posted.
##
## Refused on two counts, both of them the player's own labour: past the structures that
## exist, and past the people there are. The second is the one that used to be missing -- a
## colony could staff more farms than it had colonists and produce food out of nobody.
static func assign_worker(planet: PlanetState, building_id: StringName) -> bool:
	if planet == null or not STAFFABLE.has(building_id):
		return false
	if workers_on(planet, building_id) >= int(planet.structures.get(building_id, 0)):
		return false
	if idle_workers(planet) <= 0:
		return false
	planet.worker_assignment[building_id] = workers_on(planet, building_id) + 1
	return true


## Pull one civilian off `building_id`. Returns whether anybody was pulled.
static func unassign_worker(planet: PlanetState, building_id: StringName) -> bool:
	if planet == null:
		return false
	var current := workers_on(planet, building_id)
	if current <= 0:
		return false
	if current <= 1:
		planet.worker_assignment.erase(building_id)
	else:
		planet.worker_assignment[building_id] = current - 1
	return true


## Take one civilian off a randomly chosen worked farm or mine, or do nothing.
##
## Called when a colonist dies. The point is that the death is not *also* an invisible change
## to somebody's staffing: a colony that staffed all four of its workers and then lost one to
## starvation would carry on producing as though it had not, because the assignment table and
## the population had drifted apart. Returns the structure that lost the worker, or `&""`.
##
## The choice is random rather than a fixed order because any fixed order makes one building
## the one that always loses, and a player who noticed would be being told something false
## about which of their farms was marginal.
static func release_random_worker(planet: PlanetState, rng: RandomNumberGenerator = null) -> StringName:
	if planet == null:
		return &""
	var staffed: Array[StringName] = []
	for id: StringName in STAFFABLE:
		if workers_on(planet, id) > 0:
			staffed.append(id)
	if staffed.is_empty():
		return &""
	var pick := staffed[0]
	if rng != null and staffed.size() > 1:
		pick = staffed[rng.randi() % staffed.size()]
	unassign_worker(planet, pick)
	return pick


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
	# Before food and mining, because both now read the assignment table and must be looking
	# at a table that matches the structures and the population standing this turn.
	reconcile_workers(planet)

	# --- Food ------------------------------------------------------------------
	var food_bonus := 1.0 + faction.tech_effect(&"food_bonus")
	var food_produced := _food_output(planet, buildings) * food_bonus
	var food_consumed := planet.population * float(db.get("FOOD_PER_POP"))

	report.food_produced = food_produced
	report.food_consumed = food_consumed

	# `net = gross - consumption`, and `consumption` is exactly one food per civilian --
	# troops are excluded, so a garrison is not a mouth.
	#
	# The bank is then `clamp(stored + net, 0, capacity)` and the surplus is reported *next*
	# turn rather than this one -- see `_bank_food`.
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
	# Only when the bank is dry *and* the colony is still going backwards.
	#
	# The two conditions are not redundant, and collapsing them is how a colony starves on a
	# turn it is making food: `_bank_food` has just clamped the bank, so a colony whose net is
	# positive always ends this line above zero however empty it started. `net < 0` alone would
	# kill people in a colony that is drawing down a stockpile it can still afford to spend;
	# `stock <= 0` alone would kill them on the turn a last delivery arrives.
	if net < 0.0 and planet.food_stock <= 0.0:
		report.starving = true
		report.food_starved = true
		_add_warning(planet, &"starving")
		if planet.population > 0.0:
			var chance := float(db.get("STARVATION_DEATH_CHANCE"))
			if rng != null and rng.randf() < chance:
				planet.population = maxf(0.0, planet.population - 1.0)
				report.population_delta -= 1.0
				# The dead colonist was somebody's farmhand. Dropping them without
				# touching the assignment would leave the colony staffed past its own
				# population, which is exactly what `reconcile_workers` exists to prevent.
				release_random_worker(planet, rng)

	# --- Power -----------------------------------------------------------------
	_power_turn(planet, buildings, report)

	# --- Mining ----------------------------------------------------------------
	# Read through the same helper the panel reads, so the quoted rate and the credited rate
	# are one expression rather than two that happen to agree today.
	var metal_per_turn := get_projected_metal_delta(planet, buildings, faction)
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
	# Funded from the income credited above, not from the balance it is already part of. The
	# `income` argument is `report.metals_mined`, and mining has already run: whatever the
	# project takes this turn, the colony earned it this turn, so the stockpile is unchanged
	# by the act of building. `boost_construction` is the explicit opt-in for spending stock.
	_advance_construction(
		galaxy, planet, faction, buildings, hulls, db, report.metals_mined)

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
	# Named as a constant even though it is zero: the colony ship's berths are the only
	# housing a new colony has, so a floor of one would let a body nobody built house a
	# colonist. See `BASE_HOUSING`.
	var houses := float(db.get("BASE_HOUSING"))
	var power_out := 0.0
	var power_in := 0.0
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
## boundary.
##
## A serialised field on the planet rather than node metadata, and deliberately so. The flag is
## read by the next turn's resolution, so leaving it out of the save form made a round-trip
## resolve a different turn than the state it came from: the live colony reported the overflow
## it had earned, its copy did not, and the two state hashes diverged. The old note here argued
## that a mid-turn save should not manufacture a warning for a colony that has since been given
## a granary -- but the granary changes `food_capacity`, and the overflow being reported is the
## one that already happened, before the granary existed.
static func _bank_food(
	planet: PlanetState, net: float, db: Node, report: Report
) -> void:
	# Raise last turn's warning, if one was earned.
	if planet.pending_food_overflow:
		_add_warning(planet, &"food_overflow")
		planet.pending_food_overflow = false

	planet.food_stock += net
	if planet.food_stock < 0.0:
		planet.food_stock = 0.0

	if planet.food_stock > planet.food_capacity:
		report.food_overflowed = true
		planet.pending_food_overflow = true
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
	# A power shortage costs *buildings*, not people. That asymmetry is deliberate and is the
	# design's, not an oversight: running out of power stops new construction and everything
	# already standing keeps working, while running out of food kills. Making a blacked-out
	# colony lethal as well would have meant two independent 50% death rolls a colony short of
	# both could face -- 75% of turns losing somebody -- for a shortage the design explicitly
	# declines to make a penalty.
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

## Food produced this turn, from the farms that are actually worked.
##
## A farm produces only while a civilian is posted to it. That is the whole of what "requires
## 1 pop" means, and the number of workers is the player's decision rather than a side effect
## of an iteration order -- so three farms with two farmhands produce for two, not three.
##
## The landed Colony Ship's own +5 is included here rather than added by the caller.
##
## It used to be left out of the resolver entirely and added by hand in the panel, which is
## exactly the bug this pair of lines is the fix for: the panel showed a net of `+3` while the
## turn resolver banked a net of `-2`, and the colony bled food every turn while the readout
## claimed it was gaining. One function, two readers.
static func _food_output(planet: PlanetState, buildings: Dictionary) -> float:
	return _output_for(planet, buildings, &"farm", "yield_amount") \
		+ _unattended_output(planet, buildings, "yield_amount")


## Only the landed Colony Ship qualifies.
##
## A Colony Ship feeds its colonists from its own stores; there is no job to fill and no `+`
## button to press.
##
## This used to accept anything with `pop_required == 0`, which is a serious bug rather than a
## sloppy one: `yield_amount` is the *power* field for a reactor. A Nuclear plant reads 40, a
## Coal plant 8, a Solar array 1, and all three are `pop_required = 0`. So a colony with a
## reactor was producing forty extra food a turn from a structure that makes electricity and
## nothing else -- the food line was, in effect, reporting power generation.
##
## Gated on the structure's **kind** rather than on its staffing, because "needs a worker" and
## "produces food" are different questions and only the roster answers the second.
const UNATTENDED_OUTPUT_KINDS: Array[int] = [BuildingData.Kind.COLONY_PAD]
static func _unattended_output(
	planet: PlanetState, buildings: Dictionary, yield_field: StringName
) -> float:
	var total := 0.0
	if planet == null:
		return total
	for building_id: StringName in planet.structures:
		if STAFFABLE.has(building_id):
			continue
		var count := int(planet.structures[building_id])
		if count <= 0:
			continue
		var def: Resource = buildings.get(building_id, null) as Resource
		if def == null or not UNATTENDED_OUTPUT_KINDS.has(int(def.get("kind"))):
			continue
		total += float(def.get(yield_field)) * count
	return total


static func _metal_output(planet: PlanetState, buildings: Dictionary) -> float:
	return _output_for(planet, buildings, &"mine", "metal_per_turn") \
		+ _unattended_output(planet, buildings, "metal_per_turn")


## This colony's metal income for the coming turn, before the faction's mining bonus.
##
## The public face of `_metal_output`, and what the planet detail panel and the `PER_TURN` ship
## gate both read. It exists because they used to re-derive the figure from the structure
## table instead, which paid for every mine the colony *had* rather than the ones somebody was
## posted to -- so posting a worker moved the stockpile and the turn's income and left the
## displayed rate exactly where it was. One function, two readers, no second derivation.
static func metal_output(planet: PlanetState, buildings: Dictionary) -> float:
	if planet == null:
		return 0.0
	return _metal_output(planet, buildings)


## The metal this colony's stockpile will gain next turn. **The** projected metal rate.
##
## This is the figure `simulate_colony` credits, tech bonus included, so it is the number the
## panel quotes and the number the turn delivers. The bug it fixes: the panel read the raw mine
## output while the resolver applied `mining_bonus` on top, so an empire with `automated_mining`
## was shown `METAL 599 (+10)` and banked `+12.5`. The rate under-read by exactly the bonus the
## player had researched -- the more technology they earned, the further the readout drifted,
## which is the worst possible direction for a figure meant to predict the turn.
##
## `_metal_output` is still the right answer to "what do the mines produce", which is a
## different question and has its own callers. This is "what will the bank gain".
static func get_projected_metal_delta(
	planet: PlanetState, buildings: Dictionary, faction: FactionState = null
) -> float:
	if planet == null:
		return 0.0
	var bonus := 1.0
	if faction != null:
		bonus += faction.tech_effect(&"mining_bonus")
	return _metal_output(planet, buildings) * bonus


## The food this colony's pantry will gain next turn. **The** projected food rate.
##
## The twin of `get_projected_metal_delta`, and fixed for the same reason. The panel computed
## `worked_farms - population` while the resolver computed
## `(worked_farms * (1 + food_bonus)) - population * FOOD_PER_POP`, so a hydroponics empire was
## told it had `+6` coming when `+8.5` was on its way.
##
## Consumption goes through `FOOD_PER_POP` rather than a literal `1.0`, because that is what
## the resolver multiplies by. Both readers taking the constant from the same place is what
## makes them agree when the constant is not one.
static func get_projected_food_delta(
	planet: PlanetState, buildings: Dictionary, faction: FactionState = null, db: Node = null
) -> float:
	if planet == null:
		return 0.0
	var bonus := 1.0
	if faction != null:
		bonus += faction.tech_effect(&"food_bonus")
	var per_pop := 1.0
	if db != null:
		per_pop = float(db.get("FOOD_PER_POP"))
	return _food_output(planet, buildings) * bonus - planet.population * per_pop


## Output from the worked copies of one structure kind.
##
## The yield is read from the field the Phase 8 roster actually states -- farms are
## `yield_amount`, mines are `metal_per_turn` -- because the two are authored in different
## fields and a single accessor that guessed would be wrong for one of them.
static func _output_for(
	planet: PlanetState, buildings: Dictionary, building_id: StringName, yield_field: StringName
) -> float:
	if planet == null:
		return 0.0
	var def: Resource = buildings.get(building_id, null) as Resource
	if def == null:
		return 0.0
	var per_copy := float(def.get(yield_field))
	if per_copy <= 0.0:
		return 0.0
	# `_staffed` gates on the *assignment*, not on the population: a colony of six with two
	# farmhands runs two farms however many it built, and a colony of two with none runs
	# none however many it built.
	return per_copy * float(_staffed(planet, def, building_id))


## Post exactly `count` civilians to `building_id`. Returns the posting that stands.
##
## Absolute rather than a delta, which is what makes it safe to apply twice.
##
## Every colony order is queued *and* mirrored onto the client's own replica, so the resolver
## can be handed an order whose effect the sender has already applied locally. A
## `+1`/`-1` delta applied to both copies moves the posting twice; a target applied to both
## copies lands in the same place either way. `SessionController.assign_worker` therefore
## submits the count it just produced rather than the press that produced it, and this is
## what actually commits it on the authority.
##
## Clamped exactly as `assign_worker` clamps: never past the structures standing, never past
## the idle civilians. A count that cannot be honoured is accepted as far as it can be, and
## the shortfall is corrected by `reconcile_workers` at the top of the next colony turn
## rather than by refusing the whole order here.
static func set_worker_count(
	planet: PlanetState, building_id: StringName, count: int
) -> int:
	if planet == null or not STAFFABLE.has(building_id):
		return 0
	var standing := int(planet.structures.get(building_id, 0))
	if standing <= 0:
		return 0
	# What the rest of the colony is already employing is not available to this structure.
	var committed := 0
	for id: StringName in planet.worker_assignment:
		if id != building_id:
			committed += int(planet.worker_assignment[id])
	var hands := int(floor(planet.population))
	var wanted := clampi(count, 0, mini(standing, maxi(0, hands - committed)))
	if wanted <= 0:
		planet.worker_assignment.erase(building_id)
	else:
		planet.worker_assignment[building_id] = wanted
	return workers_on(planet, building_id)


## Post or pull one civilian, then say what the posting is now.
##
## `ColonySim.assign_worker` and `ColonySim.unassign_worker` already answer "is that
## allowed"; this answers "and what does the colony look like afterwards", which is what a
## client has to put on the wire so the authority can land on the same posting it did.
static func nudge_worker(
	planet: PlanetState, building_id: StringName, adding: bool
) -> int:
	if planet == null or not STAFFABLE.has(building_id):
		return 0
	if adding:
		assign_worker(planet, building_id)
	else:
		unassign_worker(planet, building_id)
	return workers_on(planet, building_id)


## Leave exactly `count` copies of `building_id` standing. Returns the metal refunded.
##
## Absolute for the same reason `set_worker_count` is: the sender has already mirrored the
## scrap locally, so re-applying it must be a no-op rather than a second structure gone.
## Scrapping down to `count` refunds half the original cost per copy removed, matching
## `destroy_structure` exactly -- it is that function expressed as a target.
##
## A structure still in `building_queue` is cancelled rather than scrapped, as everywhere
## else: a half-finished project that is stopped refunds nothing, or a player works out
## that stopping early is cheaper than finishing.
static func set_structure_count(
	planet: PlanetState, building_id: StringName, count: int,
	buildings: Dictionary, db: Node
) -> float:
	if planet == null or building_id == &"":
		return 0.0
	var current := int(planet.structures.get(building_id, 0))
	var wanted := maxi(0, count)
	if wanted >= current:
		return 0.0
	if int(planet.building_queue.get(building_id, 0)) > 0:
		planet.building_queue.erase(building_id)
		planet.build_metal = 0.0
		planet.build_turns_remaining = 0
		planet.build_total_turns = 0
		recount_capacity(planet, buildings, db)
		return 0.0
	var def: Resource = buildings.get(building_id, null) as Resource
	if def == null:
		return 0.0
	var removed := current - wanted
	var refund := float(def.get("cost_metals")) * GameDB.SCRAP_REFUND_RATE * float(removed)
	if wanted <= 0:
		planet.structures.erase(building_id)
		planet.worker_assignment.erase(building_id)
	else:
		planet.structures[building_id] = wanted
	# The posting cannot exceed what is left standing; `recount_capacity` runs the clamp.
	planet.reserve_metals += refund
	recount_capacity(planet, buildings, db)
	return refund


## Leave exactly `count` copies of `hull_id` in the orbit over `planet_index`.
##
## The ship half of `set_structure_count`, and idempotent for the same reason. Returns the
## metal refunded, which is half the original cost per hull removed.
static func set_hull_count(
	galaxy: GalaxyState, planet: PlanetState, faction: FactionState,
	hull_id: StringName, count: int, hulls: Dictionary
) -> float:
	if planet == null or hull_id == &"":
		return 0.0
	var orbiter := galactic_orbital_fleet(galaxy, planet.index, faction.id) if faction != null \
		else null
	if orbiter == null:
		return 0.0
	var current := int(orbiter.ships.get(hull_id, 0))
	var wanted := maxi(0, count)
	if wanted >= current:
		return 0.0
	var removed := current - wanted
	orbiter.remove_ships(hull_id, removed)
	var def: Resource = hulls.get(hull_id, null) as Resource
	var refund := 0.0
	if def != null:
		refund = float(def.get("cost_metals")) * GameDB.SCRAP_REFUND_RATE * float(removed)
	planet.reserve_metals += refund
	if orbiter.ship_count() <= 0 and galaxy != null:
		galaxy.remove_fleet(orbiter.id)
	return refund


## Whether one copy of `def` is worked and therefore producing.
##
## For a farm or a mine the answer is *is anyone posted to it*, read from the assignment table.
## It used to be *does the colony have any civilians at all*, which is a threshold rather than
## a reservation: one colonist satisfied every farm on the planet at once, so a colony with
## nine farms and one person fed nine. Making it an explicit posting is what lets a colony
## choose where its labour goes.
##
## Anything that is not a farm or a mine produces unattended. A granary stores and a landed
## colony ship runs off its own reactor; there is nobody to post to them and a `pop_required`
## on such a structure describes a staffing *threshold* for its output, not a job.
static func _staffed(planet: PlanetState, def: Resource, building_id: StringName = &"") -> int:
	var id := building_id if building_id != &"" else StringName(str(def.get("id")))
	if STAFFABLE.has(id):
		return workers_on(planet, id)
	if int(def.get("pop_required")) <= 0:
		return 1
	return 1 if planet.population >= 1.0 else 0


## Whether `building_id` would have somebody to work it when it finishes.
##
## The check behind the build-order warning: queueing a farm with no idle colonists is legal
## -- the colony will grow, or a Barracks conversion will free one, before the farm lands --
## but it is worth saying, because the structure finishes *unworked* and produces nothing.
static func would_be_staffed(planet: PlanetState, building_id: StringName) -> bool:
	if planet == null or not STAFFABLE.has(building_id):
		return true
	# Only about the idle pool, and not about whether the colony already stands a farm. The
	# question the warning asks is "will the new farm have somebody working it", and a colony
	# with six unstaffed farms and no idle colonists still has nobody for the seventh.
	return idle_workers(planet) >= 1


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
	buildings: Dictionary, hulls: Dictionary, db: Node, income: float
) -> void:
	if not planet.building_queue.is_empty():
		_advance_structure(planet, buildings, db, income)
		return
	if planet.count(&"space_port") <= 0:
		return
	if planet.ship_queue.is_empty():
		return
	_advance_ship(galaxy, planet, faction, hulls, income)


## One turn of the structure under construction.
##
## Funded from this turn's production, not from the stockpile.
##
## The slice credited here is the metal the mines actually earned *this* turn, moved out of
## the balance that same mining step has just credited. Because the two are the same metal, the
## transfer is a wash and `reserve_metals` ends the turn exactly where it started: a colony
## building out of its income pays for the project out of its income, and the stockpile is not
## raided to do it. This used to draw a flat `cost / build_turns` from storage instead, so a
## 100-metal City Complex cost 33 a turn whatever the colony earned, and a rich colony watching
## its bank drain while a project it could easily afford sat at "33%" for three turns had no
## way to tell funding from theft.
##
## What is left for storage to do is what the player asks for explicitly: `boost_construction`
## moves metal in when a project needs finishing faster, and that is the only path by which
## the bank funds a project. A colony whose mines earn nothing therefore builds nothing until
## it boosts, which is the honest consequence of having no income rather than a hidden tax.
##
## Completion is decided by the accumulated pool rather than by a turn count, so a slow colony
## takes longer and a fast one finishes sooner. The turn counter is still decremented because
## the bar reads it.
static func _advance_structure(
	planet: PlanetState, buildings: Dictionary, db: Node, income: float
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
	# Only what is still owed, and only what was earned. Clamped twice so neither the pool nor
	# the bank can be driven past the project's price by a rich turn.
	_contribute(planet, minf(income, maxf(0.0, cost - planet.build_metal)))
	planet.build_turns_remaining -= 1
	if planet.build_metal >= cost - 0.001:
		finish_construction(planet, buildings, db)


## Move `amount` of metal already sitting in `reserve_metals` into the structure project's
## pool, and return how much actually moved.
##
## Bounded by what the colony holds, because the caller is offering income that has just been
## credited to the bank. The caller must therefore run *after* mining; see `_advance_structure`.
static func _contribute(planet: PlanetState, amount: float) -> float:
	var moved := clampf(amount, 0.0, maxf(0.0, planet.reserve_metals))
	if moved <= 0.0:
		return 0.0
	planet.reserve_metals -= moved
	planet.build_metal += moved
	return moved


## One turn of the hull at the head of the shipyard queue.
##
## Funded from this turn's production, exactly as a structure is: the metal credited here is
## the metal the mines earned this turn, so the stockpile neither grows nor shrinks because a
## hull is in the yard. `boost_construction` remains the only way storage pays for a ship.
static func _advance_ship(
	galaxy: GalaxyState, planet: PlanetState, faction: FactionState, hulls: Dictionary,
	income: float
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
	var paid := float(job.get("metal", 0.0))
	# Only what is still owed, and only what was earned this turn.
	var share := clampf(minf(income, maxf(0.0, cost - paid)), 0.0, planet.reserve_metals)
	if share > 0.0:
		planet.reserve_metals -= share
		paid += share
	job["metal"] = paid
	# Same rule as the structure queue: metal already assigned is not owed again, and the hull
	# gets it back through the same `boost_construction` path, so a ship paid for by hand and
	# a ship paid for by the mines both advance the same bar.
	if paid >= cost - 0.001:
		# The last turn's income can carry the hull past its price. The overshoot is metal the
		# colony earned and the yard has no use for, so it goes back to storage rather than
		# being silently destroyed: the pool is cleared either way, so without this a colony
		# that over-earns on the finishing turn quietly loses the difference.
		planet.reserve_metals += maxf(0.0, paid - cost)
		planet.shipyard_progress = cost
		planet.ship_queue.pop_front()
		# The hull exists in orbit the moment it is paid for. It used to leave the yard and
		# vanish: `ship_queue.pop_front()` was the end of the line, so a ship the player had
		# spent several turns and a hundred metal on simply stopped existing, and nothing
		# ever put it in a fleet.
		deliver_ships(galaxy, planet, faction, hull_id, 1, hulls)
	else:
		planet.shipyard_progress = paid


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


## Bring the project's assigned metal to exactly `paid`, moving the difference either way.
##
## A target rather than a transfer, which is what makes it safe to apply twice.
##
## `boost_construction` and `refund_construction` are deltas, and every one of them is
## mirrored onto the client's own copy of the colony *and* shipped as an order -- so the
## authority applies an order whose effect the sender has already applied locally, and a
## delta would move the metal a second time. A target converges instead of accumulating, so
## a mirrored boost, a retried submission and an honest single application all land on the
## same figure. Same reasoning as `set_worker_count`.
##
## Named beside `project_paid` and `set_project_paid` rather than over either: those read the
## pool and write it, and this is the one that decides the difference between them and moves
## it. The upward direction is still bounded by storage and by what the project still owes,
## and the downward direction only by what is banked against it, so neither cap has moved:
## this is the two existing functions composed, not a third rule.
static func bring_project_paid_to(
	planet: PlanetState, paid: float, buildings: Dictionary = {}, hulls: Dictionary = {}
) -> float:
	if planet == null:
		return 0.0
	if project_kind(planet) == ProjectKind.NONE:
		return 0.0
	var current := project_paid(planet)
	var wanted := maxf(0.0, paid)
	if wanted <= current:
		return refund_construction(planet, current - wanted)
	return boost_construction(planet, wanted - current, buildings, hulls)


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
## Land everything in the queue and clear the project.
##
## The pool is funded by this turn's income, which is credited to the stockpile first and then
## transferred in, so a colony that over-earns on the finishing turn can finish the project
## with metal to spare. That surplus is returned here rather than destroyed: it is metal the
## colony earned and the finished project has no further claim on. The pool is zeroed either
## way, because keeping the overshoot against a project that no longer exists is money owed
## against nothing.
static func finish_construction(
	planet: PlanetState, buildings: Dictionary, db: Node
) -> void:
	# Priced before the queue is cleared, since clearing is what erases the definition lookup.
	var cost := queued_cost(planet, buildings)
	for building_id: StringName in planet.building_queue:
		var count := int(planet.building_queue[building_id])
		planet.structures[building_id] = int(planet.structures.get(building_id, 0)) + count
	planet.building_queue.clear()
	planet.build_turns_remaining = 0
	planet.build_total_turns = 0
	planet.reserve_metals += maxf(0.0, planet.build_metal - cost)
	planet.build_metal = 0.0
	# Recount immediately: the structures that just landed change capacity, housing and the
	# power budget, and everything after this point in the turn should see the new numbers
	# rather than the previous turn's. This is what makes a Granary's +1000 food, a City
	# Complex's +20 housing and an Energy Storage's +1000 energy appear the moment the
	# project completes rather than at the start of the following turn.
	_recount_capacity(planet, buildings, db)
	reconcile_workers(planet)


## Scrap one structure, returning half its original metal cost to the colony.
##
## Returns the refund, or 0.0 when nothing was scrapped. The refund is the *original* cost's
## half rather than a share of what was actually paid, so scrapping a half-finished project
## returns exactly what scrapping a finished one would: a refund scaled by the work done is a
## discount on stopping early, and a player who works that out never finishes anything.
##
## Any worker posted to it goes back to the idle pool in the same call, because a scrapped farm
## holding a farmhand's labour would be a way to keep a job that no longer exists.
static func destroy_structure(
	planet: PlanetState, building_id: StringName, buildings: Dictionary, db: Node
) -> float:
	if planet == null or building_id == &"":
		return 0.0
	if int(planet.structures.get(building_id, 0)) <= 0:
		return 0.0
	# A structure under construction is cancelled, not scrapped: the queue entry goes and the
	# metal banked against it goes with it, rather than the project becoming a standing
	# building that never had its metal paid for.
	if int(planet.building_queue.get(building_id, 0)) > 0:
		planet.building_queue.erase(building_id)
		planet.build_metal = 0.0
		planet.build_turns_remaining = 0
		planet.build_total_turns = 0
		return 0.0
	var def: Resource = buildings.get(building_id, null) as Resource
	if def == null:
		return 0.0
	var refund := float(def.get("cost_metals")) * GameDB.SCRAP_REFUND_RATE
	planet.structures[building_id] = int(planet.structures[building_id]) - 1
	if int(planet.structures[building_id]) <= 0:
		planet.structures.erase(building_id)
	# The worker goes home before the recount, so the released labour is visible to it.
	planet.worker_assignment.erase(building_id)
	planet.reserve_metals += refund
	recount_capacity(planet, buildings, db)
	return refund


## Scrap one hull from the fleet parked over `planet_index`, returning half its metal cost.
##
## Finds the orbital fleet the same way delivery does, for the same reason: a hull is either
## in a fleet or in the yard, and there is no third place to scrap one from.
static func destroy_ship(
	galaxy: GalaxyState, planet: PlanetState, faction: FactionState,
	hull_id: StringName, hulls: Dictionary
) -> float:
	if planet == null or faction == null or hull_id == &"":
		return 0.0
	var orbiter := galactic_orbital_fleet(galaxy, planet.index, faction.id)
	if orbiter == null or orbiter.remove_ships(hull_id, 1) <= 0:
		return 0.0
	var def: Resource = hulls.get(hull_id, null) as Resource
	var refund := 0.0
	if def != null:
		refund = float(def.get("cost_metals")) * GameDB.SCRAP_REFUND_RATE
	planet.reserve_metals += refund
	# An emptied fleet is removed rather than left standing as an empty marker: an empty
	# orbital fleet is still a selectable thing on the roster, and selecting it offers nothing.
	if orbiter.ship_count() <= 0 and galaxy != null:
		galaxy.remove_fleet(orbiter.id)
	return refund


## `GalaxyState.orbital_fleet`, spelled out so this file names its own dependency.
static func galactic_orbital_fleet(
	galaxy: GalaxyState, planet_index: int, faction_id: int
) -> FleetState:
	if galaxy == null:
		return null
	return galaxy.orbital_fleet(planet_index, faction_id)


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
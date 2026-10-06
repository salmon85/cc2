extends Node
## Shared tuning constants autoload.
##
## Every balance number that more than one subsystem reads lives here so the economy has a
## single place to be tuned and the turn resolver never hard-codes a magic number.

## Galactic charter (turn) numbers.
const TURNS_PER_YEAR := 4

## Starting imperial resources handed to each faction.
const START_TREASURY := 1000.0
const START_METALS := 400.0
const START_RARE_ELEMENTS := 150.0
const START_ENERGY := 300.0
const START_TECH_POINTS := 0.0

## Population is measured in millions of colonists.
const START_POPULATION := 3.0

## Growth and consumption.
##
## Phase 8 replaces the old fractional model with the integer one the design document
## specifies: one pop is one pop, it eats one food a turn, and it dies as a whole unit.
## The fractional figures that used to live here (`FOOD_SURPLUS_GROWTH`, `STARVATION_DECAY`,
## `MAX_POP_GROWTH_RATE`) scaled population by a percentage every turn, which cannot express
## "1 pop dies" at all.
const FOOD_PER_POP := 1.0

## Per-turn chance of one pop dying when the colony is out of food *and* has no reserve.
## The design document's 50%.
const STARVATION_DEATH_CHANCE := 0.5

## Per-turn chance of one pop being born when there is surplus, housing room and pop >= 2,
## before the soft cap below.
const POP_GROWTH_CHANCE := 0.50

## The soft cap: birth chance falls by this much per existing pop.
##
## A flat 50% every turn is not a growth rate, it is a coin toss -- a colony of four and a
## colony of forty both add one person on half their turns, so the only thing that stops a
## colony growing without limit is the player refusing to build housing. Scaling the chance
## down with the population that is already there makes the curve flatten on its own, while
## still responding upwards the moment a colony loses people: a world depopulated by famine
## repopulates quickly, and a crowded one trickles.
const POP_GROWTH_PENALTY_PER_POP := 0.015

## Floor and ceiling on the scaled birth chance. The floor matters as much as the fall: a
## colony of two thousand still grows, just slowly, so a large empire is never permanently
## frozen and a player's recovery from a disaster is never gated behind a rebuild.
const POP_GROWTH_MIN_CHANCE := 0.05
const POP_GROWTH_MAX_CHANCE := 0.50

## A colony below this population does not grow. Two is the smallest number from which one
## more can be a meaningful step.
const MIN_POP_FOR_GROWTH := 2.0

## Research.
##
## Research is passive in Phase 8: there are no allocation sliders, and the budget comes
## from the empire's total civilian population across every world it holds. A pop is a
## scientist whether or not it is assigned to a field, and the four fields are fed in
## proportion to what is still ahead in each rather than by a player-chosen split.
##
## The tax slider went with it: there is no longer an income figure for a player to set a
## percentage of, so `MIN_TAX_RATE` / `MAX_TAX_RATE` / `DEFAULT_TAX_RATE` and the whole
## morale block they fed are gone rather than left as tuning nobody reads. `FactionState`
## keeps `tax_rate` so an old save still round-trips; nothing consults it.
const RESEARCH_POINTS_PER_POP := 2.0

## The population thresholds that level technology up and unlock buildings and hulls.
##
## The design document makes research a function of population rather than of a budget the
## player divides, so the "research tree" is now a ladder: cross a milestone and the next
## tier unlocks. `ResearchStage.milestones()` is the single definition; the UI reads it and
## so does the resolver, which is what keeps the unlock order and the displayed progress
## from disagreeing.
const TECH_MILESTONES: Array[float] = [
	6.0, 14.0, 26.0, 42.0, 64.0, 92.0,
]

## How many hulls each milestone unlocks. Index 0 is the starting roster, before any
## milestone is crossed, so the first entry is never consulted.
const HULLS_PER_MILESTONE: int = 2

## Movement: parsecs per turn at drive level 0, before propulsion research.
## Fleet movement is in parsecs per turn, and the system is now 12000 parsecs across.
## These are fifty times the old galactic values for the same reason the map is fifty times
## wider: a scout covering one parsec per turn would take three months of turns to reach its
## neighbour, which reads as the fleet not moving at all.
const BASE_MOVEMENT := 50.0
const MOVEMENT_PER_DRIVE_LEVEL := 37.5
const MAX_MOVEMENT := 600.0
## Warp lanes are traversed in a single turn regardless of drive level.
const WARP_LANE_TRAVEL := 0.25

## Sensor ranges in parsecs.
## Sensor reach, in parsecs. Scaled with the map for the same reason as movement: against
## a 6000-parsec half-extent, a six-parsec bubble covers a single orbit ring and no more,
## so scouting would be worthless.
const SCOUT_SENSOR_RANGE := 900.0
const FLEET_SENSOR_RANGE := 450.0
const COLONY_SENSOR_RANGE := 300.0

## Storage.
##
## Food is the only resource with a hard cap that raises a warning when exceeded. Metal has
## no cap at all, and overflowing power storage is silent -- the surplus is simply lost, so a
## world that generates more power than it can bank wastes the rest rather than being
## nagged about it.
const FOOD_STORAGE_PER_GRANARY := 1000.0

## Food every colony can keep without a granary: the landed Colony Ship's own hold. Without
## it a brand new colony would have zero capacity and would overflow its very first meal.
const BASE_FOOD_STORAGE := 100.0

## Power every colony can bank without an Energy Storage structure.
const BASE_POWER_STORAGE := 100.0

## Warning thresholds. A warning is raised *on the next turn* after the condition is met, so
## a player who overflows sees it reported in the following turn's news rather than
## retroactively in the turn it happened.
const FOOD_OVERFLOW_WARNING := true
const POWER_OVERFLOW_WARNING := false

## Combat.
const SHIELD_ABSORPTION_PER_POINT := 1.0
const BEAM_ACCURACY := 0.75
const MISSILE_ACCURACY := 0.85
const POINT_DEFENSE_ACCURACY := 0.60
const DOGFIGHT_ACCURACY := 0.70
const MAX_COMBAT_ROUNDS := 6
const RETREAT_SALVAGE := 0.5
const FLEET_MORALE_BREAK_THRESHOLD := 0.35

## Invasion.
##
## Phase 8 replaces the probabilistic ground battle with a deterministic one. The design
## document is explicit: invading troops "land and engage garrison deterministically". So
## the assault is arithmetic -- troops lost equal the garrison they must chew through, and
## whoever has troops left over holds the surface -- rather than a victory roll against a
## defence score. That also makes invasion *repeatable*, which a combat stage seeded from
## the shared RNG was not: two clients that reached the same state could disagree about
## whether a world had fallen.
const COLONIZATION_COST := 120.0

## Troops raised per turn at a Barracks, per Barracks, before the barracks must be fed.
const TROOPS_PER_BARRACK := 1.0

## Pop a troop is converted from. One civilian becomes one troop, to the last unit.
const POP_PER_TROOP := 1.0

## Troops a planetary garrison fights with per unit of civilian population, used to derive a
## garrison for a colony that never built Barracks. Without it an un-garrisoned world would
## fall to a single troop, which makes population worthless in a war.
const GARRISON_TROOPS_PER_POP := 0.5

## Global economy balance.
const TREASURY_FLOOR := -500.0
const MAINTENANCE_PER_COLONY := 4.0
const SHIP_UPKEEP_PER_HULL_POINT := 0.5
const STRUCTURE_UPKEEP := 1.0

## Convenience: the four research fields in slider order.
const TECH_FIELD_ORDER: Array[int] = [
	0, 1, 2, 3,
]

## The hull ladder a faction climbs as its population crosses each milestone.
##
## Ordered weakest-first, and deliberately *not* the registry's load order: the ladder is the
## order a player acquires ships in, which is the order the design document lists them in.
## `ResearchStage.apply_milestones` hands out `HULLS_PER_MILESTONE` of these per rung, so a
## 2-milestone empire holds the first four and a 4-milestone empire the first eight.
const HULL_LADDER: Array[StringName] = [
	&"corvette", &"frigate", &"destroyer", &"cruiser",
	&"battlecruiser", &"battleship", &"battlestar", &"dreadnought",
	&"titan", &"leviathan",
]

## Hulls every empire starts with, regardless of population. A player who has never grown
## still needs one hull to move and one lift to settle a second world.
##
## The Space Port *adds* two more to this list (the Corvette and the Frigate) rather than
## replacing it: a port is what turns a settlement into an outpost, so the ships that make an
## outpost worth having are exactly the ones it should hand you.
const STARTER_HULLS: Array[StringName] = [
	&"colony_ship", &"exploration_ship", &"troop_transport", &"cargo_transport",
]

## The roster a Space Port makes immediately constructible, with no research and no milestone.
##
## These are the six hulls a colony cannot function without once it has a berth: something to
## survey with, something to carry food and metal with, something to carry troops with, a kit
## to settle a second world with, and two warships to keep the first one. Anything above the
## Frigate is still earned by population.
const PORT_HULLS: Array[StringName] = [
	&"exploration_ship", &"cargo_transport", &"troop_transport", &"colony_ship",
	&"corvette", &"frigate",
]

## Hulls that exist to move something other than ordnance: cargo, troops, or a colony kit.
##
## The Load/Unload control's visibility rule and the cargo modal's roster. Keyed on the hull
## rather than on the colony's structures, because a colony with no Space Port can still be
## sitting under a transport somebody else launched at it -- and that transport is exactly what
## the player wants to use.
const LOGISTIC_HULLS: Array[StringName] = [
	&"cargo_transport", &"troop_transport", &"colony_ship",
]

## How many distinct surface variants a world rolls at generation.
##
## The count lives here rather than in `PlanetVisuals` so the generator -- which is in the
## simulation layer and must not reach into the presentation layer to find out how many
## looks there are -- and the renderer read the same number from one place.
const PLANET_VISUAL_VARIANTS: int = 5


## Build the default research slider allocation (evenly spread).
##
## Retained for wire compatibility only. Phase 8 removed the sliders: research is driven by
## population and split by `ResearchStage`, so there is no allocation for a player to make.
## Old saves still carry the field and it still round-trips, but nothing reads it to decide
## anything.
static func default_research_allocation() -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(4)
	for i in 4:
		out[i] = 0.25
	return out
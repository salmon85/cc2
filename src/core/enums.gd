extends RefCounted
class_name Enums
## Global enumerations shared across simulation, data resources and UI.
##
## Kept in a single `class_name` script so every subsystem refers to the exact same
## enum types (GDScript enums are script-local; centralising them keeps ordinals stable).

## Classification of a planetary body. Ordinals index into `Defs.planet_types`.
enum PlanetClass {
	TERRESTRIAL, ## Balanced, high base habitability.
	DESERT,       ## Arid; rich in metals, poor in organics.
	ICE,          ## Frozen; water/energy rich, needs terraforming.
	VOLCANIC,     ## Extreme heat; abundant rare elements, low habitability.
	GAS_GIANT,    ## Uncolonizable without advanced terraforming tech.
	BARREN,       ## Dead rock; mining only.
}

## The four imperial research fields from the design document.
enum TechField {
	PROPULSION,   ## Movement range, hyperjump efficiency.
	ENERGY,       ## Shields, deflectors, beam output.
	WEAPONS,      ## Missiles, torpedoes, cannons, bombarders.
	INDUSTRIAL,   ## Terraforming, hydroponics, robotics.
}

## Functional role of a hull, which gates what orders it may receive.
##
## Phase 8 extends this to the full combat ladder the design document lists. The original
## six ordinals are preserved so anything already serialised -- saves, network payloads,
## the `ShipRole.Role` comparisons scattered through combat -- keeps meaning what it meant.
enum ShipRole {
	SCOUT,      ## High speed, wide scanner, minimal hull.
	COLONY,     ## Colony kit / self-sacrificing drop pod.
	TRANSPORT,  ## Bulk cargo and ground troop lift.
	CORVETTE,   ## Light patrol and screen.
	CRUISER,    ## Mainline combatant.
	DREADNOUGHT, ## Capital ship, bombardment capable.
	EXPLORATION, ## Survey hull: researches the planets it sits above.
	FRIGATE,    ## Escort.
	DESTROYER,  ## Line escort.
	BATTLECRUISER, ## Heavy cruiser.
	BATTLESHIP, ## Capital line.
	BATTLESTAR, ## Super-capital line.
	TITAN,      ## Siege capital.
	LEVIATHAN,  ## Fleet flagship.
	CARGO,      ## Bulk food / metal / power lift.
	TROOP,      ## Dedicated troop lift.
}

## Hull roles that fight. Used by the travel modal to separate the combat roster from the
## non-combat lift, and by the combat stage to decide what counts as a warship.
const COMBAT_ROLES: Array[int] = [
	ShipRole.SCOUT, ShipRole.CORVETTE, ShipRole.CRUISER, ShipRole.FRIGATE,
	ShipRole.DESTROYER, ShipRole.BATTLECRUISER, ShipRole.BATTLESHIP,
	ShipRole.BATTLESTAR, ShipRole.DREADNOUGHT, ShipRole.TITAN, ShipRole.LEVIATHAN,
]

## Hull roles that are lift rather than warships: colony kits, cargo and troop carriers.
const SUPPORT_ROLES: Array[int] = [
	ShipRole.COLONY, ShipRole.TRANSPORT, ShipRole.CARGO, ShipRole.TROOP,
]

## What a queued order asks the turn resolver to do.
enum OrderType {
	NONE,
	MOVE_FLEET,   ## Plot a course toward a star system.
	SIEGE_STAR,   ## Hold position and bombard the system's planets.
	COLONIZE,     ## Colony ship drops a base kit on a target body.
	BUILD_SHIP,   ## Push a hull onto a colony's shipyard queue.
	BUILD_STRUCTURE, ## Push a building onto a colony's construction queue.
	SET_TAX,      ## Legacy: retained on the wire so old packets still parse.
	SET_RESEARCH, ## Legacy: retained on the wire so old packets still parse.
	CANCEL_BUILD, ## Drop the last item off a build queue.
	DISBAND,      ## Disband a fleet, returning scrap.
	TRAVEL,       ## Send a chosen set of ships from one orbit to another.
	RECRUIT_TROOP, ## Convert 1 civilian pop into 1 military troop.
	BOOST_BUILD,  ## Spend stored metal on the construction in progress.
	SET_BUILD_MODE, ## Choose single-project or per-turn ship production.
	LOAD_CARGO,   ## Load food / metal / power / troops from a planet.
	UNLOAD_CARGO, ## Unload the same back onto a planet.
	REFUND_BUILD, ## Pull metal back out of the construction in progress.
	ASSIGN_WORKER, ## Post one more civilian to a staffable structure.
	UNASSIGN_WORKER, ## Pull one civilian off a staffable structure.
	SCRAP_STRUCTURE, ## Scrap a standing structure, refunding half its cost.
	LAND_COLONY_SHIP, ## Spend an orbital Colony Ship to settle the world beneath it.
}

## The highest `OrderType` ordinal the wire format accepts.
const MAX_ORDER_TYPE: int = 20

## How a colony spends its per-turn construction allowance.
enum BuildMode {
	SINGLE,    ## Exactly one building per turn.
	PER_TURN,  ## One or more ships per turn, if the colony can afford the metal.
}

## Player control mode.
enum FactionKind {
	HUMAN,
	AI,
	NEUTRAL, ## Unclaimed systems that block expansion.
}

## Star spectral classes, purely cosmetic/positional.
enum StarClass {
	M, K, G, F, A, B, O,
}

## Result of a single combat exchange, used for the news log.
enum CombatOutcome {
	NONE,
	ATTRITION, ## Both sides damaged, engagement continues.
	FLEET_DESTROYED, ## One side annihilated.
	FLEET_SURVIVED,  ## Attacker withdrew after taking losses.
	RETREAT,         ## Defender fled.
}


## Human-readable label for a planet class. Pure function, no engine state.
static func planet_class_name(cls: PlanetClass) -> String:
	match cls:
		PlanetClass.TERRESTRIAL: return "Terrestrial"
		PlanetClass.DESERT: return "Desert"
		PlanetClass.ICE: return "Ice"
		PlanetClass.VOLCANIC: return "Volcanic"
		PlanetClass.GAS_GIANT: return "Gas Giant"
		PlanetClass.BARREN: return "Barren"
	return "Unknown"


## Human-readable label for a tech field.
static func tech_field_name(field: TechField) -> String:
	match field:
		TechField.PROPULSION: return "Propulsion"
		TechField.ENERGY: return "Energy & Shields"
		TechField.WEAPONS: return "Weapons & Ballistics"
		TechField.INDUSTRIAL: return "Industrial & Biospheric"
	return "Unknown"


## Human-readable label for a ship role.
static func ship_role_name(role: ShipRole) -> String:
	match role:
		ShipRole.SCOUT: return "Scout"
		ShipRole.COLONY: return "Colony Ship"
		ShipRole.TRANSPORT: return "Transport"
		ShipRole.CORVETTE: return "Corvette"
		ShipRole.CRUISER: return "Cruiser"
		ShipRole.DREADNOUGHT: return "Dreadnought"
		ShipRole.EXPLORATION: return "Exploration Ship"
		ShipRole.FRIGATE: return "Frigate"
		ShipRole.DESTROYER: return "Destroyer"
		ShipRole.BATTLECRUISER: return "Battlecruiser"
		ShipRole.BATTLESHIP: return "Battleship"
		ShipRole.BATTLESTAR: return "Battlestar"
		ShipRole.TITAN: return "Titan"
		ShipRole.LEVIATHAN: return "Leviathan"
		ShipRole.CARGO: return "Cargo Transport"
		ShipRole.TROOP: return "Troop Transport"
	return "Unknown"


## Whether a hull role fights, as opposed to carrying cargo, troops or a colony kit.
##
## The travel modal and the combat stage both need this partition, and it used to be
## re-derived at each call site as "is this role in the warship list" with a different
## list each time. One definition, used by both.
##
## Takes an `int` rather than a `ShipRole` because every caller reads the role out of a
## `Resource` with `get("role")`, which is a `Variant`. GDScript cannot cast a `Variant` to an
## enum by call syntax, so the honest signature is the one the callers actually have.
static func role_is_combat(role: int) -> bool:
	return COMBAT_ROLES.has(role)


## Whether a hull role is lift: cargo, troops or a colony kit.
static func role_is_support(role: int) -> bool:
	return SUPPORT_ROLES.has(role)
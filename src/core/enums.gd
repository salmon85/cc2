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
enum ShipRole {
	SCOUT,     ## High speed, wide scanner, minimal hull.
	COLONY,   ## Colony kit / self-sacrificing drop pod.
	TRANSPORT, ## Bulk cargo and ground troop lift.
	CORVETTE,  ## Light patrol and screen.
	CRUISER,   ## Mainline combatant.
	DREADNOUGHT, ## Capital ship, bombardment capable.
}

## What a queued order asks the turn resolver to do.
enum OrderType {
	NONE,
	MOVE_FLEET,   ## Plot a course toward a star system.
	SIEGE_STAR,   ## Hold position and bombard the system's planets.
	COLONIZE,     ## Colony ship drops a base kit on a target body.
	BUILD_SHIP,   ## Push a hull onto a colony's shipyard queue.
	BUILD_STRUCTURE, ## Push a building onto a colony's construction queue.
	SET_TAX,      ## Adjust the imperial tax slider (0..100).
	SET_RESEARCH, ## Set per-field research slider weights (0..100).
	CANCEL_BUILD, ## Drop the last item off a build queue.
	DISBAND,      ## Disband a fleet, returning scrap.
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
	return "Unknown"
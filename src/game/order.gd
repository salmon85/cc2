extends RefCounted
class_name Order
## One queued player or AI order, submitted during the order phase and executed by the
## turn resolver during the execution phase.
##
## Orders are plain dictionaries on the wire (see `to_dict`/`from_dict`) so the same
## structure works for a local single-player queue, a network packet and a save file.

## `Enums.OrderType`.
var type: int = 0

## Faction that issued the order. The resolver rejects orders from a faction that does
## not own the asset the order refers to.
var faction: int = -1

## Fleet the order applies to, or -1 for imperial orders.
var fleet: int = -1

## Target system index, or -1. Always -1 now that there is one system and fleets
## travel between planets; kept on the wire so old orders still parse.
var target_system: int = -1

## Target planet index, or -1.
var target_planet: int = -1

## Payload, meaning depends on `type`:
##   MOVE_FLEET     {}
##   SIEGE_STAR     {}
##   COLONIZE       {}
##   BUILD_SHIP     {"hull": StringName}
##   BUILD_STRUCTURE{"building": StringName, "count": int}
##   SET_TAX        {"rate": float}
##   SET_RESEARCH   {"allocation": PackedFloat64Array}
##   CANCEL_BUILD   {}
##   DISBAND        {}
var payload: Dictionary = {}


## Build an order. Static constructors keep call sites readable and type-safe.
static func make_move_fleet(faction_id: int, fleet_id: int, target_planet: int) -> Order:
	var o := Order.new()
	o.type = 1  # MOVE_FLEET
	o.faction = faction_id
	o.fleet = fleet_id
	o.target_planet = target_planet
	return o


static func make_colonize(faction_id: int, fleet_id: int, planet_index: int) -> Order:
	var o := Order.new()
	o.type = 3  # COLONIZE
	o.faction = faction_id
	o.fleet = fleet_id
	o.target_planet = planet_index
	return o


static func make_siege(faction_id: int, fleet_id: int, target_system: int) -> Order:
	var o := Order.new()
	o.type = 2  # SIEGE_STAR
	o.faction = faction_id
	o.fleet = fleet_id
	o.target_system = target_system
	return o


static func make_build_ship(faction_id: int, planet_index: int, hull_id: StringName) -> Order:
	var o := Order.new()
	o.type = 4  # BUILD_SHIP
	o.faction = faction_id
	o.target_planet = planet_index
	o.payload = {"hull": hull_id}
	return o


static func make_build_structure(
	faction_id: int, planet_index: int, building_id: StringName, count: int = 1
) -> Order:
	var o := Order.new()
	o.type = 5  # BUILD_STRUCTURE
	o.faction = faction_id
	o.target_planet = planet_index
	o.payload = {"building": building_id, "count": count}
	return o


static func make_set_tax(faction_id: int, rate: float) -> Order:
	var o := Order.new()
	o.type = 6  # SET_TAX
	o.faction = faction_id
	o.payload = {"rate": rate}
	return o


static func make_set_research(faction_id: int, allocation: PackedFloat64Array) -> Order:
	var o := Order.new()
	o.type = 7  # SET_RESEARCH
	o.faction = faction_id
	o.payload = {"allocation": allocation}
	return o


static func make_cancel_build(faction_id: int, planet_index: int) -> Order:
	var o := Order.new()
	o.type = 8  # CANCEL_BUILD
	o.faction = faction_id
	o.target_planet = planet_index
	return o


static func make_disband(faction_id: int, fleet_id: int) -> Order:
	var o := Order.new()
	o.type = 9  # DISBAND
	o.faction = faction_id
	o.fleet = fleet_id
	return o


## Human-readable label, used by the resolver's rejection log and the UI.
func describe() -> String:
	match type:
		1: return "Fleet %d of %s moves to planet %d" % [fleet, _faction_tag(), target_planet]
		2: return "Fleet %d besieges system %d" % [fleet, target_system]
		3: return "Fleet %d colonises planet %d" % [fleet, target_planet]
		4: return "Build %s at planet %d" % [payload.get("hull", "?"), target_planet]
		5: return "Build %d x %s at planet %d" % [
			int(payload.get("count", 1)), payload.get("building", "?"), target_planet]
		6: return "Set tax rate to %.2f" % float(payload.get("rate", 0.0))
		7: return "Set research allocation"
		8: return "Cancel construction at planet %d" % target_planet
		9: return "Disband fleet %d" % fleet
	return "Unknown order"


func _faction_tag() -> String:
	return "faction %d" % faction


func to_dict() -> Dictionary:
	return {
		"type": type,
		"faction": faction,
		"fleet": fleet,
		"target_system": target_system,
		"target_planet": target_planet,
		"payload": payload.duplicate(true),
	}


## Rebuild from `to_dict()`. Returns false when the payload is unusable, so a malformed
## network packet is rejected at the boundary rather than half-applied.
static func from_dict(data: Dictionary) -> Order:
	if not data.has("type"):
		push_error("[Order] payload missing 'type'")
		return null
	var kind := int(data.get("type", 0))
	if kind < 0 or kind > Enums.OrderType.DISBAND:
		# A malformed or hostile packet must not become an order that silently
		# resolves to OrderType.NONE.
		push_error("[Order] payload has an unknown type %d" % kind)
		return null
	var o := Order.new()
	o.type = kind
	o.faction = int(data.get("faction", -1))
	o.fleet = int(data.get("fleet", -1))
	o.target_system = int(data.get("target_system", -1))
	o.target_planet = int(data.get("target_planet", -1))
	o.payload = (data.get("payload", {}) as Dictionary).duplicate(true)
	return o


## Ordering-independent fingerprint, used by determinism tests.
func fingerprint() -> String:
	var keys := payload.keys()
	var parts := PackedStringArray()
	for key: Variant in keys:
		parts.append("%s=%s" % [KeyText.key(key), str(payload[key])])
	parts.sort()
	return "%d:%d:%d:%d:%d:%s" % [
		type, faction, fleet, target_system, target_planet, str(parts),
	]
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
##   SET_TAX        {"rate": float}          -- inert as of Phase 8
##   SET_RESEARCH   {"allocation": [...]}    -- inert as of Phase 8
##   CANCEL_BUILD   {}
##   DISBAND        {}
##   TRAVEL         {"ships": {hull_id: count}}
##   RECRUIT_TROOP  {}
##   BOOST_BUILD    {"metals": float}
##   SET_BUILD_MODE {"mode": int}
##   LOAD_CARGO     {"kind": String, "amount": float}
##   UNLOAD_CARGO   {"kind": String, "amount": float}
##   REFUND_BUILD   {"metals": float}
##   ASSIGN_WORKER  {"building": StringName}
##   UNASSIGN_WORKER{"building": StringName}
##   SCRAP_STRUCTURE{"building": StringName}
##
## The three colony-staffing orders exist because those actions used to be pure local
## mutations: a networked client applied them to its own replica and shipped nothing, so the
## server's next snapshot simply overwrote them and the player's work vanished. Anything a
## player does to a colony is now an order, and the client applies it locally *and* queues
## it, exactly as `BUILD_STRUCTURE` already does.
##
## `SET_TAX` and `SET_RESEARCH` are retained rather than removed: the tax slider and the
## research allocation sliders are both gone from the UI, so nothing produces these any more,
## but a client or save from before this phase still sends them. Keeping the ordinals means
## the packet parses instead of being rejected as an unknown type.
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


## Send a chosen set of ships from their current world to `planet_index`.
##
## `ships` is a `{hull_id: count}` manifest. An empty manifest means the whole fleet, which
## is what makes this a strict superset of `make_move_fleet` rather than a second way of
## saying the same thing: the travel modal can express both with one order type.
static func make_travel(
	faction_id: int, fleet_id: int, planet_index: int, ships: Dictionary = {}
) -> Order:
	var o := Order.new()
	o.type = 10  # TRAVEL
	o.faction = faction_id
	o.fleet = fleet_id
	o.target_planet = planet_index
	o.payload = {"ships": ships.duplicate(true)}
	return o


## Convert one civilian on `planet_index` into one troop. Requires a Barracks.
static func make_recruit_troop(faction_id: int, planet_index: int) -> Order:
	var o := Order.new()
	o.type = 11  # RECRUIT_TROOP
	o.faction = faction_id
	o.target_planet = planet_index
	return o


## Have `paid` metal assigned to the construction in progress on `planet_index`.
##
## `paid` is the *total* the project should be carrying, not a transfer to make, and that is
## deliberate. The client mirrors every action onto its own copy of the colony and then ships
## the order, so the authority applies an order whose effect the sender has already applied;
## a delta would move the metal twice and a target lands in the same place either way. It
## also makes a retried submission harmless rather than a second deduction.
static func make_boost_build(faction_id: int, planet_index: int, paid: float) -> Order:
	var o := Order.new()
	o.type = 12  # BOOST_BUILD
	o.faction = faction_id
	o.target_planet = planet_index
	o.payload = {"paid": paid}
	return o


## Choose single-project or per-turn construction on `planet_index`.
static func make_set_build_mode(faction_id: int, planet_index: int, mode: int) -> Order:
	var o := Order.new()
	o.type = 13  # SET_BUILD_MODE
	o.faction = faction_id
	o.target_planet = planet_index
	o.payload = {"mode": mode}
	return o


## Move `amount` of `kind` between a world and a fleet parked over it.
static func make_cargo(
	faction_id: int, fleet_id: int, kind: StringName, amount: float, loading: bool
) -> Order:
	var o := Order.new()
	o.type = 14 if loading else 15  # LOAD_CARGO / UNLOAD_CARGO
	o.faction = faction_id
	o.fleet = fleet_id
	o.payload = {"kind": String(kind), "amount": amount}
	return o


## Have `paid` metal assigned to the construction in progress on `planet_index`.
##
## The mirror of `make_boost_build`, and deliberately a separate type rather than a negative
## amount: a signed payload is how a refund turns into a silent free grant the first time a
## sign is lost, and the two directions have different caps (one is bounded by storage, the
## other by what has already been assigned). `paid` is again a target rather than a transfer,
## for the same idempotence reason.
static func make_refund_build(faction_id: int, planet_index: int, paid: float) -> Order:
	var o := Order.new()
	o.type = 16  # REFUND_BUILD
	o.faction = faction_id
	o.target_planet = planet_index
	o.payload = {"paid": paid}
	return o


## Post one more civilian to `building_id` on `planet_index`.
static func make_assign_worker(faction_id: int, planet_index: int, building_id: StringName) -> Order:
	var o := Order.new()
	o.type = 17  # ASSIGN_WORKER
	o.faction = faction_id
	o.target_planet = planet_index
	o.payload = {"building": building_id}
	return o


## Pull one civilian off `building_id` on `planet_index`.
static func make_unassign_worker(
	faction_id: int, planet_index: int, building_id: StringName
) -> Order:
	var o := Order.new()
	o.type = 18  # UNASSIGN_WORKER
	o.faction = faction_id
	o.target_planet = planet_index
	o.payload = {"building": building_id}
	return o


## Scrap one standing copy of `building_id` on `planet_index`, refunding half its cost.
static func make_scrap_structure(
	faction_id: int, planet_index: int, building_id: StringName
) -> Order:
	var o := Order.new()
	o.type = 19  # SCRAP_STRUCTURE
	o.faction = faction_id
	o.target_planet = planet_index
	o.payload = {"building": building_id}
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
		10: return "Fleet %d travels to planet %d with %s" % [
			fleet, target_planet, _manifest_text()]
		11: return "Raise a troop at planet %d" % target_planet
		12: return "Boost construction at planet %d with %d metal" % [
			target_planet, int(payload.get("metals", 0.0))]
		13: return "Set planet %d build mode to %s" % [
			target_planet,
			"per-turn ships" if int(payload.get("mode", 0)) == 1 else "single project"]
		14: return "Load %s into fleet %d" % [payload.get("kind", "?"), fleet]
		15: return "Unload %s from fleet %d" % [payload.get("kind", "?"), fleet]
		16: return "Refund %d metal from construction at planet %d" % [
			int(payload.get("metals", 0.0)), target_planet]
		17: return "Post a worker to %s at planet %d" % [
			payload.get("building", "?"), target_planet]
		18: return "Pull a worker off %s at planet %d" % [
			payload.get("building", "?"), target_planet]
		19: return "Scrap %s at planet %d" % [payload.get("building", "?"), target_planet]
	return "Unknown order"


## Compact rendering of a travel manifest, for the news line.
func _manifest_text() -> String:
	var ships: Dictionary = payload.get("ships", {}) as Dictionary
	if ships.is_empty():
		return "the whole fleet"
	var ids := PackedStringArray()
	for key: Variant in ships:
		ids.append("%s x%d" % [String(key), int(ships[key])])
	ids.sort()
	return ", ".join(ids)


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
	if kind < 0 or kind > Enums.MAX_ORDER_TYPE:
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
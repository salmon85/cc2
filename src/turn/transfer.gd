extends RefCounted
class_name TransferStage
## Cargo and troop movement between a world and the fleets parked over it.
##
## Split out from `InvasionStage` because these are logistics, not combat: nothing here can
## change who owns anything, and every one of these operations is a plain add or subtract
## that a client and a server can perform in the same order and get the same answer.
##
## The Phase 8 travel modal shows a live cargo readout, which means it needs to ask these
## questions *without* committing to anything — `capacity_for` and `loadable` are the
## queries the readout uses, and `load` / `unload` are the mutations the orders call.

## The cargo manifest keys, as they appear in `FleetState.cargo` and in a transfer order.
const KIND_METALS := &"metals"
const KIND_FOOD := &"food"
const KIND_POWER := &"power"
const KIND_TROOPS := &"troops"
const KIND_CIVILIANS := &"civilians"

## Every kind that can be moved, in the order the modal lists them.
const KINDS: Array[StringName] = [
	KIND_METALS, KIND_FOOD, KIND_POWER, KIND_TROOPS, KIND_CIVILIANS,
]

## Human-readable label for a cargo kind, for the modal's readout.
static func kind_name(kind: StringName) -> String:
	match kind:
		KIND_METALS: return "Metal"
		KIND_FOOD: return "Food"
		KIND_POWER: return "Power"
		KIND_TROOPS: return "Troops"
		KIND_CIVILIANS: return "Civilians"
	return String(kind).capitalize()


## What a world holds of `kind`.
static func planet_stock(planet: PlanetState, kind: StringName) -> float:
	match kind:
		KIND_METALS: return planet.reserve_metals
		KIND_FOOD: return planet.food_stock
		KIND_POWER: return planet.power
		KIND_TROOPS: return float(planet.troops)
		KIND_CIVILIANS: return planet.population
	return 0.0


## Take `amount` of `kind` out of a world, bounded by what it holds.
static func planet_withdraw(planet: PlanetState, kind: StringName, amount: float) -> float:
	if amount <= 0.0:
		return 0.0
	var taken := minf(amount, planet_stock(planet, kind))
	if taken <= 0.0:
		return 0.0
	match kind:
		KIND_METALS: planet.reserve_metals -= taken
		KIND_FOOD: planet.food_stock -= taken
		KIND_POWER: planet.power -= taken
		KIND_TROOPS: planet.troops -= int(taken)
		KIND_CIVILIANS: planet.population -= taken
	return taken


## Put `amount` of `kind` into a world, bounded by its storage capacity.
##
## Food and power are the two kinds with a cap, and they are clamped rather than refused:
## a colony that receives more food than it can hold keeps the excess as food-in-transit
## nowhere and simply stores what fits. This is the same overflow rule the colony sim applies
## to production, and for the same reason — the warning is raised there, on the following
## turn, rather than invented here.
static func planet_deposit(planet: PlanetState, kind: StringName, amount: float) -> float:
	if amount <= 0.0:
		return 0.0
	match kind:
		KIND_METALS:
			planet.reserve_metals += amount
			return amount
		KIND_FOOD:
			var room := maxf(0.0, planet.food_capacity - planet.food_stock)
			var stored := minf(amount, room)
			planet.food_stock += stored
			return stored
		KIND_POWER:
			var room2 := maxf(0.0, planet.power_capacity - planet.power)
			var banked := minf(amount, room2)
			planet.power += banked
			return banked
		KIND_TROOPS:
			planet.troops += int(amount)
			return float(int(amount))
		KIND_CIVILIANS:
			planet.population += amount
			return amount
	return 0.0


## How much of `kind` the fleet's hulls can hold in total.
##
## Only hulls that actually lift `kind` are counted, so a fleet of warships and one troop
## transport has zero metal capacity between them rather than one troop transport's capacity
## silently applying to everything. Cargo is the thing the hull says it carries.
static func capacity_for(fleet: FleetState, kind: StringName) -> float:
	var total := 0.0
	for key: StringName in fleet.ships:
		var def: Resource = fleet.hulls().get(key, null) as Resource
		if def == null:
			continue
		if not def.call("carries", _kind_code(kind)):
			continue
		var count := int(fleet.ships[key])
		if kind == KIND_CIVILIANS:
			total += float(def.get("civilian_capacity")) * count
		elif kind == KIND_TROOPS:
			total += float(def.get("troop_capacity")) * count
		else:
			total += float(def.get("cargo_capacity")) * count
	return total


## How much of `kind` the fleet is currently carrying.
static func carried(fleet: FleetState, kind: StringName) -> float:
	return maxf(0.0, float(fleet.cargo.get(String(kind), 0.0)))


## How much of `kind` the fleet could still take on.
static func free_space(fleet: FleetState, kind: StringName) -> float:
	return maxf(0.0, capacity_for(fleet, kind) - carried(fleet, kind))


## How much of `kind` a world could hand over to this fleet right now.
##
## The minimum of what the world holds and what the fleet has room for, which is what the
## modal's `+` button should advance by: pressing it twice must not let the player
## "over-load" a ship and then have the surplus silently vanish.
static func loadable(planet: PlanetState, fleet: FleetState, kind: StringName) -> float:
	return minf(planet_stock(planet, kind), free_space(fleet, kind))


## The `ShipHullData.CargoKind` code a manifest key stands for.
static func _kind_code(kind: StringName) -> int:
	match kind:
		KIND_METALS: return ShipHullData.CargoKind.METALS
		KIND_FOOD: return ShipHullData.CargoKind.FOOD
		KIND_POWER: return ShipHullData.CargoKind.POWER
		KIND_TROOPS: return ShipHullData.CargoKind.TROOPS
		KIND_CIVILIANS: return ShipHullData.CargoKind.CIVILIANS
	return ShipHullData.CargoKind.NONE


## Load `amount` of `kind` from the world into the fleet's holds. Returns what moved.
static func load(
	planet: PlanetState, fleet: FleetState, kind: StringName, amount: float
) -> float:
	if planet == null or fleet == null or amount <= 0.0:
		return 0.0
	var movable := minf(amount, loadable(planet, fleet, kind))
	if movable <= 0.0:
		return 0.0
	var taken := planet_withdraw(planet, kind, movable)
	if taken <= 0.0:
		return 0.0
	fleet.cargo[String(kind)] = carried(fleet, kind) + taken
	return taken


## Unload `amount` of `kind` from the fleet onto the world. Returns what moved.
static func unload(
	planet: PlanetState, fleet: FleetState, kind: StringName, amount: float
) -> float:
	if planet == null or fleet == null or amount <= 0.0:
		return 0.0
	var held := carried(fleet, kind)
	if held <= 0.0:
		return 0.0
	var landed := minf(amount, held)
	var stored := planet_deposit(planet, kind, landed)
	fleet.cargo[String(kind)] = held - landed
	return stored
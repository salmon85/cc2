extends RefCounted
class_name OrderQueue
## Per-turn order buffer, keyed by faction.
##
## The resolver consumes each faction's orders in submission order, so two orders from the
## same faction resolve deterministically regardless of network arrival jitter — the
## server sorts by a monotonic sequence number, not by wall-clock time.

## Faction id -> orders, in submission order.
var _queues: Dictionary = {}

## Faction id -> whether that faction has pressed "End Turn".
var _ready: Dictionary = {}

## Monotonic counter giving each order a stable position.
var _sequence: int = 0


## Queue an order. Returns false for a malformed order rather than storing garbage.
func submit(order: Order) -> bool:
	if order == null:
		push_error("[OrderQueue] refusing a null order")
		return false
	if order.faction < 0:
		push_error("[OrderQueue] refusing an order with no issuing faction")
		return false
	if not _queues.has(order.faction):
		_queues[order.faction] = [] as Array[Order]
	(_queues[order.faction] as Array).append(order)
	_sequence += 1
	return true


## Mark a faction's orders as locked in for this turn.
func set_ready(faction_id: int, ready: bool) -> void:
	_ready[faction_id] = ready


func is_ready(faction_id: int) -> bool:
	return bool(_ready.get(faction_id, false))


## Whether every registered faction has pressed End Turn.
##
## `active_factions` is supplied by the resolver because defeated factions must not be
## able to stall the turn by going quiet.
func all_ready(active_factions: PackedInt32Array) -> bool:
	if active_factions.is_empty():
		return false
	for f in active_factions:
		if not is_ready(f):
			return false
	return true


## Orders for one faction, in submission order.
func orders_for(faction_id: int) -> Array[Order]:
	var out: Array[Order] = []
	for o in (_queues.get(faction_id, []) as Array):
		out.append(o)
	return out


## Every faction that has queued at least one order this turn.
func factions_with_orders() -> PackedInt32Array:
	var ids := _queues.keys()
	ids.sort()
	var out := PackedInt32Array()
	for id: int in ids:
		out.append(id)
	return out


## Drop every order and clear the ready flags. Called after a turn resolves.
func clear() -> void:
	_queues.clear()
	_ready.clear()
	_sequence = 0


func pending_count() -> int:
	var total := 0
	for f in _queues:
		total += (_queues[f] as Array).size()
	return total
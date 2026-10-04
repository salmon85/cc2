extends TurnSyncPeer
class_name TurnSyncServer
## Authoritative server half of the turn-synchronisation protocol.
##
## Holds the live `GalaxyState`, collects every active player's orders for the turn, and
## resolves once -- and only once -- all of them are in. The resolver it calls is the same
## `TurnResolver` single player runs, which is what makes networked play unable to diverge
## from offline play: there is exactly one implementation of a turn.
##
## Extends `TurnSyncPeer` rather than implementing the RPCs separately, because Godot
## requires both roles to expose an identical `@rpc` method set at the same node path.
## See that file for the full explanation of why that constraint is not negotiable.

## Emitted when a turn resolves and has been broadcast.
signal turn_broadcast(turn_num: int, state_hash: String)

## The `NetworkManager` hosting this server. Supplies the peer-to-slot table.
var net: NetworkManager = null

## Clients told the server is full are dropped rather than left hanging.
const REFUSAL_FULL := "server is full"


## Point the server at a generated galaxy and prepare to collect orders.
##
## `active_slots` is the set of empire slots the server waits on. It is recomputed from
## the live connection table as peers come and go, but seeding it matters: a slot that
## never connects must not block turn 1 forever.
func begin(new_galaxy: GalaxyState, active_slots: PackedInt32Array) -> bool:
	if new_galaxy == null:
		push_error("[TurnSyncServer] begin: no galaxy")
		return false
	galaxy = new_galaxy
	resolve_autoloads()
	if defs != null and not galaxy.rebind_definitions(defs):
		push_error("[TurnSyncServer] galaxy references unknown definitions")
	_rng = RandomNumberGenerator.new()
	_rng.seed = galaxy.seed_value
	if _rng.seed == 0:
		_rng.randomize()
	current_turn = galaxy.turn
	_active_slots = active_slots.duplicate()
	_pending.clear()
	_initialised = true
	return true


## The slots the server is currently waiting on.
func active_slots() -> PackedInt32Array:
	return _active_slots


## How many active slots have submitted for the live turn.
func submitted_count() -> int:
	return _pending.size()


## Stage a slot's orders directly, bypassing the transport.
##
## Live traffic arrives through `rpc_submit_orders`, which additionally validates the
## sender and the turn. This is the seam for a test that needs a server with known
## pending orders and no socket behind it. Returns false for a slot the server is not
## waiting on.
func stage_orders(slot_id: int, orders: Array) -> bool:
	if not _active_slots.has(slot_id):
		return false
	_pending[slot_id] = orders.duplicate(true)
	return true


## Whether every active slot has handed in its orders.
func all_submitted() -> bool:
	if _active_slots.is_empty():
		return false
	for s in _active_slots:
		if not _pending.has(s):
			return false
	return true


## Adopt a newly connected slot so it is included in the next turn's wait.
func add_active_slot(slot_id: int) -> void:
	if slot_id < 0 or _active_slots.has(slot_id):
		return
	_active_slots.append(slot_id)
	_active_slots.sort()


## Drop a departed slot.
##
## Its queued orders are discarded with it: resolving a turn containing orders from an
## empire that has left the game would let a disconnect change the simulation's outcome.
func remove_active_slot(slot_id: int) -> void:
	_active_slots.erase(slot_id)
	_pending.erase(slot_id)


## Look up the submitting peer's slot. Overrides the client's stub, which is what makes
## `_accept_orders` authoritative about who is filing.
func slot_of_peer(peer_id: int) -> int:
	if net == null:
		return -1
	return net.slot_of(peer_id)


## Resolve the turn if every slot has submitted, and broadcast the result.
##
## Returns the broadcast payload, or an empty Dictionary when the turn is not ready yet
## (which is the normal case on the first of several submissions).
func resolve_if_ready() -> Dictionary:
	if galaxy == null or not all_submitted():
		return {}
	var resolving_turn := galaxy.turn

	# Deterministic assembly: orders are applied in *slot* order, never arrival order.
	# Two players submitting in the opposite order across two runs must produce the
	# same galaxy, or a replay of a networked game would not reproduce its own hash.
	var orders: Array = []
	for s in _active_slots:
		var raw: Array = _pending.get(s, []) as Array
		for entry: Variant in raw:
			var order := Order.from_dict(entry as Dictionary)
			if order != null:
				orders.append(order)

	var report := TurnResolver.resolve_turn(galaxy, orders, defs, db, _rng, 0)
	var payload := build_payload(report)
	_pending.clear()
	broadcast(payload)
	return payload


## The wire form of a resolved turn: the full state, its hash, and the report.
##
## A full snapshot rather than a diff. With turn counts in the tens a full state is a few
## tens of kilobytes over a reliable channel, which is cheaper than the correctness risk
## of a diff that can drift; `full_state_or_diff` is named for that reason.
func build_payload(report: Dictionary) -> Dictionary:
	return {
		"turn": galaxy.turn,
		"state": galaxy.to_dict(),
		"state_hash": str(galaxy.state_hash()),
		"report": report,
	}


## Send a payload to every connected client.
##
## A node outside the tree has no multiplayer interface, and calling an RPC on one logs
## `Condition "!is_inside_tree()" is true` rather than failing quietly. Resolution still
## advances the galaxy and still reports locally; only the wire hop is skipped, so a server
## driven headlessly (or before it is added to the tree) resolves turns without spewing
## errors into an otherwise clean log.
func broadcast(payload: Dictionary) -> void:
	current_turn = galaxy.turn
	turn_broadcast.emit(galaxy.turn, str(payload.get("state_hash", "")))
	if not is_inside_tree():
		return
	rpc_broadcast_turn_resolution.rpc(
		galaxy.turn, str(payload.get("state_hash", "")), payload)

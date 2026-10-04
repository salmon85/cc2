extends TurnSyncPeer
class_name TurnSyncClient
## Client half of the turn-synchronisation protocol.
##
## Stages orders locally, ships them when the player presses End Turn, then waits for the
## server's resolution. The client never calls `TurnResolver` itself -- it has no way to
## disagree with the server about what happened, only a hash to check it against.
##
## Extends `TurnSyncPeer` for the shared `@rpc` surface; see that file for why both roles
## must live in one script.

## Emitted when the client submits and enters the waiting state.
signal awaiting_resolution(turn_num: int)

## Text shown while waiting for the other players.
const WAITING_TEXT := "Awaiting other players..."

## The `NetworkManager` this client dials through.
var net: NetworkManager = null

## The GUI bound to this client, once the welcome has been handled.
##
## Held so a resolution arriving later can refresh the panels without `app.gd` having to
## re-walk the tree on every turn. Null in a headless client.
var game_client: GameClient = null

## True between submitting and receiving the server's resolution. The UI locks the order
## controls while this holds, which is what stops a player from staging orders for a turn
## the server has already closed.
var awaiting: bool = false

## Orders staged locally for the coming turn, in submission order.
var staged: Array[Order] = []


## Prepare the client with the galaxy the server sent at connect time.
func begin(new_galaxy: GalaxyState, assigned_slot: int) -> bool:
	if new_galaxy == null:
		push_error("[TurnSyncClient] begin: no galaxy")
		return false
	galaxy = new_galaxy
	slot = assigned_slot
	resolve_autoloads()
	current_turn = galaxy.turn
	staged.clear()
	awaiting = false
	_initialised = true
	return true


## Stage an order locally. Rejected while awaiting, mirroring the server's own rule that
## a turn is closed once submitted.
func stage_order(order: Order) -> bool:
	if order == null or awaiting:
		return false
	staged.append(order)
	return true


## Whether any orders are staged for the coming turn.
func has_staged_orders() -> bool:
	return not staged.is_empty()


## Ship the staged orders and enter the waiting state.
##
## Returns false when the client is already waiting, which is the guard that makes a
## double-click on End Turn harmless rather than a protocol violation.
func submit_turn() -> bool:
	if awaiting or galaxy == null:
		return false
	# A client detached from the tree has no multiplayer interface, and `rpc_id` on one
	# fails with "Condition \"!is_inside_tree()\" is true". Refuse rather than claim a
	# turn was submitted: entering the waiting state with the packet undelivered would
	# strand the player until the next resolution arrived.
	if not is_inside_tree():
		return false
	var wire: Array = []
	for o in staged:
		wire.append(o.to_dict())
	# Clear *before* sending: if the send fails the turn is still closed locally, and
	# silently re-queueing would replay orders the server may already have accepted.
	staged.clear()
	awaiting = true
	var target_turn := galaxy.turn
	rpc_submit_orders.rpc_id(1, target_turn, wire)
	awaiting_resolution.emit(target_turn)
	return true


## Status text for the top bar.
func status_text() -> String:
	if awaiting:
		return WAITING_TEXT
	if galaxy == null:
		return "not connected"
	return "your turn"


## Apply an incoming resolution: verify the snapshot, adopt it, and unlock.
##
## Returns true when the client is now in sync and free to act.
func receive_resolution(_turn_num: int, _server_hash: String, payload: Dictionary) -> bool:
	var applied := apply_snapshot(payload)
	if applied < 0:
		# The snapshot did not match the hash the server published. Leave `awaiting`
		# set: a client that unlocked on a desynced state would let the player stage
		# orders against a galaxy the server does not have, which is unrecoverable.
		return false
	awaiting = false
	turn_resolved.emit(current_turn, payload.get("report", {}) as Dictionary)
	return true


## The RPC entry point. Inherited signature, overridden body.
func apply_broadcast(turn_num: int, state_hash: String, payload: Dictionary) -> void:
	receive_resolution(turn_num, state_hash, payload)


## The player's own orders staged for the coming turn, for the order queue UI.
func staged_orders() -> Array[Order]:
	return staged.duplicate()


## The RPC entry point for the handshake. Inherited signature, overridden body.
##
## `apply_snapshot` in the base class has already rebuilt `galaxy` and verified the hash
## by the time this runs, so the only work left is recording the empire and telling the
## session it may start. `awaiting` is explicitly cleared: a client that joined mid-turn
## must be free to act on the state it was just handed.
func apply_welcome(assigned_slot: int, payload: Dictionary) -> void:
	slot = assigned_slot
	awaiting = false
	_initialised = true
	welcomed.emit(assigned_slot, payload)

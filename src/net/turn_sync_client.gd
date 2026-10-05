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

## Whether this client has sent a ready flag, so the interface can draw the button
## without asking the server every frame.
var _ready_flagged: bool = false

## The server's authoritative readiness tally. Authoritative because a client counting
## its own flags would disagree with every other client about who is ready.
var ready_count: int = 0
var total_slots: int = 0

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
	# The flag was raised *for the turn that just resolved*. Carrying it forward would
	# leave the READY button sitting in its red, pressed-looking state during a turn
	# nobody has committed to -- and, worse, the button would read "already ready" to a
	# player who had done nothing, which is the one state the lobby cannot recover from
	# on its own. The server clears the same flag in its own bookkeeping; this is the
	# local mirror of it, and both are needed because the button draws from here.
	_ready_flagged = false
	turn_resolved.emit(current_turn, payload.get("report", {}) as Dictionary)
	return true


## The RPC entry point. Inherited signature, overridden body.
func apply_broadcast(turn_num: int, state_hash: String, payload: Dictionary) -> void:
	receive_resolution(turn_num, state_hash, payload)


## The player's own orders staged for the coming turn, for the order queue UI.
func staged_orders() -> Array[Order]:
	return staged.duplicate()


## Tell the server this player is ready to begin, and submit anything they staged.
##
## Returns false when the client is not in the tree or has no seat yet -- both of which
## mean the packet would go nowhere, and reporting success for a send that never left
## would leave the lobby waiting on a ready flag nobody can see.
##
## Raising the flag submits the staged orders with it. There is no separate commit control
## any more: the END TURN button was removed and READY took its place, so a player who
## staged orders and pressed READY meant "apply these". Sending only the flag left the
## server holding an empty submission for that slot, which is indistinguishable from a
## player who readied up with nothing to do -- their orders were silently dropped.
func set_ready(is_ready: bool = true) -> bool:
	if not is_inside_tree() or slot < 0:
		return false
	if not is_ready:
		rpc_set_ready.rpc_id(1, false)
		_ready_flagged = false
		return true
	if awaiting or galaxy == null:
		return false
	# Submit first: the resolution can arrive on the very next packet, and a flag raised
	# ahead of an empty submission would let the server resolve this slot as a no-op.
	var wire: Array = []
	for o in staged:
		wire.append(o.to_dict())
	staged.clear()
	awaiting = true
	awaiting_resolution.emit(galaxy.turn)
	rpc_submit_orders.rpc_id(1, galaxy.turn, wire)
	rpc_set_ready.rpc_id(1, true)
	_ready_flagged = true
	return true


## Adopt a lobby readiness broadcast.
func apply_ready_count(count: int, total: int) -> void:
	ready_count = maxi(0, count)
	total_slots = maxi(0, total)
	lobby_ready_changed.emit(ready_count, total_slots)


## Whether this client has sent a ready flag the server has not retracted.
##
## Local rather than authoritative: it records what *we* asked for, which is what the
## button needs to draw itself. The server's own view can lag by a packet, and a button
## that flickers between two states waiting for the round trip is worse than one that
## shows what this client last did.
func is_ready_flagged() -> bool:
	return _ready_flagged


## Emitted by the server's start announcement. Carries the authoritative state.
func apply_match_start(payload: Dictionary) -> void:
	var state_hash := str(payload.get("state_hash", ""))
	var applied := apply_snapshot({"state": payload.get("state", {}), "state_hash": state_hash})
	if applied < 0:
		return
	match_started.emit(payload)


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

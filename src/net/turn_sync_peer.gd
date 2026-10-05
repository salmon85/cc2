extends Node
class_name TurnSyncPeer
## Shared RPC surface for the turn-synchronisation protocol.
##
## ## Why this file exists separately from the server and client
##
## Godot builds a *node checksum* from the set of `@rpc` methods on a node, and requires
## every peer that addresses the same node path to agree on that set. Two scripts carrying
## different RPC methods -- a `TurnSyncServer` and a `TurnSyncClient`, as the obvious
## reading of the protocol suggests -- fail with:
##
##     The rpc node checksum failed. Make sure to have the same methods on both nodes.
##
## and every RPC across that path is then *silently* dropped. The failure is not a
## diagnostic you can catch; the packet just never arrives.
##
## So both roles use this one script, which declares the *union* of the protocol's methods.
## A role that must not service a given method checks `is_server()` and drops it. Keeping
## the surface uniform is what lets one process host a real server and real clients
## simultaneously (see `tests/test_enet_sync.gd`), and it is also simply less code.
##
## The authority check is not redundant with the local guard. `@rpc("authority", ...)`
## makes the *engine* reject a client forging `rpc_broadcast_turn_resolution`; the guard
## makes the node itself refuse work it is not entitled to perform, so a future refactor
## that routes a call through `call()` instead of `.rpc()` still cannot cheat.

## Emitted on the client when the server's turn resolution arrives and verifies.
signal turn_resolved(turn_num: int, report: Dictionary)

## Emitted on the client if the replicated state does not match the server's hash. A
## desync is fatal to a competitive game, so it is surfaced rather than swallowed.
signal desync_detected(turn_num: int, local_hash: int, server_hash: int)

## Emitted on the server each time a peer's orders land, for logging.
signal orders_received(slot: int, turn_num: int, count: int)

## Emitted on the client once the server has handed over a slot and the starting state.
signal welcomed(assigned_slot: int, payload: Dictionary)

## Emitted on the server when a peer is told the game is full and dropped.
signal peer_refused(peer_id: int, reason: String)

## Emitted when the server reports a new ready count for the lobby.
signal lobby_ready_changed(ready_count: int, total_slots: int)

## Emitted on the client when the server announces the match has begun.
signal match_started(payload: Dictionary)

## Emitted on the server when a peer reports readiness. The lobby consumes this.
signal ready_changed(peer_id: int, is_ready: bool)

## The empire slot this peer was assigned, or -1 before the handshake completes.
var slot: int = -1

## The stardate this peer believes it is on. -1 until the first state arrives.
var current_turn: int = -1

## Authoritative state replica. On the server this is the live state; on a client it is
## rebuilt from each broadcast. Clients never simulate -- that is the whole point of an
## authoritative server.
var galaxy: GalaxyState = null

## Definition registry and tuning constants, needed to rebuild a galaxy from the wire.
var defs: Node = null
var db: Node = null

## Server-only: the turn currently collecting orders, and what has arrived so far.
## Keyed by faction slot so a slot's orders are unambiguous even when they arrive out of
## order. A slot is present in this map only once it has actually submitted -- an empty
## order list is a legitimate submission and is stored as an empty Array, which is why
## "no orders" can never be confused with "has not submitted yet".
var _pending: Dictionary = {}

## Server-only: factions that must submit before the turn can resolve. Derived from the
## assigned slots minus departed peers, so a disconnect cannot deadlock the turn.
var _active_slots: PackedInt32Array = PackedInt32Array()

## Server-only: the resolver's RNG. Kept on the peer so a snapshot carries its position.
var _rng: RandomNumberGenerator = null

## Set once the first state has been applied; guards against a duplicate handshake.
var _initialised: bool = false


## True when this peer is the authority (the hosting server).
func is_server() -> bool:
	return multiplayer.multiplayer_peer is ENetMultiplayerPeer \
		and (multiplayer.multiplayer_peer as ENetMultiplayerPeer).get_connection_status() \
			== MultiplayerPeer.CONNECTION_CONNECTED \
		and _is_authority()


## The engine's own notion of authority for this peer's branch. A dedicated server is
## always peer 1; a client never is. This is the same test `@rpc("authority")` uses, so
## the node's guards and the engine's enforcement can never disagree.
func _is_authority() -> bool:
	return multiplayer.get_unique_id() == 1


# --- Protocol: client -> server -------------------------------------------------

# --- Protocol: server -> a single joining client --------------------------------

## Server -> one client: your empire, and the game as it currently stands.
##
## This is the handshake. Without it a joining client has no way to learn which empire it
## was given (the slot is chosen by the server, not requested by the player) and no way to
## obtain the galaxy -- generating one locally would produce a *different* game, which is
## the entire failure mode an authoritative server exists to prevent.
##
## `full_state_or_diff` has the same meaning as in `rpc_broadcast_turn_resolution`, and
## the `state_hash` is a decimal String for the same reason: JSON has no 64-bit integer.
@rpc("authority", "call_remote", "reliable")
func rpc_welcome(
	assigned_slot: int, state_hash: String, full_state_or_diff: Dictionary
) -> void:
	if _is_authority():
		return
	var payload := full_state_or_diff.duplicate(true)
	payload["slot"] = assigned_slot
	var applied := apply_snapshot(payload)
	if applied < 0:
		# The opening state did not verify, so the client has nothing trustworthy to
		# play on. Leave the handshake unfinished; `app.gd` reports this and exits
		# rather than starting a game against a galaxy the server does not hold.
		push_error("[TurnSyncPeer] welcome snapshot failed parity check")
		return
	# Hand off to the role hook, exactly as a resolution does, so the client can mark
	# itself initialised before the session starts binding panels to it.
	apply_welcome(assigned_slot, payload)


## Role hook invoked once a welcome snapshot has been applied and verified.
##
## The base records the slot and reports; the client subclass marks itself ready.
func apply_welcome(assigned_slot: int, payload: Dictionary) -> void:
	slot = assigned_slot
	welcomed.emit(assigned_slot, payload)


## Server -> one client: the game is full. The client should report and exit.
@rpc("authority", "call_remote", "reliable")
func rpc_refuse(reason: String) -> void:
	if _is_authority():
		return
	push_error("[TurnSyncPeer] refused by server: %s" % reason)


## Client -> server: mark yourself ready (or un-ready) in the lobby.
##
## Sent by the client when the player confirms they are ready to play. The server is the
## only party that decides whether the match starts: a client cannot start one, and the
## RPC is refused from a peer the server has not seated.
@rpc("any_peer", "call_remote", "reliable")
func rpc_set_ready(is_ready: bool) -> void:
	if not _is_authority():
		return
	# The sender, not the payload, decides whose readiness this is.
	var sender := multiplayer.get_remote_sender_id()
	if slot_of_peer(sender) < 0:
		return
	ready_changed.emit(sender, is_ready)


## Role hook for a readiness report. The base reports it; the server applies it to its
## lobby.
func apply_ready(_peer_id: int, _is_ready: bool) -> void:
	pass


## Server -> clients: how many players have readied.
##
## The count is authoritative rather than each client counting its own optimism: a flag
## can be in flight, or refused, and a button that says "Ready 2/2" to one player and
## "Ready 1/2" to another at the same instant makes the lobby look broken.
@rpc("authority", "call_remote", "reliable")
func rpc_lobby_ready_count(ready_count: int, total_slots: int) -> void:
	if _is_authority():
		return
	apply_ready_count(ready_count, total_slots)


## Role hook for a readiness broadcast. The base class only reports it.
func apply_ready_count(ready_count: int, total_slots: int) -> void:
	lobby_ready_changed.emit(ready_count, total_slots)


## Server -> clients: the match is starting. Carries the same shape as a welcome, so a
## client's first state arrives by the same code path whether it joined early or the
## lobby filled later.
@rpc("authority", "call_remote", "reliable")
func rpc_match_started(state_hash: String, full_state_or_diff: Dictionary) -> void:
	if _is_authority():
		return
	apply_match_start({"state_hash": state_hash, "state": full_state_or_diff})


## Role hook for the match-start announcement. The base reports it; the client adopts
## the authoritative state.
func apply_match_start(_payload: Dictionary) -> void:
	match_started.emit(_payload)


## Client -> server: hand in this slot's orders for `turn_num`.
##
## `orders` is an Array of `Order.to_dict()` payloads. An empty Array is a valid
## submission meaning "I submit no orders this turn" -- that is what lets the server
## distinguish a player who did nothing from a player who has not yet finished.
@rpc("any_peer", "call_remote", "reliable")
func rpc_submit_orders(turn_num: int, orders: Array) -> void:
	if not _is_authority():
		# The engine already blocks this; the guard documents that a client has no
		# business submitting on the authority's behalf.
		return
	if not _accept_orders(turn_num, orders):
		return
	orders_received.emit(slot, turn_num, orders.size())


## Server-only half of the client -> server path. Split out so the logic is testable
## without a live peer, and so `rpc_submit_orders` stays a thin protocol shell.
func _accept_orders(turn_num: int, orders: Array) -> bool:
	if galaxy == null:
		return false
	if turn_num != galaxy.turn:
		# Orders for a turn that is not the live one are stale or malicious. Dropping
		# them is what keeps a late packet from corrupting a turn already resolved.
		return false
	# The submitting peer's own slot is authoritative, not anything in the payload: a
	# client must not be able to file orders for another empire.
	var submitting := multiplayer.get_remote_sender_id()
	var owner_slot := slot_of_peer(submitting)
	if owner_slot < 0 or not _active_slots.has(owner_slot):
		return false
	_pending[owner_slot] = orders.duplicate(true)
	return true


## Map a connected peer id to the empire slot it was assigned. Overridden by the server
## implementation; the client has no table of its own and returns -1.
func slot_of_peer(_peer_id: int) -> int:
	return -1


# --- Protocol: server -> clients ----------------------------------------------

## Server -> clients: the resolved turn, with the full authoritative state.
##
## `state_hash` is a decimal string of `GalaxyState.state_hash()`. It is a *string* on
## the wire because the value is a 64-bit hash and JSON has no integer type wide enough
## to round-trip it; a bare number would silently lose precision and every client would
## report a false desync.
@rpc("authority", "call_remote", "reliable")
func rpc_broadcast_turn_resolution(
	turn_num: int, state_hash: String, full_state_or_diff: Dictionary
) -> void:
	if _is_authority():
		return
	# Hand off to the role hook so `TurnSyncClient` can unlock its waiting state.
	apply_broadcast(turn_num, state_hash, full_state_or_diff)


## Role hook invoked when a resolution arrives. The base class only reports it, so a bare
## `TurnSyncPeer` can be dropped onto a node without silently adopting state; the client
## subclass overrides this to verify the hash and unlock.
func apply_broadcast(turn_num: int, state_hash: String, payload: Dictionary) -> void:
	var report: Dictionary = payload.get("report", {})
	turn_resolved.emit(turn_num, report)


## Apply a server snapshot locally. Returns the resulting state hash, or -1 when the
## payload was unusable. Split from `rpc_broadcast_turn_resolution` so the same code
## serves the RPC and the test's direct calls.
func apply_snapshot(payload: Dictionary) -> int:
	var raw: Dictionary = payload.get("state", {})
	if raw.is_empty():
		return -1
	var expected := str(payload.get("state_hash", ""))

	# Deserialise into a *scratch* object first, so the hash can be checked before
	# anything is committed. Adopting the payload and then discovering it desyncs would
	# leave the client holding the server's bad state -- exactly the split-brain the hash
	# exists to prevent.
	var incoming := GalaxyState.new()
	if not incoming.from_dict(raw):
		return -1
	# The definitions are not serialised (they ship with the game and are re-resolved
	# at load time), so a client replica must rebind them before it can simulate the
	# colony or research stage against the mirrored state.
	if not incoming.rebind_definitions(defs):
		push_error("[TurnSyncPeer] snapshot references unknown definitions")

	var actual := str(incoming.state_hash())
	if not expected.is_empty() and expected != actual:
		desync_detected.emit(current_turn, int(actual), int(expected))
		return -1

	# Mutate the galaxy *in place* rather than replacing the reference.
	#
	# Everything already bound to this galaxy -- the SessionController, and through it
	# every panel, the map and the fleet views -- holds this exact object. Handing them a
	# new one silently leaves them reading the previous turn forever: the stardate does
	# not move and ships never appear to move, while the sync peer's own copy looks
	# perfectly correct. Deserialising into the live object is what makes those holders
	# see the new state, and `from_dict()` already does exactly that.
	if galaxy == null:
		galaxy = incoming
	else:
		if not galaxy.from_dict(raw):
			# Should be unreachable: `raw` was just accepted into `incoming`. Treated as a
			# failure rather than a partial write, so the two never disagree.
			push_error("[TurnSyncPeer] snapshot failed to apply to the live galaxy")
			return -1
		if defs != null and not galaxy.rebind_definitions(defs):
			pass  # already reported above; a partially known registry is still playable

	current_turn = galaxy.turn
	return int(actual)


# --- Shared helpers ------------------------------------------------------------

## Resolve the autoloads from the running tree, if they are not already bound.
func resolve_autoloads() -> void:
	if defs != null and db != null:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	if defs == null:
		defs = tree.root.get_node_or_null(NodePath("Defs"))
	if db == null:
		db = tree.root.get_node_or_null(NodePath("GameDB"))

extends Node
class_name NetworkManager
## ENet transport: hosts a game or joins one, and maps connected peers to empire slots.
##
## ## Why this does not simply assign `multiplayer_peer` to the scene root
##
## The obvious implementation is `multiplayer.multiplayer_peer = peer`. That works for a
## client and cannot work for the integration test, which needs a real server *and* two
## real clients alive at once in a single process. Godot resolves a node's multiplayer
## interface by walking up from the node to the nearest ancestor that has one set, so the
## way to run three independent stacks in one tree is to give each a branch root:
##
##     /root/Net/Server   -> server MultiplayerAPI
##     /root/Net/Client0  -> client MultiplayerAPI
##     /root/Net/Client1  -> client MultiplayerAPI
##
## `SceneTree.set_multiplayer(api, path)` installs one. The branch must be a node *below*
## root -- assigning to `root` itself collides with the SceneTree's own default interface.
## A normal single-process client uses exactly the same code with one branch; nothing here
## is test-only scaffolding.

## Emitted once the local peer is listening (server) or has connected (client).
signal connection_succeeded

## Emitted when a join attempt cannot reach a listening server.
signal connection_failed(reason: String)

## Emitted when a remote peer joins and is assigned a slot. Server-side only.
signal peer_joined(peer_id: int, slot: int)

## Emitted when a remote peer leaves. `slot` is -1 when the peer had no slot.
signal peer_left(peer_id: int, slot: int)

const LOOPBACK := "127.0.0.1"

## Name the RPC endpoint carries in every branch.
##
## ## Why the name is not arbitrary
##
## Godot addresses an RPC target by a path that is *sent* relative to the branch root but
## *resolved* relative to the tree root. The two only line up when the node sits at the
## same depth with the same name on every peer. Give the server and client different
## names and nothing is ever delivered; leave both unnamed and Godot's `@Node@7`
## placeholders differ per instance, which fails the same way -- with no diagnostic beyond
## "Failed to get path from RPC". Both directions of the protocol were silently dead until
## this was pinned down.
##
## So every peer names its sync endpoint identically. Use `add_sync_endpoint()` rather
## than adding the node by hand.
const SYNC_NODE_NAME := "TurnSync"

## Peer id -> empire slot. Server-side only; a client has exactly one entry (its own).
var _slots: Dictionary = {}

## Empire slot -> peer id, the inverse of `_slots`.
var _owners: Dictionary = {}

## The live transport, or null when not hosting/joined.
var peer: ENetMultiplayerPeer = null

## The branch interface this manager installed, or null.
var api: MultiplayerAPI = null

## Number of empire slots on a host. Ignored by a client.
var max_players: int = CC2CLI.DEFAULT_SLOTS

## True when this instance is hosting.
var is_host: bool = false

## Human-readable state for the status bar and the log.
var status: String = "idle"

## Reserve an OS-assigned port.
##
## `ENetMultiplayerPeer.create_server(0)` binds an ephemeral port, but this engine build
## exposes no way to read back which port it chose, so a client could not be told what to
## dial. `TCPServer` does report the port it was given, so the test (and any launcher
## that wants to print a connect string) reserves one this way, releases it, and hands
## the number to ENet.
static func reserve_ephemeral_port() -> int:
	var probe := TCPServer.new()
	if probe.listen(0, LOOPBACK) != OK:
		probe.stop()
		return CC2CLI.DEFAULT_NET_PORT
	var port := probe.get_local_port()
	probe.stop()
	return port


## Start listening for clients.
##
## `max_players` is the number of *remote* empire slots; the server itself does not take
## one. Returns OK on success, or the ENet error code so the caller can report why.
func host_game(port: int, in_max_players: int) -> Error:
	if is_host:
		return ERR_ALREADY_IN_USE
	max_players = maxi(1, in_max_players)
	var listener := ENetMultiplayerPeer.new()
	# max_clients excludes the server peer, so this is exactly the slot count.
	var err := listener.create_server(port, max_players)
	if err != OK:
		status = "host failed: %s" % error_string(err)
		return err

	peer = listener
	is_host = true
	_install_branch(listener)
	_connect_signals()

	# Peer 1 is the server. Reserve nothing: the server is the authority, not a player.
	status = "hosting on port %d (%d slots)" % [port, max_players]
	connection_succeeded.emit()
	return OK


## Dial a server.
##
## Returns OK when the underlying peer was created; the *connection* completes
## asynchronously, so a caller that needs to know should await `connection_succeeded`
## and handle `connection_failed`. Returning OK here does not mean the join worked.
func join_game(address: String, port: int) -> Error:
	if is_host:
		return ERR_ALREADY_IN_USE
	var target := address.strip_edges()
	if target.is_empty():
		target = LOOPBACK
	var dialer := ENetMultiplayerPeer.new()
	var err := dialer.create_client(target, port)
	if err != OK:
		status = "join failed: %s" % error_string(err)
		return err

	peer = dialer
	is_host = false
	_install_branch(dialer)
	_connect_signals()
	status = "joining %s:%d" % [target, port]
	return OK


## Close the connection and release the branch. Idempotent.
func close() -> void:
	if peer != null:
		peer.close()
	_disconnect_signals()
	peer = null
	api = null
	is_host = false
	_slots.clear()
	_owners.clear()
	status = "closed"


## Close the connection and free this node and everything under it.
##
## `close()` deliberately leaves the node standing -- a caller may still want to read
## `status`. This frees the whole subtree, so a finished scenario cannot leave a
## MultiplayerAPI wired to a closed peer or hold a socket open for the next one.
func dispose() -> void:
	close()
	# `get_parent()` is only legal inside the tree; a manager that was never added (or
	# was already detached) has to skip straight to the free.
	if is_inside_tree():
		get_parent().remove_child(self)
	# Deferred, not immediate: the ENet driver and the RPC path cache can still be
	# holding this subtree at the moment the caller decides to shut down, and `free()`
	# aborts with "Object is locked and can't be freed". `queue_free()` releases at the
	# end of the frame, by which time both have let go.
	queue_free()


## Our own peer id, or 0 when there is no peer.
func unique_id() -> int:
	if peer == null:
		return 0
	return peer.get_unique_id()


## The empire slot assigned to `peer_id`, or -1.
func slot_of(peer_id: int) -> int:
	return int(_slots.get(peer_id, -1))


## The peer holding `slot`, or 0 when the slot is empty.
func peer_of(slot: int) -> int:
	return int(_owners.get(slot, 0))


## Slots currently held, in ascending order.
func occupied_slots() -> PackedInt32Array:
	var out := PackedInt32Array()
	var keys := _owners.keys()
	keys.sort()
	for k: int in keys:
		out.append(k)
	return out


## Lowest unoccupied slot, or -1 when the game is full.
func free_slot() -> int:
	for candidate in maxi(1, max_players):
		if not _owners.has(candidate):
			return candidate
	return -1


## How many slots are still open.
func free_slot_count() -> int:
	var taken := 0
	for s in _owners:
		taken += 1
	return maxi(0, maxi(1, max_players) - taken)


## Claim `slot` for `peer_id`. Server-side only. Returns false when the slot is taken.
func assign_slot(peer_id: int, slot: int) -> bool:
	if _owners.has(slot):
		return false
	if peer_id in _slots:
		return false
	_owners[slot] = peer_id
	_slots[peer_id] = slot
	return true


## Create the turn-sync endpoint for this branch, named so it matches every other peer.
##
## `script` is `TurnSyncServer` on the host and `TurnSyncClient` on a client; it must be
## the same script class on both sides (see `TurnSyncPeer`) or the RPC node checksum will
## not match. Returns the node, already added.
func add_sync_endpoint(script: Script) -> Node:
	var endpoint := Node.new()
	endpoint.name = SYNC_NODE_NAME
	endpoint.set_script(script)
	add_child(endpoint)
	return endpoint


## Release `peer_id`'s slot, if it holds one. Used on disconnect and by tests.
func release_peer(peer_id: int) -> void:
	var slot := slot_of(peer_id)
	_slots.erase(peer_id)
	if slot >= 0:
		_owners.erase(slot)


# --- Internals ---------------------------------------------------------------

## Install `new_peer` as the multiplayer interface for this node's whole subtree.
##
## ## Why the manager is its own branch root
##
## `SceneTree.set_multiplayer(api, path)` scopes an interface to `path` and everything
## beneath it, and a node resolves its multiplayer by walking *up* to the nearest ancestor
## that has one. Two arrangements follow from that, and the wrong one is subtle:
##
##   * A holder node that is a **child** of the manager scopes only the manager's
##     descendants *below the holder*. The manager itself, and any `TurnSyncPeer` hung
##     directly off it, still fall through to the tree's default interface and see peer
##     id 1 -- so a client resolved as the *server* and was refused with "RPC on yourself
##     is not allowed by selected mode".
##   * Re-parenting the manager into a fresh holder fixes that but renames the subtree
##     (`@Node@8` becomes `_Node_7/@Node@8`) and invalidates the RPC path cache, so every
##     later RPC fails with "Failed to get path from RPC".
##
## The manager is already a node below the tree root, so it can simply *be* the branch
## root: no holder, no re-parenting, stable names, and the manager plus everything it owns
## resolve to exactly one interface. Three managers in one tree therefore host three
## genuinely independent stacks, which is what lets the integration test run a real server
## and two real clients in a single process.
func _install_branch(new_peer: ENetMultiplayerPeer) -> void:
	var branch := MultiplayerAPI.create_default_interface()
	branch.multiplayer_peer = new_peer
	api = branch

	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or not is_inside_tree():
		# No tree, or the manager has not been added yet. The interface is still usable
		# for connection-status checks; nothing will be routed until the manager is in
		# the tree, which is why every caller must `add_child()` before hosting.
		return
	tree.set_multiplayer(branch, get_path())


## Wire the connection signals.
##
## `connected_to_server`, `connection_failed` and `server_disconnected` are emitted by
## the *MultiplayerAPI*, not by the peer -- reaching for them on `ENetMultiplayerPeer`
## fails at runtime with "Invalid access to property or key". Peer membership changes are
## on both, and the API is used for those too so there is exactly one source per signal.
func _connect_signals() -> void:
	if api == null:
		return
	api.connected_to_server.connect(_on_connected)
	api.connection_failed.connect(_on_failed)
	api.server_disconnected.connect(_on_server_gone)
	api.peer_connected.connect(_on_peer_connected)
	api.peer_disconnected.connect(_on_peer_disconnected)


## Tear the connections down. `close()` sets `api = null` immediately afterwards, so this
## must run first.
func _disconnect_signals() -> void:
	if api == null:
		return
	if api.connected_to_server.is_connected(_on_connected):
		api.connected_to_server.disconnect(_on_connected)
	if api.connection_failed.is_connected(_on_failed):
		api.connection_failed.disconnect(_on_failed)
	if api.server_disconnected.is_connected(_on_server_gone):
		api.server_disconnected.disconnect(_on_server_gone)
	if api.peer_connected.is_connected(_on_peer_connected):
		api.peer_connected.disconnect(_on_peer_connected)
	if api.peer_disconnected.is_connected(_on_peer_disconnected):
		api.peer_disconnected.disconnect(_on_peer_disconnected)


func _on_connected() -> void:
	status = "connected to %s" % LOOPBACK
	connection_succeeded.emit()


func _on_failed() -> void:
	status = "connection failed"
	connection_failed.emit("could not reach the server")


func _on_server_gone() -> void:
	status = "server disconnected"
	peer_left.emit(0, -1)


func _on_peer_connected(peer_id: int) -> void:
	if not is_host:
		return
	var slot := free_slot()
	if slot < 0:
		# Full. Refusing here rather than assigning an overlapping slot is what stops
		# two empires sharing one faction id and corrupting each other's orders.
		push_error("[NetworkManager] no free slot for peer %d" % peer_id)
		return
	if assign_slot(peer_id, slot):
		peer_joined.emit(peer_id, slot)


func _on_peer_disconnected(peer_id: int) -> void:
	var slot := slot_of(peer_id)
	release_peer(peer_id)
	peer_left.emit(peer_id, slot)

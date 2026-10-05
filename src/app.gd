extends Node
## Bootstrap node. Parses the command line and routes into the correct run mode.
##
## The routing decision itself lives in `CC2CLI` as a pure function so it can be exercised
## headlessly without instantiating a scene tree.

const CLIENT_SCENE := preload("res://scenes/client/GameClient.tscn")

## Resolved options from the command line.
var options: CC2CLI.Options = null

## Live session node, or null in setup-menu mode.
var session: Node = null

## Transport the session uses to reach the authority.
var transport: PeerTransport = null

## ENet stack, when running as a dedicated server or a network client.
var net: NetworkManager = null

## Authoritative turn-sync endpoint. Present on the server only.
var turn_sync: TurnSyncServer = null

## Galaxy the server owns. Kept so a headless run has one authority to hand out.
var server_galaxy: GalaxyState = null

## Empire slots a dedicated server waits on, derived from `--slots`.
var server_slots: PackedInt32Array = PackedInt32Array()

## Slot/ready/match-start state for a dedicated server. Null in client and local modes.
var lobby: SessionLobby = null

## The mounted game GUI, once one exists. Kept so a session-level event -- a peer
## leaving, say -- can reach the player's event log rather than only the terminal.
var game_client: GameClient = null


func _ready() -> void:
	options = CC2CLI.parse_os()

	print("[cc2] launch: %s" % options.describe())
	for warning in options.warnings:
		print("[cc2] warning: %s" % warning)

	if not _route(options):
		push_error("[cc2] failed to start: %s" % options.describe())
		get_tree().quit(1)


## Instantiate the session for `opts`. Returns false when the mode cannot be served.
func _route(opts: CC2CLI.Options) -> bool:
	match opts.mode:
		CC2CLI.Mode.DEDICATED_SERVER:
			session = _make_session("dedicated-server")
			if not _start_dedicated_server(opts):
				return false
		CC2CLI.Mode.SINGLE_PLAYER:
			# Single player is a client bound to an in-process authority: the same
			# turn-resolution code runs, there is no separate offline path.
			session = _make_session("single-player")
			_attach_client(opts)
		CC2CLI.Mode.CLIENT:
			session = _make_session("network-client")
			_attach_client(opts)
		CC2CLI.Mode.SETUP_MENU:
			print("[cc2] setup menu requested; no headless session started")
			return true
		_:
			push_error("[cc2] unknown run mode %d" % opts.mode)
			return false
	return session != null


## Bring up a headless authoritative server: generate the galaxy, listen, and wait.
##
## Nothing here touches a `Control`, a `Viewport` or any presentation node, which is what
## lets the same build serve `--headless --server` in CI and the GUI on a desktop.
func _start_dedicated_server(opts: CC2CLI.Options) -> bool:
	var defs := _autoload("Defs")
	var db := _autoload("GameDB")
	if defs == null or db == null:
		push_error("[cc2] dedicated server needs the Defs and GameDB autoloads")
		return false
	if (defs.get("buildings") as Dictionary).is_empty():
		push_error("[cc2] definitions not loaded; cannot generate a galaxy")
		return false

	var rng := RandomNumberGenerator.new()
	# A `--seed` must reproduce exactly, including the galaxy layout, so honour it
	# before generating rather than reseeding afterwards.
	if opts.seed_given:
		rng.seed = opts.seed_value
	else:
		rng.randomize()
	var galaxy := GalaxyGenerator.generate(
		defs, rng, opts.system_count, opts.faction_count, db)
	if galaxy == null:
		push_error("[cc2] dedicated server failed to generate a galaxy")
		return false
	server_galaxy = galaxy

	# The empire ids a joining player can be given, which is also how many humans the
	# game admits. These are *available* slots, not ones being waited on: the set of
	# slots the server actually holds up for is rebuilt from who is actually connected,
	# in `_on_peer_joined`. Seeding the wait set with every slot up front meant the very
	# first game with `--slots=2` waited on a second player who may never arrive, and
	# turn 1 therefore never resolved.
	server_slots = PackedInt32Array()
	for i in opts.slots:
		server_slots.append(i)
	# An empire is a faction, so a slot with no faction behind it would seat a player in
	# a game they cannot play. `--factions` defaults to 2 while `--slots` allows up to 8,
	# so this is reachable by typing, not just by accident.
	if opts.slots > galaxy.factions.size():
		push_warning("[cc2] %d slots requested but only %d factions exist; seating %d" % [
			opts.slots, galaxy.factions.size(), galaxy.factions.size()])
		server_slots = PackedInt32Array()
		for i in galaxy.factions.size():
			server_slots.append(i)

	net = NetworkManager.new()
	net.name = "Net"
	# The manager is its own multiplayer branch root, so it must be in the tree before
	# it hosts -- `host_game` installs the interface against its own path.
	session.add_child(net)

	var err := net.host_game(opts.port, opts.slots)
	if err != OK:
		push_error("[cc2] dedicated server could not listen on port %d: %s" % [
			opts.port, error_string(err)])
		return false

	lobby = SessionLobby.new(opts.slots)
	turn_sync = net.add_sync_endpoint(TurnSyncServer) as TurnSyncServer
	turn_sync.net = net
	turn_sync.lobby = lobby
	turn_sync.ready_changed.connect(turn_sync.apply_ready)
	lobby.match_start_requested.connect(func() -> void:
		turn_sync.try_start_match())
	# Start with an *empty* wait set. `begin()` treats its argument as "slots to hold the
	# turn for", and seeding it with every advertised slot would block turn 1 on a second
	# player who may never connect. Real joins populate it via `_on_peer_joined`.
	if not turn_sync.begin(galaxy, PackedInt32Array()):
		push_error("[cc2] dedicated server failed to bind its galaxy")
		return false

	# A peer that joins mid-turn must not be able to stall the turn it missed; adding it
	# here means it is simply counted from the next resolution onward.
	net.peer_joined.connect(_on_peer_joined)
	net.peer_left.connect(_on_peer_left)

	print("[cc2] dedicated server ready: %s:%d, %d slots, seed %d, %d systems, stardate %d" % [
		opts.ip, opts.port, opts.slots, galaxy.seed_value,
		galaxy.systems.size(), galaxy.turn + 1])
	return true


## Seat a newly connected peer: tell it which empire it holds and hand over the galaxy.
##
## The slot is adopted into the wait set *before* the welcome goes out, so a peer that
## submits immediately is not refused for arriving in a turn that did not yet count it.
func _on_peer_joined(peer_id: int, slot: int) -> void:
	if slot < 0:
		return
	# The lobby is the authority on who holds what; `NetworkManager` only routes peers.
	if lobby != null:
		var assigned := lobby.join(peer_id)
		if assigned < 0:
			turn_sync.refuse(peer_id, TurnSyncServer.REFUSAL_FULL)
			print("[cc2] refused peer %d: server is full" % peer_id)
			return
		if assigned != slot:
			print("[cc2] peer %d routed to slot %d by the lobby (net said %d)" % [
				peer_id, assigned, slot])
		slot = assigned
	print("[cc2] peer %d joined as empire %d" % [peer_id, slot])
	turn_sync.add_active_slot(slot)
	if not turn_sync.send_welcome(peer_id, slot):
		push_error("[cc2] could not send the opening state to peer %d" % peer_id)


func _on_peer_left(peer_id: int, slot: int) -> void:
	if slot < 0:
		return
	print("[cc2] peer %d left (empire %d held for %.0fs)" % [
		peer_id, slot, lobby.grace_seconds if lobby != null else 0.0])
	if lobby != null:
		# Starts the grace clock rather than freeing the slot outright, so a player who
		# reconnects inside the window gets their empire back.
		lobby.leave(peer_id)
	turn_sync.remove_active_slot(slot)


## Drive the authority: resolve the turn as soon as every connected player has submitted.
##
## Nothing else calls `resolve_if_ready()`. Without this the server accepts connections and
## collects orders forever and no turn ever advances, which reads exactly like a hang.
func _process(delta: float) -> void:
	if turn_sync == null:
		return
	if lobby != null:
		_pump_lobby(delta)
	# A match that has not started yet has no turns to resolve, and resolving one would
	# advance the galaxy before every player is in it.
	if lobby != null and not lobby.started:
		return
	var payload := turn_sync.resolve_if_ready()
	if payload.is_empty():
		return
	var turn := int(payload.get("turn", 0))
	print("[cc2] turn %d resolved, hash %s" % [turn + 1, payload.get("state_hash", "")])


## Advance grace periods and start the match once the lobby is satisfied.
func _pump_lobby(delta: float) -> void:
	for slot: int in lobby.tick(delta):
		# The grace period ran out: the empire is now the AI's. The slot already stopped
		# holding the turn open when the peer left, so nothing stalls in the meantime.
		lobby.mark_ai_managed(slot)
		print("[cc2] empire %d passed to the AI (player did not return)" % slot)
	lobby.try_start()
	if lobby.started:
		turn_sync.try_start_match()


## Fetch an autoload by name without hard-referencing it, so this file stays usable in
## tests that boot without the full project.
func _autoload(named: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath(named))


## Create and name the session node for the given label.
func _make_session(label: String) -> Node:
	var node := Node.new()
	node.name = label.to_pascal_case()
	add_child(node)
	print("[cc2] session: %s" % node.name)
	return node


## Mount the client GUI onto a session node and start a game on it.
##
## The dedicated server deliberately does not attach: it runs headless and would have
## nothing to drive the interface. That split is what makes `--server` still usable in CI
## alongside the GUI build.
func _attach_client(opts: CC2CLI.Options) -> void:
	if session == null:
		return
	if opts.mode == CC2CLI.Mode.CLIENT:
		_start_network_client(opts)
	else:
		_start_local_client(opts)


## Dial a server and start a game on whatever it sends us.
##
## The galaxy is *never* generated here. A client that built its own would hold a
## different universe from the server holding the authority, which is precisely the
## split-brain an authoritative design exists to prevent -- and it would fail silently,
## looking like a desync nobody can reproduce. So the local game state does not exist
## until the server's welcome arrives.
func _start_network_client(opts: CC2CLI.Options) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return

	net = NetworkManager.new()
	net.name = "Net"
	# The manager must be in the tree before it dials: it installs the multiplayer
	# interface against its own path, which requires a resolved node path.
	session.add_child(net)

	net.connection_succeeded.connect(_on_client_connected)
	net.connection_failed.connect(_on_client_failed)
	# Two different events, and conflating them is what made one player's quit end
	# everyone else's game: `peer_left` fires when *this* client's server goes away,
	# `peer_departed` when some other player closes their window.
	net.peer_left.connect(_on_client_server_gone)
	net.peer_departed.connect(_on_client_peer_departed)

	var client_sync := net.add_sync_endpoint(TurnSyncClient) as TurnSyncClient
	client_sync.net = net
	client_sync.welcomed.connect(_on_client_welcomed)
	client_sync.turn_resolved.connect(_on_client_turn_resolved)
	client_sync.desync_detected.connect(_on_client_desync)
	client_sync.match_started.connect(_on_client_match_started)
	client_sync.lobby_ready_changed.connect(_on_client_ready_count)
	client_sync = null

	var err := net.join_game(opts.ip, opts.port)
	if err != OK:
		push_error("[cc2] could not reach %s:%d: %s" % [
			opts.ip, opts.port, error_string(err)])
		get_tree().quit(1)
		return
	print("[cc2] joining %s:%d -- waiting for the opening state" % [opts.ip, opts.port])


func _on_client_connected() -> void:
	print("[cc2] connected; handshake in progress")


func _on_client_failed(reason: String) -> void:
	push_error("[cc2] %s" % reason)
	get_tree().quit(1)


## The server reported a new lobby tally. Redraw the button so both players see the same
## count at the same moment.
func _on_client_ready_count(ready_count: int, _total_slots: int) -> void:
	if game_client != null and is_instance_valid(game_client):
		game_client.top_bar.refresh()


## The authority went away. Nothing can be played, so this session ends.
##
## Only *this* client is affected. That is the whole point of routing it separately from
## `peer_departed`: quitting here is correct, because the game genuinely has no server
## left to resolve turns against.
func _on_client_server_gone(_peer_id: int, _slot: int) -> void:
	push_error("[cc2] the server closed the connection")
	get_tree().quit(1)


## Another player left. The session is still live and this client keeps playing.
##
## The server owns the abandoned empire -- it is held for a grace period and then handed
## to the AI -- so there is nothing for a client to decide here, only something to tell
## the player. Exiting instead would end a game that is still perfectly playable, and
## would do so for every other player too, since they would each take this path.
func _on_client_peer_departed(peer_id: int) -> void:
	var text := "[cc2] another player left (peer %d); their empire is held by the server" % peer_id
	print(text)
	# The event log is where a player will actually look. A departure they only see in
	# the terminal they launched from is a departure most of them never see.
	if game_client != null and is_instance_valid(game_client):
		game_client.status_message.emit(text)


## The welcome arrived and verified: build the game client on the server's galaxy.
##
## `client_sync` is resolved from the tree rather than captured in the closure above,
## because the endpoint is created before the connection completes and a local would
## keep the node alive across the handshake for no benefit.
func _on_client_welcomed(assigned_slot: int, payload: Dictionary) -> void:
	var sync := net.get_node_or_null(NodePath(NetworkManager.SYNC_NODE_NAME)) as TurnSyncClient
	if sync == null or sync.galaxy == null:
		push_error("[cc2] welcome carried no galaxy")
		get_tree().quit(1)
		return

	var client: Control = CLIENT_SCENE.instantiate()
	session.add_child(client)
	var game_client := client as GameClient
	if game_client == null:
		push_error("[cc2] client scene root is not a GameClient")
		get_tree().quit(1)
		return
	self.game_client = game_client
	# `assigned_slot` is the empire the *server* chose. It is not necessarily 0, and
	# binding the wrong one would let a player command another empire's colonies.
	if not game_client.start(sync.galaxy, assigned_slot, 0):
		push_error("[cc2] client failed to start a session")
		get_tree().quit(1)
		return
	sync.game_client = game_client
	game_client = game_client
	# Route the GUI's End Turn through the network from now on: the controller would
	# otherwise resolve a turn locally against a galaxy the server does not hold.
	game_client.controller.turn_submitter = sync
	# Re-bind the top bar now that the session is known to be networked. `start()` ran
	# `bind()` while `turn_submitter` was still null, so the READY button would have been
	# hidden -- leaving a networked player with no way to satisfy the lobby.
	game_client.top_bar.refresh()

	print("[cc2] joined as empire %d: seed %d, %d systems, stardate %d" % [
		assigned_slot, sync.galaxy.seed_value,
		sync.galaxy.systems.size(), sync.galaxy.turn + 1])
	_declare_ready(sync)


## Tell the server this player is in, if the launch asked for it.
##
## Headless clients have no lobby UI to click, so `--ready` is how they ever get counted.
## A failure here is not fatal on its own -- the player can still be seated and wait --
## but it must be visible, because otherwise the server sits in the lobby forever with no
## indication of why.
func _declare_ready(sync: TurnSyncClient) -> void:
	if options == null or not options.auto_ready:
		return
	if sync.set_ready(true):
		print("[cc2] ready; waiting for the other players")
	else:
		push_warning("[cc2] could not send the ready flag to the server")


## The server has started the match. Everything the client needs is already bound.
func _on_client_match_started(_payload: Dictionary) -> void:
	print("[cc2] match started")


## Adopt a resolved turn: the controller holds the *same* GalaxyState object the sync
## peer just rebuilt in place, so refreshing the panels is all that is needed.
func _on_client_turn_resolved(_turn_num: int, _report: Dictionary) -> void:
	var sync := net.get_node_or_null(NodePath(NetworkManager.SYNC_NODE_NAME)) as TurnSyncClient
	if sync == null or sync.game_client == null:
		return
	sync.game_client.controller.state_changed.emit()


func _on_client_desync(turn_num: int, local_hash: int, server_hash: int) -> void:
	push_error("[cc2] desync at turn %d: local %d, server %d" % [
		turn_num + 1, local_hash, server_hash])
	get_tree().quit(1)


## Single player: generate a galaxy here and start a game on it.
func _start_local_client(opts: CC2CLI.Options) -> void:
	# The autoloads are resolved by name rather than referenced directly: this script is
	# also instantiated by the routing test outside a full game boot, where `Defs` does
	# not exist. Failing to find them here means "run a game first", which is a clearer
	# diagnostic than a compile error at load.
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var defs: Node = tree.root.get_node_or_null(NodePath("Defs"))
	var db: Node = tree.root.get_node_or_null(NodePath("GameDB"))
	if defs == null or db == null:
		print("[cc2] no autoloads present; skipping client attach")
		return
	# The registry is loaded by the autoload during a real boot. A bare `-s` run (the
	# routing test) finds the node but not its contents, and generating from an empty
	# registry would report a spurious failure.
	if (defs.get("buildings") as Dictionary).is_empty():
		print("[cc2] definitions not loaded; skipping client attach")
		return

	var rng := RandomNumberGenerator.new()
	# A `--seed` on the command line must reproduce exactly, including the galaxy
	# layout, so honour it before generating rather than reseeding afterwards.
	if opts.seed_given:
		rng.seed = opts.seed_value
	else:
		rng.randomize()
	var galaxy := GalaxyGenerator.generate(
		defs, rng, opts.system_count, opts.faction_count, db
	)
	if galaxy == null:
		push_error("[cc2] galaxy generation failed")
		return

	var client: Control = CLIENT_SCENE.instantiate()
	session.add_child(client)
	var game_client := client as GameClient
	if game_client == null:
		push_error("[cc2] client scene root is not a GameClient")
		return
	if not game_client.start(galaxy, 0, opts.seed_value if opts.seed_given else 0):
		push_error("[cc2] client failed to start a session")
		return
	print("[cc2] client attached: seed %d, %d systems, stardate %d" % [
		galaxy.seed_value, galaxy.systems.size(), galaxy.turn + 1
	])


func _exit_tree() -> void:
	if transport != null:
		transport.close()
	if net != null:
		net.close()

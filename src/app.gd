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

	# Every slot the server admits gets an empire id it can hand to a joining player.
	server_slots = PackedInt32Array()
	for i in opts.slots:
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

	turn_sync = net.add_sync_endpoint(TurnSyncServer) as TurnSyncServer
	turn_sync.net = net
	if not turn_sync.begin(galaxy, server_slots):
		push_error("[cc2] dedicated server failed to bind its galaxy")
		return false

	# A peer that joins mid-turn must not be able to stall the turn it missed; adding it
	# here means it is simply counted from the next resolution onward.
	net.peer_joined.connect(func(peer_id: int, slot: int) -> void:
		print("[cc2] peer %d joined as empire %d" % [peer_id, slot]))
	net.peer_left.connect(func(peer_id: int, slot: int) -> void:
		if slot < 0:
			return
		print("[cc2] peer %d left (empire %d dropped)" % [peer_id, slot])
		turn_sync.remove_active_slot(slot))

	print("[cc2] dedicated server ready: %s:%d, %d slots, seed %d, %d systems, stardate %d" % [
		opts.ip, opts.port, opts.slots, galaxy.seed_value,
		galaxy.systems.size(), galaxy.turn + 1])
	return true


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

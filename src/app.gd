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

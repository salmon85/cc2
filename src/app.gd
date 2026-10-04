extends Node
## Bootstrap node. Parses the command line and routes into the correct run mode.
##
## The routing decision itself lives in `CC2CLI` as a pure function so it can be exercised
## headlessly without instantiating a scene tree.

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
		CC2CLI.Mode.CLIENT:
			session = _make_session("network-client")
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


func _exit_tree() -> void:
	if transport != null:
		transport.close()
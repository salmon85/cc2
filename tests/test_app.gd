extends SceneTree
## Headless verification for Phase 1: the App bootstrap node and its routing table.
##
##   godot --headless --path . -s res://tests/test_app.gd
##
## The routing decision is `CC2CLI`'s, so this test focuses on the node-level behaviour:
## the scene instantiates, `_route` builds a session per mode, and teardown is clean.

const AppScript := preload("res://src/app.gd")

var _t: TestSupport = null


func _initialize() -> void:
	_t = TestSupport.new()

	_test_scene_loads()
	_test_routing_every_mode()
	_test_unknown_mode_is_rejected()

	var code := _t.finish("test_app")
	print("---test_app-exit=%d---" % code)
	quit(code)


func _test_scene_loads() -> void:
	_t.begin("main scene loads")
	var scene: PackedScene = load("res://src/app.tscn")
	_t.ok(scene != null, "app.tscn loads")
	if scene == null:
		return
	var inst: Node = scene.instantiate()
	_t.ok(inst != null, "app.tscn instantiates")
	_t.ok(inst is AppScript or inst.has_method("_route"), "root node carries the App script")
	if inst != null:
		inst.free()


## Build an App node without letting `_ready()` run the real CLI parse, so routing can
## be driven with an explicit Options object.
func _make_app() -> Node:
	var app := AppScript.new()
	app.set_script(null)
	# Re-attach the script so _route() is callable, but keep _ready() from firing by
	# never adding it to the tree.
	app.set_script(AppScript)
	return app


func _opts(mode: int) -> CC2CLI.Options:
	var o := CC2CLI.Options.new()
	o.mode = mode
	return o


func _test_routing_every_mode() -> void:
	_t.begin("routing table")
	var expected := {
		CC2CLI.Mode.DEDICATED_SERVER: "DedicatedServer",
		CC2CLI.Mode.SINGLE_PLAYER: "SinglePlayer",
		CC2CLI.Mode.CLIENT: "NetworkClient",
	}
	for mode: int in expected:
		var app := _make_app() as Node
		var ok_route: bool = app.call("_route", _opts(mode))
		_t.ok(ok_route, "mode %d routes successfully" % mode)
		var session: Node = app.get("session")
		_t.ok(session != null, "mode %d created a session node" % mode)
		if session != null:
			_t.eq(session.name, StringName(expected[mode]), "session named for mode %d" % mode)
			_t.eq(session.get_parent(), app, "session is parented to App")
		app.free()

	# Setup menu deliberately starts no session.
	var menu_app := _make_app() as Node
	_t.ok(menu_app.call("_route", _opts(CC2CLI.Mode.SETUP_MENU)), "setup menu routes")
	_t.eq(menu_app.get("session"), null, "setup menu creates no session")
	menu_app.free()


func _test_unknown_mode_is_rejected() -> void:
	_t.begin("unknown mode is rejected")
	var app := _make_app() as Node
	var result: bool = app.call("_route", _opts(99))
	_t.ok(not result, "an out-of-range mode fails routing instead of crashing")
	_t.eq(app.get("session"), null, "no session is created for an invalid mode")
	app.free()
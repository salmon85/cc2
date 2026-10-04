extends SceneTree
## Headless verification for Phase 1: command-line parsing and run-mode routing.
##
##   godot --headless --path . -s res://tests/test_cli.gd

const CLI := preload("res://src/core/cli.gd")

var _t: TestSupport = null


func _initialize() -> void:
	_t = TestSupport.new()

	_test_defaults()
	_test_dedicated_server()
	_test_dedicated_server_slots()
	_test_client_flags()
	_test_single_player()
	_test_setup_menu()
	_test_server_beats_client()
	_test_port_and_seed()
	_test_validation_and_warnings()

	var code := _t.finish("test_cli")
	print("---test_cli-exit=%d---" % code)
	quit(code)


func _parse(argv: Array) -> CC2CLI.Options:
	var packed := PackedStringArray()
	for a in argv:
		packed.append(a)
	return CLI.parse(packed)


func _test_defaults() -> void:
	_t.begin("defaults / setup menu")
	var opts := _parse([])
	_t.eq(opts.mode, CC2CLI.Mode.SETUP_MENU, "no flags means setup menu")
	_t.eq(opts.port, CC2CLI.DEFAULT_PORT, "default port")
	_t.eq(opts.ip, CC2CLI.DEFAULT_CLIENT_IP, "default client ip")
	_t.eq(opts.system_count, 50, "default system count")
	_t.eq(opts.faction_count, 2, "default faction count")
	_t.ok(not opts.seed_given, "no seed reported when not supplied")
	_t.ok(not opts.is_server_side(), "setup menu is not server side")


func _test_dedicated_server() -> void:
	_t.begin("dedicated server")
	var opts := _parse(["--headless", "--server"])
	_t.eq(opts.mode, CC2CLI.Mode.DEDICATED_SERVER, "--server selects dedicated server")
	_t.ok(opts.headless, "--headless recorded")
	_t.eq(opts.ip, CC2CLI.DEFAULT_BIND_IP, "server binds the wildcard address")
	_t.ok(opts.is_server_side(), "dedicated server is authoritative")
	# `--server` with no explicit port uses the ENet default, so the documented launch
	# line `godot --headless --server` needs nothing else.
	_t.eq(opts.port, CLI.DEFAULT_NET_PORT, "bare --server uses the ENet default port")
	_t.eq(opts.slots, CLI.DEFAULT_SLOTS, "slot count defaults to 2")


func _test_dedicated_server_slots() -> void:
	_t.begin("dedicated server slots")
	var full := _parse(["--server", "--port=8123", "--slots=4"])
	_t.eq(full.port, 8123, "an explicit --port is kept")
	_t.eq(full.slots, 4, "--slots=N parsed")
	_t.ok(full.port_given, "an explicit --port is recorded as given")

	var spaced := _parse(["--server", "--slots", "3"])
	_t.eq(spaced.slots, 3, "space-separated --slots consumed")

	var high := _parse(["--server", "--slots=99"])
	_t.eq(high.slots, CLI.MAX_SLOTS, "slot count clamped to the maximum")
	_t.ok(high.warnings.size() > 0, "clamping warns")

	var low := _parse(["--server", "--slots=0"])
	_t.eq(low.slots, CLI.MIN_SLOTS, "slot count clamped to the minimum")

	var junk := _parse(["--server", "--slots=many"])
	_t.eq(junk.slots, CLI.DEFAULT_SLOTS, "a non-numeric slot count falls back")
	_t.ok(junk.warnings.size() > 0, "a non-numeric slot count warns")

	var bare := _parse(["--server", "--slots"])
	_t.eq(bare.slots, CLI.DEFAULT_SLOTS, "--slots without a value falls back")
	_t.ok(bare.warnings.size() > 0, "a valueless --slots warns")


func _test_client_flags() -> void:
	_t.begin("remote client")
	var opts := _parse(["--client", "--ip=10.0.0.5", "--port=27015"])
	_t.eq(opts.mode, CC2CLI.Mode.CLIENT, "--client selects client mode")
	_t.eq(opts.ip, "10.0.0.5", "ip parsed from --ip=")
	_t.eq(opts.port, 27015, "port parsed from --port=")
	_t.ok(not opts.is_server_side(), "remote client is not authoritative")

	# An --ip on its own implies client mode (documented convenience form).
	var implicit := _parse(["--ip=192.168.1.9"])
	_t.eq(implicit.mode, CC2CLI.Mode.CLIENT, "--ip alone implies client mode")

	# Space-separated form.
	var spaced := _parse(["--client", "--ip", "localhost", "--port", "12345"])
	_t.eq(spaced.ip, "localhost", "space-separated --ip value consumed")
	_t.eq(spaced.port, 12345, "space-separated --port value consumed")

	# host:port shorthand.
	var shorthand := _parse(["--client", "--ip=example.com:9001"])
	_t.eq(shorthand.ip, "example.com", "host:port shorthand splits on colon")


func _test_single_player() -> void:
	_t.begin("single player")
	var opts := _parse(["--single"])
	_t.eq(opts.mode, CC2CLI.Mode.SINGLE_PLAYER, "--single selects single player")
	_t.ok(opts.is_server_side(), "single player hosts its own authority")
	_t.eq(opts.ip, CC2CLI.DEFAULT_LOOPBACK, "single player uses loopback")

	# A client dialing loopback still goes through the client code path, so single
	# player and a networked loopback session cannot behave differently.
	var loop := _parse(["--client", "--ip=127.0.0.1"])
	_t.eq(loop.mode, CC2CLI.Mode.CLIENT, "loopback client stays a client (authority is local)")


func _test_setup_menu() -> void:
	_t.begin("explicit setup menu")
	var opts := _parse(["--menu"])
	_t.eq(opts.mode, CC2CLI.Mode.SETUP_MENU, "--menu selects setup")
	var opts2 := _parse(["--setup"])
	_t.eq(opts2.mode, CC2CLI.Mode.SETUP_MENU, "--setup selects setup")


func _test_server_beats_client() -> void:
	_t.begin("flag precedence")
	var opts := _parse(["--server", "--client", "--ip=1.2.3.4"])
	_t.eq(opts.mode, CC2CLI.Mode.DEDICATED_SERVER, "--server wins over --client")
	_t.eq(opts.ip, CC2CLI.DEFAULT_BIND_IP, "server rewrites bind address")
	_t.ok(opts.warnings.size() > 0, "conflicting flags produce a warning")


func _test_port_and_seed() -> void:
	_t.begin("seed handling")
	var numeric := _parse(["--seed=12345"])
	_t.ok(numeric.seed_given, "seed flag recorded")
	_t.eq(numeric.seed_value, 12345, "numeric seed preserved verbatim")

	var word := _parse(["--seed=aurora-7"])
	_t.ok(word.seed_given, "word seed recorded")
	_t.ok(word.seed_value != 0, "word seed hashed to a nonzero value")

	# Same textual seed must hash identically across calls (reproducibility).
	var word2 := _parse(["--seed=aurora-7"])
	_t.eq(word2.seed_value, word.seed_value, "string seed is stable")

	var space_sep := _parse(["--seed", "777"])
	_t.eq(space_sep.seed_value, 777, "space-separated seed consumed")


func _test_validation_and_warnings() -> void:
	_t.begin("validation + warnings")
	var bad_port := _parse(["--port=70000"])
	_t.eq(bad_port.port, 65535, "out-of-range port clamped to 65535")
	_t.ok(bad_port.warnings.size() > 0, "clamped port warns")

	var junk_port := _parse(["--port=abc"])
	_t.eq(junk_port.port, CLI.DEFAULT_PORT, "non-numeric port falls back to default")
	_t.ok(junk_port.warnings.size() > 0, "non-numeric port warns")

	var low_systems := _parse(["--systems=5"])
	_t.eq(low_systems.system_count, 30, "system count clamped to spec minimum of 30")

	var high_systems := _parse(["--systems=999"])
	_t.eq(high_systems.system_count, 100, "system count clamped to spec maximum of 100")

	var in_range_systems := _parse(["--systems=64"])
	_t.eq(in_range_systems.system_count, 64, "valid system count passes through")

	var factions := _parse(["--factions=6"])
	_t.eq(factions.faction_count, 6, "faction count parsed")

	var unknown := _parse(["--warp=9"])
	_t.ok(unknown.warnings.size() > 0, "unknown flag warns instead of crashing")
	_t.eq(unknown.mode, CC2CLI.Mode.SETUP_MENU, "unknown flag does not change mode")

	var dangling := _parse(["--ip"])
	_t.eq(dangling.ip, CLI.DEFAULT_CLIENT_IP, "dangling --ip keeps the default")
	_t.ok(dangling.warnings.size() > 0, "dangling --ip warns")

	# Engine passthrough args must be ignored silently.
	var passthrough := _parse(["--path", ".", "--verbose", "-v", "--render-thread", "4"])
	_t.eq(passthrough.warnings.size(), 0, "engine passthrough args produce no warnings")

	# A genuine unknown flag must still be reported, flag or not.
	var real_unknown := _parse(["--warp=9"])
	_t.ok(real_unknown.warnings.size() > 0, "unknown flag warns")
	_t.ok(
		real_unknown.warnings[0].contains("--warp=9"),
		"warning names the offending flag")


func _describe_check() -> void:
	# Ensure Options.describe() never crashes and names the mode.
	var opts := _parse(["--server", "--seed=9"])
	var text := opts.describe()
	_t.ok(text.contains("DEDICATED_SERVER"), "describe() names the mode")
	_t.ok(text.contains("seed=9"), "describe() includes the seed")
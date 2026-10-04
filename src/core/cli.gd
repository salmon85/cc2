extends RefCounted
class_name CC2CLI
## Command-line front end.
##
## Parses the documented launch flags and resolves them into a concrete run mode:
##
##   godot --headless --server                         dedicated authoritative server
##   godot --client --ip=10.0.0.5 --port=27015          connect to a remote server
##   godot                                           local setup menu / single player
##
## Single player is *not* a separate code path: it is a client attached to an in-process
## loopback server, so offline play and networked play run identical turn-resolution code.

const DEFAULT_PORT := 27015
const DEFAULT_BIND_IP := "0.0.0.0"
const DEFAULT_CLIENT_IP := "127.0.0.1"
## Single player runs its authority in-process on the loopback interface.
const DEFAULT_LOOPBACK := "127.0.0.1"

## Engine-level flags that Godot consumes before handing `get_cmdline_args()` to us.
## They must never be reported as unknown: `godot --headless --server --verbose` is a
## perfectly normal launch line.
const ENGINE_FLAGS: Array = [
	"--verbose", "--quiet", "--debug", "--path", "--editor", "--project-manager",
	"--main-pack", "--render-thread", "--display-driver", "--audio-driver",
	"--resolution", "--position", "--max-fps", "--gpu-index", "--language",
	"--remote-debug", "--remote-fs", "--script", "-s", "-v", "-q", "-d", "-e",
]


## What the bootstrap node should do after parsing.
enum Mode {
	SINGLE_PLAYER, ## Client + in-process loopback server.
	DEDICATED_SERVER, ## Headless authoritative server.
	CLIENT, ## Connect out to a remote server.
	SETUP_MENU, ## Interactive local setup (no headless server requested).
}


## Parsed, validated result of the command line.
class Options extends RefCounted:
	var mode: int = Mode.SETUP_MENU
	var ip: String = DEFAULT_CLIENT_IP
	var port: int = DEFAULT_PORT
	var seed_value: int = 0
	var seed_given: bool = false
	var system_count: int = 50
	var faction_count: int = 2
	var headless: bool = false
	var log_turns: bool = false
	## Non-fatal notes (unknown flags, clamped values) surfaced to the player.
	var warnings: PackedStringArray = PackedStringArray()

	func is_server_side() -> bool:
		return mode == Mode.DEDICATED_SERVER or mode == Mode.SINGLE_PLAYER

	func describe() -> String:
		var mode_name: String = [
			"SINGLE_PLAYER", "DEDICATED_SERVER", "CLIENT", "SETUP_MENU"
		][mode]
		return "%s ip=%s port=%d seed=%d systems=%d factions=%d%s" % [
			mode_name, ip, port, seed_value, system_count, faction_count,
			"" if not warnings.is_empty() else " (no warnings)",
		]


## Parse an argument vector. `argv` normally comes from `OS.get_cmdline_args()`,
## which excludes the engine binary itself. Injection-friendly for tests.
static func parse(argv: PackedStringArray) -> Options:
	var opts := Options.new()
	var want_server := false
	var want_client := false

	var i := 0
	while i < argv.size():
		var arg := argv[i]
		match arg:
			"--server":
				want_server = true
			"--client":
				want_client = true
			"--single", "--singleplayer", "--local":
				opts.mode = Mode.SINGLE_PLAYER
			"--setup", "--menu":
				opts.mode = Mode.SETUP_MENU
			"--headless":
				opts.headless = true
			"--log-turns":
				opts.log_turns = true
			_:
				# --key=value forms
				if arg.begins_with("--ip="):
					opts.ip = _clean_host(arg.substr(5))
					# A bare --ip also selects client mode, matching the documented UX.
					want_client = true
				elif arg.begins_with("--port="):
					opts.port = _parse_port(arg.substr(7), opts)
				elif arg.begins_with("--seed="):
					_parse_seed(arg.substr(7), opts)
				elif arg.begins_with("--systems="):
					opts.system_count = _parse_clamped_int(
						arg.substr(10), opts, 30, 100, "systems", 50)
				elif arg.begins_with("--factions="):
					opts.faction_count = _parse_clamped_int(
						arg.substr(11), opts, 1, 8, "factions", 2)
				elif arg == "--ip" or arg == "--port" or arg == "--seed":
					# Space-separated variant: consume the next token.
					if i + 1 < argv.size():
						i += 1
						var value := argv[i]
						if arg == "--ip":
							opts.ip = _clean_host(value)
							want_client = true
						elif arg == "--port":
							opts.port = _parse_port(value, opts)
						else:
							_parse_seed(value, opts)
					else:
						opts.warnings.append("flag %s given without a value" % arg)
				elif not arg.begins_with("-"):
					# A bare value belonging to a preceding engine flag (e.g. `--path .`).
					pass
				elif _is_engine_flag(arg):
					pass
				else:
					opts.warnings.append("unknown flag ignored: %s" % arg)
		i += 1

	# Resolve server/client intent last so --server beats an incidental --ip=.
	if opts.mode != Mode.SINGLE_PLAYER:
		if want_server and want_client:
			opts.warnings.append("--server and --client both given; running dedicated server")
			opts.mode = Mode.DEDICATED_SERVER
		elif want_server:
			opts.mode = Mode.DEDICATED_SERVER
			opts.ip = DEFAULT_BIND_IP
		elif want_client:
			opts.mode = Mode.CLIENT
		elif opts.mode != Mode.SETUP_MENU:
			pass

	if opts.mode == Mode.DEDICATED_SERVER:
		opts.ip = DEFAULT_BIND_IP

	return opts


## Convenience wrapper reading the real process command line.
static func parse_os() -> Options:
	return parse(OS.get_cmdline_args())


static func _is_engine_flag(arg: String) -> bool:
	# JSON round-trips turn an `Array[String]` into a `PackedStringArray`, so the
	# table is stored untyped and compared as strings.
	return ENGINE_FLAGS.has(str(arg))


static func _clean_host(value: String) -> String:
	var host := value.strip_edges()
	if host.is_empty():
		return DEFAULT_CLIENT_IP
	# Accept a bare "host:port" as well as the documented --ip/--port pair.
	if host.contains(":") and not host.begins_with("["):
		var parts := host.split(":")
		return parts[0].strip_edges()
	return host


static func _parse_port(value: String, opts: Options) -> int:
	var parsed := _parse_clamped_int(value, opts, 1, 65535, "port", DEFAULT_PORT)
	return parsed


static func _parse_seed(value: String, opts: Options) -> void:
	opts.seed_given = true
	var as_int := value.to_int()
	# A non-numeric seed is hashed so "aurora-7" is a legal, reproducible seed.
	opts.seed_value = as_int if value.strip_edges().is_valid_int() else abs(hash(value))


static func _parse_clamped_int(
	value: String, opts: Options, lo: int, hi: int, label: String, fallback: int
) -> int:
	var raw := value.strip_edges()
	if not raw.is_valid_int():
		opts.warnings.append("%s '%s' is not an integer; using %d" % [label, raw, fallback])
		return fallback
	var parsed := raw.to_int()
	if parsed < lo or parsed > hi:
		var clamped := clampi(parsed, lo, hi)
		opts.warnings.append(
			"%s %d out of range [%d, %d]; clamped to %d" % [label, parsed, lo, hi, clamped])
		return clamped
	return parsed
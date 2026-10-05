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
## Default port for the ENet dedicated server. Kept separate from `DEFAULT_PORT` (the
## Quake-style 27015 the original game shipped with) because the Phase 6 transport binds
## its own default, and silently repointing a documented constant the CLI tests pin would
## be a behaviour change nobody asked for.
const DEFAULT_NET_PORT := 7777
## Default number of empire slots a dedicated server opens.
const DEFAULT_SLOTS := 2
const MIN_SLOTS := 1
const MAX_SLOTS := 8
## Stars the generator wants per empire, matching its own homeworld spacing rule. Kept
## here as well as in `GalaxyGenerator` so the CLI can size a map for the empires it is
## about to ask for rather than discovering the shortfall after generation.
const MIN_SYSTEMS_PER_FACTION := 5
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
	## Whether --factions was given explicitly. Without this a derived floor (see
	## `reconcile_slot_empires`) could not tell "the operator asked for two" from "nobody
	## said, and two is just the default", and would silently overrule the first.
	var faction_count_given: bool = false
	## Empire slots a dedicated server opens. One slot per connected human; the server
	## itself is not a slot, so `--slots=2` admits two remote players.
	var slots: int = DEFAULT_SLOTS
	## Whether --port was given explicitly, so `--server` can fall back to the ENet
	## default without overriding a port the operator actually asked for.
	var port_given: bool = false
	var headless: bool = false
	var log_turns: bool = false
	## Declare the local player ready without a lobby UI to click.
	##
	## A headless client has nobody at a button, and an interactive one would otherwise
	## have no way to say "I am here" other than a keypress. Either way the flag has to
	## reach the server, and it is the server that decides when the match starts.
	var auto_ready: bool = false
	## Non-fatal notes (unknown flags, clamped values) surfaced to the player.
	var warnings: PackedStringArray = PackedStringArray()

	func is_server_side() -> bool:
		return mode == Mode.DEDICATED_SERVER or mode == Mode.SINGLE_PLAYER

	func describe() -> String:
		var mode_name: String = [
			"SINGLE_PLAYER", "DEDICATED_SERVER", "CLIENT", "SETUP_MENU"
		][mode]
		return "%s ip=%s port=%d seed=%d planets=%d factions=%d slots=%d%s%s" % [
			mode_name, ip, port, seed_value, system_count, faction_count, slots,
			" ready" if auto_ready else "",
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
			"--ready", "--auto-ready":
				opts.auto_ready = true
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
					# The flag is still called `--systems`, but the game is one system now
					# and this is its planet count. Renaming the flag would break every
					# existing launch script for no gain in clarity -- the help text and
					# the `planets=` log line say what it means.
				elif arg.begins_with("--factions="):
					opts.faction_count = _parse_clamped_int(
						arg.substr(11), opts, 1, 8, "factions", 2)
					opts.faction_count_given = true
				elif arg.begins_with("--slots="):
					opts.slots = _parse_clamped_int(
						arg.substr(8), opts, MIN_SLOTS, MAX_SLOTS,
						"slots", DEFAULT_SLOTS)
				elif arg == "--ip" or arg == "--port" or arg == "--seed" \
						or arg == "--slots":
					# Space-separated variant: consume the next token.
					if i + 1 < argv.size():
						i += 1
						var value := argv[i]
						if arg == "--ip":
							opts.ip = _clean_host(value)
							want_client = true
						elif arg == "--port":
							opts.port = _parse_port(value, opts)
						elif arg == "--slots":
							opts.slots = _parse_clamped_int(
								value, opts, MIN_SLOTS, MAX_SLOTS,
								"slots", DEFAULT_SLOTS)
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
			# `--server` with no explicit --port uses the ENet default rather than
			# 27015, so the documented launch line needs no port at all.
			if not opts.port_given:
				opts.port = DEFAULT_NET_PORT
		elif want_client:
			opts.mode = Mode.CLIENT
		elif opts.mode != Mode.SETUP_MENU:
			pass

	if opts.mode == Mode.DEDICATED_SERVER:
		opts.ip = DEFAULT_BIND_IP

	reconcile_slot_empires(opts)

	return opts


## Make `--slots=N` actually playable: an empire is a faction, so a slot with no faction
## behind it seats a player in a game they cannot play.
##
## `--factions` defaults to 2 while `--slots` goes up to 8, so `--slots=4` used to open
## four seats over a two-empire galaxy and the server then quietly shrank itself back to
## two -- the third and fourth players were refused with no error anyone could see. Raising
## the faction count to match is the fix; the two flags describe one game and were never
## meant to be set independently.
##
## An explicit `--factions` wins: an operator who says `--slots=8 --factions=2` is running
## a two-human game with spectators' seats, not a mistake, so it is honoured and left to
## `App` to report. The planet count is raised alongside the factions so there is always
## enough of the system to give every empire its own starting world: a cramped system
## would quietly cap the empire count back down to below the slot count -- the same bug
## one layer down.
static func reconcile_slot_empires(opts: Options) -> void:
	if opts.mode != Mode.DEDICATED_SERVER:
		return
	if opts.faction_count_given or opts.slots <= opts.faction_count:
		return
	opts.faction_count = opts.slots
	opts.system_count = maxi(opts.system_count, opts.slots * MIN_SYSTEMS_PER_FACTION)


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
	opts.port_given = true
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
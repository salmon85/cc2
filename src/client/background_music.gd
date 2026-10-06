extends Node
class_name BackgroundMusic
## Looping background music, wired up only when there is an audio device to play it through.
##
## The guard is the point of this class. A headless run -- the eleven test suites, and the
## dedicated server that CI runs the same way -- has no audio hardware, and touching
## `AudioStreamPlayer` there asks the engine to open a device that does not exist. Depending on
## the platform that is a warning, a stream of errors, or a hard failure that takes the whole
## test run down over a background track. So the player node is not merely muted headlessly,
## it is never created: `start()` returns before it builds anything, and the node that holds
## it stays an empty `Node`.
##
## `music_allowed()` is a **static, pure function** so the decision itself is testable without
## an audio device. A guard that can only be exercised by running audio is a guard nobody
## exercises.

## Emitted when music actually starts. Not emitted in a headless run, which is how a caller
## (and the test suite) can tell silence from playback.
signal music_started

## The track, as a bare file name inside `AssetPaths.SOUNDS_DIR`.
const TRACK := "music.ogg"

## Loop the whole track from its first frame.
##
## Zero rather than a "skip the intro" offset: the file is a single continuous piece, and an
## offset is only meaningful when the track has an intro that should play once. A non-zero
## loop point on this file would cut the first few seconds off every repeat.
const LOOP_OFFSET := 0.0

## The player, or null when audio is unavailable -- which is the normal case headlessly.
var _player: AudioStreamPlayer = null

## Why the guard refused, for a caller that wants to say so. Empty when playback was allowed.
var _refusal: String = ""


## Whether this run may open an audio device and play.
##
## Three separate disqualifiers, because they are three different situations that happen to
## share one consequence:
##
##   - `DisplayServer.get_name() == "headless"` -- the canonical check, and the one that
##     covers `--headless`, the test suites and the dedicated server.
##   - a script-mode invocation -- `-s`/`--script` on the command line, or a script under
##     `res://tests/`. A test run can be launched *without* `--headless` on a developer
##     machine that happens to have a sound card, and then the DisplayServer check says
##     "fine" and the audio device opens in the middle of a test that never asked for one.
##   - `Engine.is_editor_hint()` -- the editor plays audio on its own terms.
##
## `OS.has_feature("template")` is deliberately *not* a disqualifier on its own: it is true of
## every exported build, desktop included, and testing for it would mute exactly the players
## this class exists to serve. It only ever appears here in combination with the headless
## check, where it is what identifies an exported *server*.
static func music_allowed() -> bool:
	return refusal_reason().is_empty()


## Why playback is unavailable, or "" when it is available.
##
## Returns prose rather than a bool so a caller can report the actual cause instead of a bare
## "no audio", and so a test can assert *which* guard fired.
static func refusal_reason() -> String:
	if DisplayServer.get_name() == "headless":
		return "headless display server"
	if is_test_run():
		return "automated test run"
	if Engine.is_editor_hint():
		return "running inside the editor"
	return ""


## Whether this process was launched as a script rather than as the game.
##
## Reads the command line rather than a flag of our own: the test harness is the caller, not
## this class, and a flag it would have to remember to set is a flag it can forget.
##
## Both spellings of the flag are caught because Godot accepts either, and the `=` form is a
## single argument rather than a pair. `res://tests/` catches a script invoked by path, and
## the filename test catches one run from a copy outside the project directory -- which is
## what a developer debugging a single failing suite actually does.
static func is_test_run() -> bool:
	for arg: String in OS.get_cmdline_args():
		if arg == "-s" or arg == "--script" or arg == "-e" or arg == "--editor":
			return true
		if arg.begins_with("--script=") or arg.begins_with("-s="):
			return true
		if arg.begins_with("res://tests/"):
			return true
		if arg.ends_with(".gd") and arg.contains("test_"):
			return true
	return false


func _ready() -> void:
	# Started from `_ready` so dropping this node onto a scene is enough; `start` is still
	# idempotent, so an explicit call afterwards is harmless.
	start()


## Start the music if this run can play it. Returns whether playback actually began.
##
## Everything audio-related happens after the guard, including the `load()`: importing and
## decoding a multi-megabyte Ogg is wasted work in a process that is about to throw it away,
## and the load is the step most likely to emit a diagnostic the test gate would trip over.
func start() -> bool:
	if _player != null:
		return _player.playing
	var reason := refusal_reason()
	if not reason.is_empty():
		# Not a `push_warning`: this is the expected, correct outcome for every test suite
		# and for a dedicated server, and a warning would be noise they all have to filter
		# past -- and `tools/verify.sh` fails a run on any unexpected diagnostic.
		_refusal = reason
		return false
	var stream := load(AssetPaths.sounds_path(TRACK)) as AudioStream
	if stream == null:
		_refusal = "no stream at %s" % AssetPaths.sounds_path(TRACK)
		push_warning("[BackgroundMusic] %s" % _refusal)
		return false
	_configure_loop(stream)
	_player = AudioStreamPlayer.new()
	_player.name = "MusicPlayer"
	_player.stream = stream
	_player.bus = "Master"
	_player.finished.connect(_on_music_finished)
	add_child(_player)
	_player.play()
	_refusal = ""
	music_started.emit()
	return true


## Make `stream` repeat from its first frame without a gap.
##
## Set on the resource rather than by re-`play()`ing on `finished`, because restarting a
## player re-seeks and there is a frame of silence while it does -- which is audible as a
## click once a minute in a track that is supposed to be seamless. The `finished` handler
## below stays as a backstop for an import that produced a stream type with no loop flag.
##
## Static so the loop configuration can be asserted without an audio device: "the track loops
## seamlessly" is a claim about the stream, and a claim that can only be checked by listening
## to it is one nobody checks.
static func _configure_loop(stream: AudioStream) -> void:
	if stream is AudioStreamOggVorbis:
		var vorbis := stream as AudioStreamOggVorbis
		vorbis.loop = true
		vorbis.loop_offset = LOOP_OFFSET
	elif stream is AudioStreamWAV:
		# The WAV path spells the same idea differently: an enum rather than a bool, and a
		# begin/end pair rather than an offset. `loop_end` of 0 means "to the end of the
		# sample", which is looping the whole track.
		var wav := stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = 0
	elif "loop" in stream:
		# The MP3 importer uses the Vorbis spelling. Set under its own guard rather than as a
		# pair: a stream type with `loop` but no `loop_offset` would otherwise raise on the
		# second line of a loop the first line already asked for.
		stream.set("loop", true)
		if "loop_offset" in stream:
			stream.set("loop_offset", LOOP_OFFSET)


func _on_music_finished() -> void:
	# Backstop for a stream whose loop flag did not take. Never reached when looping works,
	# because `finished` is not emitted for a looping stream.
	if _player != null:
		_player.play()


## Stop playback and release the device. Safe to call when nothing is playing.
func stop() -> void:
	if _player == null:
		return
	_player.stop()
	if is_instance_valid(_player):
		_player.queue_free()
	_player = null


## Whether the music is currently audible.
##
## Reads the player rather than a remembered flag, so it cannot report "playing" for a stream
## that was stopped underneath it.
func is_playing_music() -> bool:
	return _player != null and _player.playing


## The player node, or null in a run that is not allowed to make one.
##
## Public so a caller -- and the GUI suite -- can assert that a headless run really did not
## create one, rather than taking the guard's word for it.
func player() -> AudioStreamPlayer:
	return _player


## Why playback is unavailable, or "" when it is available or did start.
func refusal() -> String:
	return _refusal


func _exit_tree() -> void:
	stop()
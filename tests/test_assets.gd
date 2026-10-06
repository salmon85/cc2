extends SceneTree
## Asset directory policy and background-music integration.
##
## Two things are under test, and both are about *routing* rather than about pictures or
## sound:
##
##   - every asset path is named in one place, generated imagery can only be written to
##     `res://data/graphics/`, and a name cannot escape that directory;
##   - background music is wired up, and this run is one of the runs that must not have it.
##
## The second half is the interesting one. This suite is itself an audio-disabled run, so it
## can assert the guard rather than merely describe it: if the guard regressed and an
## `AudioStreamPlayer` were constructed here, the assertions below would see it -- and so
## would the audio device, if the machine running CI had one.

var sup: TestSupport


func _initialize() -> void:
	sup = TestSupport.new()

	_test_directories()
	_test_path_containment()
	_test_graphics_writes()
	_test_sounds_track()
	_test_music_guard()
	_test_loop_configuration()

	quit(sup.finish("test_assets"))


# --- directory policy -----------------------------------------------------

func _test_directories() -> void:
	sup.begin("asset directories")
	sup.eq(AssetPaths.GRAPHICS_DIR, "res://data/graphics/",
		"generated imagery has one declared home")
	sup.eq(AssetPaths.SOUNDS_DIR, "res://data/sounds/",
		"and audio has another")
	sup.eq(AssetPaths.DATA_DIR, "res://data/", "both live under the authored asset root")

	sup.ok(DirAccess.dir_exists_absolute(AssetPaths.GRAPHICS_DIR),
		"the graphics directory exists on disk")
	sup.ok(DirAccess.dir_exists_absolute(AssetPaths.SOUNDS_DIR),
		"the sounds directory exists on disk")

	# The definition subdirectories must survive the routing change: they are where the
	# authored `.tres` files live, and `res://data/` is not a graphics folder.
	for sub: String in ["buildings", "ships", "planet_types", "tech"]:
		sup.ok(DirAccess.dir_exists_absolute(AssetPaths.DATA_DIR + sub),
			"the authored %s directory is untouched" % sub)


## A file name cannot be used to leave the directory it belongs to.
##
## The policy is only worth having if it is enforced at the point of writing, and a helper
## that concatenates whatever it is handed is a convention. `../` and an absolute path are
## the two shapes that actually escape.
func _test_path_containment() -> void:
	sup.begin("path containment")
	sup.eq(AssetPaths.graphics_path("logo.png"), "res://data/graphics/logo.png",
		"a bare name lands in the graphics directory")
	sup.eq(AssetPaths.graphics_path("sub/dir/logo.png"), "res://data/graphics/logo.png",
		"a nested name is reduced to its last component")
	sup.eq(AssetPaths.graphics_path("../../etc/passwd"), "res://data/graphics/passwd",
		"a traversal is stripped rather than followed")
	sup.eq(AssetPaths.graphics_path("/etc/passwd"), "res://data/graphics/passwd",
		"and so is an absolute path")
	sup.eq(AssetPaths.sounds_path("../../data/buildings/farm.tres"),
		"res://data/sounds/farm.tres",
		"the sounds directory is guarded the same way")

	# Everything the helper can return is inside the directory.
	for name: String in ["a.png", "../b.png", "../../../c.png", "/d.png", ""]:
		var produced := AssetPaths.graphics_path(name)
		sup.ok(produced.begins_with(AssetPaths.GRAPHICS_DIR),
			"'%s' stays inside the graphics directory (got '%s')" % [name, produced])


## A generated texture is written where the policy says, and lands nowhere else.
func _test_graphics_writes() -> void:
	sup.begin("graphics writes")
	var probe := "_probe_%d.png" % Time.get_ticks_usec()

	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.6, 0.9, 1.0))
	var written := AssetPaths.save_texture(image, probe)
	sup.ok(not written.is_empty(), "a texture can be saved", "save_texture returned empty")
	sup.ok(written.begins_with(AssetPaths.GRAPHICS_DIR),
		"and it is written into the graphics directory", "wrote '%s'" % written)
	sup.ok(FileAccess.file_exists(written), "the file is there afterwards")
	# The listing holds bare file names; the save returns a full path.
	sup.ok(written.get_file() in AssetPaths.list_graphics(),
		"and the directory listing reports it", "listing: %s" % str(AssetPaths.list_graphics()))

	# The extension is supplied rather than required, and an explicit one is respected.
	var no_ext := AssetPaths.save_texture(image, probe.trim_suffix(".png"))
	sup.ok(no_ext.get_extension() == "png",
		"a name without an extension gets one", "wrote '%s'" % no_ext)

	# A null image is refused rather than crashing a generator mid-export.
	sup.eq(AssetPaths.save_texture(null, probe), "",
		"a null image is refused")

	# The listing excludes engine sidecars, which are bookkeeping rather than assets.
	for entry: String in AssetPaths.list_graphics():
		sup.ok(entry.get_extension() != "import",
			"'%s' in the listing is an asset, not an import sidecar" % entry)

	# Clean up, so a run of the suite does not fill the directory with probes.
	for path: String in [written, no_ext]:
		if path != "" and FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## The procedural appearance exporter writes through the policy, not around it.
func _test_graphics_exports() -> void:
	sup.begin("procedural texture export")
	var exported := PlanetVisuals.export_texture(&"ocean", 0, 24)
	sup.ok(not exported.is_empty(), "a world look can be exported", "returned empty")
	sup.ok(exported.begins_with(AssetPaths.GRAPHICS_DIR),
		"and the export lands in the graphics directory", "wrote '%s'" % exported)
	sup.ok(FileAccess.file_exists(exported), "producing a real file")
	if not exported.is_empty() and FileAccess.file_exists(exported):
		var loaded := Image.load_from_file(exported)
		sup.ok(loaded != null and loaded.get_width() == 24,
			"which reads back as the image that was written")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(exported))
	sup.eq(PlanetVisuals.export_texture(&"ocean", 0, 0), "",
		"a degenerate size is refused rather than written")


# --- audio ----------------------------------------------------------------

func _test_sounds_track() -> void:
	sup.begin("background track")
	var path := AssetPaths.sounds_path(BackgroundMusic.TRACK)
	sup.eq(path, "res://data/sounds/music.ogg",
		"the track is resolved through the sounds directory")
	sup.ok(FileAccess.file_exists(path), "and the file is there", "no '%s'" % path)
	# Loading a stream opens no audio device, so this is safe to do in a headless run -- and
	# it is what proves the import pipeline can reach the file at all.
	var stream := load(path)
	sup.ok(stream is AudioStream,
		"and it loads as an audio stream", "got %s" % type_string(typeof(stream)))


## This run must not have audio. Asserted, not assumed.
func _test_music_guard() -> void:
	sup.begin("headless music guard")
	sup.ok(BackgroundMusic.is_test_run(),
		"the run identifies itself as an automated test run")
	sup.ok(not BackgroundMusic.music_allowed(),
		"and therefore refuses to play music")
	sup.ok(not BackgroundMusic.refusal_reason().is_empty(),
		"with a reason the caller could report")

	# The canonical check is specifically about a headless display server, and this suite is
	# run with `--headless`, so that is the reason on this machine.
	sup.eq(DisplayServer.get_name(), "headless",
		"the suite really is running headless, which is the case being guarded")

	# A node built under those conditions must not come back with a player.
	var music := BackgroundMusic.new()
	root.add_child(music)
	sup.eq(music.player(), null,
		"adding the music node in a headless run creates no AudioStreamPlayer")
	sup.ok(not music.is_playing_music(), "and nothing is playing")
	sup.ok(not music.start(), "start() reports that it did not start")
	sup.eq(music.player(), null,
		"and still no player exists after an explicit start attempt")
	sup.ok(music.refusal().contains("headless") or music.refusal().contains("test"),
		"the refusal says why", "refusal='%s'" % music.refusal())

	# And nothing audio-ish was added to the tree at all.
	var players := 0
	for child: Node in root.get_children():
		if child is AudioStreamPlayer:
			players += 1
	sup.eq(players, 0, "no AudioStreamPlayer exists anywhere in the scene tree")
	music.queue_free()


## The track is configured to loop from its first frame.
##
## Checked against a stream built in memory rather than the real 4 MB file: the property that
## matters is the one being set on the resource, and asserting it on a constructed Vorbis
## stream proves the rule without decoding a track to do it.
func _test_loop_configuration() -> void:
	sup.begin("seamless looping")
	var vorbis := AudioStreamOggVorbis.new()
	vorbis.loop = false
	BackgroundMusic._configure_loop(vorbis)
	sup.ok(vorbis.loop, "an Ogg Vorbis stream is set to loop")
	sup.near(vorbis.loop_offset, 0.0, 0.0001,
		"from its first frame, so no part of the track is skipped each repeat")

	# The WAV path spells it differently -- an enum and a begin/end pair -- and the rule has
	# to cover both spellings rather than whichever one the shipped track happens to use.
	var wav := AudioStreamWAV.new()
	wav.loop_mode = AudioStreamWAV.LOOP_DISABLED
	BackgroundMusic._configure_loop(wav)
	sup.eq(wav.loop_mode, AudioStreamWAV.LOOP_FORWARD,
		"and a WAV stream is looped forwards by the same rule")
	sup.eq(wav.loop_begin, 0, "from its first frame")
	sup.eq(wav.loop_end, 0, "to the end of the sample")

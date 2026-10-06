extends RefCounted
class_name AssetPaths
## The one place that knows where assets live.
##
## Every directory an asset can be *read from* or *written to* is named here rather than
## spelled out at its use site. Two spellings of the same path is two paths: one gets updated
## when the layout moves and the other does not, and the failure is a missing file at runtime
## rather than a compile error.
##
## It is deliberately a `RefCounted` of pure static functions with no autoload behind it. The
## test suites run with `-s res://tests/test_*.gd` and stand in for the project's autoloads
## themselves, so anything that needed a live node would be untestable headlessly -- which is
## exactly where a path constant most needs checking.

## Root of the authored asset tree.
const DATA_DIR := "res://data/"

## Where generated textures, procedural image saves and sprite assets are written.
##
## The rule is one-directional and worth stating plainly: *generated* imagery goes to
## `graphics/`, and only *authored* data (the `.tres` definitions) sits in the subdirectories
## beside it. A generator that drops a PNG beside the definitions it was reading makes the
## asset tree a build artefact, and a build artefact that is checked in is a binary that can
## drift from the code that produces it without anything failing.
const GRAPHICS_DIR := "res://data/graphics/"

## Where audio is read from.
const SOUNDS_DIR := "res://data/sounds/"


## The absolute path of a file in the graphics directory.
##
## Takes a bare file name, not a path: a caller that can pass `"../../etc/passwd"` is a
## caller that can eventually be made to, and the policy is only worth having if the input
## cannot leave the directory.
static func graphics_path(file_name: String) -> String:
	return GRAPHICS_DIR + _bare(file_name)


## The absolute path of a file in the sounds directory.
static func sounds_path(file_name: String) -> String:
	return SOUNDS_DIR + _bare(file_name)


## Strip any directory component from `file_name`, so a name cannot escape its directory.
##
## `String.get_file()` rather than a hand-rolled split: it is the engine's own answer to
## "the last component", so a Windows-style separator or a trailing slash behaves the same as
## a Unix one.
static func _bare(file_name: String) -> String:
	return file_name.get_file()


## Create `directory` if it is missing. Returns false when it could not be made.
##
## Called before every save rather than once at boot: an asset writer that assumes the tree
## is already there works on the developer's machine, where the directory exists from an
## earlier run, and fails on a fresh checkout.
static func ensure_directory(directory: String) -> bool:
	if DirAccess.dir_exists_absolute(directory):
		return true
	return DirAccess.make_dir_recursive_absolute(directory) == OK \
		or DirAccess.dir_exists_absolute(directory)


## Write `image` into the graphics directory as a PNG. Returns the path written, or "".
##
## The enforcement point for the graphics policy: a caller cannot name a destination, so
## there is no way for a generated image to land somewhere else. Name is taken as a bare file
## name and the extension is supplied here.
static func save_texture(image: Image, file_name: String) -> String:
	if image == null:
		push_error("[AssetPaths] refusing to save a null image")
		return ""
	if not ensure_directory(GRAPHICS_DIR):
		push_error("[AssetPaths] could not create %s" % GRAPHICS_DIR)
		return ""
	var stem := _bare(file_name)
	if stem.get_extension().is_empty():
		stem += ".png"
	var target := GRAPHICS_DIR + stem
	var err := image.save_png(target)
	if err != OK:
		push_error("[AssetPaths] could not write %s (%s)" % [target, error_string(err)])
		return ""
	return target


## Every file in the graphics directory, sorted, excluding `.import` sidecars.
##
## Excludes the sidecars because they are engine bookkeeping, not assets: a caller asking
## "what graphics does this build have" wants `logo.png`, not `logo.png.import`.
static func list_graphics() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(GRAPHICS_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.get_extension() != "import":
			out.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	var sorted := Array(out)
	sorted.sort()
	return PackedStringArray(sorted)
extends RefCounted
class_name KeyText
## Canonical rendering of dictionary keys for fingerprints and serialisation.
##
## Godot's `String(key)` is *not* stable across a type change: a `StringName` renders as
## `&"farm"` while a `String` renders as `"farm"`. A save file round-trips every
## StringName key to String, so any fingerprint that used `str()` directly would hash an
## identical planet differently before and after a load, breaking the determinism the
## turn engine depends on.
##
## Every `str(key)` in a fingerprint or serialiser should go through `key()` instead.

## Render a single key the same way whether it is a StringName or a String.
static func key(k: Variant) -> String:
	if k is StringName:
		return String(k)
	return str(k)


## Sorted, canonical rendering of a dictionary's keys.
static func sorted_keys(source: Dictionary) -> String:
	var out := PackedStringArray()
	for k: Variant in source:
		out.append(key(k))
	out.sort()
	return str(out)
extends RefCounted
class_name TestSupport
## Tiny assertion + reporting harness shared by every headless verification script.
##
## Deliberately dependency-free so it works before (and independent of) any game system:
## the test scripts run under `godot --headless -s res://tests/<file>.gd`, where the
## simulation autoloads are not necessarily present.
##
## Failure-path verification
## -------------------------
## Godot does not deliver its global `error` signal to plain Nodes in this build, so a
## test cannot observe `push_error()` from GDScript. Guards in this codebase are therefore
## written to *return* a rejection value (false / "" / null / empty) in addition to
## reporting one, and tests assert on that return value via `expect_guard`.

var checks: int = 0
var failures: PackedStringArray = PackedStringArray()
var section: String = ""


## Print a section banner.
func begin(title: String) -> void:
	section = title
	print("")
	print("=== %s ===" % title)


## Assert a condition. `detail` is printed on failure.
func ok(condition: bool, label: String, detail: String = "") -> bool:
	checks += 1
	if condition:
		print("  [PASS] %s" % label)
		return true
	var message := label if detail.is_empty() else "%s  -- %s" % [label, detail]
	failures.append("[%s] %s" % [section, message])
	print("  [FAIL] %s" % message)
	return false


## Assert strict equality with the actual value reported on failure.
func eq(actual: Variant, expected: Variant, label: String) -> bool:
	return ok(actual == expected, label, "got %s, expected %s" % [str(actual), str(expected)])


## Assert two numbers are within `tolerance` of each other.
func near(actual: float, expected: float, tolerance: float, label: String) -> bool:
	var delta := absf(actual - expected)
	return ok(
		delta <= tolerance,
		label,
		"got %f, expected %f +-%f (delta %f)" % [actual, expected, tolerance, delta])


## Assert `value` lies inside [lo, hi].
func in_range(value: float, lo: float, hi: float, label: String) -> bool:
	return ok(
		value >= lo and value <= hi,
		label,
		"got %f outside [%f, %f]" % [value, lo, hi])


## Assert that `block` triggers a guard, i.e. returns a rejection value.
## A rejection is null, false, an empty String, or an empty Array/Dictionary.
func expect_guard(label: String, block: Callable) -> Variant:
	var result: Variant = block.call()
	ok(_is_rejection(result), label, "guard accepted the input (returned %s)" % str(result))
	return result


## Assert that `block` completes normally, returning something that is not a rejection.
func expect_accept(label: String, block: Callable) -> Variant:
	var result: Variant = block.call()
	ok(not _is_rejection(result), label, "guard rejected a valid input (returned %s)" % str(result))
	return result


## True when `value` represents a rejection.
static func _is_rejection(value: Variant) -> bool:
	if value == null:
		return true
	if value is bool:
		return not (value as bool)
	if value is String:
		return (value as String).is_empty()
	if value is Array:
		return (value as Array).is_empty()
	if value is Dictionary:
		return (value as Dictionary).is_empty()
	if value is PackedStringArray:
		return (value as PackedStringArray).is_empty()
	return false


## Print the summary and return the process exit code (0 clean, 1 on any failure).
func finish(title: String) -> int:
	print("")
	if failures.is_empty():
		print("RESULT %s: OK (%d checks passed)" % [title, checks])
		return 0
	print("RESULT %s: FAILED (%d/%d checks failed)" % [title, failures.size(), checks])
	for failure in failures:
		print("  * %s" % failure)
	return 1
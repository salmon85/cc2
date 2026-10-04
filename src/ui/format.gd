extends RefCounted
class_name Format
## Number and text formatting for the client readouts.
##
## Every readout in the game goes through here so the whole HUD speaks with one voice:
## fixed decimal places, thousands separators, and explicit signs on deltas. A treasury
## showing "1,000" and a treasury showing "1000" in the same panel is the kind of detail
## that makes an interface feel unfinished.

## Format a currency amount, e.g. 12345.6 -> "12,346".
static func credits(value: float) -> String:
	return "%s" % _group(int(round(value)))


## Format a signed delta, always showing + or -, e.g. 12.4 -> "+12.4".
static func signed(value: float, places: int = 1) -> String:
	if value >= 0.0:
		return "+" + String.num(value, places)
	return String.num(value, places)


## Format a 0..1 ratio as a percentage, e.g. 0.35 -> "35%".
static func percent(ratio: float) -> String:
	return "%d%%" % int(round(ratio * 100.0))


## Format a plain float with a fixed number of places.
static func fixed(value: float, places: int = 1) -> String:
	return String.num(value, places)


## Format a signed delta in a colour: green for a surplus, amber for a deficit. Used for
## net income so the eye can find trouble without reading the sign.
static func signed_colored(value: float, places: int = 1) -> String:
	if value < -0.05:
		return "[color=#%s]%s[/color]" % [CC2Theme.AMBER.to_html(false), signed(value, places)]
	return "[color=#%s]%s[/color]" % [CC2Theme.PHOSPHOR.to_html(false), signed(value, places)]


## Thousands-separated integer. Godot has no built-in grouping, so do it by hand.
static func _group(value: int) -> String:
	var negative := value < 0
	var digits := str(absi(value))
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return "-" + out if negative else out


## Uppercase section heading with the box-drawing look the terminal aesthetic uses.
static func heading(text: String) -> String:
	return "-- %s " % text.to_upper() + "-".repeat(maxi(2, 44 - text.length()))


## A "label ....... value" readout line, the standard two-column form.
static func field(label: String, value: String, width: int = 18) -> String:
	return "%s %s" % [label.rpad(width), value]
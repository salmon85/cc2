extends Button
class_name EyeButton
## A button that draws an eye rather than printing one.
##
## The icon is geometry, not a glyph or an asset. Two reasons, both about this project
## specifically: the UI is built entirely in code with no texture pipeline for chrome (the one
## generated-texture path, `PlanetVisuals.export_texture`, exists to give each world a stable
## procedural sprite, which is a different job), and the fallback font carries no eye
## codepoint -- U+1F441 is an emoji and needs an emoji font, so a text button wearing one
## renders a tofu box in the default theme.
##
## Drawing it means the glyph is a real vector at whatever size the theme gives the button, so
## it stays sharp beside the dropdown and cannot drift out of step with the rest of the chrome.
##
## Everything button-shaped -- hover, press, disabled dimming, tooltip, focus -- is inherited,
## because this *is* a Button and only `_draw` is added.

## How the icon sits inside the button: a fraction of the shorter edge.
const ICON_FILL := 0.62

## Closed outline thickness, in pixels, kept readable down to a 16-pixel button.
const STROKE := 1.5


func _draw() -> void:
	var extent := minf(size.x, size.y) * ICON_FILL
	if extent <= 2.0:
		return
	var centre := size * 0.5
	var half_w := extent * 0.5
	var half_h := extent * 0.26
	var colour := CC2Theme.PHOSPHOR_DIM if disabled else (
		CC2Theme.WHITE_DIM if is_hovered() else CC2Theme.CYAN)

	# The almond, from two quadratic arcs meeting at the corners. A plain ellipse would be
	# cheaper and reads as a dot at 16 pixels; the corners are what make it an eye.
	var outline := PackedVector2Array()
	for i in 17:
		outline.append(_quad(
			centre + Vector2(-half_w, 0.0), centre + Vector2(0.0, -2.0 * half_h),
			centre + Vector2(half_w, 0.0), float(i) / 16.0))
	for i in range(1, 17):
		outline.append(_quad(
			centre + Vector2(half_w, 0.0), centre + Vector2(0.0, 2.0 * half_h),
			centre + Vector2(-half_w, 0.0), float(i) / 16.0))
	draw_polyline(outline, colour, STROKE, true)
	draw_circle(centre, maxf(1.0, extent * 0.12), colour)


## One point of a quadratic Bezier. Control point `mid` is placed at twice the bulge the
## curve should reach, because the curve only ever gets halfway to it at `t = 0.5`.
static func _quad(from: Vector2, mid: Vector2, to: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return u * u * from + 2.0 * u * t * mid + t * t * to
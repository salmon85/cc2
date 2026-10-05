extends RefCounted
class_name CC2Theme
## Retro-futuristic sci-fi Amiga terminal theme.
##
## The whole palette is built in code from `Color` and `StyleBoxFlat` so the client has no
## binary asset dependencies: it renders identically on any machine, at any stretch
## setting, from a text editor-readable source file.
##
## Palette rationale (Colonial Conquest II / Amiga terminal lineage):
##   - a near-black background with a faint green cast, the way a phosphor CRT bleeds
##   - phosphor green as the primary readout colour, the "everything is nominal" colour
##   - cyan as the secondary, used for structure and selection highlights
##   - amber as the alert colour, reserved for warnings and deficits
##   - red only for genuine failure, so it keeps its meaning

## --- Palette ---------------------------------------------------------------

const BG := Color(0.020, 0.039, 0.031)          ## #050A08 near-black, green cast
const BG_PANEL := Color(0.035, 0.063, 0.051)     ## #090F0D panel fill
const BG_SUNK := Color(0.012, 0.024, 0.020)      ## #020605 recessed readouts
const BORDER := Color(0.157, 0.408, 0.267)       ## #286844 dim frame
const BORDER_BRIGHT := Color(0.259, 0.643, 0.404) ## #42A467 active frame

const PHOSPHOR := Color(0.200, 1.000, 0.400)     ## #33FF66 primary readout
const PHOSPHOR_DIM := Color(0.129, 0.612, 0.278) ## #219C47 inactive readout
const CYAN := Color(0.400, 0.800, 1.000)         ## #66CCFF secondary
const CYAN_DIM := Color(0.208, 0.435, 0.545)     ## #356F8B
const AMBER := Color(1.000, 0.690, 0.000)        ## #FFB000 warning
const ALERT := Color(1.000, 0.290, 0.290)        ## #FF4A4A failure
const WHITE_DIM := Color(0.780, 0.855, 0.812)    ## body copy

## Per-faction identity colours, indexed by faction id modulo length. Chosen to stay
## legible against BG and to remain distinguishable in the common colour-vision
## deficiencies: the set alternates hue *and* lightness rather than hue alone.
const FACTION_COLORS: Array[Color] = [
	Color(0.200, 1.000, 0.400),   ## 0 phosphor green — the player
	Color(1.000, 0.690, 0.000),   ## 1 amber
	Color(0.400, 0.800, 1.000),   ## 2 cyan
	Color(1.000, 0.400, 0.560),   ## 3 magenta
	Color(0.600, 0.470, 1.000),   ## 4 violet
	Color(1.000, 0.470, 0.290),   ## 5 orange
	Color(0.400, 1.000, 0.780),   ## 6 aqua
	Color(0.900, 0.900, 0.400),   ## 7 yellow
]

## Spectral class colours, indexed by `Enums.StarClass` (M, K, G, F, A, B, O). These run
## from cool red dwarfs to hot blue giants, matching how the classes actually look.
const STAR_COLORS: Array[Color] = [
	Color(1.000, 0.780, 0.600),   ## M — orange dwarf
	Color(1.000, 0.850, 0.700),   ## K — orange-white
	Color(1.000, 1.000, 0.850),   ## G — yellow-white (Sol)
	Color(0.900, 0.940, 1.000),   ## F — white
	Color(0.800, 0.880, 1.000),   ## A — blue-white
	Color(0.700, 0.820, 1.000),   ## B — blue
	Color(0.650, 0.750, 1.000),   ## O — blue giant
]

## --- Metrics ---------------------------------------------------------------

## Map labels only. Smaller than `FONT_SMALL` because a star name sits next to a glyph on
## a dark field, where a plate used to be needed to keep it legible -- and the plate is
## gone. Bigger than nothing so the names still read at the default zoom.
const FONT_TINY := 9
const FONT_SMALL := 11
const FONT_BODY := 13
const FONT_HEAD := 16
const FONT_BIG := 22
const PANEL_PAD := 8
const BORDER_W := 1


## Colour assigned to a faction id. Unknown ids fall back to a neutral grey so an
## out-of-range faction still renders instead of erroring.
static func faction_color(faction_id: int) -> Color:
	if faction_id < 0:
		return Color(0.45, 0.50, 0.47)
	return FACTION_COLORS[faction_id % FACTION_COLORS.size()]


## Colour assigned to a spectral class ordinal, clamped to the table.
static func star_color(star_class: int) -> Color:
	if star_class < 0:
		return STAR_COLORS[2]
	return STAR_COLORS[clampi(star_class, 0, STAR_COLORS.size() - 1)]


## Palette for a planet, chosen from the id hash of its `PlanetTypeData`.
##
## Bodies are the map's new primary markers -- a hundred planets rather than a hundred
## stars -- so they need to be distinguishable from each other at a glance without any
## class semantics. A stable hash gives every type its own colour forever, across saves,
## which matters because the id is all that survives serialisation.
const PLANET_COLORS: Array[Color] = [
	Color(0.800, 0.520, 0.360),   ## rust
	Color(0.400, 0.720, 0.560),   ## verdant
	Color(0.400, 0.560, 0.820),   ## ocean
	Color(0.860, 0.780, 0.440),   ## desert
	Color(0.640, 0.520, 0.780),   ## ice-violet
	Color(0.820, 0.460, 0.460),   ## molten
	Color(0.560, 0.640, 0.480),   ## barren
	Color(0.480, 0.480, 0.540),   ## rock
]


## Colour for a planet of `type_id`. Falls back to a neutral grey for an empty or
## unknown id, so a body whose definition failed to load still renders.
static func planet_color(type_id: StringName) -> Color:
	if type_id == &"":
		return Color(0.50, 0.54, 0.52)
	var key := str(type_id)
	return PLANET_COLORS[absi(key.hash()) % PLANET_COLORS.size()]


## A flat, square-cornered box. The Amiga look has no rounded corners and no gradients,
## so every surface in this theme is a StyleBoxFlat with a 1px border.
static func box(
	fill: Color, border: Color, width: int = BORDER_W, pad: int = PANEL_PAD
) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(width)
	sb.set_corner_radius_all(0)
	sb.content_margin_left = pad
	sb.content_margin_right = pad
	sb.content_margin_top = pad
	sb.content_margin_bottom = pad
	sb.anti_aliasing = false
	return sb


## The recessed fill used behind numeric readouts, so numbers sit "inside" the panel.
static func sunk(fill: Color = BG_SUNK, border: Color = BORDER) -> StyleBoxFlat:
	var sb := box(fill, border)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	return sb


## Build the application theme. Returns a fresh Theme each call so callers may mutate it.
static func build() -> Theme:
	var theme := Theme.new()

	# --- Labels -------------------------------------------------------------
	theme.set_color("font_color", "Label", PHOSPHOR)
	theme.set_color("font_outline_color", "Label", BG)
	theme.set_constant("outline_size", "Label", 0)
	theme.set_font_size("font_size", "Label", FONT_BODY)

	# --- Panel --------------------------------------------------------------
	theme.set_stylebox("panel", "Panel", box(BG_PANEL, BORDER))

	# --- PanelContainer (the framed boxes the layout is built from) ---------
	theme.set_stylebox("panel", "PanelContainer", box(BG_PANEL, BORDER))
	theme.set_stylebox("panel", "PanelContainer", box(BG_PANEL, BORDER, BORDER_W, 6))

	# --- Buttons ------------------------------------------------------------
	theme.set_stylebox("normal", "Button", box(BG_SUNK, BORDER))
	theme.set_stylebox("hover", "Button", box(BG_PANEL, BORDER_BRIGHT))
	theme.set_stylebox("pressed", "Button", box(Color(0.08, 0.16, 0.12), PHOSPHOR))
	theme.set_stylebox("focus", "Button", box(Color(0, 0, 0, 0), BORDER_BRIGHT))
	theme.set_stylebox("disabled", "Button", box(BG_SUNK, Color(0.10, 0.14, 0.12)))
	theme.set_color("font_color", "Button", PHOSPHOR)
	theme.set_color("font_hover_color", "Button", Color(0.65, 1.0, 0.75))
	theme.set_color("font_pressed_color", "Button", BG)
	theme.set_color("font_disabled_color", "Button", PHOSPHOR_DIM)
	theme.set_font_size("font_size", "Button", FONT_BODY)

	# --- Sliders ------------------------------------------------------------
	# The grabber is a square block and the track a 4px sunken rule, so a slider reads
	# as a machined control rather than a rounded mobile widget.
	theme.set_stylebox("slider", "HSlider", sunk())
	theme.set_stylebox("grabber_area", "HSlider", box(CYAN_DIM, CYAN_DIM, 0, 0))
	theme.set_stylebox("grabber_area_highlight", "HSlider", box(CYAN, CYAN, 0, 0))
	theme.set_constant("center_grabber", "HSlider", 1)
	theme.set_icon("grabber", "HSlider", _slider_grabber())

	# --- Progress bar -------------------------------------------------------
	theme.set_stylebox("background", "ProgressBar", sunk())
	theme.set_stylebox("fill", "ProgressBar", box(CYAN_DIM, CYAN_DIM, 0, 0))

	# --- Option / check buttons --------------------------------------------
	theme.set_stylebox("normal", "OptionButton", box(BG_SUNK, BORDER))
	theme.set_stylebox("hover", "OptionButton", box(BG_PANEL, BORDER_BRIGHT))
	theme.set_stylebox("pressed", "OptionButton", box(Color(0.08, 0.16, 0.12), PHOSPHOR))
	theme.set_color("font_color", "OptionButton", PHOSPHOR)
	theme.set_font_size("font_size", "OptionButton", FONT_BODY)

	theme.set_color("font_color", "CheckBox", PHOSPHOR)
	theme.set_font_size("font_size", "CheckBox", FONT_BODY)

	# --- Scroll containers --------------------------------------------------
	theme.set_stylebox("panel", "ScrollContainer", box(BG_PANEL, BORDER, BORDER_W, 0))
	theme.set_stylebox("scroll", "VScrollBar", sunk(BG_SUNK, BORDER))
	theme.set_stylebox("grabber", "VScrollBar", box(CYAN_DIM, CYAN_DIM, 0, 0))
	theme.set_stylebox("grabber_highlight", "VScrollBar", box(CYAN, CYAN, 0, 0))

	# --- Popup menu (used by OptionButton) ----------------------------------
	theme.set_stylebox("panel", "PopupMenu", box(BG_PANEL, BORDER_BRIGHT))
	theme.set_color("font_color", "PopupMenu", PHOSPHOR)
	theme.set_color("font_hover_color", "PopupMenu", Color(0.65, 1.0, 0.75))
	theme.set_font_size("font_size", "PopupMenu", FONT_BODY)

	# --- Rich text ----------------------------------------------------------
	theme.set_color("default_color", "RichTextLabel", PHOSPHOR)
	theme.set_font_size("normal_font_size", "RichTextLabel", FONT_SMALL)
	theme.set_font_size("bold_font_size", "RichTextLabel", FONT_BODY)
	theme.set_stylebox("normal", "RichTextLabel", box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 0))

	# --- Separator ----------------------------------------------------------
	var sep := StyleBoxLine.new()
	sep.color = BORDER
	sep.thickness = 1
	theme.set_stylebox("separator", "HSeparator", sep)
	theme.set_stylebox("separator", "VSeparator", sep)

	return theme


## A small square grabber image, drawn in code so no texture file is needed.
static func _slider_grabber() -> ImageTexture:
	var size := 10
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	# 1px cyan frame, phosphor centre, so the grabber matches the rest of the chrome.
	for y in size:
		for x in size:
			var edge := x == 0 or y == 0 or x == size - 1 or y == size - 1
			if edge:
				img.set_pixel(x, y, CYAN)
			else:
				img.set_pixel(x, y, PHOSPHOR)
	return ImageTexture.create_from_image(img)


## Apply the theme to a control and its descendants.
static func apply(control: Control) -> void:
	var t := build()
	control.theme = t
	# Children that already carry their own theme would otherwise keep it; clearing the
	# override lets the inherited theme reach them.
	for child in control.find_children("*", "Control", true, false):
		(child as Control).theme = null
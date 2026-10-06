extends RefCounted
class_name SessionController
## Owns the authoritative game state and mediates every action the player can take.
##
## This is the single seam between the presentation layer and the simulation. The panels
## never touch `GalaxyState` directly; they call methods here, and read back through the
## accessors. Phase 6 will replace the internals with a network authority that ships the
## same calls to a server, and the panels will not need to change.
##
## Everything here is deterministic: one seeded RNG, one order queue, and exactly the
## same `TurnResolver` the headless server runs.

## Emitted after a turn resolves, with the report from `TurnResolver.resolve_turn`.
signal turn_resolved(report: Dictionary)

## Emitted whenever any displayed value may have changed. Panels use this to refresh
## rather than polling every frame.
signal state_changed

## Emitted when an action is refused, so the client can show why instead of silently
## doing nothing — the same "guards return a reason" discipline the Phase 4 tests use.
signal action_rejected(reason: String)

## Seeded simulation RNG. Shared with the resolver so a save/load resumes the stream.
var rng: RandomNumberGenerator = null

## The authoritative state.
var galaxy: GalaxyState = null

## Orders staged for the coming turn.
var queue: OrderQueue = null

## Definition registry and tuning constants, resolved from the autoloads.
var defs: Node = null
var db: Node = null

## Faction the local player controls.
var player_id: int = 0

## Selected system index on the map, or -1.
var selected_system: int = -1

## Selected planet index in the inspector, or -1.
var selected_planet: int = -1

## Selected fleet id, or -1.
var selected_fleet: int = -1

## Last turn report, kept so the client can render a turn summary after the fact.
var last_report: Dictionary = {}


func _init() -> void:
	rng = RandomNumberGenerator.new()


## Point the controller at a galaxy. Binds definitions so tech and hull lookups resolve.
func attach(new_galaxy: GalaxyState, player_faction: int = 0) -> bool:
	if new_galaxy == null:
		action_rejected.emit("no galaxy to attach")
		return false
	galaxy = new_galaxy
	player_id = player_faction
	queue = OrderQueue.new()
	_resolve_autoloads()
	if defs != null and not galaxy.rebind_definitions(defs):
		# Not fatal: a galaxy may legitimately reference an id the registry no longer
		# ships, and the rest of the state is still playable. Surface it once.
		action_rejected.emit("galaxy references unknown definitions")
	rng.seed = galaxy.seed_value
	if rng.seed == 0:
		rng.randomize()
	state_changed.emit()
	return true


func _resolve_autoloads() -> void:
	# `Engine.get_main_loop()` returns null while the tree is still initialising, so ask
	# through a node where possible; a detached controller simply leaves them unresolved
	# and the guards downstream report it rather than crashing.
	var loop := Engine.get_main_loop()
	var tree := loop as SceneTree
	if tree == null:
		return
	if defs == null:
		defs = tree.root.get_node_or_null(NodePath("Defs"))
	if db == null:
		db = tree.root.get_node_or_null(NodePath("GameDB"))


# --- Queries ---------------------------------------------------------------

## The player's faction, or null.
func player() -> FactionState:
	if galaxy == null:
		return null
	return galaxy.faction(player_id)


## Every fleet the player owns, in stable id order.
func player_fleets() -> Array[FleetState]:
	if galaxy == null:
		return [] as Array[FleetState]
	var out := galaxy.fleets_of(player_id)
	out.sort_custom(func(a: FleetState, b: FleetState) -> bool: return a.id < b.id)
	return out


## The selected fleet, or null.
func fleet() -> FleetState:
	if galaxy == null or selected_fleet < 0:
		return null
	return galaxy.fleet(selected_fleet)


## Planets the player has colonised, in stable index order.
func player_colonies() -> Array[PlanetState]:
	if galaxy == null:
		return [] as Array[PlanetState]
	var out := galaxy.colonies_of(player_id)
	out.sort_custom(func(a: PlanetState, b: PlanetState) -> bool: return a.index < b.index)
	return out


## Whether the player may currently see a system. Unknown systems are never visible.
func can_see(system_index: int) -> bool:
	if galaxy == null or system_index < 0:
		return false
	return FowStage.can_see(galaxy, player_id, system_index)


## The system a planet sits in, or -1.
##
## `PlanetState` deliberately does not cache its system, so this walks `planet_indices`.
## It is only ever called for the one body the player has selected, so the cost is a
## single pass and a second cache would be a place for the two to disagree.
func system_of_planet(planet_index: int) -> int:
	if galaxy == null or planet_index < 0:
		return -1
	for s in galaxy.systems:
		if s.planet_indices.has(planet_index):
			return s.index
	return -1


## Whether the player is entitled to see who owns a system.
##
## Two cases qualify, and only two:
##   - it is the player's own system, which they of course know; or
##   - the player has a fleet actually parked there, which is the same "my ships are
##     sitting in it" knowledge a real player would have.
##
## A fleet merely *heading* somewhere does not count. It reveals the origin now and the
## destination when it arrives, which is the information a player is entitled to -- not
## a permanent mark on every system within sensor range.
##
## "Parked there" is now "parked on a world that orbits there". Fleets sit on planets, and
## with one system every fleet in the game orbits the star, so the test has to be about
## which body a ship is over rather than about which system -- otherwise the answer is
## trivially yes for the entire galaxy and the rule stops filtering anything.
##
## An unowned system is always "known": there is no owner to reveal, and rendering the
## neutral form is what makes empty space read as empty rather than as redacted.
##
## This lives here rather than in the map view because it is not only a drawing rule.
## Every panel that renders ownership has to agree on it, and two copies of "own empire
## or own fleet in orbit" is how the map stopped leaking while the inspector went on
## reporting each empire's holdings.
func knows_owner_of(system_index: int) -> bool:
	if galaxy == null or system_index < 0:
		return false
	var sys := galaxy.system(system_index)
	if sys == null:
		return false
	if sys.owner < 0:
		return true
	if sys.owner == player_id:
		return true
	# A fleet parked on a world in this system counts as presence. A fleet merely sailing
	# to it does not: `destination` set means the fleet is under way and has not settled
	# anywhere yet.
	#
	# "In this system" is deliberately narrow. With one system every world resolves here,
	# so a broader reading -- "a ship of mine is anywhere at all" -- would make the rule
	# vacuous and turn the entire map into a known-object map the moment a player launched
	# one ship. The first body of the system is the one that can be occupied; a ship on any
	# other world in the same system does not stand in for it.
	var first := _first_planet_of(system_index)
	if first < 0:
		return false
	for key: int in galaxy.fleets:
		var f: FleetState = galaxy.fleets[key]
		if f.active and f.owner == player_id and f.destination < 0 and f.system == first:
			return true
	return false


## Whether the player is entitled to a planet's *catalogue name*.
##
## Separate from `knows_owner_of`, which asks who owns a world, and from the inspector's
## economy gate, which asks what is built on it. The name is its own leak: it is a free
## fact about a world the player has never visited, it is stable across turns, and it is
## what a player uses to refer to a place before they know anything about it. A map of
## named rivals' worlds is a map somebody has already scouted.
##
## So the bar is deliberately the strictest of the three: the player owns the world, or has
## a fleet parked on that specific world. `surveyed` does not count here even though it
## counts for the economy -- a survey records what the world *is*, not what somebody named
## it, and letting a survey through would re-expose every name the moment a scout's sweep
## lit up a neighbouring orbit.
func knows_name_of(planet_index: int) -> bool:
	if galaxy == null or planet_index < 0:
		return false
	var p := galaxy.planet(planet_index)
	if p == null:
		return false
	if p.owner == player_id:
		return true
	for key: int in galaxy.fleets:
		var f: FleetState = galaxy.fleets[key]
		if f.active and f.owner == player_id and f.destination < 0 \
				and f.system == planet_index:
			return true
	return false


## Shown in place of the name of a world the player is not entitled to.
##
## Lives here rather than in the panel or the map, because the rule is the controller's and
## every caller must reach the same verdict -- a name the map will not draw but the log will
## print is still a leak, and the log is where a player looks when they are not sure what
## they just clicked.
const UNKNOWN_NAME := "Unknown Planet"


## A world's display name, or the fog placeholder.
##
## The `knows_name_of` gate and the formatting are bound together here so the map marker,
## the inspector heading and the selection log cannot drift apart. All three previously
## re-derived the fallback themselves: the map said "Unknown Planet", the panel said
## "Unknown Planet", and the log said the real name -- the one reader that was leaking did
## so precisely because nobody had put all three on one function.
##
## The `P-N` fallback is position-derived, not a real name, so a world nobody named still
## has a stable handle without revealing anything the player could not count off the bodies
## they can already see.
func display_name(planet_index: int) -> String:
	if galaxy == null:
		return UNKNOWN_NAME
	var p := galaxy.planet(planet_index)
	if p == null:
		return UNKNOWN_NAME
	if not knows_name_of(planet_index):
		return UNKNOWN_NAME
	if p.name != "":
		return p.name
	return "P-%d" % (p.index + 1)


## The lowest-indexed body in `system_index`, or -1. With one system this is planet 0.
func _first_planet_of(system_index: int) -> int:
	var sys := galaxy.system(system_index) if galaxy != null else null
	if sys == null or sys.planet_indices.is_empty():
		return -1
	return sys.planet_indices[0]


## Orders the player has staged but not yet submitted.
func pending_orders() -> Array[Order]:
	if queue == null:
		return [] as Array[Order]
	return queue.orders_for(player_id)


# --- Selection -------------------------------------------------------------

func select_system(index: int) -> void:
	if galaxy == null:
		return
	if index < 0 or galaxy.system(index) == null:
		action_rejected.emit("no such system")
		return
	selected_system = index
	# Selecting a system selects its first body, so the inspector is never blank when
	# it could show something useful.
	selected_planet = -1
	var sys: SystemState = galaxy.system(index)
	if sys != null and sys.planet_indices.size() > 0:
		selected_planet = sys.planet_indices[0]
	state_changed.emit()


## Select a planet. The map calls this on every body click now, so the selected system
## follows the planet rather than the other way round: the inspector's top section is the
## world, and a body whose system disagrees with the selection would show the star's
## details above the planet's.
func select_planet(index: int) -> void:
	if galaxy == null:
		return
	if galaxy.planet(index) == null:
		action_rejected.emit("no such planet")
		return
	selected_planet = index
	for sys in galaxy.systems:
		if sys.planet_indices.has(index):
			selected_system = sys.index
			break
	state_changed.emit()


func select_fleet(id: int) -> void:
	if galaxy == null:
		return
	var target := galaxy.fleet(id)
	if target == null or not target.active:
		action_rejected.emit("no such fleet")
		return
	if target.owner != player_id:
		action_rejected.emit("that fleet is not yours")
		return
	selected_fleet = id
	# A fleet sits on a planet now; `target.system` is that planet's index. Keep the
	# selection consistent with it so the inspector shows the world the fleet is over.
	selected_planet = target.system
	for sys in galaxy.systems:
		if sys.planet_indices.has(target.system):
			selected_system = sys.index
			break
	state_changed.emit()


# --- Player actions --------------------------------------------------------

## Whether `queue_move` would accept this destination for the selected fleet.
##
## Split out because the map asks this *before* offering to confirm. A proposal the player
## could never commit should never reach the prompt -- showing "CONFIRM" on an order that
## is guaranteed to be refused teaches the player that the button does not work.
##
## Silent by design: this is a question, not an action, and emitting `action_rejected` here
## would fire the log's refusal message for a click the player is still in the middle of.
func can_queue_move(target_planet: int) -> bool:
	var f := fleet()
	if f == null:
		return false
	if galaxy == null or galaxy.planet(target_planet) == null:
		return false
	if not f.active:
		return false
	if f.destination >= 0:
		return false
	return target_planet != f.system


## Queue a move for the selected fleet. Returns false and explains when refused.
##
## `target_planet` is a planet index. Fleets used to move between star systems; there is one
## system now, so the map's destinations are worlds and the fleet ends up parked on the
## planet the player clicked.
func queue_move(target_planet: int) -> bool:
	var f := fleet()
	if f == null:
		action_rejected.emit("select a fleet first")
		return false
	if galaxy == null or galaxy.planet(target_planet) == null:
		action_rejected.emit("no such destination")
		return false
	if not f.active:
		action_rejected.emit("that fleet has been destroyed")
		return false
	if f.destination >= 0:
		action_rejected.emit("that fleet is already in transit")
		return false

	var order := Order.make_move_fleet(player_id, f.id, target_planet)
	if queue.submit(order):
		# Keep the in-flight mirror in step so the map draws the transit line immediately
		# rather than only after the turn resolves.
		MovementStage.issue_move(galaxy, f.id, player_id, target_planet)
		state_changed.emit()
		return true
	action_rejected.emit("the order was refused")
	return false


## Queue a structure for the selected colony. `building_id` must be a known building the
## faction has unlocked and the colony is allowed to add.
##
## There is deliberately no metal gate. The colony is not asked to have the full cost banked
## before it may commit to a project: construction draws the colony's metal out of storage a
## slice each turn, so a colony with an empty bank and four mines can still start a City
## Complex and pay for it over the turns that follow. Gating on the balance made construction
## impossible for a young colony -- exactly the colony whose mines are about to produce the
## metal -- and it made the "no upfront payment" rule a UI convention rather than a rule.
##
## Power is the one thing that can still block a build, and it blocks *new* structures only.
## `can_supply_power` is the same test the resolver applies, so the button and the order cannot
## disagree.
func queue_build_structure(building_id: StringName) -> bool:
	var planet := _selected_owned_planet()
	if planet == null:
		return false
	var me := player()
	if me == null:
		return false
	if not me.unlocked_buildings.has(building_id):
		action_rejected.emit("you cannot build that structure yet")
		return false
	if defs == null:
		action_rejected.emit("definitions are not loaded")
		return false
	var def: Resource = defs.building(building_id) as Resource
	if def == null:
		action_rejected.emit("unknown structure")
		return false
	if not def.can_add(planet.count(building_id)):
		action_rejected.emit("this colony is already at its limit")
		return false
	if def.draws_power():
		var needed := float(def.get("power_required"))
		if not planet.can_supply_power(needed):
			action_rejected.emit("this colony cannot supply the power that structure needs")
			return false
	# Exactly one building per turn per planet.
	if not planet.building_queue.is_empty():
		action_rejected.emit("this colony is already building something")
		return false

	var order := Order.make_build_structure(player_id, planet.index, building_id, 1)
	if queue.submit(order):
		# Applied at press time as well as staged, so the progress bar appears on this frame
		# rather than when the order resolves at the end of the turn. A player who pressed
		# Build and saw no bar would press it again.
		#
		# Applying twice is harmless: `_apply_build_structure` refuses to touch a colony whose
		# slot is already full, so the resolver's pass over the same order finds the work done
		# and does nothing. That is the same mirror-the-move idiom `queue_move` uses.
		TurnResolver.apply_build_structure(galaxy, player(), order, defs, db)
		state_changed.emit()
		return true
	action_rejected.emit("the order was refused")
	return false


## Queue a hull for the selected colony's Space Port.
##
## Delegates the legality question to `TurnResolver.can_build_ship` rather than restating
## it. The rules are the Space Port requirement, the `PER_TURN` production floor and the
## power check, and a second copy of them in the client is a second copy that can drift.
func queue_build_ship(hull_id: StringName) -> bool:
	var planet := _selected_owned_planet()
	if planet == null:
		return false
	var me := player()
	if me == null:
		return false
	# A Space Port on this world hands over the six baseline hulls with no research and no
	# milestone, so the unlock check asks the resolver rather than reading the faction's
	# unlock set -- otherwise the port would be a button that refuses.
	if not TurnResolver.hull_available(planet, hull_id, me):
		action_rejected.emit("that hull is not available at this colony")
		return false
	if defs == null:
		action_rejected.emit("definitions are not loaded")
		return false
	var hull: Resource = defs.ship_hull(hull_id) as Resource
	if hull == null:
		action_rejected.emit("unknown hull")
		return false
	if planet.count(&"space_port") <= 0:
		action_rejected.emit("this colony has no Space Port")
		return false
	if not TurnResolver.can_build_ship(planet, hull, me, db):
		action_rejected.emit("this colony cannot start that hull")
		return false

	var order := Order.make_build_ship(player_id, planet.index, hull_id)
	if queue.submit(order):
		# Mirrored at press time, for the shipyard bar's sake, exactly as a structure is.
		TurnResolver.apply_build_ship(galaxy, player(), order, defs, db)
		state_changed.emit()
		return true
	action_rejected.emit("the order was refused")
	return false


## Land the selected fleet's Colony Ship on the world it is parked over.
##
## The Colony Ship is the one structure that cannot be built: it flies here and is consumed on
## arrival, leaving the housing, food, metal and power a landed colony ship provides. Returns
## false and explains when the fleet has no kit, is under way, or the world already has one.
func land_colony_ship() -> bool:
	var f := fleet()
	if f == null:
		action_rejected.emit("select a fleet first")
		return false
	if f.destination >= 0:
		action_rejected.emit("that fleet is under way")
		return false
	var planet: PlanetState = null
	if galaxy != null:
		planet = galaxy.planet(f.system) as PlanetState
	if planet == null:
		action_rejected.emit("that fleet is not parked over a world")
		return false
	var faction := player()
	if faction == null:
		return false
	if not InvasionStage.land_colony_ship(galaxy, f, planet, faction):
		if not f.has_colony_ship():
			action_rejected.emit("that fleet carries no Colony Ship")
		elif planet.colonized:
			action_rejected.emit("that world is already settled")
		else:
			action_rejected.emit("that world already has a landed Colony Ship")
		return false
	state_changed.emit()
	return true


## Whether the selected fleet could land its Colony Ship right now.
##
## A question rather than an action, so the fleet panel's button can be disabled with a reason
## instead of offering something that is guaranteed to be refused.
func can_land_colony_ship() -> bool:
	var f := fleet()
	if f == null or galaxy == null or f.destination >= 0 or f.system < 0:
		return false
	return InvasionStage.can_land_colony_ship(f, galaxy.planet(f.system))


## Convert one civilian on the selected colony into one troop.
##
## Costs a pop and needs a Barracks, and it is the only route to troops: the barracks is not
## a production building that yields troops, it is a converter. That is what the design
## document specifies, and it is what makes population a military resource as well as an
## economic one.
func queue_recruit_troop() -> bool:
	var planet := _selected_owned_planet()
	if planet == null:
		return false
	if planet.count(&"barracks") <= 0:
		action_rejected.emit("this colony has no Barracks")
		return false
	if planet.population < 1.0:
		action_rejected.emit("no civilians left to convert")
		return false
	if queue.submit(Order.make_recruit_troop(player_id, planet.index)):
		state_changed.emit()
		return true
	action_rejected.emit("the order was refused")
	return false


## Transfer `metals` from the selected colony's storage against its construction.
##
## One half of the metal dialog; `refund_construction` is the other. Works on a structure or a
## hull -- whichever is in the build slot -- because from the player's side they are the same
## decision. Clamped to what the colony holds *and* to what the project still owes, so the
## caller cannot overpay by accident.
func boost_construction(metals: float) -> float:
	var planet := _selected_owned_planet()
	if planet == null:
		return 0.0
	if ColonySim.project_kind(planet) == ColonySim.ProjectKind.NONE:
		action_rejected.emit("nothing is under construction")
		return 0.0
	var spent := ColonySim.boost_construction(
		planet, metals, _building_table(), _hull_table())
	if spent <= 0.0:
		action_rejected.emit("nothing more to spend on this project")
		return 0.0
	state_changed.emit()
	return spent


## Pull `metals` back out of the selected colony's construction and into its storage.
##
## The mirror of `boost_construction`. Bounded by what is banked against the project and by
## nothing else, so "take it all out" always works and the bar returns to zero.
func refund_construction(metals: float) -> float:
	var planet := _selected_owned_planet()
	if planet == null:
		return 0.0
	if ColonySim.project_kind(planet) == ColonySim.ProjectKind.NONE:
		action_rejected.emit("nothing is under construction")
		return 0.0
	var returned := ColonySim.refund_construction(planet, metals)
	if returned <= 0.0:
		action_rejected.emit("no metal is assigned to this project")
		return 0.0
	state_changed.emit()
	return returned


## The building registry, or an empty dictionary when the autoload is missing.
##
## Passed as an empty table rather than null so `ColonySim` degrades to the unbounded clamp in
## a bare headless run, instead of refusing every boost.
func _building_table() -> Dictionary:
	if defs == null:
		return {} as Dictionary
	return defs.get("buildings") as Dictionary


## The hull registry, or an empty dictionary when the autoload is missing.
func _hull_table() -> Dictionary:
	if defs == null:
		return {} as Dictionary
	return defs.get("ship_hulls") as Dictionary


## Choose single-project or per-turn ship production on the selected colony.
func set_build_mode(planet_index: int, mode: int) -> bool:
	var planet: PlanetState = null
	if galaxy != null:
		planet = galaxy.planet(planet_index) as PlanetState
	if planet == null or planet.owner != player_id:
		action_rejected.emit("select one of your colonies first")
		return false
	planet.build_mode = mode
	if queue.submit(Order.make_set_build_mode(player_id, planet_index, mode)):
		state_changed.emit()
		return true
	return false


## Load `amount` of `kind` from the selected fleet's world into its holds.
func load_cargo(kind: StringName, amount: float) -> float:
	var f := fleet()
	if f == null:
		action_rejected.emit("select a fleet first")
		return 0.0
	var planet := _fleet_planet()
	if planet == null:
		return 0.0
	var moved := TransferStage.load(planet, f, kind, amount)
	if moved <= 0.0:
		action_rejected.emit("nothing to load")
		return 0.0
	state_changed.emit()
	return moved


## Unload `amount` of `kind` from the selected fleet onto the world it is over.
func unload_cargo(kind: StringName, amount: float) -> float:
	var f := fleet()
	if f == null:
		action_rejected.emit("select a fleet first")
		return 0.0
	var planet := _fleet_planet()
	if planet == null:
		return 0.0
	var moved := TransferStage.unload(planet, f, kind, amount)
	if moved <= 0.0:
		action_rejected.emit("nothing to unload")
		return 0.0
	state_changed.emit()
	return moved


## The world the selected fleet is parked over, or null.
##
## Cargo moves between a fleet and the surface, so it needs the world and not the fleet. A
## fleet under way has no world to move cargo with, which is the same reason it cannot survey.
func _fleet_planet() -> PlanetState:
	var f := fleet()
	if f == null or galaxy == null or f.destination >= 0 or f.system < 0:
		action_rejected.emit("that fleet is not parked over a world")
		return null
	var planet: PlanetState = galaxy.planet(f.system)
	if planet == null or planet.owner != player_id or not planet.colonized:
		action_rejected.emit("that fleet is not over one of your colonies")
		return null
	return planet


## Set the imperial tax rate, 0..1.
##
## Retained for wire compatibility only. Phase 8 removed the tax slider and the tax UI, and
## `TurnResolver` ignores the resulting order, so this now stages an order that does
## nothing. Old tests and old clients call it; nothing in the game does.
func set_tax_rate(rate: float) -> bool:
	var me := player()
	if me == null:
		return false
	me.tax_rate = clampf(rate, 0.0, 1.0)
	if queue.submit(Order.make_set_tax(player_id, me.tax_rate)):
		state_changed.emit()
		return true
	return false


## Set the research split.
##
## Inert as of Phase 8, for the same reason as `set_tax_rate`: research is population-driven
## and the allocation sliders are gone. Kept so an old client does not fail to parse.
func set_research_allocation(weights: PackedFloat64Array) -> bool:
	var me := player()
	if me == null:
		return false
	var total := 0.0
	for w in weights:
		total += maxf(0.0, w)
	if total <= 0.0:
		action_rejected.emit("research allocation must not sum to zero")
		return false
	var normalised := PackedFloat64Array()
	for w in weights:
		normalised.append(maxf(0.0, w) / total)
	if queue.submit(Order.make_set_research(player_id, normalised)):
		for i in 4:
			me.research_allocation[i] = normalised[i]
		state_changed.emit()
		return true
	return false


## Send a chosen set of ships from their world to `target_planet`.
##
## `ships` is a `{hull_id: count}` manifest; an empty one means the whole fleet. This is what
## the travel modal's OK button submits, and it is a `TRAVEL` order rather than a `MOVE_FLEET`
## one so that the partial-manifest case travels on the wire as what it is.
func queue_travel(target_planet: int, ships: Dictionary = {}, fleet_id: int = -1) -> bool:
	# `fleet_id` names the source orbit explicitly. The travel flow gets to this point by the
	# player picking a *world* and then some of the ships over it, so the fleet those ships
	# belong to was never selected in the ordinary sense -- and reading the selection here
	# would dispatch whatever happened to be selected rather than what the player chose.
	var f: FleetState = null
	if fleet_id >= 0:
		f = galaxy.fleet(fleet_id) if galaxy != null else null
	else:
		f = fleet()
	if f == null:
		action_rejected.emit("select a fleet first")
		return false
	if f.owner != player_id:
		action_rejected.emit("that fleet is not yours")
		return false
	if galaxy == null or galaxy.planet(target_planet) == null:
		action_rejected.emit("no such destination")
		return false
	if not f.active:
		action_rejected.emit("that fleet has been destroyed")
		return false
	if f.destination >= 0:
		action_rejected.emit("that fleet is already in transit")
		return false
	if target_planet == f.system:
		action_rejected.emit("that fleet is already there")
		return false

	var order := Order.make_travel(player_id, f.id, target_planet, ships)
	if queue.submit(order):
		# Mirror onto the live galaxy so the map draws the transit line immediately rather
		# than only after the turn resolves.
		MovementStage.issue_move(galaxy, f.id, player_id, target_planet)
		state_changed.emit()
		return true
	action_rejected.emit("the order was refused")
	return false


# --- Orbits, cargo, and the travel flow --------------------------------------

## Fleets the player has parked over `planet_index`, in stable id order.
##
## The travel flow's "Select Source Location" step asks for a *world*, not a fleet: a player
## clicking a body means "the ships I have there", and which of several fleets that is is an
## implementation detail they were never shown.
func fleets_in_orbit_at(planet_index: int) -> Array[FleetState]:
	if galaxy == null or planet_index < 0:
		return [] as Array[FleetState]
	return galaxy.fleets_in_orbit_at(planet_index, player_id)


## The lowest-id fleet parked over `planet_index`, or null.
##
## The one the travel flow dispatches from and the one the panels adopt afterwards, so that
## selecting a transit fleet shows the player the ships that are leaving rather than the ones
## that stayed behind.
func orbital_fleet(planet_index: int) -> FleetState:
	if galaxy == null:
		return null
	return galaxy.orbital_fleet(planet_index, player_id)


## Whether `planet_index` is a legal travel source: a real world with at least one of the
## player's own ships in orbit.
##
## A question rather than an action, so the travel flow can tell the player why a click did
## not advance the workflow instead of silently ignoring the click.
func can_travel_from(planet_index: int) -> bool:
	return not fleets_in_orbit_at(planet_index).is_empty()


## Every hull the player has in orbit over `planet_index`, as `{hull_id: count}`.
##
## The union across the world's fleets, which is what the manifest modal lists: a player sees
## "2 Corvettes" whether they are in one fleet or two.
func hulls_in_orbit_at(planet_index: int) -> Dictionary:
	var out: Dictionary = {}
	for f in fleets_in_orbit_at(planet_index):
		for hull_id: StringName in f.ships:
			out[hull_id] = int(out.get(hull_id, 0)) + int(f.ships[hull_id])
	return out


## Whether the player has a Cargo Transport, Troop Transport or Colony Ship over this world.
##
## The Load/Unload button's visibility rule. It is about the *ships in orbit*, not about the
## selected fleet: the control is opened from a planet, and a transport sitting over the
## planet is what the player wants to use whether or not they happened to click it first.
func has_transports_at(planet_index: int) -> bool:
	for hull_id: StringName in hulls_in_orbit_at(planet_index):
		if GameDB.LOGISTIC_HULLS.has(hull_id):
			return true
	return false


## Move `amount` of `kind` between `planet_index`'s stockpiles and the transports in its orbit.
##
## Keyed on the planet rather than on the selected fleet, because the dialog the player opened
## is about a world and its orbit. `hull_id` names *which* transport in that orbit; an empty
## one means the whole orbital lift, which is what "load everything" means when a colony has
## only one Cargo Transport.
##
## Changes are applied on OK rather than on every slider move, so a half-finished dialog leaves
## nothing behind -- the same rule the travel manifest follows.
func transfer_at_planet(
	planet_index: int, hull_id: StringName, kind: StringName, amount: float, loading: bool
) -> float:
	var planet := _owned_colony(planet_index)
	if planet == null:
		return 0.0
	var lifts := _transports_at(planet_index, hull_id, kind)
	if lifts.is_empty():
		action_rejected.emit("no transport in orbit here lifts that")
		return 0.0
	var moved := 0.0
	for f in lifts:
		if moved >= amount:
			break
		var step := amount - moved
		if loading:
			moved += TransferStage.load(planet, f, kind, step)
		else:
			moved += TransferStage.unload(planet, f, kind, step)
	if moved <= 0.0:
		action_rejected.emit("nothing to load" if loading else "nothing to unload")
		return 0.0
	state_changed.emit()
	return moved


## The transports in orbit over `planet_index` that lift `kind`.
##
## A single-membership `Array` so the loop over it keeps a concrete element type; a `Variant`
## array is exactly the sort of thing that turns into a runtime cast error three files away.
func _transports_at(
	planet_index: int, hull_id: StringName, kind: StringName
) -> Array[FleetState]:
	var out: Array[FleetState] = []
	var code := _cargo_kind_code(kind)
	for f in fleets_in_orbit_at(planet_index):
		for key: StringName in f.ships:
			var def: Resource = _hull_table().get(key, null) as Resource
			if def == null:
				continue
			if hull_id != &"" and key != hull_id:
				continue
			if not def.call("carries", code):
				continue
			if not out.has(f):
				out.append(f)
	return out


## The `ShipHullData.CargoKind` a manifest key stands for.
##
## Delegates to `TransferStage` rather than repeating its table, so a new cargo kind needs one
## edit rather than one here and one there.
func _cargo_kind_code(kind: StringName) -> int:
	match kind:
		TransferStage.KIND_METALS:
			return ShipHullData.CargoKind.METALS
		TransferStage.KIND_FOOD:
			return ShipHullData.CargoKind.FOOD
		TransferStage.KIND_POWER:
			return ShipHullData.CargoKind.POWER
		TransferStage.KIND_TROOPS:
			return ShipHullData.CargoKind.TROOPS
		TransferStage.KIND_CIVILIANS:
			return ShipHullData.CargoKind.CIVILIANS
	return ShipHullData.CargoKind.NONE


## A world the player owns and has settled, by index, or null with a reason emitted.
func _owned_colony(planet_index: int) -> PlanetState:
	if galaxy == null or planet_index < 0:
		action_rejected.emit("select one of your colonies first")
		return null
	var planet: PlanetState = galaxy.planet(planet_index)
	if planet == null or planet.owner != player_id or not planet.colonized:
		action_rejected.emit("select one of your colonies first")
		return null
	return planet


# --- The turn --------------------------------------------------------------

## Set when this session is bound to a remote authority rather than resolving locally.
##
## A networked client must never call `TurnResolver` itself: it would advance a local
## galaxy the server knows nothing about, and the two would silently diverge. With this
## set, `end_turn()` ships the orders instead and returns an empty report -- the real
## resolution arrives later as a broadcast.
var turn_submitter: TurnSyncClient = null

## True while the client waits for the server to resolve.
func is_awaiting_server() -> bool:
	return turn_submitter != null and turn_submitter.awaiting


## Signal the lobby ready flag (or take it back).
##
## Commit this player's turn and tell the server they are ready.
##
## Only meaningful in a networked session: single player has no lobby to be ready *for*.
## Returns false when there is no server to tell, which the caller reports rather than
## silently doing nothing -- a player who presses READY and sees no change needs to know
## whether the button is broken or the flag simply does not apply here.
##
## This ships the staged orders as part of raising the flag. The END TURN button used to be
## that commit step, and it has been removed: READY *is* the commit now. Leaving the two
## separate would mean a player staged four orders, pressed READY, and watched them vanish
## because nothing had submitted them -- the button would have looked like it did nothing.
func set_ready(is_ready: bool) -> bool:
	if turn_submitter == null:
		return false
	# Only a raise commits. Un-readying is a correction within the same lobby, and must
	# not re-ship orders the player already submitted.
	if not is_ready:
		return turn_submitter.set_ready(false)
	if is_awaiting_server():
		action_rejected.emit(TurnSyncClient.WAITING_TEXT)
		return false
	var staged := orders_to_submit()
	for o in staged:
		turn_submitter.stage_order(o)
	if queue != null:
		queue.clear()
	return turn_submitter.set_ready(true)


## Whether this client has told the server it is ready. False in a local session.
func is_ready_flagged() -> bool:
	if turn_submitter == null:
		return false
	return turn_submitter.is_ready_flagged()


## True when this session is bound to a remote authority.
func is_networked() -> bool:
	return turn_submitter != null


## How many players the server says have readied, and how many it is waiting for.
##
## From the server rather than counted locally: only the server knows whether a flag
## actually landed, and a tally each client computes for itself is a tally they can
## disagree about.
func ready_tally() -> Vector2i:
	if turn_submitter == null:
		return Vector2i.ZERO
	return Vector2i(turn_submitter.ready_count, turn_submitter.total_slots)


## The orders this player has staged, ready for the wire.
func orders_to_submit() -> Array[Order]:
	if queue == null:
		return [] as Array[Order]
	return queue.orders_for(player_id)


## Resolve one turn: submit staged orders to the deterministic resolver, then refresh.
##
## This is the same call the dedicated server makes; single-player is a client bound to
## an in-process authority, not a separate code path.
func end_turn() -> Dictionary:
	if galaxy == null:
		action_rejected.emit("no game in progress")
		return {}

	# Networked: hand the orders to the server and wait. It is the authority, and it is
	# the only thing that can advance a turn every peer agrees on.
	if turn_submitter != null:
		return _end_turn_over_network()

	var orders: Array = []
	if queue != null:
		orders = queue.orders_for(player_id)
	var report := TurnResolver.resolve_turn(galaxy, orders, defs, db, rng, player_id)
	last_report = report
	if queue != null:
		queue.clear()
	# A fleet destroyed mid-turn is no longer selectable.
	if fleet() == null or not fleet().active:
		selected_fleet = -1
	turn_resolved.emit(report)
	state_changed.emit()
	return report


## Ship staged orders and enter the waiting state.
##
## Returns an empty Dictionary so every caller already written against `end_turn()` keeps
## working: it means "nothing resolved yet". The turn genuinely has not happened, and the
## caller learns that from the resolution broadcast rather than from this call.
func _end_turn_over_network() -> Dictionary:
	if is_awaiting_server():
		action_rejected.emit(TurnSyncClient.WAITING_TEXT)
		return {}
	var staged := orders_to_submit()
	for o in staged:
		turn_submitter.stage_order(o)
	if queue != null:
		queue.clear()
	if not turn_submitter.submit_turn():
		# The submission never went out. Un-queueing would risk replaying orders the
		# server may already hold, so the staged set is deliberately left consumed.
		action_rejected.emit("could not reach the server")
		return {}
	state_changed.emit()
	return {}


# --- Internals -------------------------------------------------------------

## The selected planet, if the player actually owns it.
func _selected_owned_planet() -> PlanetState:
	if galaxy == null or selected_planet < 0:
		action_rejected.emit("select one of your colonies first")
		return null
	var planet := galaxy.planet(selected_planet)
	if planet == null or planet.owner != player_id or not planet.colonized:
		action_rejected.emit("select one of your colonies first")
		return null
	return planet


## Whether the faction's imperial stores could pay for a hull, ignoring where it would be
## built.
##
## Retained for the AI and for callers that only want the "is this hull affordable at all"
## question. The build path does *not* use it: Phase 8 builds out of a colony's own stored
## metal, and an empire with a full treasury and an empty colony cannot lay a keel.
func can_afford_hull(hull: Resource) -> bool:
	var me := player()
	if me == null:
		return false
	return me.metals >= hull.cost_metals \
		and me.rare_elements >= hull.cost_rare \
		and me.energy >= hull.cost_energy
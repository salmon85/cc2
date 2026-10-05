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
	for key: int in galaxy.fleets:
		var f: FleetState = galaxy.fleets[key]
		if not f.active or f.owner != player_id:
			continue
		# In orbit only: `system` is cleared or left behind once a fleet is under way.
		if f.system == system_index and f.destination < 0:
			return true
	return false


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


func select_planet(index: int) -> void:
	if galaxy == null:
		return
	if galaxy.planet(index) == null:
		action_rejected.emit("no such planet")
		return
	selected_planet = index
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
	selected_system = target.system
	state_changed.emit()


# --- Player actions --------------------------------------------------------

## Queue a move for the selected fleet. Returns false and explains when refused.
func queue_move(target_system: int) -> bool:
	var f := fleet()
	if f == null:
		action_rejected.emit("select a fleet first")
		return false
	if galaxy == null or galaxy.system(target_system) == null:
		action_rejected.emit("no such destination")
		return false
	if not f.active:
		action_rejected.emit("that fleet has been destroyed")
		return false
	if f.destination >= 0:
		action_rejected.emit("that fleet is already in transit")
		return false

	var order := Order.make_move_fleet(player_id, f.id, target_system)
	if queue.submit(order):
		# Keep the in-flight mirror in step so the map draws the warp line immediately
		# rather than only after the turn resolves.
		MovementStage.issue_move(galaxy, f.id, player_id, target_system)
		state_changed.emit()
		return true
	action_rejected.emit("the order was refused")
	return false


## Queue a structure for the selected colony. `building_id` must be a known building the
## faction has unlocked and the colony is allowed to add.
func queue_build_structure(building_id: StringName) -> bool:
	var planet := _selected_owned_planet()
	if planet == null:
		return false
	var me := player()
	if me == null:
		return false
	if not me.unlocked_buildings.has(building_id):
		action_rejected.emit("you have not researched that structure")
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
	if not can_afford(def):
		action_rejected.emit("insufficient materials")
		return false

	var order := Order.make_build_structure(player_id, planet.index, building_id, 1)
	if queue.submit(order):
		# Debit now so the slider/selector shows the true remaining budget; the
		# resolver will not charge again.
		_charge(def)
		state_changed.emit()
		return true
	action_rejected.emit("the order was refused")
	return false


## Queue a ship for the selected colony's shipyard.
func queue_build_ship(hull_id: StringName) -> bool:
	var planet := _selected_owned_planet()
	if planet == null:
		return false
	var me := player()
	if me == null:
		return false
	if not me.unlocked_ships.has(hull_id):
		action_rejected.emit("you have not researched that hull")
		return false
	if planet.shipyard_progress < 1.0:
		action_rejected.emit("this colony has no operational shipyard")
		return false
	if defs == null:
		action_rejected.emit("definitions are not loaded")
		return false
	var hull: Resource = defs.ship_hull(hull_id) as Resource
	if hull == null:
		action_rejected.emit("unknown hull")
		return false
	if not can_afford_hull(hull):
		action_rejected.emit("insufficient materials")
		return false

	var order := Order.make_build_ship(player_id, planet.index, hull_id)
	if queue.submit(order):
		_charge_hull(hull)
		state_changed.emit()
		return true
	action_rejected.emit("the order was refused")
	return false


## Set the imperial tax rate, 0..1.
func set_tax_rate(rate: float) -> bool:
	var me := player()
	if me == null:
		return false
	me.tax_rate = clampf(rate, 0.0, 1.0)
	if queue.submit(Order.make_set_tax(player_id, me.tax_rate)):
		state_changed.emit()
		return true
	return false


## Set the research split. The four weights are normalised before being submitted so the
## sliders can be dragged independently and still describe a real budget.
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
		# Mirror onto the faction immediately so the sliders read back correctly.
		for i in 4:
			me.research_allocation[i] = normalised[i]
		state_changed.emit()
		return true
	return false


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
## Only meaningful in a networked session: single player has no lobby to be ready *for*.
## Returns false when there is no server to tell, which the caller reports rather than
## silently doing nothing -- a player who presses READY and sees no change needs to know
## whether the button is broken or the flag simply does not apply here.
func set_ready(is_ready: bool) -> bool:
	if turn_submitter == null:
		return false
	return turn_submitter.set_ready(is_ready)


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


## Whether the faction can currently pay for a structure definition.
func can_afford(def: Resource) -> bool:
	var me := player()
	if me == null:
		return false
	return me.metals >= def.cost_metals \
		and me.rare_elements >= def.cost_rare \
		and me.energy >= def.cost_energy


func _charge(def: Resource) -> void:
	var me := player()
	if me == null:
		return
	_charge_amounts(def.cost_metals, def.cost_rare, def.cost_energy)


func can_afford_hull(hull: Resource) -> bool:
	var me := player()
	if me == null:
		return false
	return me.metals >= hull.cost_metals \
		and me.rare_elements >= hull.cost_rare \
		and me.energy >= hull.cost_energy


func _charge_hull(hull: Resource) -> void:
	var me := player()
	if me == null:
		return
	_charge_amounts(hull.cost_metals, hull.cost_rare, hull.cost_energy)


## Debit a cost and clamp. The clamp keeps a floating-point overshoot from leaving the
## treasury at -0.0000001, which the HUD would otherwise render as a negative balance.
func _charge_amounts(metals: float, rare: float, energy: float) -> void:
	var me := player()
	if me == null:
		return
	me.metals = maxf(0.0, me.metals - metals)
	me.rare_elements = maxf(0.0, me.rare_elements - rare)
	me.energy = maxf(0.0, me.energy - energy)
extends RefCounted
class_name MovementStage
## Stage 1 of turn resolution: fleets travel, and arriving fleets are handed to whoever
## holds the destination.
##
## Travel is on the authoritative RNG-free path — distance arithmetic only — so movement
## replays identically on every client without transmitting a single float.
##
## Distances are counted in **dots**, not parsecs. A dot is a fixed fraction of the map's
## span, so a crossing is the same *number of dots* on every map size and a dot is the
## same *distance* every fleet covers in a turn. That makes transit time a function of
## distance alone -- legible to the player as "14 dots, 14 turns", one pip per turn -- and
## not a product of three independent per-hull speeds that has to be estimated on the
## client and happened to disagree with what the resolver did.

## How far one dot is, as a fraction of the map radius.
##
## The outermost planet sits at `GalaxyGenerator.OUTER_ORBIT` of the radius, so a
## point-to-point hop of one dot lands just outside the rim on a straight crossing and
## inside it on a short one. Dots are a *scale*, not a grid: nothing snaps to them, they
## only have to make a distance legible.
##
## A hundredth of the radius, which makes a full-width crossing about two hundred dots on
## *every* map size -- the scale is what makes the turn count below independent of the tier.
## Coarser than this and the pips bunch up until the line reads as solid and a player
## counting them has nothing to count.
const DOT_FRACTION := 0.01

## World positions of the waypoint marks drawn along an order line.
##
## One mark per *whole* dot of the crossing, excluding the final dot: the destination's own
## planet marker sits there and drawing a pip on top of it is noise. So the list is always
## one shorter than `transit_turns`, and `transit_turns` counts the destination marker as
## the last waypoint -- the crossing has exactly as many marks as turns once you count it.
##
## This is the list the map draws *and* the one the turn count is derived from, so the two
## cannot drift. When they were computed independently -- the view walking its own loop
## while the panel asked `transit_turns` -- a change to the rate moved the marks and the
## quote together by coincidence, and nothing checked that they agreed.
static func waypoints(
	galaxy: GalaxyState, from_planet: int, to_planet: int
) -> PackedVector2Array:
	var out := PackedVector2Array()
	var a := galaxy.planet(from_planet)
	var b := galaxy.planet(to_planet)
	if a == null or b == null:
		return out
	var span := orbit_distance(a, b)
	if span <= 0.0:
		return out
	var step := dot_size(galaxy)
	var dir := (b.position - a.position) / span
	var travelled := 0.0
	# Bounded by the dot count, not by a magic number: a coarse map or a long crossing
	# cannot silently truncate the ruler.
	var guard := 0
	while travelled + step < span and guard < 4096:
		travelled += step
		guard += 1
		out.append(a.position + dir * travelled)
	return out


## Dots a fleet covers in one turn.
##
## Uniform across every hull and every role by design. A scout and a dreadnought used to
## move at different rates, which made transit time depend on what a fleet happened to be
## built from and made it impossible to quote a number to the player before committing.
##
## One dot per turn, so a turn *is* a waypoint. This is the whole contract between the
## number the panel quotes and the map the player is looking at: every pip drawn along the
## order line is one turn of flight, and the quoted count is the number of pips. At ten
## dots per turn the same crossing read "14 dots, 2 turns" -- the fleet visibly skipped
## past seven pips per turn, and a player counting the pips had no way to reconcile that
## with the figure that decides when their fleet arrives.
const DOTS_PER_TURN := 1.0

## Maximum parsecs a faction's fleets can cover this turn.
##
## `GameDB`'s figures are tuned for the `extreme` span. Everything here divides by the
## game's radius factor and multiplies by the tier's, so a `tiny` map is traversed as fast
## as an `extreme` one and a fleet always spends the same *number of turns* crossing the
## system rather than the same number of parsecs. Without this a small map is a game
## nobody ever moves in and a large one is a game nobody ever finishes.
static func map_factor(galaxy: GalaxyState) -> float:
	return GalaxyGenerator.radius_for_scale(galaxy.map_radius) / GalaxyGenerator.GALAXY_RADIUS


static func movement_allowance(faction: FactionState) -> float:
	var base := GameDB.BASE_MOVEMENT + faction.tech_effect(&"movement")
	return clampf(base, 0.0, GameDB.MAX_MOVEMENT)


## Parsecs per dot on this map.
static func dot_size(galaxy: GalaxyState) -> float:
	return maxf(galaxy.radius() * DOT_FRACTION, 0.0001)


## A distance in parsecs expressed in dots.
static func to_dots(galaxy: GalaxyState, parsecs: float) -> float:
	return parsecs / dot_size(galaxy)


## A dot count back into parsecs.
static func from_dots(galaxy: GalaxyState, dots: float) -> float:
	return dots * dot_size(galaxy)


## Dots between two planets, along the straight line between them.
static func orbit_dots(galaxy: GalaxyState, from: PlanetState, to: PlanetState) -> float:
	if from == null or to == null:
		return 0.0
	return to_dots(galaxy, orbit_distance(from, to))


## Turns a fleet would take to cross to `to_planet`, at the uniform rate.
##
## This is the pip count, rounded *up*, plus the destination's own marker -- so a player
## counting waypoints along the order line gets exactly this number, and cannot end up
## holding a figure one short of what they drew.
##
## Rounded up rather than truncated: a fleet that is already in range arrives at the end of
## the next turn rather than instantly, and a fraction of a turn never rounds the other
## way -- the player is quoted the same number the resolver will take.
static func transit_turns(galaxy: GalaxyState, from_planet: int, to_planet: int) -> int:
	var a := galaxy.planet(from_planet)
	var b := galaxy.planet(to_planet)
	if a == null or b == null:
		return 0
	var dots := orbit_dots(galaxy, a, b)
	if dots <= 0.0:
		return 0
	return maxi(1, ceili(dots / DOTS_PER_TURN))


## Dots a fleet covers per turn. The same for every fleet, by design.
##
## `faction` is accepted so the signature survives the per-hull model and so a future
## speed research has somewhere to go, but it deliberately does not change the result: a
## tech tree that made one fleet twice as fast as another would reintroduce exactly the
## "cannot quote a number before committing" problem this replaced.
static func fleet_speed(
	_fleet: FleetState, _faction: FactionState, _map_factor: float = 1.0
) -> float:
	return DOTS_PER_TURN


## Issue a move order. Returns false (and changes nothing) when the order is illegal.
##
## The target is a *planet*, not a system. There is one system, so a system target is
## either "where you already are" or "the star", and neither is a move a player would
## recognise as movement. Sending a fleet to a planet is the only legible order left.
static func issue_move(
	galaxy: GalaxyState, fleet_id: int, faction_id: int, target_planet: int
) -> bool:
	var f: FleetState = galaxy.fleet(fleet_id)
	if f == null or not f.active:
		return false
	if f.owner != faction_id:
		return false
	if f.system < 0 or f.destination >= 0:
		return false  # already in transit
	var dest: PlanetState = galaxy.planet(target_planet)
	if dest == null or dest.index == f.system:
		return false

	f.destination = dest.index
	f.travelled = 0.0
	return true


## Advance every travelling fleet by one turn.
##
## Returns the ids of fleets that arrived, in ascending id order so the caller can hand
## them to the combat stage deterministically.
static func advance(galaxy: GalaxyState) -> PackedInt32Array:
	var arrivals := PackedInt32Array()
	var ids := galaxy.fleets.keys()
	ids.sort()
	var span := map_factor(galaxy)

	for id: int in ids:
		var f: FleetState = galaxy.fleets[id] as FleetState
		if f == null or not f.active or f.destination < 0:
			continue

		var owner_state: FactionState = galaxy.faction(f.owner)
		if owner_state == null:
			# Ownerless fleet (should not happen): park it rather than crash.
			f.destination = -1
			continue

		var speed := fleet_speed(f, owner_state, span)
		var from: PlanetState = galaxy.planet(f.system)
		var to: PlanetState = galaxy.planet(f.destination)
		if from == null or to == null:
			f.destination = -1
			f.travelled = 0.0
			continue

		# `travelled` is in dots, matching `orbit_dots` and `DOTS_PER_TURN`, so the stored
		# progress is directly comparable to the leg it is covering and the map's
		# interpolation needs no separate conversion.
		var distance := orbit_dots(galaxy, from, to)

		f.travelled += speed
		if f.travelled + 0.0001 >= distance:
			f.system = to.index
			f.destination = -1
			f.travelled = 0.0
			arrivals.append(f.id)

	return arrivals


## Straight-line distance between two planets' orbits, in parsecs.
##
## Because every planet sits on a ring around one star, the distance between two worlds is
## the chord between their orbit points -- the star is in the way geometrically but not
## tactically, so the two bodies are treated as directly reachable.
static func orbit_distance(from: PlanetState, to: PlanetState) -> float:
	return from.position.distance_to(to.position)


## Every active fleet sitting on `planet_index`. Pass -1 for `faction_id` to get them all.
static func fleets_in_system(
	galaxy: GalaxyState, planet_index: int, faction_id: int
) -> Array[FleetState]:
	var out: Array[FleetState] = []
	var ids := galaxy.fleets.keys()
	ids.sort()
	for id: int in ids:
		var f: FleetState = galaxy.fleets[id] as FleetState
		if f == null or not f.active or f.system != planet_index:
			continue
		if faction_id >= 0 and f.owner != faction_id:
			continue
		out.append(f)
	return out


## Every active fleet that is somewhere on the map, in stable id order.
##
## Replaces the old per-system sweep: with one system and no neighbours, "the fleets in
## this system" would have meant "all the fleets", which is the same answer for every
## caller and hides the grouping that combat and invasion actually need.
static func fleets_in_orbit(galaxy: GalaxyState, faction_id: int = -1) -> Array[FleetState]:
	var out: Array[FleetState] = []
	var ids := galaxy.fleets.keys()
	ids.sort()
	for id: int in ids:
		var f: FleetState = galaxy.fleets[id] as FleetState
		if f == null or not f.active or f.system < 0:
			continue
		if faction_id >= 0 and f.owner != faction_id:
			continue
		out.append(f)
	return out


## Pair fleets sharing a planet into engagements, deterministically.
##
## Returns an array of `[attacker_id, defender_id]` pairs. Both sides alternate so no
## faction gets to strike first purely by iteration order.
##
## Sharing an *orbit* is what counts, not sharing a neighbourhood: two fleets pass each other
## 400 parsecs apart and do not fight, which is what stops the whole map becoming one
## battle the moment two empires expand.
static func find_engagements(galaxy: GalaxyState) -> Array:
	var pairs: Array = []
	var by_system: Dictionary = {}

	var ids := galaxy.fleets.keys()
	ids.sort()
	for id: int in ids:
		var f: FleetState = galaxy.fleets[id] as FleetState
		if f == null or not f.active or f.system < 0:
			continue
		if not by_system.has(f.system):
			by_system[f.system] = [] as Array[FleetState]
		(by_system[f.system] as Array).append(f)

	var system_indices := by_system.keys()
	system_indices.sort()
	for sys_index: int in system_indices:
		var fleets: Array = by_system[sys_index]
		# Group by owner, then pair each faction against the others in a stable order.
		var by_owner: Dictionary = {}
		for f: FleetState in fleets:
			if not by_owner.has(f.owner):
				by_owner[f.owner] = [] as Array[FleetState]
			(by_owner[f.owner] as Array).append(f)
		if by_owner.size() < 2:
			continue

		var owners := by_owner.keys()
		owners.sort()
		for i in owners.size():
			for j in range(i + 1, owners.size()):
				for a: FleetState in by_owner[owners[i]]:
					for d: FleetState in by_owner[owners[j]]:
						pairs.append([a.id, d.id])
	return pairs
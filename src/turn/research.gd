extends RefCounted
class_name ResearchStage
## Stage 5 of turn resolution: turn a faction's civilian population into tech points, then
## complete any milestone the empire has earned.
##
## Research is *passive* in Phase 8. There are no allocation sliders and no tax slider, and
## the design document is explicit about why: "research is passive, driven by total empire
## civilian pop across all planets. Milestone populations level up technology and unlock
## buildings/ships."
##
## That replaces a budget the player divided. It also removes the last reason for the income
## figure to exist, so this stage reads population rather than `last_income`, and the four
## fields are fed in proportion to the cost of what remains rather than by a stored vector.

## Convert a faction's population into tech points. Returns the total granted.
##
## Only civilians count. Troops are explicitly excluded by the design document — "troops do
## not consume food and do not produce research" — which is why this reads `population`
## directly rather than any combined figure. A faction with no surviving colonies researches
## nothing at all, exactly as before.
static func accumulate(faction: FactionState, galaxy: GalaxyState, defs: Node, db: Node) -> float:
	if galaxy.colonies_of(faction.id).is_empty():
		return 0.0

	var civilians := 0.0
	for colony in galaxy.colonies_of(faction.id):
		civilians += colony.population
	if civilians <= 0.0:
		return 0.0

	var per_pop := float(db.get("RESEARCH_POINTS_PER_POP"))
	var bonus := 1.0 + faction.tech_effect(&"research_bonus")
	var total := civilians * per_pop * bonus

	# Split across the four fields by the relative cost of what is still ahead in each.
	# This is what replaces the sliders: the player cannot starve a field they have not
	# noticed, and cannot dump everything into one, but a field whose cheapest remaining
	# node is expensive gets proportionally less.
	var weights := _field_weights(defs, faction)
	var weight_total := 0.0
	for w in weights:
		weight_total += w
	if weight_total <= 0.0:
		return 0.0

	var granted := 0.0
	for i in 4:
		var share: float = total * (weights[i] / weight_total)
		faction.tech_points[i] += share
		granted += share
	return granted


## Relative weight of each research field: the cheapest node still unreached in that field.
##
## A field with nothing left contributes zero, which is what finally retires an exhausted
## branch -- under the slider model a player kept dragging a quarter of their budget into a
## field whose every node was already researched.
static func _field_weights(defs: Node, faction: FactionState) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(4)
	if defs == null:
		return out
	for field in 4:
		var cheapest := 0.0
		for id: StringName in tech_order_for(defs, field):
			if faction.researched.has(id):
				continue
			var node: Resource = defs.call("tech_node", id) as Resource
			if node == null or not _prerequisites_met(faction, node):
				continue
			var cost := float(node.get("cost"))
			if cost <= 0.0:
				continue
			if cheapest <= 0.0 or cost < cheapest:
				cheapest = cost
		out[field] = cheapest
	return out


## Complete every tech node the faction can now afford, cheapest-first within each field
## so a small surplus always buys something rather than being stranded behind a tier-4 node.
##
## Retained alongside the population ladder: the point pool still exists, and a node whose
## cost has been met completes immediately. What has gone is the player choosing which field
## it comes from.
static func complete_available(faction: FactionState, defs: Node) -> Array[StringName]:
	var tech := defs.get("tech_nodes") as Dictionary
	if tech.is_empty():
		push_error("[ResearchStage] no tech definitions available")
		return [] as Array[StringName]

	var completed: Array[StringName] = []
	var progressed := true

	# Loop because completing one node can unlock cheaper nodes in other fields.
	while progressed:
		progressed = false
		for field in 4:
			# Cheapest affordable node in this field wins.
			var best: StringName = &""
			var best_cost := INF
			for id: StringName in tech_order_for(defs, field):
				if faction.researched.has(id):
					continue
				var node: Resource = tech[id] as Resource
				if not _prerequisites_met(faction, node):
					continue
				var cost := float(node.get("cost"))
				if cost <= faction.tech_points[field] and cost < best_cost:
					best_cost = cost
					best = id
			if best != &"":
				var node2: Resource = tech[best] as Resource
				faction.tech_points[int(node2.get("field"))] -= float(node2.get("cost"))
				faction.researched[best] = true
				# The cache is what `tech_effect` reads, so it is written here too. Without
				# it a node's effects only appeared after the next `rebind_definitions` --
				# which fires on a load, and nowhere else -- so a save/reload run and an
				# uninterrupted one disagreed about a whole turn of bonuses.
				faction.cache_tech_node(best, node2)
				_apply_unlocks(faction, node2, defs)
				completed.append(best)
				progressed = true

	return completed


## All node ids in `field`, in the registry's dependency-respecting order.
static func tech_order_for(defs: Node, field: int) -> PackedStringArray:
	var order := defs.get("tech_order") as PackedStringArray
	var tech := defs.get("tech_nodes") as Dictionary
	var out := PackedStringArray()
	for id in order:
		var node: Resource = tech.get(id, null) as Resource
		if node != null and int(node.get("field")) == field:
			out.append(id)
	return out


static func _prerequisites_met(faction: FactionState, node: Resource) -> bool:
	for prereq in node.get("prerequisites"):
		if not faction.researched.has(StringName(prereq)):
			return false
	return true


## Unlock the ships and buildings a completed node grants, and report which.
static func _apply_unlocks(faction: FactionState, node: Resource, defs: Node) -> void:
	for hull_id in node.get("unlocks_ships"):
		faction.unlocked_ships[StringName(hull_id)] = true
	for building_id in node.get("unlocks_buildings"):
		faction.unlocked_buildings[StringName(building_id)] = true


## Human-readable line for the turn report.
static func describe_completion(faction: FactionState, node_id: StringName, defs: Node) -> String:
	var node := defs.call("tech_node", node_id) as Resource
	if node == null:
		return "%s researched %s" % [faction.name, node_id]
	return "%s completed %s: %s" % [faction.name, node.get("display_name"), node.get("description")]


# --- The population ladder -------------------------------------------------

## The population thresholds that unlock technology, read once so the resolver and the UI
## cannot disagree about where the rungs are.
static func milestones(db: Node) -> Array[float]:
	var raw: Array = db.get("TECH_MILESTONES") as Array
	var out: Array[float] = []
	for entry: Variant in raw:
		out.append(float(entry))
	return out


## How many milestones `pop` has crossed.
static func milestones_reached(pop: float, db: Node) -> int:
	var reached := 0
	for threshold in milestones(db):
		if pop >= threshold:
			reached += 1
		else:
			break
	return reached


## The population needed for the next milestone above `pop`, or -1 at the top of the ladder.
static func next_milestone(pop: float, db: Node) -> float:
	for threshold in milestones(db):
		if threshold > pop:
			return threshold
	return -1.0


## The highest tier of hull the faction's population has earned.
##
## The design document's progression is population-driven: each milestone adds hulls, and
## what it adds is the next ones up the combat ladder. This is a *reset* rather than an
## extension of the research tree, because a research tree driven by a budget the player no
## longer controls would still need unlocks, and the milestone is the thing the design
## document actually names.
static func hull_tier_for(pop: float, db: Node) -> int:
	return milestones_reached(pop, db)


## Grant the hulls and buildings a faction's population has earned.
##
## Returns the hull ids newly unlocked, in ladder order, so the caller can report them. The
## tier is stored on the faction: without it a colony captured and then lost would take the
## unlocks with it, and a faction that shrank and grew back would re-unlock its whole fleet
## every time.
static func apply_milestones(
	faction: FactionState, pop: float, defs: Node, db: Node
) -> Array[StringName]:
	var tier := hull_tier_for(pop, db)
	if tier <= int(faction.tech_tier):
		return [] as Array[StringName]
	faction.tech_tier = tier

	var ladder := GameDB.HULL_LADDER as Array
	var unlocked: Array[StringName] = []
	var per := maxi(1, int(db.get("HULLS_PER_MILESTONE")))
	for i in mini(tier * per, ladder.size()):
		var hull_id := StringName(str(ladder[i]))
		if not faction.unlocked_ships.has(hull_id):
			faction.unlocked_ships[hull_id] = true
			unlocked.append(hull_id)
	return unlocked


## Every building the Phase 8 roster defines, unlocked from the start.
##
## Buildings are not gated behind the ladder: the design document puts the milestone
## progression on ships and structures that need population to staff, and a player who
## cannot build a Granary until 6 pop has nothing to spend their first metal on.
static func starter_buildings(defs: Node) -> Array[StringName]:
	var out: Array[StringName] = []
	for id: Variant in (defs.get("buildings") as Dictionary):
		out.append(StringName(str(id)))
	out.sort()
	return out
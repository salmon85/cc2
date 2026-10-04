extends RefCounted
class_name ResearchStage
## Stage 4 of turn resolution: turn research income into tech points, then complete any
## nodes the treasury of points in each field can now afford.

## Convert a faction's net surplus into tech points, split by the research sliders.
##
## Only a *surplus* funds research: an empire running a deficit must cut spending first,
## which is what makes the tax slider a real decision rather than a display.
static func accumulate(
	faction: FactionState, galaxy: GalaxyState, db: Node
) -> float:
	var income: float = maxf(0.0, faction.last_income)
	var budget := income * float(db.get("RESEARCH_BUDGET_SHARE"))
	var bonus := 1.0 + faction.tech_effect(&"research_bonus")
	budget *= bonus

	# A faction with no surviving colonies cannot research at all.
	if galaxy.colonies_of(faction.id).is_empty():
		return 0.0

	faction.normalize_allocation()
	var granted := 0.0
	for i in 4:
		var share: float = budget * float(faction.research_allocation[i])
		faction.tech_points[i] += share
		granted += share
	return granted


## Complete every tech node the faction can now afford, cheapest-first within each field
## so a small surplus always buys something rather than being stranded behind a tier-4
## node. Returns the ids completed, in completion order.
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
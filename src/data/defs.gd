extends Node
## Definition registry autoload.
##
## Loads the `.tres` entity definitions from `res://data/` once at startup and exposes
## them through typed, id-keyed accessors. Everything downstream refers to entities by
## `StringName` id, never by raw resource path, so moving or re-authoring a `.tres` cannot
## break save games or network traffic.

## Directory holding the entity `.tres` files.
const DEF_DIR := "res://data"

## planet class -> PlanetTypeData
var planet_types: Dictionary = {}

## ship role -> ShipHullData
var ship_hulls: Dictionary = {}

## building id -> BuildingData
var buildings: Dictionary = {}

## tech id -> TechNodeData
var tech_nodes: Dictionary = {}

## Every tech id, ordered so prerequisites always resolve before their dependents.
var tech_order: PackedStringArray = PackedStringArray()

var _loaded: bool = false


## Where the Resource *scripts* live, which is not the same as where the `.tres` data is.
const SCRIPT_DIR := "res://src/data"

## Load every definition file. Safe to call more than once.
func load_all() -> void:
	if _loaded:
		return
	planet_types = _load_dir("res://src/data/planet_type_data.gd", "res://data/planet_types")
	ship_hulls = _load_dir("res://src/data/ship_hull_data.gd", "res://data/ships")
	buildings = _load_dir("res://src/data/building_data.gd", "res://data/buildings")
	tech_nodes = _load_dir("res://src/data/tech_node_data.gd", "res://data/tech")
	tech_order = _topologically_sort_tech()
	_loaded = true
	validate_all()


## Load every `*.tres` in `dir`, keyed by the resource's `id` field. `script_path` names
## the class the data files are expected to instantiate; a mismatch is an error, because
## a definition authored against the wrong schema would silently mis-balance the game.
## A missing directory yields an empty dictionary rather than aborting the boot.
func _load_dir(script_path: String, dir: String) -> Dictionary:
	var result: Dictionary = {}
	var script_res := load(script_path) as GDScript
	if script_res == null:
		push_error("[Defs] could not load definition script %s" % script_path)
		return result

	var guard := DirAccess.open(dir)
	if guard == null:
		push_warning("[Defs] directory missing: %s" % dir)
		return result

	for file_name in guard.get_files():
		if not file_name.ends_with(".tres"):
			continue
		var path := dir.path_join(file_name)
		var res := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if res == null:
			push_error("[Defs] could not load %s" % path)
			continue
		if not res.has_method("get"):
			push_error("[Defs] %s is not an entity definition" % path)
			continue
		var id: StringName = StringName(str(res.get("id")))
		if id == &"":
			push_error("[Defs] %s has an empty id" % path)
			continue
		if result.has(id):
			push_error("[Defs] duplicate id '%s' (%s)" % [id, path])
			continue
		result[id] = res
	return result


## Order tech ids so every prerequisite appears before the node that needs it.
## Falls back to declaration order if the graph contains a cycle, and reports it.
func _topologically_sort_tech() -> PackedStringArray:
	var remaining: Array = tech_nodes.keys()
	remaining.sort()
	var ordered := PackedStringArray()

	while not remaining.is_empty():
		var progressed := false
		for id in remaining:
			var deps: Array = tech_nodes[id].get("prerequisites")
			var ready := true
			for dep in deps:
				if StringName(dep) in tech_nodes and StringName(dep) not in ordered:
					ready = false
					break
			if ready:
				ordered.append(StringName(id))
				remaining.erase(id)
				progressed = true
				break
		if not progressed:
			# Cycle: emit what is left in stable order so the game still loads.
			push_warning("[Defs] tech prerequisite cycle among %s" % str(remaining))
			for id in remaining:
				ordered.append(StringName(id))
			break
	return ordered


## Sanity-check every loaded definition. Any problem is a hard error: shipping a galaxy
## with a broken `.tres` would silently change balance, so this fails loudly at boot.
##
## Returns every issue found (empty when the data set is clean), which is also what the
## headless verification asserts on.
func validate_all() -> PackedStringArray:
	var issues := PackedStringArray()
	for id: StringName in planet_types:
		for issue in (planet_types[id] as Resource).call("validate"):
			issues.append("[PlanetTypeData '%s'] %s" % [id, issue])
	for id: StringName in ship_hulls:
		for issue in (ship_hulls[id] as Resource).call("validate"):
			issues.append("[ShipHullData '%s'] %s" % [id, issue])
	for id: StringName in buildings:
		for issue in (buildings[id] as Resource).call("validate"):
			issues.append("[BuildingData '%s'] %s" % [id, issue])
	for id: StringName in tech_nodes:
		var node: Resource = tech_nodes[id]
		for issue in node.call("validate"):
			issues.append("[TechNodeData '%s'] %s" % [id, issue])
		for dep in node.get("prerequisites"):
			if StringName(dep) not in tech_nodes:
				issues.append("[TechNodeData '%s'] unknown prerequisite '%s'" % [id, dep])
	for id in tech_order:
		if id not in tech_nodes:
			issues.append("[Defs] tech order references unknown id '%s'" % id)
	for issue in issues:
		push_error(issue)
	return issues


## Thin probe wrapper around `_load_dir`, so the headless suite can prove a missing
## directory degrades to an empty registry rather than crashing the boot.
func _load_dir_probe(script_path: String, dir: String) -> PackedStringArray:
	var result := _load_dir(script_path, dir)
	var ids := PackedStringArray()
	for key: Variant in result:
		ids.append(String(key))
	return ids


## Typed accessors ---------------------------------------------------------------

func planet_type(id: StringName) -> Resource:
	return planet_types.get(id, null) as Resource


func ship_hull(id: StringName) -> Resource:
	return ship_hulls.get(id, null) as Resource


func building(id: StringName) -> Resource:
	return buildings.get(id, null) as Resource


func tech_node(id: StringName) -> Resource:
	return tech_nodes.get(id, null) as Resource
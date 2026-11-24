class_name ZoneMap
extends RefCounted

## What each tile of the world is designated as. This is DATA on the tiles (cell -> zone type), not a mesh: the overlay
## GridMap ("Zones" in main.tscn) only draws it, and stockpiles, gathering areas and so on all ask this map what a tile is.
## One zone per tile. Cells use the Builder's build layer (y = Builder.build_layer).
##
## To add a zone: add it to Type, give it a row in INFO and in BRUSHES, and add a flat item with the same "item" name to
## structures/zone-tiles.tres. Zones are looked up by NAME (INFO's "item"), never by MeshLibrary index or enum number,
## so reordering either can't scramble a saved map.

enum Type { NONE, LOG_STOCKPILE, FOOD_STOCKPILE, GATHERING, BUILD_AREA, RESTRICTED }

## "blocks_building": nothing can be built on these tiles. "enforced": the game already acts on this zone
## (what citizens may do inside GATHERING, BUILD_AREA and RESTRICTED is decided by policies, see PolicyEngine.is_permitted).
const INFO := {
	Type.LOG_STOCKPILE: {"item": "log_stockpile", "label": "Log stockpile", "color": Color(0.92, 0.55, 0.2), "blocks_building": true, "enforced": true},
	Type.FOOD_STOCKPILE: {"item": "food_stockpile", "label": "Food stockpile", "color": Color(0.45, 0.85, 0.35), "blocks_building": true, "enforced": true},
	Type.GATHERING: {"item": "gathering", "label": "Gathering area", "color": Color(0.3, 0.6, 0.95), "blocks_building": false, "enforced": true},
	Type.BUILD_AREA: {"item": "build_area", "label": "Build area", "color": Color(0.95, 0.88, 0.4), "blocks_building": false, "enforced": true},
	Type.RESTRICTED: {"item": "restricted", "label": "Restricted area", "color": Color(0.85, 0.25, 0.25), "blocks_building": false, "enforced": true},
	Type.NONE: {"item": "", "label": "Clear zone", "color": Color(0.85, 0.85, 0.85), "blocks_building": false, "enforced": true},
}

## The paint brushes in the order of the number keys (1, 2, 3...) in zone mode
const BRUSHES := [Type.LOG_STOCKPILE, Type.FOOD_STOCKPILE, Type.GATHERING, Type.BUILD_AREA, Type.RESTRICTED, Type.NONE]

signal cell_changed(cell: Vector3i, old_type: int, new_type: int)

var _cells: Dictionary = {} # Vector3i -> Type (a tile with no zone is simply absent)
var _sorted: Dictionary = {} # Type -> Array[Vector3i], rebuilt lazily after a change

func get_type(cell: Vector3i) -> int:
	return _cells.get(cell, Type.NONE)

## Designates a tile (Type.NONE clears it). Returns false if it already was that.
func set_type(cell: Vector3i, type: int) -> bool:
	var old := get_type(cell)
	if old == type:
		return false
	if type == Type.NONE:
		_cells.erase(cell)
	else:
		_cells[cell] = type
	_sorted.erase(old)
	_sorted.erase(type)
	cell_changed.emit(cell, old, type)
	return true

## Every tile of a zone, in a fixed order (by x, then z): pile slots fill the first tile before the next
func cells_of(type: int) -> Array[Vector3i]:
	if not _sorted.has(type):
		var list: Array[Vector3i] = []
		for cell in _cells:
			if _cells[cell] == type:
				list.append(cell)
		list.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return a.x < b.x or (a.x == b.x and a.z < b.z))
		_sorted[type] = list
	return _sorted[type]

func has_any(type: int) -> bool:
	return not cells_of(type).is_empty()

func blocks_building(cell: Vector3i) -> bool:
	return is_blocking(get_type(cell))

func clear() -> void:
	for cell in _cells.keys():
		set_type(cell, Type.NONE)

# --- Type info ---------------------------------------------------------------------------------------------------

static func is_valid(type: int) -> bool:
	return INFO.has(type)

static func is_blocking(type: int) -> bool:
	return INFO.has(type) and INFO[type]["blocks_building"]

static func label(type: int) -> String:
	return INFO[type]["label"] if INFO.has(type) else "?"

static func color(type: int) -> Color:
	return INFO[type]["color"] if INFO.has(type) else Color.WHITE

static func item_name(type: int) -> String:
	return INFO[type]["item"] if INFO.has(type) else ""

static func type_from_item(item: String) -> int:
	for type in INFO:
		if INFO[type]["item"] == item and item != "":
			return type
	return Type.NONE

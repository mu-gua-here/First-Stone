class_name WorldScene
extends NavigationRegion3D

@onready var base: GridMap = $Base
@onready var structures: GridMap = $Structures

func get_base() -> GridMap:
	return base

func get_structures() -> GridMap:
	return structures

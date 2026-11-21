class_name SaveData
extends Resource

## What a saved game keeps, written to user://savegame.tres by SaveManager. First stage: structures, logs and fruit.
##
## Rules that make a save survive a NEW BUILD of the game:
##  * Things are saved by NAME (a structure's item_name), never by index: re-exporting the MeshLibrary reorders indices.
##  * Anything derived is NOT saved and is rebuilt on load (stockpile counts are a live count of the settled props).
##  * Loose props (logs, fruit) are parallel packed arrays, not one dictionary each: smaller and faster.
##  * Bump CURRENT_VERSION when a field changes meaning and migrate in SaveManager._migrate(); new fields just take defaults.

const CURRENT_VERSION := 1

@export var save_version := CURRENT_VERSION
@export var saved_unix_time := 0
@export var build_version := "" # project setting application/config/version, for debugging only

# --- Buildings on the Structures GridMap: one entry per building ---
@export var structure_names := PackedStringArray() # Structure.item_name
@export var structure_positions := PackedVector3Array()
@export var structure_yaws := PackedFloat32Array()

# --- Zones: which tiles are designated as what (stockpile, gathering...), by zone NAME ---
@export var zones_saved := false # false in saves from before zones existed: the starting zones are kept
@export var zone_cells := PackedVector3Array() # (x, y, z) of each zoned tile
@export var zone_names := PackedStringArray() # ZoneMap item name, parallel to zone_cells

# --- Loose resource props (logs, fruit): one entry per prop ---
@export var prop_types := PackedStringArray()
@export var prop_positions := PackedVector3Array()
@export var prop_rotations := PackedVector3Array() # Euler angles
@export var prop_amounts := PackedInt32Array()

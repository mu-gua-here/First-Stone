extends HBoxContainer
class_name PolicyActionRow

## One action of a rule's THEN list (policy_action_row.tscn). Edits its Action in place.
## [what to do v]  [activity v]  [zone v]  [up]  [X]
## The activity dropdown only shows for Allow / Forbid; the zone dropdown for Allow / Forbid / Go to.

signal changed
signal remove_requested
signal move_requested(direction: int) # -1 = earlier in the list, +1 = later

@onready var _kind_option: OptionButton = %KindOption
@onready var _activity_option: OptionButton = %ActivityOption
@onready var _zone_option: OptionButton = %ZoneOption
@onready var _up_button: Button = %UpButton
@onready var _remove_button: Button = %RemoveButton

var _action: Action
var _kinds: Array[int] = [] # lines up with the kind dropdown's items (-1 = a category heading)
var _zones: Array[int] = [] # lines up with the zone dropdown's items (ZoneMap.Type)
var _loading := false
var _built := false


## `first` = the first action of the rule (its Up button is disabled)
func setup(action: Action, first: bool) -> void:
	_action = action
	if not _built:
		_build()
	_loading = true
	_kind_option.select(_kinds.find(action.kind))
	_activity_option.select(action.activity)
	_zone_option.select(_zones.find(action.zone))
	_up_button.disabled = first
	_loading = false
	_update_visibility()


func _build() -> void:
	_built = true
	for category in PolicyCatalog.ACTION_CATEGORIES:
		_kind_option.add_separator(category)
		_kinds.append(-1)
		for entry in PolicyCatalog.ACTIONS:
			if entry["cat"] == category:
				_kind_option.add_item(entry["label"])
				_kinds.append(entry["kind"])
	for activity in PolicyCatalog.ACTIVITY_LABELS:
		var text: String = PolicyCatalog.ACTIVITY_LABELS[activity]
		_activity_option.add_item(text.substr(0, 1).to_upper() + text.substr(1), activity)
	for type in ZoneMap.BRUSHES:
		if type != ZoneMap.Type.NONE:
			_zone_option.add_item(ZoneMap.label(type))
			_zones.append(type)

	PolicyCatalog.tint(_kind_option, PolicyCatalog.COLOR_ACTION)
	PolicyCatalog.tint(_activity_option, PolicyCatalog.COLOR_VALUE)
	PolicyCatalog.tint(_zone_option, PolicyCatalog.COLOR_NAME)
	PolicyCatalog.tint(_remove_button, PolicyCatalog.COLOR_NO)

	_kind_option.item_selected.connect(_on_kind_selected)
	_activity_option.item_selected.connect(_on_activity_selected)
	_zone_option.item_selected.connect(_on_zone_selected)
	_up_button.pressed.connect(func() -> void: move_requested.emit(-1))
	_remove_button.pressed.connect(func() -> void: remove_requested.emit())


func _update_visibility() -> void:
	var permission := _action.is_permission()
	_activity_option.visible = permission
	_zone_option.visible = permission or _action.kind == Action.Kind.GO_TO_ZONE


func _on_kind_selected(index: int) -> void:
	if _loading or _kinds[index] < 0:
		return
	_action.kind = _kinds[index] as Action.Kind
	# Walking *to* the restricted area is rarely the point, so Go to starts on the gathering area
	if _action.kind == Action.Kind.GO_TO_ZONE and _action.zone == ZoneMap.Type.RESTRICTED:
		_action.zone = ZoneMap.Type.GATHERING
		_zone_option.select(_zones.find(_action.zone))
	_update_visibility()
	changed.emit()


func _on_activity_selected(index: int) -> void:
	if _loading:
		return
	_action.activity = _activity_option.get_item_id(index) as Action.Activity
	changed.emit()


func _on_zone_selected(index: int) -> void:
	if _loading:
		return
	_action.zone = _zones[index]
	changed.emit()

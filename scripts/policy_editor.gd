extends Node
class_name PolicyEditor

## The policy editor (prototype): the player's rule book for the settlement, reached through the NoticeBoard.
## The UI is the PolicyEditor scene instanced in main.tscn (edit it in the editor); this script wires it to PolicyEngine.
##
##  - Rules tab: the list of policies (highest priority first: the first rule that fits a citizen wins), and a
##    "Legal Mad Libs" form for the selected rule: WHEN <conditions> THEN [Action]. The conditions are a tree of
##    PolicyGroupRows (each its own ALL/AND or ANY/OR, optionally NOT) holding PolicyClauseRows (each optionally NOT),
##    so AND, OR and NOT can be mixed freely. Below it: the rule read back as a colour-coded sentence, and a live
##    preview of how many citizens the rule fits right now.
##  - Data Hub tab: every citizen's vital stats, refreshed while open.
##
## Rules are the same Policy / Condition / Action Resources PolicyEngine.think() runs, and are edited in place, so a change
## takes effect the moment the editor closes. The editor pauses the world like the pause menu does (not online: the world
## runs on the server there, and online clients can't change the rules from here yet).
## Closes with the Close button, a click on the dimmed area, Esc or the pause key.
## Colours: see PolicyCatalog (WHEN/THEN gold, fields blue, values green, AND/OR orange, NOT red, actions violet, names teal).

const PAUSE_ACTION := &"pause_menu" # project.godot input map
const REFRESH_EVERY := 0.5 # seconds between live-preview / Data Hub refreshes
const NEW_RULE_NAME := "New rule"
const MAX_NAMES_SHOWN := 6
const HUB_COLUMNS := ["Name", "Age", "Health", "Hunger", "Energy", "Happiness", "Task", "Job"]
const STAT_WARN_BELOW := 60.0
const STAT_BAD_BELOW := 30.0
## The whole editor window is drawn at this fraction of its authored size (on top of the game's UI scale)
const EDITOR_SCALE := 0.75

## One condition of a rule's WHEN sentence (policy_clause_row.tscn)
@export var clause_row_scene: PackedScene
## One bracket of conditions with its own AND / OR / NOT (policy_group_row.tscn)
@export var group_row_scene: PackedScene
## One action of the THEN list (policy_action_row.tscn)
@export var action_row_scene: PackedScene

@onready var _layer: CanvasLayer = %Layer
@onready var _dim: ColorRect = %Dim
@onready var _center: Control = $Layer/Center # full-screen holder of the panel; scaled (a container would reset its child's scale)
@onready var _title: Label = %Title
@onready var _close_button: Button = %CloseButton
@onready var _online_note: Label = %OnlineNote
@onready var _tabs: TabContainer = %Tabs

@onready var _rule_list: ItemList = %RuleList
@onready var _new_button: Button = %NewButton
@onready var _delete_button: Button = %DeleteButton
@onready var _up_button: Button = %UpButton
@onready var _down_button: Button = %DownButton
@onready var _reset_button: Button = %ResetButton
@onready var _reset_dialog: ConfirmationDialog = %ResetDialog

@onready var _empty_note: Label = %EmptyNote
@onready var _form: VBoxContainer = %Form
@onready var _name_edit: LineEdit = %NameEdit
@onready var _enabled_check: CheckBox = %EnabledCheck
@onready var _idle_check: CheckBox = %IdleCheck
@onready var _survival_check: CheckBox = %SurvivalCheck
@onready var _default_note: Label = %DefaultNote
@onready var _when_label: Label = %WhenLabel
@onready var _then_label: Label = %ThenLabel
@onready var _condition_holder: VBoxContainer = %ConditionHolder
@onready var _action_holder: VBoxContainer = %ActionHolder
@onready var _add_action_button: Button = %AddActionButton
@onready var _sentence: RichTextLabel = %Sentence
@onready var _preview: RichTextLabel = %PreviewLabel

@onready var _hub_summary: RichTextLabel = %HubSummary
@onready var _hub_tree: Tree = %HubTree

var _policy: Policy = null # the rule being edited
var _root_group: PolicyGroupRow = null # the editable conditions of _policy
var _loading := false # true while the form is filled from a rule, so that doesn't write back into it
var _prev_mouse_mode := Input.MOUSE_MODE_VISIBLE
var _was_shift_locked := false # the camera's pointer lock when the editor opened, put back when it closes
var _refresh_timer := 0.0


func _ready() -> void:
	add_to_group("policy_editor")
	# Globals.is_gameplay_input_blocked() reads this group: the always-running nodes (time control, quick save / load, pause
	# key, build / demolish keys...) check it and ignore their keys while the editor is open
	add_to_group("gameplay_input_blocker")
	_layer.visible = false
	_center.scale = Vector2.ONE * EDITOR_SCALE
	_center.resized.connect(_update_center_pivot)
	_update_center_pivot.call_deferred()

	PolicyCatalog.tint(_title, PolicyCatalog.COLOR_KEYWORD)
	PolicyCatalog.tint(_when_label, PolicyCatalog.COLOR_KEYWORD)
	PolicyCatalog.tint(_then_label, PolicyCatalog.COLOR_KEYWORD)
	PolicyCatalog.tint(_name_edit, PolicyCatalog.COLOR_NAME)
	PolicyCatalog.tint(_add_action_button, PolicyCatalog.COLOR_ACTION)
	PolicyCatalog.tint(_default_note, PolicyCatalog.COLOR_KEYWORD)
	PolicyCatalog.tint(_online_note, PolicyCatalog.COLOR_WARN)
	PolicyCatalog.tint(_delete_button, PolicyCatalog.COLOR_NO)
	PolicyCatalog.tint(_new_button, PolicyCatalog.COLOR_GOOD)

	for i in HUB_COLUMNS.size():
		_hub_tree.set_column_title(i, HUB_COLUMNS[i])
		_hub_tree.set_column_expand(i, i == 0 or i == 7)
		_hub_tree.set_column_custom_minimum_width(i, 150 if i == 0 else 90)

	_dim.gui_input.connect(_on_dim_gui_input)
	_close_button.pressed.connect(close)
	_tabs.tab_changed.connect(func(_i: int) -> void: _refresh_hub())

	_rule_list.item_selected.connect(_on_rule_selected)
	_new_button.pressed.connect(_on_new_pressed)
	_delete_button.pressed.connect(_on_delete_pressed)
	_up_button.pressed.connect(_on_move_pressed.bind(-1))
	_down_button.pressed.connect(_on_move_pressed.bind(1))
	_reset_button.pressed.connect(_reset_dialog.popup_centered)
	_reset_dialog.confirmed.connect(_on_reset_confirmed)

	_name_edit.text_changed.connect(_on_name_changed)
	_enabled_check.toggled.connect(func(on: bool) -> void: _set_flag("enabled", on))
	_idle_check.toggled.connect(func(on: bool) -> void: _set_flag("only_when_idle", on))
	_survival_check.toggled.connect(func(on: bool) -> void: _set_flag("survival", on))
	_add_action_button.pressed.connect(_on_add_action_pressed)


# --- Opening and closing -----------------------------------------------------------------------------------------

func _update_center_pivot() -> void:
	_center.pivot_offset = _center.size * 0.5 # scale about the middle of the screen, so the panel stays centred

func _view() -> Node:
	return get_tree().get_first_node_in_group("view")

func is_open() -> bool:
	return _layer.visible

## Called by the NoticeBoard when the player reads the notices
func open() -> void:
	if is_open():
		return
	for blocker in get_tree().get_nodes_in_group("gameplay_input_blocker"):
		if blocker != self and blocker.has_method("is_open") and bool(blocker.call("is_open")):
			return # the pause menu or another dialog is already showing
	_prev_mouse_mode = Input.mouse_mode
	var view := _view()
	_was_shift_locked = view != null and bool(view.get("shift_locked"))
	Globals.cancel_gameplay_input()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_online_note.visible = Globals.online_client
	_tabs.visible = not Globals.online_client
	_layer.visible = true
	_set_paused(true)
	_refresh_list(_policy)
	_refresh_hub()
	_refresh_timer = REFRESH_EVERY

func close() -> void:
	if not is_open():
		return
	_layer.visible = false
	_set_paused(false)
	# The camera drops its pointer lock on its own as soon as the cursor is freed (view._sync_shift_lock_state), so putting
	# the mouse mode back alone leaves the game thinking it isn't locked: restore it through the camera instead
	var view := _view()
	if _was_shift_locked and view != null and view.has_method("set_shift_lock"):
		view.call("set_shift_lock", true)
	else:
		Input.mouse_mode = _prev_mouse_mode

func _set_paused(on: bool) -> void:
	if Globals.online_client or Globals.hosting_world:
		return # the world runs on the server; pausing here would only stall the network
	get_tree().paused = on

func _input(event: InputEvent) -> void:
	if not is_open() or not event is InputEventKey or not event.pressed or event.echo:
		return
	if _reset_dialog.visible:
		return # Esc cancels the dialog, not the editor
	# Typing a rule name must not close the editor when the name has a "p" in it
	var typing := get_viewport().gui_get_focus_owner() is LineEdit
	if event.is_action_pressed("ui_cancel") or (not typing and event.is_action_pressed(PAUSE_ACTION)):
		close()
		get_viewport().set_input_as_handled()

## While open nothing underneath should react (only matters where the tree isn't paused: hosting a world)
func _unhandled_input(_event: InputEvent) -> void:
	if is_open():
		get_viewport().set_input_as_handled()

func _on_dim_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		close()

func _process(delta: float) -> void:
	if not is_open():
		return
	_refresh_timer -= delta
	if _refresh_timer > 0.0:
		return
	_refresh_timer = REFRESH_EVERY
	_refresh_preview()
	_refresh_hub()


# --- The rule list -----------------------------------------------------------------------------------------------

func _list_text(policy: Policy, index: int) -> String:
	var text := "%d. %s" % [index + 1, policy.policy_name if policy.policy_name != "" else "(unnamed rule)"]
	if policy.is_default:
		text += "  [tradition]"
	if not policy.enabled:
		text += "  (off)"
	return text

## Rule names are teal; a switched-off rule is greyed out
func _style_list_item(index: int) -> void:
	var policy: Policy = PolicyEngine.policies[index]
	_rule_list.set_item_text(index, _list_text(policy, index))
	_rule_list.set_item_custom_fg_color(index, PolicyCatalog.COLOR_NAME if policy.enabled else PolicyCatalog.COLOR_MUTED)

## Rebuilds the list and selects `select` (or the first rule)
func _refresh_list(select: Policy = null) -> void:
	_loading = true
	_rule_list.clear()
	for i in PolicyEngine.policies.size():
		_rule_list.add_item("")
		_style_list_item(i)
	var index := PolicyEngine.policies.find(select)
	if index < 0 and not PolicyEngine.policies.is_empty():
		index = 0
	if index >= 0:
		_rule_list.select(index)
		_policy = PolicyEngine.policies[index]
	else:
		_policy = null
	_loading = false
	_load_form()

func _on_rule_selected(index: int) -> void:
	_policy = PolicyEngine.policies[index]
	_load_form()

func _update_buttons() -> void:
	var index := PolicyEngine.policies.find(_policy)
	_delete_button.disabled = _policy == null or _policy.is_default
	_up_button.disabled = index <= 0
	_down_button.disabled = index < 0 or index >= PolicyEngine.policies.size() - 1

func _on_new_pressed() -> void:
	# Starts as the design doc's example: WHEN [Age] is above [12] THEN [Gather resources]
	var when: Array[Condition] = [Condition.leaf("age", ">", 12)]
	var rule := Policy.new()
	rule.policy_name = NEW_RULE_NAME
	rule.condition = Condition.op_and(when)
	rule.action = Action.new_assign_gather()
	rule.only_when_idle = true
	# Just above the lowest rule (the gathering tradition), so it outranks it; the player moves it from there
	rule.priority = PolicyEngine.policies.back().priority + 5 if not PolicyEngine.policies.is_empty() else 0
	PolicyEngine.add_policy(rule)
	_refresh_list(rule)
	_name_edit.grab_focus()
	_name_edit.select_all()

func _on_delete_pressed() -> void:
	PolicyEngine.remove_policy(_policy)
	_refresh_list(null)

func _on_move_pressed(direction: int) -> void:
	PolicyEngine.move_policy(_policy, direction)
	_refresh_list(_policy)

func _on_reset_confirmed() -> void:
	PolicyEngine.reset_to_default_traditions()
	_refresh_list(null)


# --- The rule form -----------------------------------------------------------------------------------------------

func _load_form() -> void:
	_update_buttons()
	_form.visible = _policy != null
	_empty_note.visible = _policy == null
	_clear_conditions()
	if _policy == null:
		return
	_loading = true
	_name_edit.text = _policy.policy_name
	_enabled_check.button_pressed = _policy.enabled
	_idle_check.button_pressed = _policy.only_when_idle
	_survival_check.button_pressed = _policy.survival
	_default_note.visible = _policy.is_default

	_root_group = group_row_scene.instantiate()
	_condition_holder.add_child(_root_group)
	_root_group.setup(_policy.condition, 0, group_row_scene, clause_row_scene, false)
	_root_group.changed.connect(_apply_condition)

	_rebuild_action_rows()
	_loading = false
	_refresh_texts()

## One row per action of the rule, in order
func _rebuild_action_rows() -> void:
	for child in _action_holder.get_children():
		_action_holder.remove_child(child)
		child.queue_free()
	if _policy == null:
		return
	for i in _policy.actions.size():
		var action := _policy.actions[i]
		if action == null:
			continue
		var row: PolicyActionRow = action_row_scene.instantiate()
		_action_holder.add_child(row)
		row.setup(action, i == 0)
		row.changed.connect(_after_edit)
		row.remove_requested.connect(_on_action_remove.bind(action))
		row.move_requested.connect(_on_action_move.bind(action))

func _clear_conditions() -> void:
	if _root_group != null:
		_condition_holder.remove_child(_root_group)
		_root_group.queue_free()
		_root_group = null

## Rebuilds the rule's Condition from the group tree (an empty tree = no condition = matches everyone)
func _apply_condition() -> void:
	if _loading or _policy == null or _root_group == null:
		return
	_policy.condition = _root_group.to_condition()
	_after_edit()

func _on_name_changed(text: String) -> void:
	if _loading or _policy == null:
		return
	_policy.policy_name = text
	_after_edit()

func _set_flag(property: String, on: bool) -> void:
	if _loading or _policy == null:
		return
	_policy.set(property, on)
	_after_edit()

func _on_add_action_pressed() -> void:
	if _loading or _policy == null:
		return
	_policy.actions.append(Action.new_assign_gather())
	_rebuild_action_rows()
	_after_edit()

func _on_action_remove(action: Action) -> void:
	if _policy == null:
		return
	_policy.actions.erase(action)
	_rebuild_action_rows()
	_after_edit()

func _on_action_move(direction: int, action: Action) -> void:
	if _policy == null:
		return
	var i := _policy.actions.find(action)
	var j := i + direction
	if i < 0 or j < 0 or j >= _policy.actions.size():
		return
	_policy.actions.remove_at(i)
	_policy.actions.insert(j, action)
	_rebuild_action_rows()
	_after_edit()

func _after_edit() -> void:
	if _loading or _policy == null:
		return
	var index := PolicyEngine.policies.find(_policy)
	if index >= 0:
		_style_list_item(index)
	_refresh_texts()
	PolicyEngine.policies_changed.emit()


# --- Sentence, live preview and Data Hub -------------------------------------------------------------------------

func _refresh_texts() -> void:
	_sentence.text = PolicyCatalog.describe(_policy, true) if _policy != null else ""
	_refresh_preview()

func _citizens() -> Array:
	var found: Array = []
	var builder = Globals.builder
	if builder == null:
		return found
	for citizen in builder.citizens:
		if is_instance_valid(citizen):
			found.append(citizen)
	return found

func _refresh_preview() -> void:
	if _policy == null:
		_preview.text = ""
		return
	var citizens := _citizens()
	if citizens.is_empty():
		_preview.text = PolicyCatalog.paint("No citizens to test this rule on yet.", PolicyCatalog.COLOR_MUTED, true)
		return
	var matches := PolicyEngine.find_matches(_policy.condition, citizens)
	var text := "Fits %s of %d citizens right now" % [
		PolicyCatalog.paint(str(matches.size()), PolicyCatalog.COLOR_VALUE, true), citizens.size()]
	if not matches.is_empty():
		var names: Array[String] = []
		for citizen in matches.slice(0, MAX_NAMES_SHOWN):
			names.append(PolicyCatalog.paint(citizen.data.citizen_name, PolicyCatalog.COLOR_NAME, true))
		text += ": " + ", ".join(names)
		if matches.size() > MAX_NAMES_SHOWN:
			text += " and %d more" % (matches.size() - MAX_NAMES_SHOWN)
	text += "."
	if not _policy.enabled:
		text += " " + PolicyCatalog.paint("(The rule is switched off.)", PolicyCatalog.COLOR_MUTED, true)
	_preview.text = text

## Red when a stat is low, amber when middling, green when healthy
func _stat_color(value: float) -> Color:
	if value < STAT_BAD_BELOW:
		return PolicyCatalog.COLOR_BAD
	if value < STAT_WARN_BELOW:
		return PolicyCatalog.COLOR_WARN
	return PolicyCatalog.COLOR_GOOD

func _refresh_hub() -> void:
	if not is_open() or _tabs.current_tab != 1:
		return
	var citizens := _citizens()
	var root := _hub_tree.get_root()
	# Rows are reused between refreshes so the scroll position doesn't jump; only a change in population rebuilds them
	if root == null or root.get_child_count() != citizens.size():
		_hub_tree.clear()
		root = _hub_tree.create_item()
		for i in citizens.size():
			_hub_tree.create_item(root)
	var item := root.get_first_child()
	var totals := {"health": 0.0, "hunger": 0.0, "energy": 0.0, "happiness": 0.0}
	for citizen in citizens:
		item.set_text(0, citizen.data.citizen_name)
		item.set_custom_color(0, PolicyCatalog.COLOR_NAME)
		item.set_text(1, str(PolicyEngine.get_field(citizen, "age")))
		item.set_custom_color(1, PolicyCatalog.COLOR_VALUE)
		for i in range(2, 6):
			var field: String = HUB_COLUMNS[i].to_lower()
			var value := float(PolicyEngine.get_field(citizen, field))
			totals[field] += value
			item.set_text(i, str(roundi(value)))
			item.set_custom_color(i, _stat_color(value))
		item.set_text(6, str(PolicyEngine.get_field(citizen, "task")))
		item.set_custom_color(6, PolicyCatalog.COLOR_ACTION)
		var job := str(PolicyEngine.get_field(citizen, "job"))
		item.set_text(7, job if job != "" else "-")
		item.set_custom_color(7, PolicyCatalog.COLOR_VALUE if job != "" else PolicyCatalog.COLOR_MUTED)
		item = item.get_next()
	if citizens.is_empty():
		_hub_summary.text = PolicyCatalog.paint("Nobody lives here yet.", PolicyCatalog.COLOR_MUTED, true)
		return
	var n := float(citizens.size())
	var parts: Array[String] = []
	for stat in ["health", "hunger", "energy", "happiness"]:
		var average: float = totals[stat] / n
		parts.append("%s %s" % [stat, PolicyCatalog.paint(str(roundi(average)), _stat_color(average), true)])
	_hub_summary.text = "Population %s  |  average %s" % [
		PolicyCatalog.paint(str(citizens.size()), PolicyCatalog.COLOR_VALUE, true), ", ".join(parts)]

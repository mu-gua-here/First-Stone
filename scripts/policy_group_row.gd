extends HBoxContainer
class_name PolicyGroupRow

## A bracket of a rule's WHEN sentence: "[NOT] ALL / ANY of these:" followed by conditions (PolicyClauseRow) and further groups
## (more PolicyGroupRows), so a rule can mix AND, OR and NOT freely, e.g.
##     (Age is at least 16 AND Is hungry is no) OR NOT (Task is eating)
## The editor shows one root group per rule. Each group has its own AND / OR switch and its own YES / NOT toggle; every condition has
## its own YES / NOT toggle too (NOT flips it). to_condition() turns the whole tree back into the Condition PolicyEngine evaluates.
## A bar down the left side takes a colour from the group's depth so you can see which conditions belong together.

signal changed
signal removed

@onready var _bar: ColorRect = %Bar
@onready var _not_toggle: Button = %NotToggle
@onready var _mode_option: OptionButton = %ModeOption
@onready var _remove_button: Button = %RemoveButton
@onready var _empty_note: Label = %EmptyNote
@onready var _items: VBoxContainer = %Items
@onready var _add_condition_button: Button = %AddConditionButton
@onready var _add_group_button: Button = %AddGroupButton

# A scene can't instance itself, so the editor hands both row scenes down the tree
var _group_scene: PackedScene
var _clause_scene: PackedScene
var _depth := 0
var _loading := false


func _ready() -> void:
	_mode_option.add_item("ALL of these (AND)")
	_mode_option.add_item("ANY of these (OR)")
	PolicyCatalog.tint(_mode_option, PolicyCatalog.COLOR_LOGIC)
	PolicyCatalog.tint(_remove_button, PolicyCatalog.COLOR_NO)
	PolicyCatalog.tint(_empty_note, PolicyCatalog.COLOR_MUTED)
	PolicyCatalog.tint(_add_condition_button, PolicyCatalog.COLOR_FIELD)
	PolicyCatalog.tint(_add_group_button, PolicyCatalog.COLOR_LOGIC)

	_not_toggle.toggled.connect(_on_not_toggled)
	_mode_option.item_selected.connect(func(_i: int) -> void: _emit_changed())
	_remove_button.pressed.connect(func() -> void: removed.emit())
	_add_condition_button.pressed.connect(_on_add_condition_pressed)
	_add_group_button.pressed.connect(_on_add_group_pressed)


## Fills the group from a Condition (null = an empty group). Call after the row is in the tree.
func setup(condition: Condition, depth: int, group_scene: PackedScene, clause_scene: PackedScene, removable: bool) -> void:
	_loading = true
	_depth = depth
	_group_scene = group_scene
	_clause_scene = clause_scene
	_bar.color = PolicyCatalog.GROUP_COLORS[depth % PolicyCatalog.GROUP_COLORS.size()]
	_remove_button.visible = removable
	_add_group_button.visible = depth < PolicyCatalog.MAX_GROUP_DEPTH

	var node := _simplify(condition)
	var negated := false
	if node != null and node.kind == Condition.Kind.NOT and node.children[0].kind != Condition.Kind.LEAF:
		negated = true # NOT around an AND / OR: the box on the group flips all of it
		node = node.children[0]
	_not_toggle.button_pressed = negated
	PolicyCatalog.style_not_toggle(_not_toggle, negated)

	var members: Array = []
	if node != null:
		if node.kind == Condition.Kind.AND or node.kind == Condition.Kind.OR:
			members = node.children
			_mode_option.select(1 if node.kind == Condition.Kind.OR else 0)
		else:
			members = [node] # a lone condition: shown as a group of one
			_mode_option.select(0)
	for member in members:
		_add_item(member)
	_loading = false
	_update_empty_note()


## The Condition this group stands for; null when it is empty (an empty root = the rule applies to everyone, and an empty
## nested group simply drops out of its parent)
func to_condition() -> Condition:
	var parts: Array[Condition] = []
	for item in _items.get_children():
		var part: Condition = item.to_condition()
		if part != null:
			parts.append(part)
	if parts.is_empty():
		return null
	var node := Condition.op_or(parts) if _mode_option.selected == 1 else Condition.op_and(parts)
	return Condition.op_not(node) if _not_toggle.button_pressed else node


## Strips doubled NOTs (NOT NOT x = x) and empty NOTs so the tree only ever has the shapes the rows can show:
## a condition, NOT condition, or a group (optionally under NOT)
static func _simplify(condition: Condition) -> Condition:
	var c := condition
	while c != null and c.kind == Condition.Kind.NOT:
		if c.children.is_empty() or c.children[0] == null:
			return null
		var inner := c.children[0]
		if inner.kind != Condition.Kind.NOT:
			break
		if inner.children.is_empty() or inner.children[0] == null:
			return null
		c = inner.children[0]
	return c

static func _is_clause(c: Condition) -> bool:
	return c.kind == Condition.Kind.LEAF or (c.kind == Condition.Kind.NOT and c.children[0].kind == Condition.Kind.LEAF)

func _add_item(condition: Condition) -> void:
	var c := _simplify(condition)
	if c == null:
		return
	var row: Control
	if _is_clause(c):
		row = _clause_scene.instantiate()
		_items.add_child(row)
		row.setup(c)
	else:
		row = _group_scene.instantiate()
		_items.add_child(row)
		row.setup(c, _depth + 1, _group_scene, _clause_scene, true)
	row.changed.connect(_emit_changed)
	row.removed.connect(_on_item_removed.bind(row))

func _on_item_removed(row: Control) -> void:
	_items.remove_child(row)
	row.queue_free()
	_update_empty_note()
	_emit_changed()

func _on_add_condition_pressed() -> void:
	_add_item(Condition.leaf("age", ">=", 16))
	_update_empty_note()
	_emit_changed()

func _on_add_group_pressed() -> void:
	# A new group starts with one condition so it isn't an empty bracket that would vanish from the rule
	var starter: Array[Condition] = [Condition.leaf("age", ">=", 16)]
	_add_item(Condition.op_and(starter))
	_update_empty_note()
	_emit_changed()

func _update_empty_note() -> void:
	_empty_note.visible = _items.get_child_count() == 0

func _on_not_toggled(negated: bool) -> void:
	PolicyCatalog.style_not_toggle(_not_toggle, negated)
	_emit_changed()

func _emit_changed() -> void:
	if not _loading:
		changed.emit()

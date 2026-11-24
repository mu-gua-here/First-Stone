extends HBoxContainer
class_name PolicyClauseRow

## One "[YES/NOT] [Field] [is at least] [16]" blank of a rule's WHEN sentence. The layout lives in policy_clause_row.tscn; this
## script fills the dropdowns from PolicyCatalog and turns the choices back into a Condition (to_condition()): a leaf,
## wrapped in a NOT when the toggle is flipped from YES to NOT.

signal changed
signal removed

@onready var _not_toggle: Button = %NotToggle
@onready var _field_option: OptionButton = %FieldOption
@onready var _op_option: OptionButton = %OpOption
@onready var _value_spin: SpinBox = %ValueSpin
@onready var _value_choice: OptionButton = %ValueChoice
@onready var _value_text: LineEdit = %ValueText
@onready var _remove_button: Button = %RemoveButton

# Parallel to the field dropdown's items: the field id of each item, or "" for a category heading
var _field_ids: Array[String] = []
var _op_ids: Array[String] = []
var _choice_values: Array = [] # what each entry of the value dropdown stands for (true / false, or the choice strings)
var _loading := false


func _ready() -> void:
	PolicyCatalog.tint(_field_option, PolicyCatalog.COLOR_FIELD)
	PolicyCatalog.tint(_op_option, PolicyCatalog.COLOR_OP)
	PolicyCatalog.tint(_value_spin, PolicyCatalog.COLOR_VALUE)
	PolicyCatalog.tint(_value_text, PolicyCatalog.COLOR_VALUE)
	PolicyCatalog.tint(_remove_button, PolicyCatalog.COLOR_NO)

	_not_toggle.toggled.connect(_on_not_toggled)
	_field_option.item_selected.connect(_on_field_selected)
	_op_option.item_selected.connect(func(_i: int) -> void: _emit_changed())
	_value_choice.item_selected.connect(_on_value_choice_selected)
	_value_spin.value_changed.connect(func(_v: float) -> void: _emit_changed())
	_value_text.text_changed.connect(func(_t: String) -> void: _emit_changed())
	_remove_button.pressed.connect(func() -> void: removed.emit())


## Fills the row from a leaf, or from a NOT around a leaf. Call after the row is in the tree.
func setup(condition: Condition) -> void:
	_loading = true
	var leaf := condition
	var negated := false
	if condition.kind == Condition.Kind.NOT and not condition.children.is_empty():
		leaf = condition.children[0]
		negated = true
	_not_toggle.button_pressed = negated
	PolicyCatalog.style_not_toggle(_not_toggle, negated)

	_populate_fields(leaf.field)
	var index := _field_ids.find(leaf.field)
	if index < 0:
		index = _field_ids.find(_first_field())
	_field_option.select(index)
	_configure(_field_ids[index], leaf.op, leaf.value)
	_loading = false


func to_condition() -> Condition:
	var field := _field_ids[_field_option.selected]
	var type := PolicyCatalog.field_type(field)
	var op := _op_ids[maxi(_op_option.selected, 0)]
	var value = null
	match type:
		PolicyCatalog.ValueType.NUMBER:
			value = float(_value_spin.value) if PolicyCatalog.field_is_integer(field) else _value_spin.value
		PolicyCatalog.ValueType.BOOL, PolicyCatalog.ValueType.CHOICE:
			value = _choice_values[maxi(_value_choice.selected, 0)]
		PolicyCatalog.ValueType.TEXT:
			value = _value_text.text
	var leaf := Condition.leaf(field, op, value)
	return Condition.op_not(leaf) if _not_toggle.button_pressed else leaf


## Lists the fields under their category headings. Fields of a tier the society hasn't unlocked yet are left out (so the
## list stays short early on), except one the rule already uses.
func _populate_fields(current: String) -> void:
	_field_option.clear()
	_field_ids.clear()
	var any_locked := false
	for category in PolicyCatalog.FIELD_CATEGORIES:
		var shown: Array[String] = []
		for id in PolicyCatalog.field_ids_in(category):
			if PolicyEngine.is_field_unlocked(id) or id == current:
				shown.append(id)
			else:
				any_locked = true
		if shown.is_empty():
			continue
		_add_heading(category)
		for id in shown:
			_add_field_item(id)
	if current != "" and not PolicyCatalog.has_field(current):
		_add_heading("Other")
		_add_field_item(current) # a field the catalog doesn't know: keep it rather than lose it
	if any_locked:
		_add_heading("More unlock as your society grows")

func _add_heading(text: String) -> void:
	_field_option.add_separator(text)
	_field_ids.append("")

func _add_field_item(id: String) -> void:
	var locked := not PolicyEngine.is_field_unlocked(id)
	_field_option.add_item(PolicyCatalog.field_label(id) + (" (locked)" if locked else ""))
	_field_option.set_item_tooltip(_field_option.item_count - 1, PolicyCatalog.field_hint(id))
	_field_ids.append(id)

func _first_field() -> String:
	for id in _field_ids:
		if id != "":
			return id
	return ""


## Shows the right operator list and value editor for `field`, preset to op / value
func _configure(field: String, op: String, value) -> void:
	var type := PolicyCatalog.field_type(field)
	_op_option.clear()
	_op_ids.clear()
	for pair in PolicyCatalog.ops_for(type):
		_op_option.add_item(pair[1])
		_op_ids.append(pair[0])
	# Yes/no fields only ever say "is": a stored "!=" is shown as the opposite answer
	if type == PolicyCatalog.ValueType.BOOL and op == "!=":
		op = "=="
		value = not bool(value)
	_op_option.select(maxi(_op_ids.find(op), 0))

	_value_spin.visible = type == PolicyCatalog.ValueType.NUMBER
	_value_choice.visible = type == PolicyCatalog.ValueType.BOOL or type == PolicyCatalog.ValueType.CHOICE
	_value_text.visible = type == PolicyCatalog.ValueType.TEXT

	match type:
		PolicyCatalog.ValueType.NUMBER:
			var info: Dictionary = PolicyCatalog.FIELDS.get(field, {})
			_value_spin.min_value = float(info.get("min", 0))
			_value_spin.max_value = float(info.get("max", 100))
			_value_spin.step = 1.0
			_value_spin.value = float(value) if (value is int or value is float) else float(PolicyCatalog.default_value(field))
		PolicyCatalog.ValueType.BOOL:
			_value_choice.clear()
			_value_choice.add_item("yes")
			_value_choice.add_item("no")
			_choice_values = [true, false]
			_value_choice.select(0 if bool(value) else 1)
		PolicyCatalog.ValueType.CHOICE:
			_value_choice.clear()
			_choice_values = []
			for choice in PolicyCatalog.FIELDS[field]["choices"]:
				_value_choice.add_item(str(choice))
				_choice_values.append(choice)
			_value_choice.select(maxi(_choice_values.find(value), 0))
		PolicyCatalog.ValueType.TEXT:
			_value_text.text = str(value) if value != null else ""
	_update_value_tint()

## yes is green and no is red wherever they appear; every other value is cream
func _update_value_tint() -> void:
	var field := _field_ids[_field_option.selected]
	var color := PolicyCatalog.COLOR_VALUE
	if PolicyCatalog.field_type(field) == PolicyCatalog.ValueType.BOOL:
		color = PolicyCatalog.value_color(field, _choice_values[maxi(_value_choice.selected, 0)])
	PolicyCatalog.tint(_value_choice, color)
	_value_choice.get_popup().add_theme_color_override("font_color", PolicyCatalog.COLOR_VALUE)


func _on_value_choice_selected(_index: int) -> void:
	_update_value_tint()
	_emit_changed()

func _on_not_toggled(negated: bool) -> void:
	PolicyCatalog.style_not_toggle(_not_toggle, negated)
	_emit_changed()

func _on_field_selected(index: int) -> void:
	var field := _field_ids[index]
	_loading = true
	_configure(field, PolicyCatalog.default_op(PolicyCatalog.field_type(field)), PolicyCatalog.default_value(field))
	_loading = false
	_emit_changed()

func _emit_changed() -> void:
	if not _loading:
		changed.emit()

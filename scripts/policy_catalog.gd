extends RefCounted
class_name PolicyCatalog

## What the policy editor offers the player: the friendly name, category, type, range and unlock tier of every field a rule can
## test, and the friendly name and category of every Action. The engine's own lookup table (PolicyEngine._CITIZEN_FIELDS) stays
## the source of truth for what a field MEANS; this only describes how the editor presents it. A new field is added in
## both places: the getter in PolicyEngine, a line here.

enum ValueType { NUMBER, BOOL, CHOICE, TEXT }

## Variable progression (see Policy_System_Design): early rules only see physical traits and the situation around
## the citizen; social stats unlock later (PolicyEngine.unlock_tier, e.g. when an administration building is built).
## Fields of a locked tier are hidden from the dropdowns (except in a rule that already uses them).
const TIER_PHYSICAL := "physical"
const TIER_SITUATION := "situation"
const TIER_SOCIAL := "social"

## What Citizen.task_name() can return
const TASKS := ["idle", "gathering", "building", "pushing", "hauling", "eating", "resting", "walking", "wandering"]

## Colours: a small warm palette so the editor reads as one piece. Yes / no always wins: any yes or no is green / red
## wherever it appears (values, the YES / NOT toggles). The rest of a sentence is: amber for structure (WHEN, THEN, the
## title), burnt orange for AND / OR, blue for fields, cream for values, violet for actions, teal for names (rules, citizens).
const COLOR_YES := Color(0.486, 0.78, 0.498)
const COLOR_NO := Color(0.898, 0.396, 0.365)
const COLOR_KEYWORD := Color(0.91, 0.69, 0.294)
const COLOR_LOGIC := Color(0.851, 0.541, 0.29)
const COLOR_FIELD := Color(0.498, 0.698, 0.867)
const COLOR_OP := Color(0.725, 0.706, 0.639)
const COLOR_VALUE := Color(0.937, 0.902, 0.8)
const COLOR_ACTION := Color(0.718, 0.612, 0.902)
const COLOR_NAME := Color(0.435, 0.78, 0.71)
const COLOR_MUTED := Color(0.549, 0.533, 0.471)
const COLOR_NOT := COLOR_NO
const COLOR_GOOD := COLOR_YES # stat colours in the Data Hub: healthy / middling / low
const COLOR_WARN := COLOR_KEYWORD
const COLOR_BAD := COLOR_NO
## Bar colour of a condition group by how deeply it is nested
const GROUP_COLORS := [COLOR_LOGIC, COLOR_FIELD, COLOR_ACTION, COLOR_NAME]
## Groups nest at most this deep (the root group is depth 0)
const MAX_GROUP_DEPTH := 3

## The order the field dropdown lists its categories in; each field names its category in "cat"
const FIELD_CATEGORIES := ["Body", "Food", "Rest & shelter", "Activity", "Location", "Mood", "Work & home"]

## What PolicyEngine's "zone" field can be: "none" plus every ZoneMap item name (keep in step with ZoneMap.INFO)
const ZONES := ["none", "log_stockpile", "food_stockpile", "gathering", "build_area", "restricted"]

const FIELDS := {
	"age": {"label": "Age", "cat": "Body", "type": ValueType.NUMBER, "tier": TIER_PHYSICAL, "min": 0, "max": 120, "default": 16, "integer": true, "hint": "Years old"},
	"health": {"label": "Health", "cat": "Body", "type": ValueType.NUMBER, "tier": TIER_PHYSICAL, "min": 0, "max": 100, "default": 50, "hint": "100 = perfectly healthy"},
	"hunger": {"label": "Hunger", "cat": "Body", "type": ValueType.NUMBER, "tier": TIER_PHYSICAL, "min": 0, "max": 100, "default": 50, "hint": "100 = well fed, 0 = starving"},
	"energy": {"label": "Energy", "cat": "Body", "type": ValueType.NUMBER, "tier": TIER_PHYSICAL, "min": 0, "max": 100, "default": 50, "hint": "100 = fully rested"},
	"hungry": {"label": "Is hungry", "cat": "Food", "type": ValueType.BOOL, "tier": TIER_SITUATION, "default": true, "hint": "Hunger has dropped below the hungry threshold"},
	"food_available": {"label": "Food is available", "cat": "Food", "type": ValueType.BOOL, "tier": TIER_SITUATION, "default": true, "hint": "The stockpile holds food"},
	"is_night": {"label": "It is night", "cat": "Rest & shelter", "type": ValueType.BOOL, "tier": TIER_SITUATION, "default": true, "hint": "Between dusk and dawn"},
	"shelter_available": {"label": "Shelter is available", "cat": "Rest & shelter", "type": ValueType.BOOL, "tier": TIER_SITUATION, "default": true, "hint": "The settlement has at least one house"},
	"task": {"label": "Current task", "cat": "Activity", "type": ValueType.CHOICE, "tier": TIER_SITUATION, "choices": TASKS, "default": "idle", "hint": "What the citizen is doing right now"},
	"busy": {"label": "Is busy", "cat": "Activity", "type": ValueType.BOOL, "tier": TIER_SITUATION, "default": false, "hint": "Working, eating, resting or walking to a task or zone; idle wandering does not count"},
	"zone": {"label": "Standing in zone", "cat": "Location", "type": ValueType.CHOICE, "tier": TIER_SITUATION, "choices": ZONES, "default": "none", "hint": "The zone of the tile the citizen is standing on"},
	"happiness": {"label": "Happiness", "cat": "Mood", "type": ValueType.NUMBER, "tier": TIER_SOCIAL, "min": 0, "max": 100, "default": 50, "hint": "100 = delighted"},
	"approval": {"label": "Approval", "cat": "Mood", "type": ValueType.NUMBER, "tier": TIER_SOCIAL, "min": 0, "max": 100, "default": 50, "hint": "How much they like the leadership"},
	"job": {"label": "Job", "cat": "Work & home", "type": ValueType.TEXT, "tier": TIER_SOCIAL, "default": "", "hint": "Job title; leave empty for 'no job'"},
	"job_satisfaction": {"label": "Job satisfaction", "cat": "Work & home", "type": ValueType.NUMBER, "tier": TIER_SOCIAL, "min": 0, "max": 100, "default": 50, "hint": ""},
	"housing_satisfaction": {"label": "Housing satisfaction", "cat": "Work & home", "type": ValueType.NUMBER, "tier": TIER_SOCIAL, "min": 0, "max": 100, "default": 50, "hint": ""},
}

const NUMBER_OPS := [["==", "is"], ["!=", "is not"], ["<", "is below"], [">", "is above"], ["<=", "is at most"], [">=", "is at least"]]
const EQUALITY_OPS := [["==", "is"], ["!=", "is not"]]
const BOOL_OPS := [["==", "is"]]

## The order the action dropdown lists its categories in; each action names its category in "cat"
const ACTION_CATEGORIES := ["Work", "Home & leisure", "Zones"]

const ACTIONS := [
	{"kind": Action.Kind.ASSIGN_GATHER, "label": "Gather resources", "cat": "Work"},
	{"kind": Action.Kind.ASSIGN_BUILD_TASK, "label": "Help build", "cat": "Work"},
	{"kind": Action.Kind.ASSIGN_HAUL, "label": "Haul logs to the stockpile", "cat": "Work"},
	{"kind": Action.Kind.ASSIGN_JOB, "label": "Take a job", "cat": "Work"},
	{"kind": Action.Kind.ASSIGN_HOUSING, "label": "Move into a house", "cat": "Home & leisure"},
	# Zone actions: Allow / Forbid are permissions (they never run, see PolicyEngine.is_permitted), Go to walks to a zone
	{"kind": Action.Kind.GO_TO_ZONE, "label": "Go to", "cat": "Zones"},
	{"kind": Action.Kind.ALLOW, "label": "Allow", "cat": "Zones"},
	{"kind": Action.Kind.FORBID, "label": "Forbid", "cat": "Zones"},
]


static func field_ids() -> Array[String]:
	var ids: Array[String] = []
	for id in FIELDS:
		ids.append(id)
	return ids

## Field ids of one category, in table order
static func field_ids_in(category: String) -> Array[String]:
	var ids: Array[String] = []
	for id in FIELDS:
		if FIELDS[id]["cat"] == category:
			ids.append(id)
	return ids

static func has_field(id: String) -> bool:
	return FIELDS.has(id)

static func field_label(id: String) -> String:
	return FIELDS[id]["label"] if FIELDS.has(id) else id.capitalize()

static func field_hint(id: String) -> String:
	return FIELDS[id]["hint"] if FIELDS.has(id) else ""

static func field_type(id: String) -> int:
	return int(FIELDS[id]["type"]) if FIELDS.has(id) else ValueType.NUMBER

static func field_tier(id: String) -> String:
	return FIELDS[id]["tier"] if FIELDS.has(id) else TIER_PHYSICAL

static func field_is_integer(id: String) -> bool:
	return FIELDS.has(id) and bool(FIELDS[id].get("integer", false))

static func default_value(id: String):
	return FIELDS[id]["default"] if FIELDS.has(id) else 0

static func default_op(type: int) -> String:
	return ">=" if type == ValueType.NUMBER else "=="

static func ops_for(type: int) -> Array:
	match type:
		ValueType.NUMBER:
			return NUMBER_OPS
		ValueType.BOOL:
			return BOOL_OPS
	return EQUALITY_OPS

static func op_label(op: String) -> String:
	for pair in NUMBER_OPS:
		if pair[0] == op:
			return pair[1]
	return op

static func action_label(kind: int) -> String:
	for entry in ACTIONS:
		if entry["kind"] == kind:
			return entry["label"]
	match kind:
		Action.Kind.ALLOW:
			return "Allow"
		Action.Kind.FORBID:
			return "Forbid"
		Action.Kind.GO_TO_ZONE:
			return "Go to"
	return "?"

const ACTIVITY_LABELS := {Action.Activity.ENTER: "entering", Action.Activity.CHOP: "chopping", Action.Activity.PICK_FRUIT: "picking fruit", Action.Activity.BUILD: "building"}

## One action as words: "Eat", "Forbid entering in Restricted area", "Go to Gathering area"
static func action_text(a: Action) -> String:
	if a == null:
		return "do nothing"
	match a.kind:
		Action.Kind.ALLOW, Action.Kind.FORBID:
			return "%s %s in %s" % [action_label(a.kind), ACTIVITY_LABELS.get(a.activity, "?"), ZoneMap.label(a.zone)]
		Action.Kind.GO_TO_ZONE:
			return "%s %s" % [action_label(a.kind), ZoneMap.label(a.zone)]
	return action_label(a.kind)


# --- Colouring -------------------------------------------------------------------------------------------------

## Sets every text colour state of a control (buttons have a colour per state) to `color`
static func tint(control: Control, color: Color) -> void:
	if control is Button:
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
			control.add_theme_color_override(state, color)
		if control is OptionButton:
			control.get_popup().add_theme_color_override("font_color", color)
	elif control is SpinBox:
		control.get_line_edit().add_theme_color_override("font_color", color)
	else:
		control.add_theme_color_override("font_color", color)

## The colour of a value: yes is green and no is red for any yes/no field, everything else is cream
static func value_color(field: String, value) -> Color:
	if field_type(field) == ValueType.BOOL:
		return COLOR_YES if value else COLOR_NO
	return COLOR_VALUE

## The YES / NOT toggle in front of a condition or group: a plain "YES" (green) while the condition is used as it is,
## a red "NOT" once it is flipped
static func style_not_toggle(button: Button, negated: bool) -> void:
	button.text = "NOT" if negated else "YES"
	tint(button, COLOR_NO if negated else COLOR_YES)

## Colours a text for a RichTextLabel (and escapes the player's own text); plain when rich is false
static func paint(text: String, color: Color, rich: bool) -> String:
	if not rich:
		return text
	return "[color=#%s]%s[/color]" % [color.to_html(false), text.replace("[", "[lb]")]


# --- Reading a rule back as a sentence ("Legal Mad Libs") -------------------------------------------------------

static func format_value(field: String, value) -> String:
	match field_type(field):
		ValueType.BOOL:
			return "yes" if value else "no"
		ValueType.NUMBER:
			if (value is float or value is int) and is_equal_approx(float(value), roundf(float(value))):
				return str(int(value))
	return str(value)

static func _describe_leaf(c: Condition, rich: bool) -> String:
	var op := c.op
	var value = c.value
	if field_type(c.field) == ValueType.BOOL and op == "!=":
		op = "=="
		value = not bool(value)
	return "%s %s %s" % [paint(field_label(c.field), COLOR_FIELD, rich), paint(op_label(op), COLOR_OP, rich),
			paint(format_value(c.field, value), value_color(c.field, value), rich)]

## `rich` = BBCode with the part colours, for a RichTextLabel
static func describe_condition(c: Condition, rich: bool = false) -> String:
	if c == null:
		return paint("always", COLOR_VALUE, rich)
	match c.kind:
		Condition.Kind.LEAF:
			return _describe_leaf(c, rich)
		Condition.Kind.AND, Condition.Kind.OR:
			if c.children.is_empty():
				return paint("always" if c.kind == Condition.Kind.AND else "never", COLOR_VALUE, rich)
			var parts: Array[String] = []
			for child in c.children:
				var text := describe_condition(child, rich)
				if child.kind == Condition.Kind.AND or child.kind == Condition.Kind.OR:
					text = "(%s)" % text
				parts.append(text)
			var joiner := " %s " % paint("AND" if c.kind == Condition.Kind.AND else "OR", COLOR_LOGIC, rich)
			return joiner.join(parts)
		Condition.Kind.NOT:
			if c.children.is_empty():
				return paint("never", COLOR_VALUE, rich)
			var inner := describe_condition(c.children[0], rich)
			if c.children[0].kind != Condition.Kind.LEAF:
				inner = "(%s)" % inner
			return "%s %s" % [paint("NOT", COLOR_NOT, rich), inner]
	return "?"

static func describe(policy: Policy, rich: bool = false) -> String:
	var parts: Array[String] = []
	for a in policy.actions:
		parts.append(paint(action_text(a), COLOR_ACTION, rich))
	var then := ", ".join(parts) if not parts.is_empty() else paint("do nothing", COLOR_ACTION, rich)
	return "%s %s %s %s" % [paint("WHEN", COLOR_KEYWORD, rich), describe_condition(policy.condition, rich),
			paint("THEN", COLOR_KEYWORD, rich), then]

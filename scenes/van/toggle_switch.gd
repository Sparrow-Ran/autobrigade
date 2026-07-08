class_name ToggleSwitch
extends StaticBody3D
## Physical two-state switch mounted at a post. Host-authoritative, synced.
## If parented under a Seat, only that seat's occupant may flip it
## (or anyone, while the seat is free — same reach-over rule as levers).

signal toggled(is_on: bool)

@export var title: String = "ЗАДНИЙ ХОД"

## Synced switch state. The van reads this every physics tick.
var is_on: bool = false:
	set(new_state):
		if new_state == is_on:
			return
		is_on = new_state
		if is_node_ready():
			_update_visual()
		toggled.emit(new_state)

var _mat_on := StandardMaterial3D.new()
var _mat_off := StandardMaterial3D.new()

@onready var pivot: Node3D = $Pivot
@onready var knob: MeshInstance3D = $Pivot/Knob
@onready var title_label: Label3D = $TitleLabel


func _ready() -> void:
	add_to_group("interactable")
	_mat_on.albedo_color = Color(0.9, 0.2, 0.15)
	_mat_off.albedo_color = Color(0.5, 0.5, 0.5)
	title_label.text = title
	_update_visual()


## Interact chain entry (E while standing and looking at the switch).
func interact(_player: Node) -> void:
	request_toggle.rpc_id(1)


func get_prompt() -> String:
	return "%s [E]" % title


@rpc("any_peer", "call_local", "reliable")
func request_toggle() -> void:
	if not multiplayer.is_server() or not _sender_may_toggle():
		return
	is_on = not is_on


func _sender_may_toggle() -> bool:
	var seat := get_parent() as Seat
	if seat == null:
		return true
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	return seat.occupant_peer == sender or seat.occupant_peer == 0


func _update_visual() -> void:
	pivot.rotation.x = deg_to_rad(25.0 if is_on else -25.0)
	knob.set_surface_override_material(0, _mat_on if is_on else _mat_off)
	title_label.modulate = Color(1.0, 0.35, 0.3) if is_on else Color(1, 1, 1)

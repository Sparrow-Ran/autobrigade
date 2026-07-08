extends CanvasLayer
## Local player's HUD: crosshair, interact prompt, F3 debug panel.

## Assigned by the owning player before add_child.
var player: Node = null

var _last_van_pos := Vector3.ZERO

@onready var prompt_label: Label = $Prompt
@onready var debug_label: Label = $DebugPanel


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_panel"):
		debug_label.visible = not debug_label.visible


func _process(delta: float) -> void:
	if player == null:
		return
	prompt_label.text = player.get_interact_prompt()
	if debug_label.visible:
		debug_label.text = _build_debug_text(delta)


func _build_debug_text(delta: float) -> String:
	var van: Node = get_tree().get_first_node_in_group("van")
	if van == null:
		return "Фургон не найден"
	# Speed from position delta so it works on clients too (frozen rigid body
	# has zero linear_velocity there).
	var van_pos: Vector3 = van.global_position
	var speed_kmh := (van_pos - _last_van_pos).length() / maxf(delta, 0.0001) * 3.6
	_last_van_pos = van_pos
	return (
		"Скорость: %3.0f км/ч\nГАЗ: %d%%   ТОРМОЗ: %d%%\nВЛЕВО: %d%%   ВПРАВО: %d%%\nЗадний ход: %s"
		% [
			speed_kmh,
			roundi(van.seat_gas.lever.value * 100.0),
			roundi(van.seat_brake.lever.value * 100.0),
			roundi(van.seat_steer_left.lever.value * 100.0),
			roundi(van.seat_steer_right.lever.value * 100.0),
			"ВКЛ" if van.reverse_switch.is_on else "выкл",
		]
	)

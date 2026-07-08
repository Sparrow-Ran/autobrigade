class_name Lever
extends Node3D

enum BehaviorType {
	HOLD,  ## Stays where left (gas, steering).
	SPRING,  ## Returns to 0 when released (brake).
}

enum MoveDirection {
	FORWARD,  ## Tilts away from the player as value grows (gas, brake); vertical drag.
	LEFT,  ## Tilts to the player's left (steer-left post); horizontal drag.
	RIGHT,  ## Tilts to the player's right (steer-right post); horizontal drag.
}

@export var behavior: BehaviorType = BehaviorType.HOLD
@export var move_direction: MoveDirection = MoveDirection.FORWARD
## Max travel speed of the lever, in full-range units per second.
@export var slew_rate: float = 1.2
## Target change per pixel of mouse drag.
@export var drag_sensitivity: float = 0.004
## FORWARD levers: arm tilt at value 0 / value 1, degrees around local X.
@export var angle_at_zero_deg: float = 35.0
@export var angle_at_one_deg: float = -35.0
## LEFT/RIGHT levers: sideways tilt at value 1, degrees (value 0 is upright).
@export var side_tilt_max_deg: float = 35.0

## Actual lever position (0..1) — the only thing the van ever reads.
## Simulated on the host, synced to clients; clients only draw it.
var value: float = 0.0
## Where the player is pulling the lever to; value chases it at slew_rate.
var target: float = 0.0
var is_grabbed: bool = false

@onready var pivot: Node3D = $Pivot
@onready var value_label: Label3D = $ValueLabel


func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		if behavior == BehaviorType.SPRING and not is_grabbed:
			target = 0.0
		value = move_toward(value, target, slew_rate * delta)
	_update_visual()


func grab() -> void:
	is_grabbed = true
	# Drag starts from where the lever actually is, not from a stale target.
	target = value


func release_grab() -> void:
	is_grabbed = false


## Local grab + ask the host. Use these from player input, not grab()/release_grab().
func grab_networked() -> void:
	grab()
	if not multiplayer.is_server():
		request_grab.rpc_id(1)


func release_networked() -> void:
	release_grab()
	if not multiplayer.is_server():
		request_release.rpc_id(1)


## relative: raw mouse relative motion. Drag direction matches the lever's move direction:
## FORWARD — mouse up pushes the lever away; LEFT/RIGHT — mouse toward that side.
func drag(relative: Vector2) -> void:
	if not is_grabbed:
		return
	var amount: float
	match move_direction:
		MoveDirection.FORWARD:
			amount = -relative.y
		MoveDirection.LEFT:
			amount = -relative.x
		MoveDirection.RIGHT:
			amount = relative.x
	_set_target_networked(clampf(target + amount * drag_sensitivity, 0.0, 1.0))


## Keyboard driving: shift target by a signed amount (solo-test helper).
func nudge(amount: float) -> void:
	_set_target_networked(clampf(target + amount, 0.0, 1.0))


func _set_target_networked(new_target: float) -> void:
	if is_equal_approx(new_target, target):
		return
	target = new_target
	if not multiplayer.is_server():
		request_target.rpc_id(1, new_target)


@rpc("any_peer", "reliable")
func request_grab() -> void:
	if multiplayer.is_server() and _sender_may_control():
		grab()


@rpc("any_peer", "reliable")
func request_release() -> void:
	if multiplayer.is_server() and _sender_may_control():
		release_grab()


@rpc("any_peer", "unreliable_ordered")
func request_target(new_target: float) -> void:
	if multiplayer.is_server() and _sender_may_control():
		target = clampf(new_target, 0.0, 1.0)


func _sender_may_control() -> bool:
	var seat := get_parent() as Seat
	if seat == null:
		return true
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	# Your own post — or reaching over to an unmanned one (solo testing / co-op chaos).
	return seat.occupant_peer == sender or seat.occupant_peer == 0


func _update_visual() -> void:
	match move_direction:
		MoveDirection.FORWARD:
			pivot.rotation.x = deg_to_rad(lerpf(angle_at_zero_deg, angle_at_one_deg, value))
		MoveDirection.LEFT:
			pivot.rotation.z = deg_to_rad(lerpf(0.0, side_tilt_max_deg, value))
		MoveDirection.RIGHT:
			pivot.rotation.z = deg_to_rad(lerpf(0.0, -side_tilt_max_deg, value))
	value_label.text = "%d%%" % roundi(value * 100.0)

class_name Player
extends CharacterBody3D

const HUD_SCENE := preload("res://scenes/ui/hud.tscn")
const PLAYER_COLORS: Array[Color] = [
	Color(0.85, 0.25, 0.25),
	Color(0.25, 0.45, 0.85),
	Color(0.3, 0.8, 0.35),
	Color(0.9, 0.8, 0.2),
]
## Render layer 2 marks "this client's own body"; every camera culls it locally.
const OWN_BODY_RENDER_LAYER := 1 << 1

@export var move_speed: float = 5.0
@export var jump_velocity: float = 4.5
## Horizontal acceleration while airborne (weak drift control, preserves momentum).
@export var air_acceleration: float = 10.0
@export var mouse_sensitivity: float = 0.003
@export var pitch_min_deg: float = -60.0
@export var pitch_max_deg: float = 70.0
## Solo-test keyboard driving: lever target change per second while a key is held.
@export var keyboard_lever_rate: float = 1.5

@onready var camera_pivot: Node3D = $CameraPivot
@onready var interact_ray: RayCast3D = $CameraPivot/InteractRay
@onready var player_camera: Camera3D = $CameraPivot/Camera3D
@onready var body_mesh: MeshInstance3D = $MeshInstance3D
@onready var name_label: Label3D = $NameLabel

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var current_seat: Seat = null
## Set by Net at spawn (synced): picks the capsule color and fallback name.
var color_index: int = 0
## Set by Net at spawn (synced): the name chosen in the main menu; may be empty.
var nickname: String = ""

## Synced while riding the van bed on foot: every peer reconstructs the pose
## from its own local van transform, so passengers never lag off the bed.
var on_van: bool = false
var van_local_pos := Vector3.ZERO
var van_local_yaw: float = 0.0

var _kb_brake_held: bool = false
var _carry_van: Van = null
var _last_van_xf := Transform3D()
var _van_frame_velocity := Vector3.ZERO


func _enter_tree() -> void:
	# Node name is the owning peer id (set by Net on spawn).
	if str(name).is_valid_int():
		set_multiplayer_authority(str(name).to_int())


func _ready() -> void:
	add_to_group("players")
	# We carry riders ourselves from the van's transform delta (works on clients
	# where the van is frozen); disable the built-in platform velocity so the
	# two mechanisms never double-apply on the host.
	platform_floor_layers = 0
	_apply_color()
	name_label.text = get_display_name()
	# Late join: if this player was already seated when we learned about them,
	# the seat's occupancy sync arrived before this node spawned — re-glue now.
	for seat in get_tree().get_nodes_in_group("seats"):
		if seat.occupant_peer != 0 and str(seat.occupant_peer) == str(name):
			seat_locally(seat)
	if is_multiplayer_authority():
		Net.local_player = self
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		player_camera.current = true
		# Move own visuals to the "own body" render layer and cull it on own camera:
		# this client stops seeing its body, everyone else still does.
		body_mesh.layers = OWN_BODY_RENDER_LAYER
		name_label.layers = OWN_BODY_RENDER_LAYER
		player_camera.cull_mask &= ~OWN_BODY_RENDER_LAYER
		var hud := HUD_SCENE.instantiate()
		hud.player = self
		add_child(hud)
	else:
		player_camera.current = false


func get_display_name() -> String:
	if not nickname.is_empty():
		return nickname
	return "Игрок %d" % (color_index + 1)


func _apply_color() -> void:
	var mat: StandardMaterial3D = body_mesh.get_surface_override_material(0).duplicate()
	mat.albedo_color = PLAYER_COLORS[color_index % PLAYER_COLORS.size()]
	body_mesh.set_surface_override_material(0, mat)


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if current_seat != null:
			if current_seat.lever.is_grabbed:
				current_seat.lever.drag(event.relative)
			else:
				current_seat.rotate_view(-event.relative * mouse_sensitivity)
		else:
			rotate_y(-event.relative.x * mouse_sensitivity)
			camera_pivot.rotate_x(-event.relative.y * mouse_sensitivity)
			camera_pivot.rotation.x = clamp(
				camera_pivot.rotation.x, deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg)
			)

	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		and current_seat != null
	):
		if event.pressed:
			current_seat.lever.grab_networked()
		else:
			current_seat.lever.release_networked()

	if event.is_action_pressed("horn") and current_seat != null:
		var horn_van := current_seat.get_parent() as Van
		if horn_van != null:
			horn_van.request_horn.rpc_id(1)

	if event.is_action_pressed("reverse_toggle") and current_seat != null:
		var switch_van := current_seat.get_parent() as Van
		if switch_van != null:
			switch_van.reverse_switch.request_toggle.rpc_id(1)

	if event.is_action_pressed("interact"):
		if current_seat != null:
			current_seat.request_stand.rpc_id(1)
		else:
			_try_interact()


func _physics_process(delta: float) -> void:
	if current_seat != null:
		# EVERY peer glues seated players locally: the pose is fully derived from
		# synced occupancy + the local van transform. Beats laggy transform sync,
		# which made seated players slide off their seats on other screens.
		global_transform = current_seat.sit_point.global_transform
		if is_multiplayer_authority():
			_drive_with_keys(delta)
		return

	if not is_multiplayer_authority():
		return

	_apply_van_carry(delta)

	if not is_on_floor():
		velocity.y -= gravity * delta

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	if is_on_floor():
		if direction:
			velocity.x = direction.x * move_speed
			velocity.z = direction.z * move_speed
		else:
			velocity.x = move_toward(velocity.x, 0, move_speed)
			velocity.z = move_toward(velocity.z, 0, move_speed)
	else:
		# Airborne: nudge, don't overwrite — keeps momentum from a moving van.
		velocity.x += direction.x * air_acceleration * delta
		velocity.z += direction.z * air_acceleration * delta

	move_and_slide()

	_update_carry_van()
	_publish_van_state()


## Rides the van bed: applies the van's frame-to-frame motion to the standing
## player. Position takes the full delta, orientation only yaw — the capsule
## stays upright when the van tilts. Transform-based, so it works identically
## on the host (live physics) and clients (synced frozen body).
func _apply_van_carry(delta: float) -> void:
	if _carry_van == null:
		return
	var van_xf := _carry_van.global_transform
	var delta_xf := van_xf * _last_van_xf.affine_inverse()
	_van_frame_velocity = (
		((van_xf.origin - _last_van_xf.origin) / maxf(delta, 0.0001)).limit_length(30.0)
	)
	global_position = delta_xf * global_position
	var delta_yaw := delta_xf.basis.get_euler().y
	rotation.y += delta_yaw
	velocity = Basis(Vector3.UP, delta_yaw) * velocity
	_last_van_xf = van_xf


## After moving: are we standing on the van (or anything mounted on it)?
func _update_carry_van() -> void:
	var found: Van = null
	if is_on_floor():
		for i in get_slide_collision_count():
			var node: Node = get_slide_collision(i).get_collider()
			while node != null:
				if node is Van:
					found = node
					break
				node = node.get_parent()
			if found != null:
				break
	if found == _carry_van:
		return
	if found == null:
		# Jumped or stepped off: keep the van's momentum.
		velocity += _van_frame_velocity
		_van_frame_velocity = Vector3.ZERO
	else:
		_last_van_xf = found.global_transform
	_carry_van = found


func _publish_van_state() -> void:
	on_van = _carry_van != null
	if _carry_van != null:
		van_local_pos = _carry_van.global_transform.affine_inverse() * global_position
		van_local_yaw = rotation.y - _carry_van.rotation.y


# Solo-test helper: drive all four levers with WASD/Space from any seat.
# Nudges lever targets, so slew rate still applies and the levers visibly travel.
# The host validates each change: occupied posts belong to their occupants.
func _drive_with_keys(delta: float) -> void:
	var van := current_seat.get_parent() as Van
	if van == null:
		return

	var gas_input := Input.get_axis("move_back", "move_forward")
	if gas_input != 0.0:
		van.seat_gas.lever.nudge(gas_input * keyboard_lever_rate * delta)

	var steer_input := Input.get_axis("move_right", "move_left")
	if steer_input != 0.0:
		van.seat_steer_left.lever.nudge(steer_input * keyboard_lever_rate * delta)
		van.seat_steer_right.lever.nudge(-steer_input * keyboard_lever_rate * delta)

	var brake := van.seat_brake.lever
	if Input.is_action_pressed("jump"):
		if not _kb_brake_held:
			_kb_brake_held = true
			brake.grab_networked()
		brake.nudge(keyboard_lever_rate * delta)
	elif _kb_brake_held:
		_kb_brake_held = false
		brake.release_networked()


## Called by the seat on EVERY peer when synced occupancy says this player sat down.
func seat_locally(seat: Seat) -> void:
	current_seat = seat
	velocity = Vector3.ZERO
	_carry_van = null
	_van_frame_velocity = Vector3.ZERO
	on_van = false
	global_transform = seat.sit_point.global_transform
	reset_physics_interpolation()


## Called by the seat on EVERY peer when synced occupancy says this player stood up.
func unseat_locally(exit_transform: Transform3D) -> void:
	current_seat = null
	_kb_brake_held = false
	global_transform = exit_transform
	reset_physics_interpolation()
	if is_multiplayer_authority():
		player_camera.current = true


func _process(_delta: float) -> void:
	# Network poll applies incoming sync at the start of the frame, before _process.
	# Re-gluing here guarantees the locally derived pose always wins over the
	# (laggy) synced world transform — on every peer, every frame.
	if current_seat != null:
		global_transform = current_seat.sit_point.global_transform
	elif on_van and not is_multiplayer_authority():
		# Remote passenger on the van bed: rebuild the pose from OUR local van.
		var van: Node3D = get_tree().get_first_node_in_group("van")
		if van != null:
			global_position = van.global_transform * van_local_pos
			rotation.y = van.rotation.y + van_local_yaw


## Text for the HUD prompt under the crosshair.
func get_interact_prompt() -> String:
	if current_seat != null:
		return "Встать [E]"
	if not interact_ray.is_colliding():
		return ""
	var collider: Object = interact_ray.get_collider()
	if collider is Node and collider.is_in_group("interactable"):
		if collider.has_method("get_prompt"):
			return collider.get_prompt()
		return "Использовать [E]"
	return ""


func _try_interact() -> void:
	if not interact_ray.is_colliding():
		return
	var collider: Object = interact_ray.get_collider()
	if collider is Node and collider.is_in_group("interactable") and collider.has_method("interact"):
		collider.interact(self)

class_name Van
extends VehicleBody3D

## Force at gas lever = 1.0.
@export var max_engine_force: float = 4500.0
## Brake at brake lever = 1.0.
@export var max_brake: float = 60.0
## Wheel angle at full single-side steer, radians.
@export var max_steer_rad: float = 0.55
## Speed (km/h) at which steering authority drops to half — keeps high speed drivable.
@export var steer_falloff_kmh: float = 35.0
## Reverse gear is weaker than forward, like a real van.
@export var reverse_force_scale: float = 0.6

## Engine sound: pitch at standstill with no throttle...
@export var engine_idle_pitch: float = 0.7
## ...plus this much per unit of gas lever...
@export var engine_pitch_per_throttle: float = 0.35
## ...plus this much per km/h of actual speed.
@export var engine_pitch_per_kmh: float = 0.012

@onready var seat_gas: Seat = $SeatGas
@onready var seat_brake: Seat = $SeatBrake
@onready var seat_steer_left: Seat = $SeatSteerLeft
@onready var seat_steer_right: Seat = $SeatSteerRight
## Visual wheel radius, matches the physics wheels; used for spin speed.
const WHEEL_VISUAL_RADIUS := 0.4

@onready var reverse_switch: ToggleSwitch = $SeatBrake/ReverseSwitch
@onready var horn_player: AudioStreamPlayer3D = $HornPlayer
@onready var engine_player: AudioStreamPlayer3D = $EnginePlayer
# First two are the steering (front) pair.
@onready var wheel_visuals: Array[Node3D] = [
	$WheelFLVisual, $WheelFRVisual, $WheelRLVisual, $WheelRRVisual
]

var _prev_frame_pos := Vector3.ZERO
var _wheel_spin: float = 0.0


func _ready() -> void:
	add_to_group("van")
	horn_player.stream = _make_horn_stream()
	engine_player.stream = _make_engine_stream()
	engine_player.play()
	_prev_frame_pos = global_position
	# Van physics runs only on the host; clients receive the synced transform.
	if not multiplayer.is_server():
		freeze = true
		set_physics_process(false)


func _process(delta: float) -> void:
	# Sound and wheel visuals run locally on every peer from the same data:
	# synced lever values + motion derived from position (works on clients,
	# where the frozen body has zero physics velocity).
	var displacement := global_position - _prev_frame_pos
	_prev_frame_pos = global_position
	var safe_delta := maxf(delta, 0.0001)
	var speed_kmh := clampf(displacement.length() / safe_delta * 3.6, 0.0, 150.0)
	_update_engine_sound(speed_kmh, delta)
	_update_wheel_visuals(displacement, safe_delta, speed_kmh)


func _update_engine_sound(speed_kmh: float, delta: float) -> void:
	var gas := seat_gas.lever.value
	var target_pitch := (
		engine_idle_pitch + gas * engine_pitch_per_throttle + speed_kmh * engine_pitch_per_kmh
	)
	var smoothing := 1.0 - exp(-6.0 * delta)
	engine_player.pitch_scale = lerpf(engine_player.pitch_scale, target_pitch, smoothing)
	engine_player.volume_db = lerpf(-35.0, -25.0, clampf(gas + speed_kmh / 100.0, 0.0, 1.0))


## Wheels are pure visuals driven by slot data, not synced physics nodes:
## every peer computes identical spin/steer, and the frozen client vehicle
## can't overwrite them with garbage suspension state.
func _update_wheel_visuals(displacement: Vector3, delta: float, speed_kmh: float) -> void:
	var forward_speed := displacement.dot(-global_transform.basis.z) / delta
	_wheel_spin = wrapf(_wheel_spin + forward_speed / WHEEL_VISUAL_RADIUS * delta, -TAU, TAU)
	var steer_scale := steer_falloff_kmh / (steer_falloff_kmh + speed_kmh)
	var steer := (
		(seat_steer_left.lever.value - seat_steer_right.lever.value) * max_steer_rad * steer_scale
	)
	for i in wheel_visuals.size():
		wheel_visuals[i].rotation.y = steer if i < 2 else 0.0
		(wheel_visuals[i].get_node("Spinner") as Node3D).rotation.x = -_wheel_spin


func _physics_process(_delta: float) -> void:
	# The van only reads slot states — it knows nothing about players.
	# Negative force drives forward: positive engine_force pushes toward +Z,
	# and our nose points -Z. The reverse switch flips the sign (weaker).
	var throttle := seat_gas.lever.value * max_engine_force
	engine_force = throttle * reverse_force_scale if reverse_switch.is_on else -throttle

	brake = seat_brake.lever.value * max_brake

	# Two steering levers oppose each other: going straight after a turn
	# requires the two players to balance out. Steering softens with speed.
	var speed_kmh := linear_velocity.length() * 3.6
	var steer_scale := steer_falloff_kmh / (steer_falloff_kmh + speed_kmh)
	steering = (
		(seat_steer_left.lever.value - seat_steer_right.lever.value)
		* max_steer_rad
		* steer_scale
	)


## Rescue button: any player may ask the host to put the van back on its wheels.
@rpc("any_peer", "call_local", "reliable")
func request_flip_upright() -> void:
	if not multiplayer.is_server():
		return
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	# Keep the heading, drop roll and pitch, lift a bit so wheels settle cleanly.
	rotation = Vector3(0.0, rotation.y, 0.0)
	position.y += 1.5
	# Teleport: don't let physics interpolation smear it across the screen.
	reset_physics_interpolation()


@rpc("any_peer", "call_local", "reliable")
func request_horn() -> void:
	if multiplayer.is_server():
		_play_horn.rpc()


@rpc("authority", "call_local", "reliable")
func _play_horn() -> void:
	if not horn_player.playing:
		horn_player.play()


# Procedural engine loop — exactly 1 second of integer-Hz harmonics, so the
# loop point is seamless. Placeholder until a real sound asset lands in assets/.
func _make_engine_stream() -> AudioStreamWAV:
	var rate := 22050
	var frames := rate
	var data := PackedByteArray()
	data.resize(frames * 2)
	for i in frames:
		var t := float(i) / rate
		var v := (
			0.45 * sin(TAU * 55.0 * t)
			+ 0.3 * sin(TAU * 110.0 * t)
			+ 0.15 * sin(TAU * 165.0 * t)
			+ 0.1 * signf(sin(TAU * 55.0 * t))
		)
		# Slow amplitude wobble makes it feel mechanical rather than a pure tone.
		v *= 0.85 + 0.15 * sin(TAU * 8.0 * t)
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 20000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = frames
	wav.data = data
	return wav


# Procedural two-tone beep — placeholder until a real sound asset lands in assets/.
func _make_horn_stream() -> AudioStreamWAV:
	var rate := 22050
	var seconds := 0.35
	var frames := int(rate * seconds)
	var data := PackedByteArray()
	data.resize(frames * 2)
	for i in frames:
		var t := float(i) / rate
		var v := signf(sin(TAU * 400.0 * t)) * 0.25 + signf(sin(TAU * 505.0 * t)) * 0.25
		var envelope := clampf((seconds - t) / 0.05, 0.0, 1.0)
		data.encode_s16(i * 2, int(clampf(v * envelope, -1.0, 1.0) * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.data = data
	return wav

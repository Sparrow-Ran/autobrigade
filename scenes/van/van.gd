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

@onready var seat_gas: Seat = $SeatGas
@onready var seat_brake: Seat = $SeatBrake
@onready var seat_steer_left: Seat = $SeatSteerLeft
@onready var seat_steer_right: Seat = $SeatSteerRight
@onready var reverse_switch: ToggleSwitch = $SeatBrake/ReverseSwitch
@onready var horn_player: AudioStreamPlayer3D = $HornPlayer


func _ready() -> void:
	add_to_group("van")
	horn_player.stream = _make_horn_stream()
	# Van physics runs only on the host; clients receive the synced transform.
	if not multiplayer.is_server():
		freeze = true
		set_physics_process(false)


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


@rpc("any_peer", "call_local", "reliable")
func request_horn() -> void:
	if multiplayer.is_server():
		_play_horn.rpc()


@rpc("authority", "call_local", "reliable")
func _play_horn() -> void:
	if not horn_player.playing:
		horn_player.play()


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

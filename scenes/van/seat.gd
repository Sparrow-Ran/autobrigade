class_name Seat
extends StaticBody3D

signal occupant_changed(seat: Seat, occupant_peer: int)

## Player-facing post name, shown on the label (e.g. "ГАЗ", "ТОРМОЗ").
@export var seat_title: String = "Пост"

## Behavior of this post's lever (hold for gas/steering, spring for brake).
@export var lever_behavior: Lever.BehaviorType = Lever.BehaviorType.HOLD

## Which way this post's lever physically moves (forward for gas/brake, sideways for steering).
@export var lever_direction: Lever.MoveDirection = Lever.MoveDirection.FORWARD

## Head-turn limits for the seated view, degrees.
@export var view_yaw_limit_deg: float = 140.0
@export var view_pitch_min_deg: float = -50.0
@export var view_pitch_max_deg: float = 60.0

## Peer id of the seated player, 0 = free. Server-authoritative, synced to everyone.
var occupant_peer: int = 0:
	set(new_peer):
		if new_peer == occupant_peer:
			return
		var old_peer := occupant_peer
		occupant_peer = new_peer
		if is_node_ready():
			_apply_occupancy(old_peer, new_peer)

var _default_view_rotation: Vector3

@onready var sit_point: Marker3D = $SitPoint
@onready var exit_point: Marker3D = $ExitPoint
@onready var view_camera: Camera3D = $ViewCamera
@onready var title_label: Label3D = $TitleLabel
@onready var lever: Lever = $Lever


func _ready() -> void:
	add_to_group("interactable")
	add_to_group("seats")
	title_label.text = seat_title
	title_label.visible = occupant_peer == 0
	lever.behavior = lever_behavior
	lever.move_direction = lever_direction
	_default_view_rotation = view_camera.rotation
	# Render layer 2 is "this client's own body" — every camera skips it.
	view_camera.cull_mask &= ~(1 << 1)


func is_occupied() -> bool:
	return occupant_peer != 0


## Interact chain entry: the local player asks the host for this seat.
func interact(_player: Node) -> void:
	if is_occupied():
		return
	request_sit.rpc_id(1)


func get_prompt() -> String:
	if is_occupied():
		return "Занято: %s" % _peer_display_name(occupant_peer)
	return "Сесть [E] — %s" % seat_title


@rpc("any_peer", "call_local", "reliable")
func request_sit() -> void:
	if not multiplayer.is_server() or occupant_peer != 0:
		return
	occupant_peer = _sender_id()


@rpc("any_peer", "call_local", "reliable")
func request_stand() -> void:
	if not multiplayer.is_server() or occupant_peer != _sender_id():
		return
	occupant_peer = 0


## Server-side cleanup when a peer disconnects mid-seat.
func force_vacate(peer_id: int) -> void:
	if occupant_peer == peer_id:
		occupant_peer = 0
		lever.release_grab()


## Turns the seated view like a head: yaw/pitch deltas in radians, clamped to limits.
func rotate_view(delta: Vector2) -> void:
	view_camera.rotation.y = clamp(
		view_camera.rotation.y + delta.x,
		-deg_to_rad(view_yaw_limit_deg),
		deg_to_rad(view_yaw_limit_deg)
	)
	view_camera.rotation.x = clamp(
		view_camera.rotation.x + delta.y,
		deg_to_rad(view_pitch_min_deg),
		deg_to_rad(view_pitch_max_deg)
	)


## Runs on every peer when synced occupancy changes. Every peer glues/unglues
## the affected player locally; only the occupant peer touches its camera.
func _apply_occupancy(old_peer: int, new_peer: int) -> void:
	var my_id := multiplayer.get_unique_id()
	if new_peer == 0:
		title_label.text = seat_title
		title_label.visible = true
	else:
		title_label.text = "%s — %s" % [seat_title, _peer_display_name(new_peer)]
		# The label hangs right in front of the occupant's own view; hide it for them only.
		title_label.visible = new_peer != my_id

	if new_peer != 0:
		if new_peer == my_id:
			view_camera.rotation = _default_view_rotation
			view_camera.current = true
		var sitting := _find_player_node(new_peer)
		if sitting != null:
			sitting.seat_locally(self)
	elif old_peer != 0:
		if old_peer == my_id:
			lever.release_grab()
			view_camera.current = false
		var standing := _find_player_node(old_peer)
		if standing != null:
			standing.unseat_locally(exit_point.global_transform)
	occupant_changed.emit(self, new_peer)


func _sender_id() -> int:
	var sender := multiplayer.get_remote_sender_id()
	return sender if sender != 0 else multiplayer.get_unique_id()


func _find_player_node(peer_id: int) -> Node:
	for player in get_tree().get_nodes_in_group("players"):
		if str(player.name) == str(peer_id):
			return player
	return null


func _peer_display_name(peer_id: int) -> String:
	var player := _find_player_node(peer_id)
	return player.get_display_name() if player != null else "Игрок"

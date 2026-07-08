extends Node
## Autoload "Net". ENet session management, host-authoritative model:
## the host simulates van/lever physics, clients send lever input and receive transforms.

enum Mode { OFFLINE, HOST, CLIENT }

const PORT := 7777
const MAX_CLIENTS := 3
const LEVEL_SCENE := "res://scenes/levels/test_level.tscn"
const MENU_SCENE := "res://scenes/ui/main_menu.tscn"
const PLAYER_SCENE := preload("res://scenes/player/player.tscn")

var mode: Mode = Mode.OFFLINE
## The player node owned by this peer; set by the player itself in _ready.
var local_player: Node = null

var _level_loaded := false
var _connected := false
var _registered := false
var _spawn_index := 0


func _ready() -> void:
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_handle_cmdline_args()


## Dev shortcut: `godot ++ --host` / `godot ++ --join <ip>` skips the menu.
func _handle_cmdline_args() -> void:
	var args := OS.get_cmdline_user_args()
	if "--host" in args:
		host.call_deferred()
		return
	var join_idx := args.find("--join")
	if join_idx != -1:
		var ip := args[join_idx + 1] if join_idx + 1 < args.size() else "127.0.0.1"
		join.call_deferred(ip)


func host() -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.HOST
	print("[Net] hosting on port %d" % PORT)
	get_tree().change_scene_to_file(LEVEL_SCENE)
	return OK


func join(ip: String) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, PORT)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	print("[Net] joining %s:%d..." % [ip, PORT])
	get_tree().change_scene_to_file(LEVEL_SCENE)
	return OK


## Leave the session: the host takes the lobby down (clients get kicked back
## to the menu via server_disconnected), a client just disconnects itself.
func leave() -> void:
	_reset_to_menu()


## Called by the level's _ready on every peer once the scene exists.
func level_ready() -> void:
	_level_loaded = true
	match mode:
		Mode.HOST, Mode.OFFLINE:
			_spawn_player(multiplayer.get_unique_id())
		Mode.CLIENT:
			_try_register()


func _try_register() -> void:
	if _level_loaded and _connected and not _registered:
		_registered = true
		_register_player.rpc_id(1)


@rpc("any_peer", "reliable")
func _register_player() -> void:
	if not multiplayer.is_server():
		return
	_spawn_player(multiplayer.get_remote_sender_id())


func _spawn_player(peer_id: int) -> void:
	var container := _players_container()
	if container == null or container.has_node(str(peer_id)):
		return
	var player := PLAYER_SCENE.instantiate()
	player.name = str(peer_id)
	player.position = Vector3(2.0 * _spawn_index, 1.2, 4.0)
	player.color_index = _spawn_index
	_spawn_index += 1
	container.add_child(player, true)
	print("[Net] spawned player for peer %d" % peer_id)


func _players_container() -> Node:
	var scene := get_tree().current_scene
	return scene.get_node_or_null("Players") if scene != null else null


func _on_connected_to_server() -> void:
	_connected = true
	_try_register()


func _on_connection_failed() -> void:
	_reset_to_menu()


func _on_server_disconnected() -> void:
	_reset_to_menu()


func _on_peer_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	print("[Net] peer %d disconnected" % peer_id)
	for seat in get_tree().get_nodes_in_group("seats"):
		seat.force_vacate(peer_id)
	var container := _players_container()
	if container != null and container.has_node(str(peer_id)):
		container.get_node(str(peer_id)).queue_free()


func _reset_to_menu() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = Mode.OFFLINE
	local_player = null
	_level_loaded = false
	_connected = false
	_registered = false
	_spawn_index = 0
	get_tree().change_scene_to_file(MENU_SCENE)

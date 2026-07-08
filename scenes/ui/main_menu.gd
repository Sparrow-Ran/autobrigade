extends Control

const SETTINGS_PATH := "user://settings.cfg"

@onready var nick_edit: LineEdit = $VBox/NickEdit
@onready var host_button: Button = $VBox/HostButton
@onready var ip_edit: LineEdit = $VBox/IpEdit
@onready var join_button: Button = $VBox/JoinButton
@onready var status_label: Label = $VBox/Status


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	_load_settings()


func _on_host_pressed() -> void:
	_apply_and_save_nickname()
	var err := Net.host()
	if err != OK:
		status_label.text = "Не удалось создать сервер (код %d)" % err


func _on_join_pressed() -> void:
	var ip := ip_edit.text.strip_edges()
	if ip.is_empty():
		status_label.text = "Введите IP хоста"
		return
	_apply_and_save_nickname()
	var err := Net.join(ip)
	if err != OK:
		status_label.text = "Не удалось подключиться (код %d)" % err
	else:
		status_label.text = "Подключение к %s..." % ip


func _apply_and_save_nickname() -> void:
	Net.local_nickname = nick_edit.text.strip_edges()
	var config := ConfigFile.new()
	config.set_value("player", "nickname", Net.local_nickname)
	config.save(SETTINGS_PATH)


func _load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK:
		nick_edit.text = str(config.get_value("player", "nickname", ""))

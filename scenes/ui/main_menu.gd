extends Control

@onready var host_button: Button = $VBox/HostButton
@onready var ip_edit: LineEdit = $VBox/IpEdit
@onready var join_button: Button = $VBox/JoinButton
@onready var status_label: Label = $VBox/Status


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)


func _on_host_pressed() -> void:
	var err := Net.host()
	if err != OK:
		status_label.text = "Не удалось создать сервер (код %d)" % err


func _on_join_pressed() -> void:
	var ip := ip_edit.text.strip_edges()
	if ip.is_empty():
		status_label.text = "Введите IP хоста"
		return
	var err := Net.join(ip)
	if err != OK:
		status_label.text = "Не удалось подключиться (код %d)" % err
	else:
		status_label.text = "Подключение к %s..." % ip

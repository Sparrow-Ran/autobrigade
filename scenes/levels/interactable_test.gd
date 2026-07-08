class_name InteractableTestBox
extends StaticBody3D

@export var color_a: Color = Color(0.85, 0.65, 0.2)
@export var color_b: Color = Color(0.2, 0.85, 0.4)

@onready var mesh: MeshInstance3D = $MeshInstance3D

var _toggled: bool = false


func _ready() -> void:
	add_to_group("interactable")


func interact(_player: Node) -> void:
	_toggled = not _toggled
	mesh.set_surface_override_material(0, _make_material(color_b if _toggled else color_a))
	print("Interact: test box toggled -> ", _toggled)


func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat

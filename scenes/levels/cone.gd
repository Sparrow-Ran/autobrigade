extends RigidBody3D
## Cone physics runs on the host; clients receive the synced transform.


func _ready() -> void:
	if not multiplayer.is_server():
		freeze = true

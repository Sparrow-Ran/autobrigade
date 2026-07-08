extends RigidBody3D
## Cone physics runs on the host; clients receive the synced transform.


func _ready() -> void:
	if not multiplayer.is_server():
		freeze = true
		# Positioned by the synchronizer between physics ticks; interpolation
		# would render it stuck at stale snapshots.
		physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

extends Camera3D

# Adapted from:
# https://github.com/nekotogd/Raytracing_Godot4

@export var mouse_sensitivity : float = 0.25
@export var move_speed : float = 5.0
@export var roll_speed: float = 40.0

@export var movement_smoothness : float = 10.0
@export var rotation_smoothness : float = 15.0

var _target_basis := Basis()
var _velocity := Vector3.ZERO

func _ready():
	_target_basis = transform.basis

func _input(event):
	if event is InputEventMouseMotion:
		var yaw_angle = deg_to_rad(event.relative.x * mouse_sensitivity)
		_target_basis = _target_basis.rotated(Vector3.UP, yaw_angle)
		
		var pitch_angle = deg_to_rad(event.relative.y * mouse_sensitivity)
		_target_basis = _target_basis * Basis(Vector3(1.0, 0.0, 0.0), pitch_angle)

func _process(delta):
	if Input.is_action_pressed("left_mouse_btn"):
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		
	if Input.is_action_pressed("roll_cw"):
		_target_basis = _target_basis * Basis(Vector3(0.0, 0.0, 1.0), deg_to_rad(-roll_speed * delta))
	if Input.is_action_pressed("roll_ccw"):
		_target_basis = _target_basis * Basis(Vector3(0.0, 0.0, 1.0), deg_to_rad(roll_speed * delta))
		
	_target_basis = _target_basis.orthonormalized()
	
	var rot_weight = clamp(rotation_smoothness * delta, 0.0, 1.0)
	transform.basis = transform.basis.slerp(_target_basis, rot_weight)
		
	_move(delta)

func _move(delta):
	var input_vector := Vector3.ZERO
	input_vector.x = Input.get_action_strength("move_left") - Input.get_action_strength("move_right")
	input_vector.z = Input.get_action_strength("move_backward") - Input.get_action_strength("move_forward")
	input_vector.y = Input.get_action_strength("move_up") - Input.get_action_strength("move_down")
	if input_vector.length() > 1.0:
		input_vector = input_vector.normalized()
	
	var target_vel := Vector3.ZERO
	target_vel += global_transform.basis.z * move_speed * input_vector.z
	target_vel += global_transform.basis.x * move_speed * input_vector.x
	target_vel -= global_transform.basis.y * move_speed * input_vector.y
	
	var move_weight = clamp(movement_smoothness * delta, 0.0, 1.0)
	_velocity = _velocity.lerp(target_vel, move_weight)
	
	global_transform.origin += _velocity * delta

extends CharacterBody3D
## Quake-style player controller, ported to Godot 4.
##
## ---- Unit systems ----
## Godot 3D: 1 unit = 1 meter; +Y up; right-handed (see Godot docs:
##   "Introduction to 3D > Coordinate system"). Default 3D gravity is
##   9.8 m/s^2 in project settings. CharacterBody3D does NOT consume that
##   automatically — we apply gravity manually below — so we ignore it
##   and use Quake's much-higher tuned gravity instead.
##
## idTech 1 / 2 (Quake): 1 unit ≈ 0.038 m. This ratio comes from Quake's
##   56-unit-tall player bbox representing ~1.78 m, which is the canonical
##   conversion used by Q3 and QuakeWorld source ports. The actual Quake
##   bbox is mins=(-16,-16,-24), maxs=(16,16,32) (pmove.c lines 36-37),
##   centered at the player origin (so the origin is 24 qu above the feet).
##
## ---- Cvar references ----
## All constants below are the QuakeWorld defaults from
##   tmp/quake/QW/server/sv_phys.c and tmp/quake/QW/client/pmove.c,
## scaled to meters / seconds via QU_TO_M.
##
##   sv_gravity        800     -> 30.4   m/s^2   (sv_phys.c:44)
##   sv_maxspeed       320     -> 12.16  m/s     (sv_phys.c:46)
##   sv_stopspeed      100     ->  3.8   m/s     (sv_phys.c:45)
##   sv_accelerate     10                          (sv_phys.c:48; unitless)
##   sv_airaccelerate   0.7                        (sv_phys.c:49; unitless)
##   sv_friction        4                          (sv_phys.c:51; unitless)
##   JumpButton  velocity[2] += 270 -> 10.26 m/s (pmove.c:681)
##   PM_AirAccelerate caps wishspd at 30 qu/s -> 1.14 m/s (pmove.c:422)

const QU_TO_M: float = 0.038

# --- Quake cvar defaults, scaled to Godot meters/seconds ---
# These are @export so you can tune them in the inspector while keeping the
# Quake defaults as the starting point.
@export_group("Movement (Quake cvar equivalents)")
## sv_gravity (800 qu/s^2). Quake gravity is tuned for game feel and is much
## stronger than Earth (~3.1g). Higher = less floaty, snappier jump arcs.
@export var gravity: float          = 800.0 * QU_TO_M    # 30.4  m/s^2
## sv_maxspeed (320 qu/s). Cap on horizontal ground speed; the dot-product
## acceleration model lets you exceed it via air-strafing & bhop.
@export var max_speed: float        = 320.0 * QU_TO_M    # 12.16 m/s
## sv_stopspeed (100 qu/s). Below this speed, friction uses stop_speed
## instead of current speed, which is what makes you snap to a halt
## instead of asymptotically gliding to one.
@export var stop_speed: float       = 100.0 * QU_TO_M    #  3.8  m/s
## sv_accelerate. Higher = reach max_speed faster on the ground.
@export var ground_accel: float     = 10.0
## sv_airaccelerate. Famously small in Quake; this is what allows
## air-strafing without giving you full air control.
@export var air_accel: float        = 0.7
## sv_friction. Higher = stop sooner on the ground.
@export var friction: float         = 4.0
## JumpButton (+270 qu/s vertical impulse).
@export var jump_velocity: float    = 270.0 * QU_TO_M    # 10.26 m/s
## PM_AirAccelerate's hardcoded wishspeed cap (30 qu/s). The defining
## magic number of Quake-style movement — DO NOT raise this if you want
## bhop/air-strafe to feel correct.
@export var air_wishspeed_cap: float = 30.0 * QU_TO_M    #  1.14 m/s

@export_group("Look")
@export var sensitivity: float = 0.05

# --- State ---
var wish_dir: Vector3 = Vector3.ZERO
var wish_jump: bool = false

@onready var head: Node3D = $Head


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_handle_camera_rotation(event)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _handle_camera_rotation(event: InputEventMouseMotion) -> void:
	rotate_y(deg_to_rad(-event.relative.x * sensitivity))
	head.rotate_x(deg_to_rad(-event.relative.y * sensitivity))
	head.rotation.x = clamp(head.rotation.x, deg_to_rad(-89.0), deg_to_rad(89.0))


func _physics_process(delta: float) -> void:
	_process_input()
	_process_movement(delta)


func _process_input() -> void:
	# Godot is right-handed +Y up with -Z forward (Camera3D's default look
	# direction), so "forward" in player-local space is `-transform.basis.z`.
	var input_dir: Vector3 = Vector3.ZERO
	if Input.is_action_pressed("forward"):
		input_dir -= transform.basis.z
	elif Input.is_action_pressed("backward"):
		input_dir += transform.basis.z
	if Input.is_action_pressed("left"):
		input_dir -= transform.basis.x
	elif Input.is_action_pressed("right"):
		input_dir += transform.basis.x

	# Quake flattens forward/right onto the XY plane (which is Godot's XZ)
	# *before* normalizing (pmove.c:515-518), so look-pitch doesn't make
	# you walk faster/slower.
	input_dir.y = 0.0
	wish_dir = input_dir.normalized()

	# Hold-to-bhop. Real Quake gates this with `oldbuttons` to prevent
	# pogo-sticking, but auto-bhop is the modern norm.
	wish_jump = Input.is_action_pressed("jump")


func _process_movement(delta: float) -> void:
	if is_on_floor():
		if wish_jump:
			# JumpButton (pmove.c:681): velocity[2] += 270.
			# Crucially, NO ground friction this frame — we are no longer
			# on-ground the instant we jump, so we air-accelerate for the
			# rest of the tick. This is the bhop frame.
			velocity.y = jump_velocity
			_air_accelerate(wish_dir, max_speed, air_accel, delta)
		else:
			_apply_friction(delta)
			_accelerate(wish_dir, max_speed, ground_accel, delta)
	else:
		# In Godot, -Y is down. (Quake's +Z is up; the conversion is just a
		# coordinate swap, the physics math is identical.)
		velocity.y -= gravity * delta
		_air_accelerate(wish_dir, max_speed, air_accel, delta)

	move_and_slide()

	# PM_ClipVelocity (pmove.c:72-95): when we hit a wall or ramp, project
	# velocity along the surface. Without this you lose all speed surfing
	# into a ramp. Godot's Vector3.slide does exactly the Quake math.
	if is_on_wall():
		velocity = velocity.slide(get_wall_normal())


# SV_UserFriction / PM_Friction (sv_user.c:128-165, pmove.c:336-382).
# Note the stop_speed floor: friction at low speeds uses stop_speed instead
# of current speed, which is what gives Quake its snappy stop instead of
# the asymptotic glide of a naive `velocity *= 0.9` approach.
func _apply_friction(delta: float) -> void:
	var speed: float = velocity.length()
	# Quake: "if (speed < 1)" in qu/s. 1 qu/s ≈ 0.038 m/s.
	if speed < QU_TO_M:
		velocity.x = 0.0
		velocity.z = 0.0
		return

	var control: float = max(stop_speed, speed)
	var drop: float = control * friction * delta
	var newspeed: float = max(speed - drop, 0.0) / speed
	# Only damp horizontal components; vertical handles itself via gravity
	# (this matches the per-component ground-only loop in Quake).
	velocity.x *= newspeed
	velocity.z *= newspeed


# PM_Accelerate (pmove.c:386-410). The key insight: we project velocity
# onto wishdir and only cap that *projection*, not total speed. Side-strafe
# velocity is therefore unbounded, which is what permits bhop.
func _accelerate(dir: Vector3, wishspeed: float, accel: float, delta: float) -> void:
	var current_speed: float = velocity.dot(dir)
	var add_speed: float = wishspeed - current_speed
	if add_speed <= 0.0:
		return
	var accel_speed: float = accel * wishspeed * delta
	if accel_speed > add_speed:
		accel_speed = add_speed
	velocity += dir * accel_speed


# PM_AirAccelerate (pmove.c:412-434). Identical structure to PM_Accelerate
# except the *target* is min(wishspeed, 30 qu/s) while the *acceleration
# magnitude* still scales with the un-capped wishspeed. This asymmetry is
# the magic that lets you keep gaining speed sideways forever as long as
# you don't already have velocity in that direction.
func _air_accelerate(dir: Vector3, wishspeed: float, accel: float, delta: float) -> void:
	var wishspd: float = min(wishspeed, air_wishspeed_cap)
	var current_speed: float = velocity.dot(dir)
	var add_speed: float = wishspd - current_speed
	if add_speed <= 0.0:
		return
	var accel_speed: float = accel * wishspeed * delta
	if accel_speed > add_speed:
		accel_speed = add_speed
	velocity += dir * accel_speed

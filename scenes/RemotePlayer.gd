extends CharacterBody3D
## RemotePlayer — visual presence for a peer that isn't the local player.
##
## Transform fields are synced from the authority (the peer that *owns*
## this player) via the MultiplayerSynchronizer in the scene. We do no
## input processing, no camera, no physics integration of our own.

# Synced properties (the synchronizer writes to these).
@export var head_pitch: float = 0.0   # head's local X rotation
@export var player_name: String = ""

@onready var name_label: Label3D = $NameLabel


func _ready() -> void:
	# RemotePlayer never simulates physics; its transform comes from sync.
	set_physics_process(false)


func _process(_delta: float) -> void:
	if name_label.text != player_name:
		name_label.text = player_name

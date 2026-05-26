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


func _enter_tree() -> void:
	# The server names each spawned RemotePlayer instance after its owning
	# peer ID (see net/server.gd::_on_peer_connected). Setting authority
	# during _enter_tree (NOT _ready) is required for the spawn-time
	# replication interface to assign a network ID without warnings.
	# See: godotengine/godot PR #66794 and issue #75067.
	var peer_id := int(name)
	if peer_id > 0:
		set_multiplayer_authority(peer_id)


func _ready() -> void:
	# RemotePlayer never simulates physics; its transform comes from sync.
	set_physics_process(false)


func _process(_delta: float) -> void:
	if name_label.text != player_name:
		name_label.text = player_name

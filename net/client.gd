extends Node
## Client — runs only on client builds. Manages connection to the
## central server with offline fallback.

const CONNECT_TIMEOUT: float = 5.0
const PLAYER_SCENE: PackedScene = preload("res://scenes/Player.tscn")

# Where the server-controlled func_godot player entity was placed in the map.
# We use this position when spawning the local Player in offline mode and as
# a fallback for the online-swap case. Position is captured from main.tscn's
# entity_1_player transform before that node was removed in Task 7.
const SPAWN_POSITION: Vector3 = Vector3(0.25, 2.25, 6.25)

var peer: ENetMultiplayerPeer

@onready var spawner: MultiplayerSpawner = $"../PlayerSpawner"
@onready var players: Node3D = $"../Players"


func start() -> void:
	if Net.cli_force_offline:
		Net.is_offline = true
		print("[Client] offline mode (forced via --offline)")
		_spawn_local_offline_player()
		return

	peer = ENetMultiplayerPeer.new()
	var err := peer.create_client(Net.cli_host, Net.cli_port)
	if err != OK:
		_fallback_to_offline("could not create client: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	spawner.spawned.connect(_on_player_spawned)
	print("[Client] connecting to %s:%d..." % [Net.cli_host, Net.cli_port])
	# ENet's built-in connect timeout is ~30s, which is far too long for a UX
	# that drops into offline mode on failure. Start our own deadline.
	get_tree().create_timer(CONNECT_TIMEOUT).timeout.connect(_on_connect_timeout)


func _on_connected() -> void:
	print("[Client] connected to server")
	Toast.show_message("Connected to %s" % Net.cli_host)


func _on_connection_failed() -> void:
	Toast.show_message("Server unreachable — playing offline")
	_fallback_to_offline("connection failed (server unreachable)")


func _on_connect_timeout() -> void:
	# If we connected successfully before the timeout, multiplayer_peer is
	# still set and the connection is good — nothing to do.
	if multiplayer.multiplayer_peer != null and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return
	Toast.show_message("Server unreachable — playing offline")
	_fallback_to_offline("connection timed out after %.0fs" % CONNECT_TIMEOUT)


func _on_server_disconnected() -> void:
	Toast.show_message("Disconnected from server")
	_fallback_to_offline("server disconnected mid-game")


func _on_player_spawned(node: Node) -> void:
	# The server spawned a RemotePlayer; if it's *our* peer ID, swap it
	# for the full Player.tscn (with camera + input).
	var my_id := multiplayer.get_unique_id()
	if int(node.name) != my_id:
		return
	# We can't read position from the RemotePlayer: it's (0,0,0) at this
	# point because the spawn payload doesn't carry state when the synchronizer's
	# authority is the client peer (not the server). We use the canonical
	# SPAWN_POSITION instead. Other peers will see us at (0,0,0) for ~50ms
	# until the local Player's first sync tick replicates our position.
	# Remove the RemotePlayer that was meant to represent us locally
	# FIRST (using immediate free), so we can reuse its node name. Keeping
	# the same node name (peer_id as a string) is required so the local
	# Player's MultiplayerSynchronizer path matches the server-side
	# RemotePlayer's path — otherwise the server can't route our sync
	# messages and logs "Node not found" errors.
	var node_name := node.name
	players.remove_child(node)
	node.queue_free()
	var local: Node3D = PLAYER_SCENE.instantiate()
	local.name = node_name
	players.add_child(local)
	local.global_position = SPAWN_POSITION
	print("[Client] swapped own RemotePlayer for local Player at %s" % SPAWN_POSITION)


func _fallback_to_offline(reason: String) -> void:
	print("[Client] %s; entering offline mode" % reason)
	Net.is_offline = true
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	peer = null
	_spawn_local_offline_player()


func _spawn_local_offline_player() -> void:
	# In offline mode there's no server-spawned RemotePlayer to swap, so we
	# just instantiate a Player directly. Guard against double-spawn.
	if players.has_node("Local_Offline"):
		return
	var local: Node3D = PLAYER_SCENE.instantiate()
	local.name = "Local_Offline"
	players.add_child(local)
	local.global_position = SPAWN_POSITION
	print("[Client] spawned offline local Player at %s" % SPAWN_POSITION)

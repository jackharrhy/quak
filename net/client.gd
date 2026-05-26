extends Node
## Client — runs only on client builds. Manages connection to the
## central server with offline fallback.

const CONNECT_TIMEOUT: float = 5.0
const PLAYER_SCENE: PackedScene = preload("res://scenes/Player.tscn")
const SETTINGS_PATH := "user://settings.cfg"

# Where the server-controlled func_godot player entity was placed in the map.
# We use this position when spawning the local Player in offline mode and as
# a fallback for the online-swap case. Position is captured from main.tscn's
# entity_1_player transform before that node was removed in Task 7.
const SPAWN_POSITION: Vector3 = Vector3(0.25, 2.25, 6.25)

var peer: ENetMultiplayerPeer

# Incremented on every start() call. Captured by _on_connect_timeout
# closure so stale timers from previous attempts don't trigger a fallback.
var _attempt_id: int = 0

@onready var spawner: MultiplayerSpawner = $"../PlayerSpawner"
@onready var players: Node3D = $"../Players"


func start() -> void:
	_attempt_id += 1
	var this_attempt := _attempt_id
	Net.is_offline = false

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
	# Use is_connected() guards so retry() doesn't trigger Godot's
	# "already connected" error. We connect once and leave the connections
	# in place across retries; _fallback_to_offline doesn't disconnect them.
	if not multiplayer.connected_to_server.is_connected(_on_connected):
		multiplayer.connected_to_server.connect(_on_connected)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)
	if not spawner.spawned.is_connected(_on_player_spawned):
		spawner.spawned.connect(_on_player_spawned)
	print("[Client] connecting to %s:%d..." % [Net.cli_host, Net.cli_port])
	# Capture this_attempt in the lambda so the timer bails if start() was
	# called again before this one's timeout fires.
	get_tree().create_timer(CONNECT_TIMEOUT).timeout.connect(
		func() -> void: _on_connect_timeout(this_attempt)
	)


func retry() -> void:
	# Tear down any offline-mode local player. start() will spawn a new one
	# via _on_player_spawned (on success) or _fallback_to_offline (failure).
	if players.has_node("Local_Offline"):
		players.get_node("Local_Offline").queue_free()
	start()


func _on_connected() -> void:
	print("[Client] connected to server")
	Toast.show_message("Connected to %s" % Net.cli_host)
	# Send our protocol version. If it doesn't match the server's, the
	# server kicks us and we fall back to offline mode via _on_server_disconnected.
	$"../Server".report_version.rpc_id(1, Net.PROTOCOL_VERSION)


func _on_connection_failed() -> void:
	Toast.show_message("Server unreachable — playing offline")
	_fallback_to_offline("connection failed (server unreachable)")


func _on_server_disconnected() -> void:
	Toast.show_message("Disconnected from server")
	_fallback_to_offline("server disconnected mid-game")


func _on_connect_timeout(attempt: int) -> void:
	# Stale timer from a previous start() call — ignore.
	if attempt != _attempt_id:
		return
	# Already in offline mode — _on_connection_failed beat us to it.
	if Net.is_offline:
		return
	# Connected successfully — nothing to do.
	if multiplayer.multiplayer_peer != null and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return
	Toast.show_message("Server unreachable — playing offline")
	_fallback_to_offline("connection timed out after %.0fs" % CONNECT_TIMEOUT)


func _fallback_to_offline(reason: String) -> void:
	print("[Client] %s; entering offline mode" % reason)
	Net.is_offline = true
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	peer = null
	_spawn_local_offline_player()


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
	var chosen := await _load_or_prompt_name()
	local.player_name = chosen
	print("[Client] swapped own RemotePlayer for local Player at %s as '%s'" % [SPAWN_POSITION, chosen])


func _spawn_local_offline_player() -> void:
	# In offline mode there's no server-spawned RemotePlayer to swap, so we
	# just instantiate a Player directly. Guard against double-spawn.
	if players.has_node("Local_Offline"):
		return
	var local: Node3D = PLAYER_SCENE.instantiate()
	local.name = "Local_Offline"
	players.add_child(local)
	local.global_position = SPAWN_POSITION
	var chosen := await _load_or_prompt_name()
	local.player_name = chosen
	print("[Client] spawned offline local Player at %s as '%s'" % [SPAWN_POSITION, chosen])


func _load_or_prompt_name() -> String:
	# CLI override always wins.
	if Net.cli_name != "":
		return Net.cli_name
	# Try saved config.
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		var saved: String = cfg.get_value("player", "name", "")
		if saved != "":
			return saved
	# Prompt.
	var name := await _prompt_for_name()
	if name != "":
		cfg.set_value("player", "name", name)
		cfg.save(SETTINGS_PATH)
	return name


func _prompt_for_name() -> String:
	var dlg := AcceptDialog.new()
	dlg.title = "Pick a name"
	dlg.dialog_hide_on_ok = true
	var line := LineEdit.new()
	line.placeholder_text = "Your name"
	line.custom_minimum_size = Vector2(220, 0)
	dlg.add_child(line)
	dlg.register_text_enter(line)
	get_tree().root.add_child(dlg)
	dlg.popup_centered()
	await dlg.confirmed
	var name := line.text.strip_edges()
	dlg.queue_free()
	if name == "":
		name = "Guest_%d" % (randi() % 9999)
	return name

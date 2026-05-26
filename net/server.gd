extends Node
## Server — runs only on dedicated server builds. Manages peer connections
## and player presence replication.

var peer: ENetMultiplayerPeer


func start() -> void:
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_server(Net.cli_port, Net.MAX_CLIENTS)
	if err != OK:
		push_error("[Server] failed to create server on port %d: %s" % [Net.cli_port, error_string(err)])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_log("server listening on %d" % Net.cli_port)


func _on_peer_connected(id: int) -> void:
	_log("peer %d connected" % id)


func _on_peer_disconnected(id: int) -> void:
	_log("peer %d disconnected" % id)


func _log(msg: String) -> void:
	# ISO-8601 UTC timestamp, matches the spec's log format.
	var t := Time.get_datetime_string_from_system(true)
	print("[%sZ] %s" % [t, msg])

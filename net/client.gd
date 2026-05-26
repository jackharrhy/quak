extends Node
## Client — runs only on client builds. Manages connection to the
## central server with offline fallback.

var peer: ENetMultiplayerPeer


func start() -> void:
	if Net.cli_force_offline:
		Net.is_offline = true
		print("[Client] offline mode (forced via --offline)")
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
	print("[Client] connecting to %s:%d..." % [Net.cli_host, Net.cli_port])


func _on_connected() -> void:
	print("[Client] connected to server")


func _on_connection_failed() -> void:
	_fallback_to_offline("connection failed (server unreachable)")


func _on_server_disconnected() -> void:
	_fallback_to_offline("server disconnected mid-game")


func _fallback_to_offline(reason: String) -> void:
	print("[Client] %s; entering offline mode" % reason)
	Net.is_offline = true
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	peer = null

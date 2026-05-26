extends Node
## Client — runs only on client builds. Manages connection to the
## central server with offline fallback.

const CONNECT_TIMEOUT: float = 5.0

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


func _fallback_to_offline(reason: String) -> void:
	print("[Client] %s; entering offline mode" % reason)
	Net.is_offline = true
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	peer = null

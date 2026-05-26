extends Node
## Net — boot-time role decision and shared multiplayer state.
##
## Decides whether this instance runs as a dedicated server or as a client,
## based on the `dedicated_server` feature flag (set by the Linux Dedicated
## Server export template) or the `--dedicated-server` CLI flag (for editor
## testing). See docs/superpowers/specs/2026-05-26-multiplayer-networking-design.md.

const SERVER_HOST: String        = "quak.jackharrhy.dev"
const PORT: int                  = 27420
const MAX_CLIENTS: int           = 32
const SEND_RATE: int             = 20    # Hz
const PROTOCOL_VERSION: int      = 1

enum Role { CLIENT, SERVER }

var role: Role = Role.CLIENT
var is_offline: bool = false

# CLI overrides (parsed in _ready).
var cli_host: String = SERVER_HOST
var cli_port: int = PORT
var cli_name: String = ""
var cli_force_offline: bool = false


func _ready() -> void:
	_parse_cli_args()
	if OS.has_feature("dedicated_server") or _has_cli_flag("--dedicated-server"):
		role = Role.SERVER
		print("[Net] starting in SERVER role")
		$Server.start()
	else:
		role = Role.CLIENT
		print("[Net] starting in CLIENT role")
		if cli_force_offline:
			print("[Net] --offline flag set; skipping connection")


func _parse_cli_args() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var a: String = args[i]
		match a:
			"--host":
				if i + 1 < args.size():
					cli_host = args[i + 1]
					i += 1
			"--port":
				if i + 1 < args.size():
					var port_str: String = args[i + 1]
					if port_str.is_valid_int():
						cli_port = int(port_str)
					else:
						push_warning("[Net] invalid --port value: %s" % port_str)
					i += 1
			"--name":
				if i + 1 < args.size():
					cli_name = args[i + 1]
					i += 1
			"--offline":
				cli_force_offline = true
			"--dedicated-server":
				# Consumed by _has_cli_flag() in _ready(); no state to set here.
				pass
			_:
				if a.begins_with("--"):
					push_warning("[Net] unknown CLI flag: %s" % a)
		i += 1


func _has_cli_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()

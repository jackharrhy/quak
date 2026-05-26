# Multiplayer Networking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire up a dedicated Godot server at `quak.jackharrhy.dev:27420` that all clients connect to on launch, with player presence replication and a graceful offline fallback.

**Architecture:** One Godot project, two roles. A `Net` autoload picks server-or-client at boot based on the `dedicated_server` feature flag (or `--dedicated-server` CLI flag). Local player keeps full client-side Quake movement; remote players are interpolated presence-only `CharacterBody3D`s synced at 20 Hz via `MultiplayerSynchronizer`. Server is built via a Linux Dedicated Server export preset, packaged into a Docker image, and run on a VPS behind the project's DNS.

**Tech Stack:** Godot 4.6, GDScript, `ENetMultiplayerPeer`, `MultiplayerSpawner`, `MultiplayerSynchronizer`, Docker, GitHub Actions.

**Reference:** [`docs/superpowers/specs/2026-05-26-multiplayer-networking-design.md`](../specs/2026-05-26-multiplayer-networking-design.md)

## Tooling note for implementers

Godot is **not on `$PATH`** on the maintainer's machine. Use `scripts/godot.sh` for every CLI invocation — it locates the Godot 4.6 binary in the macOS app bundle (or honors `$GODOT` env var, or falls back to `godot` on PATH for CI).

Two smoke-test commands work for verifying scripts and scenes parse correctly without an interactive editor:

```bash
# Verifies the project loads: all .gd compiles, all imports resolve, exits 0 on success
timeout 30 scripts/godot.sh --headless --quit --path .

# Same but actually runs 5 frames, catching _ready() errors
timeout 30 scripts/godot.sh --headless --quit-after 5 --path .
```

After every task that adds or modifies a `.gd` or `.tscn` file, run the second command and confirm it exits 0 with no error output (other than the version banner). If it doesn't, fix before committing.

There is no `--check-only` lint mode that works on arbitrary scripts in Godot 4 — `--check-only` only validates `MainLoop`/`SceneTree` scripts. The `--quit-after` approach is the canonical headless smoke test.

---

## File Structure

**New files (created by this plan):**

```
res://
├── net/
│   ├── net.gd                    # autoload script; role selection, peer lifecycle
│   ├── net.tscn                  # autoload scene root; hosts MultiplayerSpawner
│   ├── server.gd                 # server-only: spawn/despawn, logging
│   ├── client.gd                 # client-only: connect, fallback, name prompt
│   ├── toast.gd                  # connection-status toast singleton (script)
│   └── toast.tscn                # toast singleton scene
├── scenes/
│   ├── RemotePlayer.gd           # remote presence script
│   └── RemotePlayer.tscn         # remote presence scene
└── docs/
    └── deployment.md             # VPS / DNS setup notes
.github/workflows/server.yml      # CI: build Docker image, push to GHCR
Dockerfile                        # 2-stage build for headless server
export_presets.cfg                # Linux Dedicated Server preset entry
```

**Modified files:**

```
project.godot                     # add Net + Toast autoloads, dedicated_server feature
scenes/Player.gd                  # add multiplayer authority guard, name handling
scenes/Player.tscn                # add MultiplayerSynchronizer
.gitignore                        # ignore dist/ output dir
```

**Responsibilities (one purpose per file):**

- `net.gd` — boot-time role decision, CLI parsing, peer lifecycle (connect/disconnect signals, retry hotkey)
- `server.gd` — pure server logic: spawn `RemotePlayer` on peer_connected, despawn on peer_disconnected, log
- `client.gd` — pure client logic: connect, swap own RemotePlayer for Player.tscn locally, prompt for name once, save to user://
- `toast.gd` — tiny CanvasLayer with a Label + Tween for "Server unreachable" etc.
- `RemotePlayer.gd` — receives position/rotation/name via `MultiplayerSynchronizer`, no input, no camera
- `Dockerfile` — reproducible headless server build
- `server.yml` — push-to-main → image-to-GHCR pipeline

---

## Tasks

Tasks are ordered so each one ends with a clean, committable state. Earlier tasks set foundations; later tasks build on them. The Docker/CI tasks come last because they're independently testable from the gameplay tasks.

---

### Task 1: Add `dedicated_server` feature flag and CLI flag plumbing

**Files:**
- Create: `res://net/net.gd`
- Create: `res://net/net.tscn`
- Modify: `res://project.godot`

This task creates the Net autoload skeleton and gets it printing role decisions, with nothing else wired up yet. We commit a "does the right thing on boot" milestone before touching networking.

- [ ] **Step 1: Create `net/net.gd` with role-selection logic**

Write `res://net/net.gd`:

```gdscript
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
					cli_port = int(args[i + 1])
					i += 1
			"--name":
				if i + 1 < args.size():
					cli_name = args[i + 1]
					i += 1
			"--offline":
				cli_force_offline = true
		i += 1


func _has_cli_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()
```

- [ ] **Step 2: Create `net/net.tscn` autoload scene**

Write `res://net/net.tscn`:

```
[gd_scene load_steps=2 format=3 uid="uid://b1net0000001"]

[ext_resource type="Script" path="res://net/net.gd" id="1_net"]

[node name="Net" type="Node"]
script = ExtResource("1_net")
```

- [ ] **Step 3: Register Net as an autoload**

Edit `res://project.godot`. Add an `[autoload]` section before the `[editor_plugins]` section (or at the appropriate position; Godot will rewrite this on save):

```
[autoload]

Net="*res://net/net.tscn"
```

The leading `*` means the node persists across scene changes.

- [ ] **Step 4: Manually verify role selection**

Open the project in Godot. Look at the Output panel when the game runs. Expected output for normal run: `[Net] starting in CLIENT role`.

Then Project Settings → Run → set "Main Run Args" to `-- --dedicated-server` (the `--` separates engine args from user args, which is what `get_cmdline_user_args` returns). Run again. Expected: `[Net] starting in SERVER role`.

Remove the `--dedicated-server` from run args afterwards. Document the trick in a comment if needed.

- [ ] **Step 5: Commit**

```bash
git add net/ project.godot
git commit -m "Add Net autoload with role selection scaffold"
```

---

### Task 2: Server can open a listening UDP port

**Files:**
- Create: `res://net/server.gd`
- Modify: `res://net/net.tscn` (add Server child node)
- Modify: `res://net/net.gd` (call into Server when role == SERVER)

This task gets a real `ENetMultiplayerPeer` server running. No clients yet; we just verify it binds and prints expected log lines.

- [ ] **Step 1: Create `net/server.gd`**

Write `res://net/server.gd`:

```gdscript
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
```

- [ ] **Step 2: Add Server child to `net.tscn`**

Modify `res://net/net.tscn`:

```
[gd_scene load_steps=3 format=3 uid="uid://b1net0000001"]

[ext_resource type="Script" path="res://net/net.gd" id="1_net"]
[ext_resource type="Script" path="res://net/server.gd" id="2_server"]

[node name="Net" type="Node"]
script = ExtResource("1_net")

[node name="Server" type="Node" parent="."]
script = ExtResource("2_server")
```

- [ ] **Step 3: Wire Net._ready() to call Server.start() when role is SERVER**

Modify `res://net/net.gd`'s `_ready()`:

```gdscript
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
```

- [ ] **Step 4: Manually verify the server opens the port**

In Project Settings → Run → Main Run Args, set `-- --dedicated-server`.
Run the project. Expected stdout (timestamps will differ):

```
[Net] starting in SERVER role
[2026-05-26T14:00:00Z] server listening on 27420
```

Outside Godot, in a separate terminal:

```bash
lsof -nP -iUDP:27420 -sUDP:^CLOSE 2>/dev/null || echo "port not listening"
```

Expected: a line showing the Godot process is bound to UDP port 27420. If the lsof line is empty, the server didn't bind — investigate before continuing.

Stop the project. Reset Main Run Args back to empty.

- [ ] **Step 5: Commit**

```bash
git add net/server.gd net/net.tscn net/net.gd
git commit -m "Add ENet server that opens listening UDP port"
```

---

### Task 3: Client connects to server, with offline fallback

**Files:**
- Create: `res://net/client.gd`
- Modify: `res://net/net.tscn` (add Client child)
- Modify: `res://net/net.gd` (call Client.start() when role == CLIENT)

This task gets the client connecting to a running server, falling back to offline if the server isn't reachable. Still no player visuals; we verify via log output.

- [ ] **Step 1: Create `net/client.gd`**

Write `res://net/client.gd`:

```gdscript
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
```

- [ ] **Step 2: Add Client child to `net.tscn`**

Modify `res://net/net.tscn`:

```
[gd_scene load_steps=4 format=3 uid="uid://b1net0000001"]

[ext_resource type="Script" path="res://net/net.gd" id="1_net"]
[ext_resource type="Script" path="res://net/server.gd" id="2_server"]
[ext_resource type="Script" path="res://net/client.gd" id="3_client"]

[node name="Net" type="Node"]
script = ExtResource("1_net")

[node name="Server" type="Node" parent="."]
script = ExtResource("2_server")

[node name="Client" type="Node" parent="."]
script = ExtResource("3_client")
```

- [ ] **Step 3: Wire Net._ready() to call Client.start() when role is CLIENT**

Modify `res://net/net.gd`'s `_ready()`:

```gdscript
func _ready() -> void:
	_parse_cli_args()
	if OS.has_feature("dedicated_server") or _has_cli_flag("--dedicated-server"):
		role = Role.SERVER
		print("[Net] starting in SERVER role")
		$Server.start()
	else:
		role = Role.CLIENT
		print("[Net] starting in CLIENT role")
		$Client.start()
```

The `cli_force_offline` check moves into `Client.start()` (already there in Step 1).

- [ ] **Step 4: Manually verify connection succeeds when server is running**

Open the project in Godot **twice** (Godot supports multiple editor instances; or just use the same instance, stop & restart). 

Instance A: set Main Run Args to `-- --dedicated-server` and run. Expected stdout:
```
[Net] starting in SERVER role
[2026-05-26T...Z] server listening on 27420
```

Instance B: set Main Run Args to `-- --host 127.0.0.1` and run. Expected stdout in B:
```
[Net] starting in CLIENT role
[Client] connecting to 127.0.0.1:27420...
[Client] connected to server
```

Expected stdout in A (server should log the new peer):
```
[2026-05-26T...Z] peer <number> connected
```

Stop both. Reset Main Run Args.

- [ ] **Step 5: Manually verify offline fallback when server is NOT running**

Set Main Run Args to empty. Run the project (server is not running). Expected stdout:

```
[Net] starting in CLIENT role
[Client] connecting to quak.jackharrhy.dev:27420...
[Client] connection failed (server unreachable); entering offline mode
```

(The DNS may or may not resolve at this point — either way, `connection_failed` will fire.)

- [ ] **Step 6: Manually verify --offline flag**

Set Main Run Args to `-- --offline`. Run. Expected:

```
[Net] starting in CLIENT role
[Client] offline mode (forced via --offline)
```

Reset Main Run Args.

- [ ] **Step 7: Commit**

```bash
git add net/client.gd net/net.tscn net/net.gd
git commit -m "Add ENet client with offline fallback"
```

---

### Task 4: Toast UI for connection status

**Files:**
- Create: `res://net/toast.gd`
- Create: `res://net/toast.tscn`
- Modify: `res://project.godot` (register Toast autoload)
- Modify: `res://net/client.gd` (call Toast.show() on state changes)

This task adds the user-visible "Server unreachable" / "Connected" overlay.

- [ ] **Step 1: Create `net/toast.gd`**

Write `res://net/toast.gd`:

```gdscript
extends CanvasLayer
## Toast — minimal "show a message for N seconds, then fade out" overlay.

const DEFAULT_DURATION: float = 3.0
const FADE_TIME: float = 0.4

@onready var label: Label = $Panel/Label
@onready var panel: PanelContainer = $Panel

var _tween: Tween


func _ready() -> void:
	panel.modulate.a = 0.0


func show_message(text: String, duration: float = DEFAULT_DURATION) -> void:
	label.text = text
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(panel, "modulate:a", 1.0, FADE_TIME)
	_tween.tween_interval(duration)
	_tween.tween_property(panel, "modulate:a", 0.0, FADE_TIME)
```

- [ ] **Step 2: Create `net/toast.tscn`**

Write `res://net/toast.tscn`:

```
[gd_scene load_steps=3 format=3 uid="uid://b1toast0000001"]

[ext_resource type="Script" path="res://net/toast.gd" id="1_toast"]

[sub_resource type="StyleBoxFlat" id="StyleBoxFlat_toast"]
bg_color = Color(0, 0, 0, 0.7)
corner_radius_top_left = 6
corner_radius_top_right = 6
corner_radius_bottom_right = 6
corner_radius_bottom_left = 6
content_margin_left = 16.0
content_margin_top = 8.0
content_margin_right = 16.0
content_margin_bottom = 8.0

[node name="Toast" type="CanvasLayer"]
layer = 100
script = ExtResource("1_toast")

[node name="Panel" type="PanelContainer" parent="."]
anchors_preset = 7
anchor_left = 0.5
anchor_top = 1.0
anchor_right = 0.5
anchor_bottom = 1.0
offset_left = -200.0
offset_top = -80.0
offset_right = 200.0
offset_bottom = -32.0
grow_horizontal = 2
grow_vertical = 0
theme_override_styles/panel = SubResource("StyleBoxFlat_toast")

[node name="Label" type="Label" parent="Panel"]
layout_mode = 2
text = ""
horizontal_alignment = 1
```

- [ ] **Step 3: Register Toast as autoload**

Edit `res://project.godot`. Add to the `[autoload]` section:

```
Toast="*res://net/toast.tscn"
```

The order matters slightly: list Net before Toast so Net is initialized first. (Either order works for functionality; this is just a convention.)

- [ ] **Step 4: Wire Toast into Client**

Modify `res://net/client.gd`. Update each of these handlers to also show a toast:

```gdscript
func _on_connected() -> void:
	print("[Client] connected to server")
	Toast.show_message("Connected to %s" % Net.cli_host)


func _on_connection_failed() -> void:
	Toast.show_message("Server unreachable — playing offline")
	_fallback_to_offline("connection failed (server unreachable)")


func _on_server_disconnected() -> void:
	Toast.show_message("Disconnected from server")
	_fallback_to_offline("server disconnected mid-game")
```

- [ ] **Step 5: Manually verify toasts**

Run the project with the server NOT running, default args. Expected: a black rounded toast appears at the bottom of the screen reading "Server unreachable — playing offline", then fades out after ~3 seconds.

Run the project with the server running (Task 3 setup) and `-- --host 127.0.0.1`. Expected: a toast reads "Connected to 127.0.0.1".

- [ ] **Step 6: Commit**

```bash
git add net/toast.gd net/toast.tscn project.godot net/client.gd
git commit -m "Add connection-status toast overlay"
```

---

### Task 5: RemotePlayer scene and script

**Files:**
- Create: `res://scenes/RemotePlayer.gd`
- Create: `res://scenes/RemotePlayer.tscn`

This task creates the visual presence for *other* players. It doesn't get spawned by anyone yet; we'll instance it manually next task to verify it works.

- [ ] **Step 1: Create `scenes/RemotePlayer.gd`**

Write `res://scenes/RemotePlayer.gd`:

```gdscript
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
```

- [ ] **Step 2: Create `scenes/RemotePlayer.tscn`**

Write `res://scenes/RemotePlayer.tscn`:

```
[gd_scene load_steps=5 format=3 uid="uid://b1remoteplayer001"]

[ext_resource type="Script" path="res://scenes/RemotePlayer.gd" id="1_remote"]

[sub_resource type="BoxShape3D" id="BoxShape3D_remote"]
size = Vector3(1.216, 2.128, 1.216)

[sub_resource type="CapsuleMesh" id="CapsuleMesh_remote"]
radius = 0.608
height = 2.128

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_remote"]
albedo_color = Color(0.8, 0.3, 0.3, 1)

[node name="RemotePlayer" type="CharacterBody3D"]
script = ExtResource("1_remote")

[node name="CollisionShape3D" type="CollisionShape3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.152, 0)
shape = SubResource("BoxShape3D_remote")

[node name="Mesh" type="MeshInstance3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.152, 0)
mesh = SubResource("CapsuleMesh_remote")
material_override = SubResource("StandardMaterial3D_remote")

[node name="NameLabel" type="Label3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 2.4, 0)
billboard = 1
no_depth_test = true
fixed_size = true
text = "player"

[node name="MultiplayerSynchronizer" type="MultiplayerSynchronizer" parent="."]
replication_interval = 0.05
delta_interval = 0.05
```

Note: the synchronizer's *replication config* (which properties to sync) is normally edited in the Godot editor's "Replication" bottom panel and stored in a `SceneReplicationConfig` resource. We'll set this up in the editor in Step 3.

- [ ] **Step 3: Configure replication properties in the editor**

Open `scenes/RemotePlayer.tscn` in Godot. Select the `MultiplayerSynchronizer` node. In the bottom **Replication** panel, click **+ Add property to sync** for each of these:

| Property | Sync setting |
|---|---|
| `RemotePlayer:position` | Always |
| `RemotePlayer:rotation:y` | Always |
| `RemotePlayer:head_pitch` | Always |
| `RemotePlayer:player_name` | On Change |

Save the scene. Godot will create a `SceneReplicationConfig` sub-resource inside the .tscn.

- [ ] **Step 4: Smoke-test by instancing it once**

Temporarily edit `main.tscn`: add a `RemotePlayer.tscn` instance as a child of the `Root` node, positioned somewhere visible (e.g. `Transform3D(1,0,0,0,1,0,0,0,1, 2, 1, 0)`). Run the project. Expected: a red capsule with a "player" label above it visible in the world.

Remove the test instance from `main.tscn` before committing. (We're verifying the scene works in isolation, not committing the test placement.)

- [ ] **Step 5: Commit**

```bash
git add scenes/RemotePlayer.gd scenes/RemotePlayer.tscn
git commit -m "Add RemotePlayer scene for replicated player presence"
```

---

### Task 6: Server spawns RemotePlayer for each peer

**Files:**
- Modify: `res://net/server.gd` (spawn on connect, despawn on disconnect)
- Modify: `res://net/net.tscn` (add `Players` Node3D + MultiplayerSpawner)
- Modify: `res://net/net.gd` (load main.tscn after networking starts)

This task makes the server actually create `RemotePlayer` instances under `Players` whenever a peer connects, and `MultiplayerSpawner` replicates them to all connected clients.

- [ ] **Step 1: Add Players + MultiplayerSpawner to `net.tscn`**

Modify `res://net/net.tscn` to add a `Players` container and a `MultiplayerSpawner`:

```
[gd_scene load_steps=4 format=3 uid="uid://b1net0000001"]

[ext_resource type="Script" path="res://net/net.gd" id="1_net"]
[ext_resource type="Script" path="res://net/server.gd" id="2_server"]
[ext_resource type="Script" path="res://net/client.gd" id="3_client"]
[ext_resource type="PackedScene" uid="uid://b1remoteplayer001" path="res://scenes/RemotePlayer.tscn" id="4_remote"]

[node name="Net" type="Node"]
script = ExtResource("1_net")

[node name="Server" type="Node" parent="."]
script = ExtResource("2_server")

[node name="Client" type="Node" parent="."]
script = ExtResource("3_client")

[node name="Players" type="Node3D" parent="."]

[node name="PlayerSpawner" type="MultiplayerSpawner" parent="."]
_spawnable_scenes = PackedStringArray("res://scenes/RemotePlayer.tscn")
spawn_path = NodePath("../Players")
```

- [ ] **Step 2: Modify server.gd to spawn/despawn RemotePlayer**

Update `res://net/server.gd`:

```gdscript
extends Node

const REMOTE_PLAYER_SCENE: PackedScene = preload("res://scenes/RemotePlayer.tscn")

var peer: ENetMultiplayerPeer

@onready var players: Node3D = $"../Players"


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
	var p := REMOTE_PLAYER_SCENE.instantiate()
	p.name = str(id)
	p.set_multiplayer_authority(id)
	players.add_child(p, true)


func _on_peer_disconnected(id: int) -> void:
	_log("peer %d disconnected" % id)
	if players.has_node(str(id)):
		players.get_node(str(id)).queue_free()


func _log(msg: String) -> void:
	var t := Time.get_datetime_string_from_system(true)
	print("[%sZ] %s" % [t, msg])
```

- [ ] **Step 3: Make sure main.tscn is the running scene**

The project's main scene (`main.tscn`) is already set as the run target via `project.godot`'s `run/main_scene`. Since both server and client load it, nothing extra is needed here. Verify by checking `project.godot:14`: `run/main_scene="uid://eprldq88q18u"`.

- [ ] **Step 4: Manually verify spawning**

Run two instances:

A (server): Main Run Args `-- --dedicated-server`. Run.
B (client): Main Run Args `-- --host 127.0.0.1`. Run.

Expected: in instance B (the client), a red capsule labelled "player" appears somewhere in the scene (the position is whatever the RemotePlayer defaults to — likely `(0,0,0)`). In instance A's stdout:

```
[...] peer <id> connected
```

Close B. Expected in A:

```
[...] peer <id> disconnected
```

Re-run B and confirm the capsule re-appears.

- [ ] **Step 5: Commit**

```bash
git add net/server.gd net/net.tscn
git commit -m "Server spawns RemotePlayer for each connected peer"
```

---

### Task 7: Client swaps own RemotePlayer for full Player.tscn

**Files:**
- Modify: `res://net/client.gd` (listen for own RemotePlayer being spawned, swap it)

This task is the load-bearing trick: every peer sees every other peer as a `RemotePlayer`, but the local client replaces *its own* RemotePlayer with the full `Player.tscn` so it has the camera and input.

- [ ] **Step 1: Modify client.gd to detect own spawn and swap**

Update `res://net/client.gd`:

```gdscript
extends Node

const PLAYER_SCENE: PackedScene = preload("res://scenes/Player.tscn")

var peer: ENetMultiplayerPeer

@onready var spawner: MultiplayerSpawner = $"../PlayerSpawner"
@onready var players: Node3D = $"../Players"


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
	spawner.spawned.connect(_on_player_spawned)
	print("[Client] connecting to %s:%d..." % [Net.cli_host, Net.cli_port])


func _on_connected() -> void:
	print("[Client] connected to server")
	Toast.show_message("Connected to %s" % Net.cli_host)


func _on_connection_failed() -> void:
	Toast.show_message("Server unreachable — playing offline")
	_fallback_to_offline("connection failed (server unreachable)")


func _on_server_disconnected() -> void:
	Toast.show_message("Disconnected from server")
	_fallback_to_offline("server disconnected mid-game")


func _on_player_spawned(node: Node) -> void:
	# The server spawned a RemotePlayer; if it's *our* peer ID, swap it
	# for the full Player.tscn (with camera + input).
	var my_id := multiplayer.get_unique_id()
	if int(node.name) != my_id:
		return
	var pos: Vector3 = (node as Node3D).global_position
	var rot: Vector3 = (node as Node3D).rotation
	var local: Node3D = PLAYER_SCENE.instantiate()
	local.name = "Local_%d" % my_id
	players.add_child(local)
	local.global_position = pos
	local.rotation = rot
	# Remove the RemotePlayer that was meant to represent us locally.
	node.queue_free()
	print("[Client] swapped own RemotePlayer for local Player at %s" % pos)


func _fallback_to_offline(reason: String) -> void:
	print("[Client] %s; entering offline mode" % reason)
	Net.is_offline = true
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	peer = null
	# Spawn a local-only Player so the game is still playable.
	if not players.has_node("Local_Offline"):
		var local: Node3D = PLAYER_SCENE.instantiate()
		local.name = "Local_Offline"
		players.add_child(local)
```

- [ ] **Step 2: Remove the player from main.tscn**

`main.tscn` currently has an `entity_1_player` node from func_godot that instances `Player.tscn` directly. Now that the player spawns via Client (online) or via the offline fallback (offline), this hard-coded instance would double-spawn the player.

Open `main.tscn` in the Godot editor. Delete the `entity_1_player` node from the scene tree. Save.

Alternative: edit `main.tscn` directly and remove the line(s) defining `entity_1_player` and its child Camera3D. The cleaner option is the editor since func_godot maps may regenerate node positions.

- [ ] **Step 3: Manually verify local swap**

Run two instances as before (A: dedicated-server, B: `--host 127.0.0.1`). Expected in B:
- A `Player.tscn` (with camera + WASD/mouse-look) appears at origin.
- You can walk around.
- The red capsule that was previously visible (representing your own peer) is gone.

Run a third instance C (also `--host 127.0.0.1`). Expected:
- In B, a new red capsule appears (representing C).
- In C, a Player.tscn appears for C, plus a red capsule representing B.
- B and C can see each other moving (positions won't sync yet — that's the next task — but the swap mechanism works).

Stop B. Expected: in C, the red capsule representing B disappears.

- [ ] **Step 4: Verify offline mode still works**

Run with default args (server not running). Expected: `Player.tscn` spawns with name "Local_Offline" and the game is fully playable solo.

- [ ] **Step 5: Commit**

```bash
git add net/client.gd main.tscn
git commit -m "Client swaps own RemotePlayer for local Player.tscn"
```

---

### Task 8: Local player broadcasts position to server

**Files:**
- Modify: `res://scenes/Player.tscn` (add MultiplayerSynchronizer)
- Modify: `res://scenes/Player.gd` (expose head_pitch, player_name; guard input on authority)

This task makes other peers actually see you moving. The `MultiplayerSynchronizer` on the local Player sends position/rotation to the server at 20 Hz; the server's MultiplayerSpawner-managed RemotePlayer mirrors it out to others.

- [ ] **Step 1: Add `head_pitch` and `player_name` exports to Player.gd**

Modify `res://scenes/Player.gd`. Near the top of the script, add:

```gdscript
# Networked state. The local-player MultiplayerSynchronizer pushes these
# to the server, which mirrors them to other peers. `head_pitch` is sampled
# from $Head.rotation.x in _physics_process.
@export var head_pitch: float = 0.0
@export var player_name: String = ""
```

In the existing `_handle_camera_rotation()` function, after the existing `head.rotation.x = clamp(...)` line, append:

```gdscript
	head_pitch = head.rotation.x
```

So whenever the local player looks up/down, the network-visible `head_pitch` follows.

- [ ] **Step 2: Add multiplayer authority guard for input**

Still in `Player.gd`, modify `_ready()`:

```gdscript
func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Only process input + camera for the local player. Authority is set
	# by Client.gd when this Player.tscn is instanced in response to our
	# own RemotePlayer being spawned.
	if not Net.is_offline:
		set_multiplayer_authority(multiplayer.get_unique_id())
	# Disable our own camera if we're somehow NOT the authority (shouldn't
	# happen, but guards against accidental double-spawn).
	if not is_multiplayer_authority() and not Net.is_offline:
		$Head/Camera3D.current = false
		set_process(false)
		set_physics_process(false)
		set_process_input(false)
```

- [ ] **Step 3: Add MultiplayerSynchronizer to Player.tscn**

Open `scenes/Player.tscn` in Godot. Add a child node of type `MultiplayerSynchronizer` to the root Player node. In the Inspector:
- Set `replication_interval` to `0.05` (20 Hz).
- Set `delta_interval` to `0.05`.

In the bottom **Replication** panel, add these synced properties:

| Property | Sync setting |
|---|---|
| `Player:position` | Always |
| `Player:rotation:y` | Always |
| `Player:head_pitch` | Always |
| `Player:player_name` | On Change |

Save the scene.

- [ ] **Step 4: Make RemotePlayer apply head_pitch to a Head node**

Currently `RemotePlayer.tscn` has no Head node — the head_pitch property exists but doesn't drive anything visible. For v1 a head bobble isn't critical, but we should at least update the script to apply head_pitch to the mesh's pitch so it's not wasted bandwidth.

Modify `scenes/RemotePlayer.gd`'s `_process()`:

```gdscript
func _process(_delta: float) -> void:
	if name_label.text != player_name:
		name_label.text = player_name
	# Rotate the visual mesh by head_pitch so others can see where we're looking.
	# Quake players don't have a real head bone; we tilt the whole capsule slightly
	# as a placeholder.
	$Mesh.rotation.x = head_pitch * 0.3
```

The `* 0.3` damps it so the capsule doesn't go fully horizontal.

- [ ] **Step 5: Manually verify two clients see each other moving**

Run three instances: A (server), B and C (both clients on `127.0.0.1`). Expected:
- In B: you see a red capsule labelled "player" (representing C). When C moves, the capsule moves smoothly (interpolated at 20 Hz).
- In C: same, but seeing B.
- The server stdout shows continued connections; no errors.

Use mouse-look in B: the capsule in C should tilt slightly (head_pitch syncing). The name still reads "player" since we haven't wired name handling yet — that's Task 9.

- [ ] **Step 6: Commit**

```bash
git add scenes/Player.gd scenes/Player.tscn scenes/RemotePlayer.gd
git commit -m "Sync local player position/rotation/pitch at 20 Hz"
```

---

### Task 9: Name handling — prompt, persist, propagate

**Files:**
- Modify: `res://net/client.gd` (load name from settings, prompt if missing, set on Player)

This task gives each player a name. Loaded from `user://settings.cfg`; prompted once if missing; sent to the server which propagates it via the synchronizer.

- [ ] **Step 1: Add name helpers to `client.gd`**

Update `res://net/client.gd`. Add these helpers near the top of the file:

```gdscript
const SETTINGS_PATH := "user://settings.cfg"


func _load_or_prompt_name() -> String:
	# CLI override always wins.
	if Net.cli_name != "":
		return Net.cli_name
	# Try config.
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
```

- [ ] **Step 2: Apply the name to the swapped-in local Player**

In `client.gd`'s `_on_player_spawned()`, after `local.global_position = pos`:

```gdscript
	var chosen := await _load_or_prompt_name()
	local.player_name = chosen
```

Also in `_fallback_to_offline()`, after creating the offline `local`:

```gdscript
		var chosen := await _load_or_prompt_name()
		local.player_name = chosen
```

(Both call sites need the await; since `_fallback_to_offline` is currently a sync function, the easiest path is to make it async by changing its signature to `func _fallback_to_offline(reason: String) -> void:` — it already returns void, just call `await` inside.)

- [ ] **Step 3: Manually verify name flow**

Delete any existing `user://settings.cfg`:

```bash
# macOS path; adjust for other OS:
rm -f ~/Library/Application\ Support/Godot/app_userdata/quak/settings.cfg
```

Run the project (server not running, offline mode). Expected: a "Pick a name" dialog appears. Type a name, click OK. The name persists for subsequent runs.

Run with the server running. The other client should see the entered name above your capsule instead of "player".

- [ ] **Step 4: Commit**

```bash
git add net/client.gd
git commit -m "Add name prompt + persistence + propagation"
```

---

### Task 10: Protocol version handshake

**Files:**
- Modify: `res://net/client.gd` (send version after connect)
- Modify: `res://net/server.gd` (track unverified peers, kick on mismatch)

This task adds the protocol versioning safety net described in the spec.

- [ ] **Step 1: Add the RPC method on Server**

Modify `res://net/server.gd`. Track peers waiting for handshake:

```gdscript
var unverified_peers: Dictionary = {}   # id (int) -> bool


func _on_peer_connected(id: int) -> void:
	_log("peer %d connected" % id)
	unverified_peers[id] = true
	var p := REMOTE_PLAYER_SCENE.instantiate()
	p.name = str(id)
	p.set_multiplayer_authority(id)
	players.add_child(p, true)


func _on_peer_disconnected(id: int) -> void:
	_log("peer %d disconnected" % id)
	unverified_peers.erase(id)
	if players.has_node(str(id)):
		players.get_node(str(id)).queue_free()


@rpc("any_peer", "reliable")
func report_version(version: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if version != Net.PROTOCOL_VERSION:
		_log("peer %d protocol_version=%d MISMATCH (expected %d); kicking" % [sender, version, Net.PROTOCOL_VERSION])
		multiplayer.multiplayer_peer.disconnect_peer(sender)
	else:
		_log("peer %d protocol_version=%d ok" % [sender, version])
		unverified_peers.erase(sender)
```

- [ ] **Step 2: Client sends its version on connect**

Modify `res://net/client.gd`. The `_on_connected` handler runs on `multiplayer.connected_to_server`. We want to RPC the server with our protocol version. The RPC target is the Server node (`/root/Net/Server`), so the RPC must be defined there with the same path.

Update `_on_connected()`:

```gdscript
func _on_connected() -> void:
	print("[Client] connected to server")
	Toast.show_message("Connected to %s" % Net.cli_host)
	# Send our protocol version. If it doesn't match, the server kicks us.
	$"../Server".report_version.rpc_id(1, Net.PROTOCOL_VERSION)
```

Note: this works because both client and server nodes have `/root/Net/Server` as their path (client never *runs* Server's logic, but the node exists in the scene tree). The RPC routes to the server peer (ID 1).

- [ ] **Step 3: Manually verify matching version succeeds**

Run A (server) and B (client `--host 127.0.0.1`). Expected server stdout:

```
[...] peer <id> connected
[...] peer <id> protocol_version=1 ok
```

- [ ] **Step 4: Manually verify mismatch kicks**

Temporarily change `Net.PROTOCOL_VERSION` on the *client* side to `999` (edit `net.gd`, run only that one Godot instance with the change, reset after testing). Run server with `PROTOCOL_VERSION = 1` and client with `999`. Expected server stdout:

```
[...] peer <id> connected
[...] peer <id> protocol_version=999 MISMATCH (expected 1); kicking
[...] peer <id> disconnected
```

Expected client stdout:

```
[Client] server disconnected mid-game; entering offline mode
```

Revert the temporary version change. (Don't commit it.)

- [ ] **Step 5: Commit**

```bash
git add net/server.gd net/client.gd
git commit -m "Add protocol version handshake with kick on mismatch"
```

---

### Task 11: F5 to retry connection

**Files:**
- Modify: `res://net/net.gd` (capture F5 globally)
- Modify: `res://net/client.gd` (expose `retry()` method that re-attempts connection)

When you're in offline mode (e.g. server was down at boot), pressing F5 should attempt reconnection without restarting the game.

- [ ] **Step 1: Add retry input handler to net.gd**

Modify `res://net/net.gd`. Add:

```gdscript
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F5:
		if role == Role.CLIENT and is_offline:
			print("[Net] F5 pressed; retrying connection")
			Toast.show_message("Reconnecting…")
			$Client.retry()
```

- [ ] **Step 2: Implement Client.retry()**

Modify `res://net/client.gd`. Add at the bottom of the file:

```gdscript
func retry() -> void:
	# Tear down any offline-mode local player. The connection flow will
	# spawn a new one via _on_player_spawned (or another _fallback_to_offline).
	if players.has_node("Local_Offline"):
		players.get_node("Local_Offline").queue_free()
	Net.is_offline = false
	start()
```

- [ ] **Step 3: Manually verify retry**

Run client with server NOT running (default args). Expected: offline mode, "Local_Offline" Player spawns. Press F5. Expected: nothing useful happens (server still not running), eventually "Server unreachable" toast appears, and a new "Local_Offline" Player spawns.

Now start the server (`-- --dedicated-server` in another instance). In the client, press F5 again. Expected: "Connected to quak.jackharrhy.dev" toast, the offline Player despawns, and the multiplayer Player spawns.

- [ ] **Step 4: Commit**

```bash
git add net/net.gd net/client.gd
git commit -m "Add F5 hotkey to retry connection from offline mode"
```

---

### Task 12: Linux Dedicated Server export preset

**Files:**
- Modify: `res://export_presets.cfg` (create if it doesn't exist)

This task makes `godot --export-release "Linux Dedicated Server"` work from the command line, which the Dockerfile depends on. Note: `export_presets.cfg` is normally Godot-managed and shouldn't be committed if it contains secrets — but the dedicated-server preset has none, so it's safe.

- [ ] **Step 1: Create the export preset in the editor**

In Godot, go to **Project → Export…**. Click **Add… → Linux**. In the dialog:
- **Name:** `Linux Dedicated Server`
- **Binary Format / Architecture:** x86_64
- **Custom (comma-separated) features:** `dedicated_server`
- **Export Path:** `dist/quak-server`

Under the **Resources** tab, leave the default (Export all resources).

Click **Manage Export Templates** if you don't have the dedicated server template installed. Download it from the official source for your Godot version.

Save and close the dialog.

- [ ] **Step 2: Verify export_presets.cfg was created**

```bash
ls export_presets.cfg && head -20 export_presets.cfg
```

Expected: a file exists containing a `[preset.0]` section with `name="Linux Dedicated Server"` and `custom_features="dedicated_server"`.

- [ ] **Step 3: Add `dist/` to .gitignore**

```bash
echo "" >> .gitignore
echo "# Build outputs" >> .gitignore
echo "dist/" >> .gitignore
```

- [ ] **Step 4: Test the export from CLI**

```bash
mkdir -p dist
scripts/godot.sh --headless --export-release "Linux Dedicated Server" dist/quak-server
```

Expected: command exits 0; `ls -lh dist/quak-server` shows a binary ~50 MB. Don't commit the binary.

- [ ] **Step 5: Smoke-test the binary**

```bash
./dist/quak-server --headless &
sleep 2
lsof -nP -iUDP:27420 2>/dev/null
kill %1
```

Expected: the lsof output shows `quak-server` is listening on UDP 27420.

- [ ] **Step 6: Commit**

```bash
git add export_presets.cfg .gitignore
git commit -m "Add Linux Dedicated Server export preset"
```

---

### Task 13: Dockerfile

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`

- [ ] **Step 1: Write `Dockerfile`**

Write `Dockerfile`:

```dockerfile
# Two-stage build: produce a headless Godot server binary, then a slim
# runtime image that just contains the binary + its few runtime deps.

# ── Stage 1: build ──
FROM barichello/godot-ci:4.6 AS build
WORKDIR /app
COPY . .
RUN mkdir -p /out \
    && godot --headless --export-release "Linux Dedicated Server" /out/quak-server

# ── Stage 2: runtime ──
FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libfontconfig1 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/quak
COPY --from=build /out/quak-server /srv/quak/quak-server
RUN chmod +x /srv/quak/quak-server

EXPOSE 27420/udp
ENTRYPOINT ["/srv/quak/quak-server", "--headless"]
```

- [ ] **Step 2: Write `.dockerignore`**

Write `.dockerignore`:

```
.git/
.godot/
dist/
docs/
tmp/
maps/autosave/
*.md
.DS_Store
```

This keeps the build context small (we don't need git history, IDE state, the cloned Quake source, or autosaves in the image).

- [ ] **Step 3: Test the Docker build locally**

```bash
docker build -t quak:dev .
```

Expected: build completes successfully. May take several minutes the first time (downloading the Godot CI image). Final image size:

```bash
docker images quak:dev
```

Expected: ~80 MB.

- [ ] **Step 4: Run the container locally**

```bash
docker run --rm -d --name quak-test -p 27420:27420/udp quak:dev
sleep 2
docker logs quak-test
```

Expected logs:

```
[Net] starting in SERVER role
[2026-...Z] server listening on 27420
```

- [ ] **Step 5: Connect a client to the container**

In Godot, set Main Run Args to `-- --host 127.0.0.1` and run. Expected: client connects to the dockerized server, capsule appears, etc.

Stop the container:

```bash
docker stop quak-test
```

- [ ] **Step 6: Commit**

```bash
git add Dockerfile .dockerignore
git commit -m "Add Dockerfile for headless server image"
```

---

### Task 14: GitHub Actions CI for server image

**Files:**
- Create: `.github/workflows/server.yml`

- [ ] **Step 1: Write the workflow**

Write `.github/workflows/server.yml`:

```yaml
name: Build & publish server image

on:
  push:
    branches: [main]
    paths:
      - "**.gd"
      - "**.tscn"
      - "**.tres"
      - "project.godot"
      - "export_presets.cfg"
      - "Dockerfile"
      - ".dockerignore"
      - ".github/workflows/server.yml"
  workflow_dispatch:

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ghcr.io/${{ github.repository_owner }}/quak:latest
            ghcr.io/${{ github.repository_owner }}/quak:sha-${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 2: Verify the workflow file is valid YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/server.yml'))" && echo "OK"
```

Expected: prints `OK` and exits 0.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/server.yml
git commit -m "Add CI workflow to build and publish server image to GHCR"
```

Note: the workflow won't actually *run* until the branch is merged to main (or until you push to main). That's expected — we're not testing CI execution here, only that the file is valid and committed.

---

### Task 15: Deployment notes

**Files:**
- Create: `docs/deployment.md`

- [ ] **Step 1: Write the deployment doc**

Write `docs/deployment.md`:

```markdown
# Server deployment

This is a one-time setup for running the `quak` dedicated server on a VPS
behind `quak.jackharrhy.dev`. The server is published as a Docker image to
GHCR by CI (see `.github/workflows/server.yml`).

## Prerequisites

- A VPS / VM with a public IP. Hetzner CX11 (~$4/month) is overkill; any
  small instance works. Must have Docker installed.
- DNS control for `jackharrhy.dev`.

## Steps

### 1. DNS

Add an A record:

```
quak.jackharrhy.dev → <your VPS IP>
```

Wait for propagation (`dig +short quak.jackharrhy.dev`).

### 2. Firewall

Allow UDP 27420 inbound. On Debian/Ubuntu with ufw:

```bash
sudo ufw allow 27420/udp
```

### 3. Pull the image

```bash
docker pull ghcr.io/jackharrhy/quak:latest
```

### 4. Run

```bash
docker run -d \
  --name quak \
  --restart unless-stopped \
  -p 27420:27420/udp \
  ghcr.io/jackharrhy/quak:latest
```

Verify it's running:

```bash
docker ps
docker logs quak
```

Expected logs: `[Net] starting in SERVER role` followed by
`server listening on 27420`.

### 5. Test

From any machine running a client build:

```
./quak.exe -- --host quak.jackharrhy.dev
```

Or set Project Settings → Run → Main Run Args to
`-- --host quak.jackharrhy.dev` in the editor.

## Updating the server

CI publishes a new image on every push to `main`. To redeploy:

```bash
docker pull ghcr.io/jackharrhy/quak:latest
docker stop quak
docker rm quak
# then re-run the docker run command above
```

(Or use `docker compose` and `docker compose up -d --pull always` if you
prefer; the basic deploy doesn't need it.)

## Troubleshooting

- **Clients can't connect:** check UDP 27420 is open in the firewall *and*
  in the VPS provider's security group / cloud firewall. ENet uses UDP only.
- **Server crashes on startup:** `docker logs quak` will show why. Most
  common cause is a missing runtime library; the `bookworm-slim` base + the
  packages in the Dockerfile cover what Godot's headless binary needs.
- **Protocol mismatch errors in logs:** clients on an older/newer build
  than the server. Either redeploy the server or update clients.
```

- [ ] **Step 2: Commit**

```bash
git add docs/deployment.md
git commit -m "Add deployment doc for VPS + Docker"
```

---

### Task 16: End-to-end smoke test

This task isn't code; it's a final manual verification that everything works together. No commit unless something needs fixing.

- [ ] **Step 1: Stop any running instances**

Kill any lingering Godot processes / docker containers from previous tasks.

- [ ] **Step 2: Build and run the container**

```bash
docker build -t quak:smoke .
docker run --rm -d --name quak-smoke -p 27420:27420/udp quak:smoke
docker logs quak-smoke
```

Expected: server listening on 27420.

- [ ] **Step 3: Run two client instances from the editor**

Each with `-- --host 127.0.0.1` in Main Run Args. (Use two separate editor windows; Godot allows multiple instances.)

Verify:
- Both clients show the "Pick a name" dialog on first run (delete `~/Library/Application Support/Godot/app_userdata/quak/settings.cfg` if needed to test fresh).
- After entering names, each client sees the *other* client's capsule labelled with their name.
- Moving in one client smoothly moves the capsule in the other client.
- Looking up/down tilts the capsule slightly.
- Closing one client makes its capsule disappear in the other.

- [ ] **Step 4: Verify offline fallback end-to-end**

Stop the docker container. Run a client. Expected: "Server unreachable — playing offline" toast, then a fully playable single-player game.

Start the docker container again. Press F5 in the client. Expected: reconnect toast, multiplayer Player swaps in.

- [ ] **Step 5: Tear down**

```bash
docker stop quak-smoke
docker rmi quak:smoke
```

If everything above worked, the implementation is complete. Open a PR.

---

## Self-Review Summary

**Spec coverage:**
- ✅ Boot flow / role decision (Task 1)
- ✅ Server opens listening port (Task 2)
- ✅ Client connects + offline fallback (Task 3)
- ✅ Toast UI (Task 4)
- ✅ RemotePlayer scene (Task 5)
- ✅ Server spawns RemotePlayer (Task 6)
- ✅ Local-player swap (Task 7)
- ✅ Position/rotation/pitch sync at 20 Hz (Task 8)
- ✅ Name handling (Task 9)
- ✅ Protocol version handshake (Task 10)
- ✅ F5 retry (Task 11)
- ✅ Export preset (Task 12)
- ✅ Dockerfile (Task 13)
- ✅ CI workflow (Task 14)
- ✅ Deployment docs (Task 15)
- ✅ End-to-end smoke test (Task 16)

**Out of scope (per spec):** voice chat, server-authoritative physics, prediction/reconciliation, text chat, kick/ban, lobby UI, persistence, automated multi-client integration tests.

**Open items the spec acknowledged and the plan inherits:**
- No TLS (cleartext UDP)
- No anti-DDoS
- No state persistence across server restarts
- Client-authoritative position (acceptable because no PvP)

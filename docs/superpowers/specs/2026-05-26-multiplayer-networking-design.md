# Multiplayer Networking — Design

**Status:** approved
**Date:** 2026-05-26
**Scope:** Networking, player replication, and dedicated server deployment for `quak`. Voice chat is explicitly out of scope and will get its own spec.

## Goals

- Single dedicated server at `quak.jackharrhy.dev` that all clients connect to on launch.
- Players see each other moving in real time but cannot affect each other (no shooting, no PvP, no shared items in v1).
- Local player movement feels identical to the existing single-player Quake controller — no input lag.
- If the server is unreachable, the game falls back to offline single-player mode.
- One Godot project, two roles (client and dedicated server) decided at runtime via the `dedicated_server` feature flag.

## Non-goals

- Voice chat (separate spec).
- Server-authoritative physics, prediction, reconciliation, or rollback. We accept the "trust the client" trade-off because players don't interact.
- Lag compensation, hit registration, weapons, combat.
- Server browser, multiple servers, lobby UI.
- Persistent state across server restarts.
- Text chat, kick/ban admin commands, spectator mode.
- Reconnect-with-same-identity (a reconnect creates a new peer).

## Architecture

### Boot flow

A new autoload `Net` runs before any scene loads. It checks `OS.has_feature("dedicated_server")` (set automatically on builds made with the Linux Dedicated Server export template) and branches into one of two roles.

```
Boot
 │
 ▼
Net._ready()
 │
 ├── OS.has_feature("dedicated_server") ──► start_server()
 │
 └── else                                ──► start_client()
```

**Server role:**
- `ENetMultiplayerPeer.create_server(PORT, MAX_CLIENTS)`
- Loads `main.tscn` headlessly (no camera, no audio rendering).
- Listens for `peer_connected` / `peer_disconnected`; spawns/despawns `RemotePlayer` nodes.
- Idle when no clients connected.

**Client role:**
- `ENetMultiplayerPeer.create_client(SERVER_HOST, PORT)`
- Brief "Connecting…" overlay (a Label fading out on success).
- On `connected_to_server` → load `main.tscn`, wait for server-spawned player.
- On any connection failure → fall back to offline mode (load `main.tscn` solo).

### File layout

```
res://
├── net/
│   ├── net.gd               # autoload; manages role + peer lifecycle
│   ├── net.tscn             # autoload scene (hosts the Players MultiplayerSpawner)
│   ├── server.gd            # server-only helpers (spawn/despawn, logging)
│   ├── client.gd            # client-only helpers (connect, fallback, name prompt)
│   └── toast.gd             # connection-status toast singleton
├── scenes/
│   ├── Player.tscn          # LOCAL player — full Quake movement, input, camera (existing)
│   ├── Player.gd            # (existing)
│   ├── RemotePlayer.tscn    # NEW: visual presence only, interpolated transform
│   └── RemotePlayer.gd      # NEW: receives state, no input, no camera
├── main.tscn                # unchanged at scene level
└── project.godot            # add Net autoload, add dedicated_server feature
```

### Configuration constants (in `net/net.gd`)

```
SERVER_HOST     = "quak.jackharrhy.dev"   # overridable via --host <host>
PORT            = 27420                   # IANA-unassigned; Quake's 27000 range
MAX_CLIENTS     = 32
SEND_RATE       = 20                      # Hz; how often clients push state to server
PROTOCOL_VERSION = 1                      # bump on protocol-breaking changes
```

## Player replication

Two scenes — `Player.tscn` (local) and `RemotePlayer.tscn` (remote presence).

### RemotePlayer scene tree

```
RemotePlayer (CharacterBody3D)
├── CollisionShape3D            # same BoxShape3D as local
├── MeshInstance3D              # placeholder capsule mesh
├── NameLabel (Label3D)         # billboard, shows player name
└── MultiplayerSynchronizer     # syncs position, rotation.y, head_pitch, player_name
```

Synced properties: `position` (Vector3), `rotation.y` (float), `head_pitch` (float, head's local X rotation), `player_name` (String).

`MultiplayerSynchronizer` is configured with `replication_interval = 0.05` (20 Hz) and `interpolation_enabled = true`. Godot will tween between received snapshots automatically.

### Replication flow

```
Client A                  Server                  Client B
   │                         │                         │
   │── input + position ────►│                         │
   │   (20 Hz)               │                         │
   │                         │── position to others ──►│
   │                         │   (20 Hz)               │
   │                         │                         │
   │◄──── position of B ─────│◄──── input + pos of B ──│
```

Each client is the multiplayer authority for its own player. The server (peer ID 1) is never the authority for any player. The server just relays.

### Spawning

A `MultiplayerSpawner` lives under `Players` (a child of the `Net` autoload's scene). Its spawnable list contains `RemotePlayer.tscn`.

**Server logic:**

```
on peer_connected(id):
    var p = preload("res://scenes/RemotePlayer.tscn").instantiate()
    p.name = str(id)
    p.set_multiplayer_authority(id)
    Players.add_child(p, true)   # MultiplayerSpawner replicates to all peers

on peer_disconnected(id):
    if Players.has_node(str(id)):
        Players.get_node(str(id)).queue_free()
```

### Local player swap

When the server spawns `RemotePlayer/<my_peer_id>`, the local client detects it (via `MultiplayerSpawner.spawned` signal) and swaps it in-place for a `Player.tscn` instance at the same position. Other peers see you as a `RemotePlayer`; you see yourself as a `Player`. The server never spawns `Player.tscn` — only `RemotePlayer.tscn`.

### Name handling

- Client checks `user://settings.cfg` for a stored name.
- If absent, shows a one-shot Godot dialog ("Pick a name").
- Name is saved locally and sent to the server as the first RPC after connection.
- Server stores it on the `RemotePlayer` node; it propagates to other clients via the synchronizer's `player_name` field.

### Spawn point

All players spawn at the existing `func_godot` player entity location in `main.tscn`. If two players overlap, normal physics push them apart. Acceptable for v1.

## Server deployment

### Export preset

A new entry in `export_presets.cfg`:

```
[preset.0]
name="Linux Dedicated Server"
platform="Linux/X11"
binary_format/architecture="x86_64"
custom_features="dedicated_server"
export_path="dist/quak-server"
```

Build command:

```bash
godot --headless --export-release "Linux Dedicated Server" dist/quak-server
```

Output: one ~50 MB statically-linked binary.

### Dockerfile

Two-stage build:

```dockerfile
# ── Stage 1: build ──
FROM barichello/godot-ci:4.6 AS build
WORKDIR /app
COPY . .
RUN godot --headless --export-release "Linux Dedicated Server" /out/quak-server

# ── Stage 2: runtime ──
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        libfontconfig1 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /srv/quak
COPY --from=build /out/quak-server /srv/quak/quak-server
RUN chmod +x /srv/quak/quak-server

EXPOSE 27420/udp
ENTRYPOINT ["/srv/quak/quak-server", "--headless"]
```

Final image size: ~80 MB.

### Run command

```bash
docker run -d --name quak \
  --restart unless-stopped \
  -p 27420:27420/udp \
  ghcr.io/jackharrhy/quak:latest
```

### CI

A GitHub Actions workflow `.github/workflows/server.yml` triggered on push to `main`:

1. Build the Docker image.
2. Push to GHCR as `ghcr.io/jackharrhy/quak:latest` and `:sha-<commit>`.

Deploys are `docker pull && docker restart quak` on the VPS.

### DNS / network setup (one-time, manual)

1. VPS with Docker installed (Hetzner CX11 or equivalent).
2. Open UDP 27420 in the firewall.
3. A record: `quak.jackharrhy.dev` → VPS IP.
4. Run the container.

Documented in `docs/deployment.md` alongside this spec.

### Protocol versioning

`Net.PROTOCOL_VERSION = 1` constant. On client connect, the client sends `PROTOCOL_VERSION` as the first RPC. If the server's version differs, the server disconnects with reason "client too old / too new". Bumped manually whenever the network protocol changes.

## Error handling and offline fallback

| Trigger | Detected via | UX |
|---|---|---|
| Server unreachable | `connection_failed` signal | Toast: "Server unreachable — playing offline" → offline mode |
| Server crashes mid-game | `server_disconnected` signal | Toast: "Disconnected from server" → offline mode |
| Protocol version mismatch | Server kicks after first RPC | Toast: "Client out of date — please update" → offline mode |
| Server full (`MAX_CLIENTS`) | `connection_failed` after clean ENet refuse | Toast: "Server is full" → offline mode |

**Offline mode:** `Net.is_offline = true` skips `MultiplayerSpawner` and synchronizer logic. The local `Player` works identically. Map loads identically. `F5` retries connection at any time.

**Toast UI:** one `CanvasLayer` autoload (`Toast`) with a `Label` + Tween. No dependency on a real UI system.

## Logging

Server-side, stdout, captured by Docker:

```
[2026-05-26T14:23:01Z] server listening on 27420
[2026-05-26T14:23:15Z] peer 1234567890 connected (name="jack")
[2026-05-26T14:23:15Z] peer 1234567890 protocol_version=1 ok
[2026-05-26T14:25:02Z] peer 1234567890 disconnected
```

Plain `print()` with timestamp prefix. `docker logs quak` works out of the box. Structured logging is a future addition if needed.

## CLI flags

Recognised by both builds (server build ignores ones that don't apply):

```
--host <host>       # client: override Net.SERVER_HOST
--port <n>          # both: override Net.PORT
--name <name>       # client: skip name prompt, use this name
--offline           # client: skip connection, go straight to offline mode
--dedicated-server  # debug: force server mode in a non-dedicated build
                    #        (equivalent to OS.has_feature("dedicated_server"))
```

`--dedicated-server` is the trick that lets us run a server instance from the editor (or any client build) for local testing without having to produce a dedicated-server export. `Net._ready()` checks both `OS.has_feature("dedicated_server")` and the CLI flag.

## Testing strategy

1. **Editor smoke test** — open project twice. One instance starts as server (launched with `--dedicated-server` in the project run args). The other connects to `127.0.0.1:27420`. Walk around, confirm both see each other.
2. **Dockerized smoke test** — `docker compose up` brings the server container up locally; two client builds connect to `localhost:27420`. Catches "works in editor, breaks in headless" issues.
3. **CI smoke test** — before publishing the Docker image, run a one-off `--headless` GDScript test that boots the project for 5 seconds and confirms `ENetMultiplayerPeer.create_server()` returned OK.

Automated multi-client integration tests are explicitly out of scope for v1.

## Open trade-offs (acknowledged, not problems)

- **No TLS / encryption.** ENet is plain UDP; player names and positions are visible to anyone sniffing the network. Acceptable for a public movement playground.
- **No anti-DDoS.** ENet has minimal built-in protection. If it becomes a problem, add `iptables` rate limits at the host level.
- **No state persistence.** Server restarts wipe all player state. Names are re-prompted client-side (cached locally), so the UX impact is minimal.
- **Client-authoritative position.** A malicious client could teleport or fly. Since there's no PvP, the worst that happens is someone looks weird to others.

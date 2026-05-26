# Server deployment

One-time setup for running the `quak` dedicated server on a VPS behind
`quak.jackharrhy.dev`. The server is published as a Docker image to GHCR by
CI (see `.github/workflows/server.yml`).

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

Wait for propagation:

```bash
dig +short quak.jackharrhy.dev
```

### 2. Firewall

Allow UDP 27420 inbound. On Debian/Ubuntu with ufw:

```bash
sudo ufw allow 27420/udp
```

If your VPS provider has a cloud firewall (Hetzner, DigitalOcean, etc.),
open UDP 27420 there too.

### 3. Pull the image

The CI pipeline publishes to GHCR on every push to `main`:

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

Verify:

```bash
docker ps
docker logs quak
```

Expected logs:

```
[Net] starting in SERVER role
[2026-...Z] server listening on 27420
```

### 5. Test

From a machine running a client build (or the Godot editor with this project
open), set the host to your domain:

```bash
./quak --host quak.jackharrhy.dev
```

In the Godot editor: Project Settings → Run → Main Run Args:
`-- --host quak.jackharrhy.dev`.

## Updating the server

CI publishes a new image on every push to `main`. To redeploy:

```bash
docker pull ghcr.io/jackharrhy/quak:latest
docker stop quak
docker rm quak
# then re-run the docker run command above
```

Or use Watchtower / `docker compose pull && docker compose up -d` if you
prefer; the basic deploy doesn't need it.

## Architecture / behaviour

- **Protocol:** ENet over UDP (port 27420 by default). No TLS — player names
  and positions are sent in cleartext.
- **Authority:** client-authoritative position (each peer broadcasts its own
  state). No PvP, so cheating is mostly inconsequential.
- **Capacity:** `MAX_CLIENTS = 32` (set in `net/net.gd`). Bumping this
  requires a rebuild & redeploy.
- **State:** server is stateless across restarts. Player names are stored
  client-side in `user://settings.cfg`.

## Troubleshooting

### Clients can't connect

- Check UDP 27420 is open in **both** the OS firewall **and** the VPS
  provider's security group / cloud firewall. ENet is UDP-only — TCP
  forwarding does nothing.
- Confirm DNS resolves: `dig +short quak.jackharrhy.dev` should show your
  VPS IP.
- Confirm the container is up: `docker ps`.
- Tail logs while a client tries to connect: `docker logs -f quak`. You
  should see `peer <id> connected`.

### Server crashes on startup

`docker logs quak` will show why. Most common cause is a missing runtime
library — the `bookworm-slim` base + the packages in the Dockerfile cover
what Godot's headless binary needs, but if you've modified the Dockerfile,
check for missing `libfontconfig1` or `ca-certificates`.

### Protocol mismatch errors

```
[...Z] peer <id> protocol_version=N MISMATCH (expected M); kicking
```

Clients on an older/newer build than the server. Either redeploy the
server (`docker pull && docker restart`) or update the client.
`Net.PROTOCOL_VERSION` in `net/net.gd` is bumped manually whenever the
network protocol changes (new RPCs, new sync fields, etc.).

### Server logs are silent in `docker logs`

The Godot project setting `application/run/flush_stdout_on_print=true` (in
`project.godot`) is required for stdout to flush line-by-line. If you fork
this project and remove that setting, you'll see this symptom. Reference:
[Godot docs — Exporting for dedicated servers](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html).

## Local patches in the codebase

A heads-up for future maintainers who re-vendor third-party addons:

### `addons/func_godot/src/map/func_godot_map.gd`

The upstream `func_godot` addon calls `EditorInterface.mark_scene_as_unsaved()`
in `clear_children()`. `EditorInterface` is stripped from dedicated server
export builds, which causes a parse error and prevents the server from
starting.

The local patch (line 64) guards the call with `Engine.is_editor_hint()`
and accesses the singleton indirectly:

```gdscript
if Engine.is_editor_hint():
    Engine.get_singleton("EditorInterface").mark_scene_as_unsaved()
```

If you re-vendor `addons/func_godot/`, re-apply this patch. (Upstream PR
welcome — this is a clear bug in func_godot for headless builds.)

## What's deliberately NOT here yet

These belong to future specs:

- Voice chat (separate brainstorming session pending).
- TLS / encryption.
- Anti-DDoS / rate limiting (use `iptables` rate limits at the host level if
  it becomes a problem).
- Server-side state persistence across restarts.
- Multiple regions / multiple servers.

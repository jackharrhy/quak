# Multiplayer networking — follow-up backlog

Issues identified during the final code review of `feat/multiplayer-networking`
that weren't blocking enough to delay merge but should be cleaned up later.

## Important (do these before the next public deploy)

### I1. Name dialog can outlive its target node

`net/client.gd:130-135` — if the server kicks/disconnects the client while
the "Pick a name" dialog is open, two flows run in parallel: the original
`_on_player_spawned` (still awaiting the dialog) and a freshly-triggered
`_spawn_local_offline_player` (which opens a *second* dialog). When the
first dialog resolves it writes `player_name` to a Player node that may be
stale.

Fix sketch: load/prompt the name once at boot (cache on `Client`),
not inside each spawn path. Or capture a weak reference and check liveness
after the `await`.

### I2. `report_version` has no server-side timeout

`net/server.gd:39-46` — a peer that connects but never RPCs
`report_version` stays connected indefinitely. Low impact (we have a 32-peer
cap, no auth) but it's a slow-leak DoS vector.

Fix sketch: in `_on_peer_connected`, start a `get_tree().create_timer(5.0)`
that kicks the peer if they haven't reported by then.

### I3. Docker container runs as root

`Dockerfile:33-57` — no `USER` directive. For a friend-server it's
defensible, but should be either fixed or explicitly documented.

Fix sketch: add a `RUN useradd -r -u 1000 quak && chown -R quak:quak /srv/quak`
step plus `USER quak`. Or update `docs/deployment.md`'s "What's deliberately
NOT here" section to acknowledge the choice and recommend `--cap-drop=ALL`.

### I4. No healthcheck, no graceful shutdown

The Dockerfile has no `HEALTHCHECK` and no signal handler in
`net/server.gd` to call `peer.close()` on `NOTIFICATION_WM_CLOSE_REQUEST`.
A hung Godot process won't be detected by `docker --restart unless-stopped`.

Fix sketch: add
`HEALTHCHECK --interval=30s CMD nc -uz localhost 27420 || exit 1`
and a `_notification` handler on the Server node.

## Minor (group as one "post-merge polish" PR)

1. `int(node.name)` in `client.gd:114` silently returns 0 on non-numeric
   names. Guard with `if not node.name.is_valid_int(): return`.
2. `Server.start()` signal connections aren't `is_connected()`-guarded
   (server.gd:20-21). Inconsistent with `client.gd`'s defensive pattern.
3. `get_tree().quit(1)` on bind failure (server.gd:17) deserves a one-line
   comment explaining why a child node hard-exits the whole process.
4. `Toast` autoload runs on the headless server (does nothing visible).
   Gate the autoload, or add an early-return in `Toast._ready` when
   `OS.has_feature("dedicated_server")`.
5. `AcceptDialog` has no `close_requested` handler. If a player closes the
   window via X, `await dlg.confirmed` never resolves and `player_name`
   stays empty forever.
6. `cfg.save()` return code unchecked (`client.gd:167`). Quietly fails on
   read-only filesystems.
7. `peer.create_client()` is synchronous and includes DNS resolution; can
   block the main thread for several seconds on slow DNS. Consider
   `IP.resolve_hostname_async`.
8. `docs/deployment.md` says "Hetzner CX11" — that SKU has been renamed
   to CX22.
9. `.dockerignore` line 27 (`*.md`) is shadowed by line 17 (`docs/`). Drop
   the redundancy.
10. `Net.gd:80` uses the Unicode ellipsis `…`; rest of the code uses ASCII
    `...`. Normalize.
11. `_spawnable_scenes` only lists `RemotePlayer.tscn`. A code comment near
    the swap site in `client.gd` reminding future readers of this would
    help.

## Operational concerns under load (for when we actually have load)

- 32 simultaneous connects = O(N²) spawn messages = ~1024 for full lobby.
  Brief stutter on first tick is expected. Load-test before bumping
  `MAX_CLIENTS`.
- F5 retry has no rate limit; a player holding F5 spams connect attempts.
  Add 1s backoff if observed in practice.

## Notes for the voice chat spec (next planned work)

The architecture cleanly accommodates a `Voice` sibling under `Net` next to
`Server`/`Client`:

- Same ENet peer can carry voice on a separate channel
  (`MultiplayerPeer.transfer_channel`)
- Voice spec should add `--mute-voice` to the CLI flags handled by `net.gd`
- Consider whether voice presence visibility (talk indicator above
  RemotePlayer's NameLabel) belongs in `RemotePlayer.tscn` or as a
  separate child node managed by the Voice singleton

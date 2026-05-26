# Two-stage build: produce a headless Godot server binary, then a slim
# runtime image that just contains the binary + its few runtime deps.
#
# Stage 1 uses barichello/godot-ci:4.6 (community-standard Godot CI image
# with editor and export templates pre-installed) to perform the export.
# Stage 2 is a thin Debian runtime that just hosts the resulting binary
# and the few shared libraries Godot's headless build needs at runtime.

# ── Stage 1: build ──
# Pin linux/amd64: the barichello/godot-ci image is only published for
# amd64, and we also want a deterministic target binary regardless of
# the host (Apple Silicon devs vs. Linux CI).
FROM --platform=linux/amd64 barichello/godot-ci:4.6 AS build
WORKDIR /app

# Pre-create the editor data path so `godot --headless --export-release`
# doesn't fail trying to mkdir under a missing $HOME. The barichello image
# usually handles this but we make it explicit for reproducibility.
RUN mkdir -p /root/.config/godot /root/.local/share/godot

# Copy the project sources. .dockerignore filters out build artifacts,
# autosaves, the cloned Quake reference repo, etc.
COPY . .

# Run the export. Output goes to /out/quak-server. The preset name must
# match export_presets.cfg::preset.0.name exactly ("Linux Dedicated Server").
RUN mkdir -p /out \
    && godot --headless --import 2>&1 \
    && godot --headless --export-release "Linux Dedicated Server" /out/quak-server

# ── Stage 2: runtime ──
# Same platform as stage 1 — the exported binary is amd64.
FROM --platform=linux/amd64 debian:bookworm-slim

# Godot headless on Linux needs libfontconfig (for text rendering paths
# even when no font is actually drawn) and ca-certificates for any HTTPS
# we may add later.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libfontconfig1 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/quak

# Copy the exported binary AND its companion .pck (export_presets.cfg has
# embed_pck=false, so Godot writes quak-server + quak-server.pck side by
# side and the binary refuses to start without the .pck next to it).
COPY --from=build /out/ /srv/quak/
RUN chmod +x /srv/quak/quak-server

# Default UDP port matches Net.PORT in net/net.gd.
EXPOSE 27420/udp

# --headless + the dedicated_server feature flag (set automatically because
# export_presets.cfg has dedicated_server=true) put Net into SERVER role.
ENTRYPOINT ["/srv/quak/quak-server", "--headless"]

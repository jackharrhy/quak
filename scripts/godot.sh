#!/usr/bin/env bash
# Wrapper that invokes the locally-installed Godot 4.6 binary.
#
# Use this in CI-style smoke tests and from subagents. Honors $GODOT
# if you want to override (e.g. CI installing a different version), and
# falls back to the macOS app-bundle location used on the maintainer's
# machine.
#
# Usage:
#   scripts/godot.sh --headless --quit --path .
#   scripts/godot.sh --headless --quit-after 5 --path .

set -euo pipefail

if [[ -n "${GODOT:-}" ]] && [[ -x "$GODOT" ]]; then
    exec "$GODOT" "$@"
fi

# macOS app bundle (maintainer default).
APP_BUNDLE="$HOME/Applications/Godot4.6.3/Contents/MacOS/Godot"
if [[ -x "$APP_BUNDLE" ]]; then
    exec "$APP_BUNDLE" "$@"
fi

# Fallback to PATH.
if command -v godot >/dev/null 2>&1; then
    exec godot "$@"
fi

echo "scripts/godot.sh: could not find a Godot binary. Set \$GODOT or install Godot." >&2
exit 1

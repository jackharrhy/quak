#!/usr/bin/env bash
# release.sh — tag a new vX.Y.Z release and push it to origin.
#
# Finds the most recent `v*` tag (semver-sorted), shows the three possible
# next versions (major / minor / patch), lets you pick exactly one, then
# creates and pushes the tag. CI handles the rest (see
# .github/workflows/client.yml — the `release` job runs on `v*` tag push).

set -euo pipefail

cd "$(dirname "$0")"

# ── Colours ──────────────────────────────────────────────────────────────
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    BOLD=$(tput bold)
    DIM=$(tput dim)
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    RESET=$(tput sgr0)
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

# ── Sanity checks ────────────────────────────────────────────────────────
if [[ ! -d .git ]]; then
    echo "${RED}error: not in a git repo${RESET}" >&2
    exit 1
fi

# Refuse to release from anything but main (catch accidents).
branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$branch" != "main" ]]; then
    echo "${RED}error: must be on main to release (you're on '$branch')${RESET}" >&2
    exit 1
fi

# Refuse if the working tree is dirty.
if ! git diff-index --quiet HEAD --; then
    echo "${RED}error: working tree has uncommitted changes${RESET}" >&2
    git status --short >&2
    exit 1
fi

# Make sure we have all tags from origin (someone else might have released).
git fetch --tags --quiet origin

# ── Compute next versions ────────────────────────────────────────────────
last_tag=$(git tag --list 'v*' --sort=-v:refname | head -n 1 || true)

if [[ -z "$last_tag" ]]; then
    # No tags yet — start at v0.1.0. Show that as the only option.
    echo "${DIM}No prior release tags found.${RESET}"
    current_display="${DIM}(none)${RESET}"
    next_major="v1.0.0"
    next_minor="v0.1.0"
    next_patch="v0.0.1"
else
    # Parse vX.Y.Z (anything beyond Z, like -rc1, is intentionally rejected).
    if [[ ! "$last_tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        echo "${RED}error: latest tag '$last_tag' isn't a clean vX.Y.Z — refusing to guess${RESET}" >&2
        exit 1
    fi
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    current_display="${BOLD}$last_tag${RESET}"
    next_major="v$((major + 1)).0.0"
    next_minor="v${major}.$((minor + 1)).0"
    next_patch="v${major}.${minor}.$((patch + 1))"
fi

# ── Present the menu ─────────────────────────────────────────────────────
HEAD_sha=$(git rev-parse --short HEAD)
HEAD_msg=$(git log -1 --pretty=%s)

printf '\n'
printf '  %sCurrent:%s %s\n' "$BOLD" "$RESET" "$current_display"
printf '  %sHEAD:%s    %s %s%s%s\n' "$BOLD" "$RESET" "$HEAD_sha" "$DIM" "$HEAD_msg" "$RESET"
printf '\n'
printf '  %sChoose next version:%s\n' "$BOLD" "$RESET"
printf '    %s1)%s %smajor%s  → %s%s%s\n' "$YELLOW" "$RESET" "$RED"   "$RESET" "$BOLD" "$next_major" "$RESET"
printf '    %s2)%s %sminor%s  → %s%s%s\n' "$YELLOW" "$RESET" "$GREEN" "$RESET" "$BOLD" "$next_minor" "$RESET"
printf '    %s3)%s %spatch%s  → %s%s%s\n' "$YELLOW" "$RESET" "$BLUE"  "$RESET" "$BOLD" "$next_patch" "$RESET"
printf '    %s4)%s cancel\n' "$YELLOW" "$RESET"
printf '\n'

while true; do
    read -r -p "  ${BOLD}> ${RESET}" choice
    case "$choice" in
        1) next="$next_major"; bump="major"; break ;;
        2) next="$next_minor"; bump="minor"; break ;;
        3) next="$next_patch"; bump="patch"; break ;;
        4|q|quit|cancel) echo "${DIM}cancelled${RESET}"; exit 0 ;;
        *) echo "  ${RED}pick 1, 2, 3, or 4${RESET}" ;;
    esac
done

# ── Confirm ──────────────────────────────────────────────────────────────
printf '\n'
printf '  %sAbout to:%s\n' "$BOLD" "$RESET"
printf '    git tag %s%s%s   %s(%s bump)%s\n' "$BOLD" "$next" "$RESET" "$DIM" "$bump" "$RESET"
printf '    git push origin %s%s%s\n' "$BOLD" "$next" "$RESET"
printf '\n'

read -r -p "  ${BOLD}proceed? [y/N] ${RESET}" confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "${DIM}cancelled${RESET}"
    exit 0
fi

# ── Tag & push ───────────────────────────────────────────────────────────
git tag "$next"
git push origin "$next"

printf '\n%s✓%s tagged and pushed %s%s%s\n' "$GREEN" "$RESET" "$BOLD" "$next" "$RESET"
printf '  watch CI: %shttps://github.com/jackharrhy/quak/actions%s\n' "$BLUE" "$RESET"
printf '  release will appear at: %shttps://github.com/jackharrhy/quak/releases/tag/%s%s\n\n' "$BLUE" "$next" "$RESET"

#!/usr/bin/env bash
# Usage: ./convert.sh <input-image>
# Resizes the input image to 512x512 and saves as PNG alongside the original.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <input-image>" >&2
  exit 1
fi

input="$1"

if [ ! -f "$input" ]; then
  echo "Error: file not found: $input" >&2
  exit 1
fi

output="${input%.*}.png"

magick "$input" -resize 512x512! "$output"

echo "Wrote $output (512x512)"

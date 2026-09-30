#!/usr/bin/env bash
# ──────────────────────────────────────────────
#   Random Wallpaper Switcher (Fedora sway port)
#   Picks from ~/.local/share/wallpapers (canonical) and
#   ~/Pictures/Wallpapers (legacy); either directory may be empty.
# ──────────────────────────────────────────────
set -euo pipefail
WALL_DIRS=()
for _d in "$HOME/.local/share/wallpapers" "$HOME/Pictures/Wallpapers"; do
    [ -d "$_d" ] && WALL_DIRS+=("$_d")
done
SCRIPT="$HOME/.config/sway/scripts/sway-wall.sh"
SELECTED_WALL=""
if ((${#WALL_DIRS[@]})); then
    SELECTED_WALL=$(find "${WALL_DIRS[@]}" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.png" -o -iname "*.jpeg" -o -iname "*.webp" \) 2>/dev/null | shuf -n 1 || true)
fi
if [ -n "${SELECTED_WALL:-}" ]; then
    exec "$SCRIPT" "$SELECTED_WALL"
else
    notify-send "Wallpaper Error" "No images found in ${WALL_DIRS[*]:-~/.local/share/wallpapers}" -u critical
fi

#!/usr/bin/env bash
# ──────────────────────────────────────────────
#   Dynamic Theme Switcher (awww + matugen) — Fedora sway port of swww-all.sh
#   Usage: sway-wall.sh /path/to/wallpaper.jpg
# ──────────────────────────────────────────────
set -euo pipefail

WALLPAPER="${1:-}"
[ -z "$WALLPAPER" ] && { echo "Usage: sway-wall.sh /path/to/wallpaper.jpg" >&2; exit 1; }
[ -f "$WALLPAPER" ] || { echo "Not found: $WALLPAPER" >&2; exit 1; }

# One switch at a time: rapid Super+R presses used to queue up full
# decode+transition+matugen+reload cycles, each slower than the last.
# mkdir is atomic and (unlike flock fds) can't leak into child processes.
LOCKDIR=/tmp/sway-wall.lockdir
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    # Stale lock (e.g. killed mid-run)? Reap after 2 minutes.
    if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
        rm -rf "$LOCKDIR" && mkdir "$LOCKDIR" 2>/dev/null || \
            { echo "wallpaper switch already in progress, skipping" >&2; exit 0; }
    else
        echo "wallpaper switch already in progress, skipping" >&2; exit 0
    fi
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

# 1. Set wallpaper. Prefer awww-daemon when it is up (it paints over the
#    sway background, so the swaymsg fallback MUST only run when the
#    daemon is down — otherwise the output reconfigure aborts awww's
#    grow animation mid-flight and you see "no transition".
if awww query >/dev/null 2>&1; then
    awww img "$WALLPAPER" --transition-type grow --transition-pos center --transition-duration 1.5 --transition-fps 30 || \
        { notify-send "Wallpaper Error" "awww failed to set $(basename "$WALLPAPER")" -u critical; exit 1; }
else
    setsid awww-daemon >/dev/null 2>&1 < /dev/null &
    sleep 0.5
    if awww query >/dev/null 2>&1; then
        awww img "$WALLPAPER" --transition-type grow --transition-pos center --transition-duration 1.5 --transition-fps 30 || \
            { notify-send "Wallpaper Error" "awww failed to set $(basename "$WALLPAPER")" -u critical; exit 1; }
    else
        swaymsg output "*" bg "$WALLPAPER" fill || \
            { notify-send "Wallpaper Error" "Could not set $(basename "$WALLPAPER")" -u critical; exit 1; }
    fi
fi

# 1.5 Record current wallpaper + stage lock-screen background (synchronous so
#    Super+R immediately followed by Super+Ctrl+L already shows the new image).
printf '%s' "$WALLPAPER" > "$HOME/.cache/current-wallpaper"
magick "$WALLPAPER" "$HOME/.cache/swaylock-bg.jpg" 2>/dev/null || cp -p "$WALLPAPER" "$HOME/.cache/swaylock-bg.jpg" 2>/dev/null || true

# 2. Extract colors with matugen (updates waybar, rofi, foot, sway, swaync, …)
matugen image "$WALLPAPER" --type scheme-content -c ~/.config/matugen/config.toml

# 2.1 Restart swayosd-server so it picks up the new style.css (reads CSS only at startup).
pkill -x swayosd-server >/dev/null 2>&1 || true
setsid swayosd-server >/dev/null 2>&1 < /dev/null &

# 2.5 Bump unpacked Chromium theme version so the next launch picks up colors
THEME_MANIFEST="$HOME/.config/helium-theme/manifest.json"
if [ -f "$THEME_MANIFEST" ]; then
    CUR_VER=$(grep -o '"version": "[^"]*"' "$THEME_MANIFEST" | head -1 | cut -d'"' -f4)
    CUR_MAJ=$(echo "$CUR_VER" | cut -sd. -f1); [ -z "$CUR_MAJ" ] && CUR_MAJ=1
    CUR_MIN=$(echo "$CUR_VER" | cut -sd. -f2); [ -z "$CUR_MIN" ] && CUR_MIN=0
    CUR_PAT=$(echo "$CUR_VER" | cut -sd. -f3)
    case "$CUR_PAT" in ''|*[!0-9]*) CUR_PAT=0 ;; esac
    if [ "$CUR_PAT" -ge 65535 ] 2>/dev/null; then
        CUR_MIN=$((CUR_MIN + 1)); CUR_PAT=0
        [ "$CUR_MIN" -ge 65535 ] && { CUR_MAJ=$((CUR_MAJ + 1)); CUR_MIN=0; }
    fi
    NEW_VERSION="$CUR_MAJ.$CUR_MIN.$((CUR_PAT + 1))"
    sed -i -E "s/\"version\": \"[^\"]+\"/\"version\": \"$NEW_VERSION\"/" "$THEME_MANIFEST"
    rm -f "$HOME/.config/helium-theme/Cached Theme.pak"
fi

# 3. Persist wallpaper as sway's own background (so reboots/awww hiccups
#    show the current image, not the stale fallback). Then apply the theme
#    WITHOUT swaymsg reload / output-bg commands: both reconfigure outputs
#    and flash the whole screen ~2s after the switch (the "awkward animation").
#    Instead, resolve matugen's $vars and push client.* colors live, and
#    reload waybar in place (SIGUSR2 = no bar blank).
printf 'output * bg "%s" fill\n' "$WALLPAPER" > ~/.config/sway/wallpaper
declare -A MC=()
while read -r _ name value; do
    [ -n "${name:-}" ] && [ -n "${value:-}" ] && MC["$name"]="$value"
done < <(grep '^set \$m_' ~/.config/sway/colors || true)
while read -r line; do
    if ((${#MC[@]})); then
        for k in "${!MC[@]}"; do line="${line//$k/${MC[$k]}}"; done
    fi
    case "$line" in *'$'*) continue;; esac
    swaymsg "$line" >/dev/null 2>&1 || true
done < <(grep '^client' ~/.config/sway/colors || true)
if pgrep -x waybar >/dev/null 2>&1; then
    pkill -USR2 -x waybar 2>/dev/null || true
elif pgrep -x .waybar-wrapped >/dev/null 2>&1; then
    pkill -USR2 -x .waybar-wrapped 2>/dev/null || true
else
    # Single-instance gated launch (shared with sway's autostart): waits
    # for the default sink and skips if a bar is already up, so this can
    # never stack a duplicate or a module-less bar at boot.
    ~/.config/sway/scripts/waybar-launch.sh >/dev/null 2>&1 < /dev/null &
fi

# 4. Terminals need no reload: foot has no live-reload (SIGUSR1/2 only
# switch dark/light themes loaded at startup), so existing foot windows keep
# the old colors until restarted while every NEW foot window reads the fresh
# ~/.config/foot/colors.ini automatically.

# 5. Reload swaync with new colors (matugen writes ~/.config/swaync/style.css)
swaync-client --reload-css -sw 2>/dev/null || { pkill -x swaync 2>/dev/null; setsid swaync >/dev/null 2>&1 < /dev/null & }

# 6. GTK apps read css at launch — restart nautilus only if a window is open
if swaymsg -t get_tree 2>/dev/null | grep -Fq '"app_id": "org.gnome.Nautilus"'; then
    pkill -x nautilus 2>/dev/null || true
    (nautilus --new-window >/dev/null 2>&1 &) || true
fi

# 7. Nudges for apps that need a restart
pgrep -x nvim >/dev/null 2>&1 && notify-send "Neovim Theme Updated" "Restart nvim to apply new colors" || true
pywalfox update 2>/dev/null || true
if pgrep -x chromium >/dev/null 2>&1 || pgrep -x brave >/dev/null 2>&1 || pgrep -x helium >/dev/null 2>&1; then
    notify-send "Browser Theme Updated" "Restart Chromium/Brave to apply new colors" -i "$WALLPAPER"
fi

# 8. Done (no "Theme Updated" popup: notifications stay silent on switch;
# nvim/browser restart nudges above still fire when those apps run).
true

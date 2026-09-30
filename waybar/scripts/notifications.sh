#!/usr/bin/env bash
# ──────────────────────────────────────────────
#   Notification count for Waybar (swaync)
# ──────────────────────────────────────────────
set -euo pipefail
count="$(swaync-client -c -sw 2>/dev/null || echo 0)"
count="${count//[^0-9]/}"
[ -z "$count" ] && count=0
dnd="$(swaync-client -D -sw 2>/dev/null || echo false)"
if [ "$dnd" = "true" ]; then
    jq -cn --argjson n "$count" '{text: ("󰂛 " + ($n | tostring)), tooltip: "Do Not Disturb on (middle-click to toggle)", class: "dnd"}'
elif ((count > 0)); then
    jq -cn --argjson n "$count" '{text: ("󰂚 " + ($n | tostring)), tooltip: "Notifications (click for panel, right-click clears all)", class: "has-notifications"}'
else
    jq -cn '{text: "󰂚", tooltip: "No notifications (click for panel)", class: "no-notifications"}'
fi

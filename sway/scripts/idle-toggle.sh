#!/usr/bin/env bash
# Toggle the swayidle idle-locking daemon on / off (port of idle-toggle.sh).
set -euo pipefail
if pgrep -x swayidle >/dev/null; then
    pkill -x swayidle
    notify-send "Idle" "Idle lock disabled"
else
    swayidle -w -C ~/.config/sway/swayidle.conf &
    disown
    notify-send "Idle" "Idle lock enabled"
fi

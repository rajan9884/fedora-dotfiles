#!/usr/bin/env bash
# ──────────────────────────────────────────────
#   Notification panel (swaync — replaces old mako/rofi history)
# ──────────────────────────────────────────────
set -euo pipefail
exec swaync-client -t -sw

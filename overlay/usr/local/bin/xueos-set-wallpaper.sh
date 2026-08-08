#!/bin/bash
# Applies the XueOS default wallpaper to every connected monitor, whatever
# it's named (xfdesktop keys its xfconf properties by output name, e.g.
# "monitoreDP-1", which varies per machine — the shipped system default in
# xfce4-desktop.xml only covers the generic "monitor0" case). Runs once at
# first login via the autostart entry below, then removes that entry.

set -euo pipefail

WALLPAPER="/usr/share/backgrounds/xueos/dark.png"

if command -v xrandr >/dev/null 2>&1; then
    while read -r output; do
        xfconf-query -c xfce4-desktop \
            -p "/backdrop/screen0/monitor${output}/workspace0/last-image" \
            -n -t string -s "${WALLPAPER}" 2>/dev/null || true
        xfconf-query -c xfce4-desktop \
            -p "/backdrop/screen0/monitor${output}/workspace0/image-style" \
            -n -t int -s 5 2>/dev/null || true
    done < <(xrandr --query 2>/dev/null | awk '/ connected/{print $1}')
fi

rm -f "${HOME}/.config/autostart/xueos-set-wallpaper.desktop"

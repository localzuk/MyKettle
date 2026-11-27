#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Tony Ayre <me@tonyayre.net>
# SPDX-License-Identifier: GPL-3.0-or-later
# Removes MyKettle. Your kettle config (incl. the local key) is kept unless you pass --purge.
set -uo pipefail
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/mykettle"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/mykettle"

systemctl --user disable --now mykettle.service 2>/dev/null
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/mykettle.service"
systemctl --user daemon-reload 2>/dev/null
kpackagetool6 -t Plasma/Applet -r org.kde.plasma.mykettle 2>/dev/null
rm -rf "$DATA"
rm -f "$HOME/.local/bin/mykettle" "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/mykettle.svg"
if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$CONF"
  echo "MyKettle removed, including its configuration."
else
  echo "MyKettle removed. Your kettle settings are still in $CONF (use --purge to delete them)."
fi
echo "Remove any MyKettle widgets left on your panel/desktop by hand, or restart Plasma."

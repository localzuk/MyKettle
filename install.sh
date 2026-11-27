#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Tony Ayre <me@tonyayre.net>
# SPDX-License-Identifier: GPL-3.0-or-later
# MyKettle installer - KDE Plasma 6 widget + local backend for Tuya/SETTI+ kettles.
# Installs everything into your home directory; no root needed (except, if
# missing, for installing python venv support with your package manager).
#
#   ./install.sh               install / upgrade, then offer to run the setup wizard
#   ./install.sh --no-wizard   install / upgrade only
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/mykettle"
BIN="$HOME/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
PLASMOID_ID="org.kde.plasma.mykettle"
RUN_WIZARD=1
[[ "${1:-}" == "--no-wizard" ]] && RUN_WIZARD=0
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mykettle/config.json"
VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$HERE/backend/mykettle.py")"
OLD_VERSION=""
if [[ -f "$DATA/mykettle.py" ]]; then
  OLD_VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$DATA/mykettle.py")"
fi

b=$'\e[1m'; g=$'\e[32m'; y=$'\e[33m'; r=$'\e[31m'; n=$'\e[0m'
step() { printf '\n%s==>%s %s%s%s\n' "$g" "$n" "$b" "$*" "$n"; }
die()  { printf '%sError:%s %s\n' "$r" "$n" "$*" >&2; exit 1; }
warn() { printf '%sWarning:%s %s\n' "$y" "$n" "$*"; }

cat <<EOF
${b}☕  MyKettle installer${n} ${VERSION} · © 2026 Tony Ayre · GPL-3.0-or-later
This installs:
  • a small Python service that talks to the kettle on your LAN  -> $DATA
  • the 'mykettle' command                                        -> $BIN/mykettle
  • a systemd user service (mykettle.service)
  • the Plasma widget "MyKettle"
EOF

# --------------------------------------------------------------------------
step "Checking requirements"
command -v python3 >/dev/null || die "python3 is not installed. Install it with your package manager (e.g. 'sudo pacman -S python' / 'sudo apt install python3')."
python3 - <<'PY' || die "Python 3.9 or newer is required."
import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)
PY
if ! python3 -c 'import venv, ensurepip' 2>/dev/null; then
  die "Python venv support is missing. Install it first:
     Debian/Ubuntu/KDE neon:  sudo apt install python3-venv
     Fedora:                  sudo dnf install python3
     Arch/CachyOS/Manjaro:    (included with python)
     openSUSE:                sudo zypper install python3"
fi
KPT="$(command -v kpackagetool6 || true)"
[[ -n "$KPT" ]] || die "kpackagetool6 not found - this widget needs KDE Plasma 6."
if command -v plasmashell >/dev/null; then
  echo "  $(plasmashell --version 2>/dev/null)"
fi
echo "  $(python3 --version)"

# --------------------------------------------------------------------------
step "Installing the backend (Python virtual environment + tinytuya)"
mkdir -p "$DATA" "$BIN"
if [[ ! -x "$DATA/venv/bin/python" ]]; then
  python3 -m venv "$DATA/venv"
fi
"$DATA/venv/bin/python" -m pip install --quiet --upgrade pip
"$DATA/venv/bin/python" -m pip install --quiet --upgrade "tinytuya>=1.13"
install -m 644 "$HERE/backend/mykettle.py" "$HERE/backend/setup_wizard.py" "$DATA/"
mkdir -p "$DATA/docs"
install -m 644 "$HERE/docs/SETUP.md" "$DATA/docs/SETUP.md"
install -m 644 "$HERE/LICENSE" "$DATA/LICENSE"

cat > "$BIN/mykettle" <<EOF
#!/bin/sh
# MyKettle command-line entry point (installed by install.sh)
exec "$DATA/venv/bin/python" "$DATA/mykettle.py" "\$@"
EOF
chmod 755 "$BIN/mykettle"
echo "  tinytuya $("$DATA/venv/bin/python" -c 'import tinytuya; print(tinytuya.__version__)')"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) warn "$BIN is not in your PATH - use the full path $BIN/mykettle, or add it to PATH." ;;
esac

# --------------------------------------------------------------------------
step "Installing the systemd user service"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/mykettle.service" <<EOF
[Unit]
Description=MyKettle - local Tuya kettle bridge for the Plasma widget
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$DATA/venv/bin/python $DATA/mykettle.py serve
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
if command -v systemctl >/dev/null && systemctl --user daemon-reload 2>/dev/null; then
  # Start it even before setup: the widget then shows the setup guide.
  systemctl --user enable --now mykettle.service >/dev/null 2>&1 || warn "could not start mykettle.service"
  systemctl --user restart mykettle.service >/dev/null 2>&1 || true
  echo "  mykettle.service enabled"
else
  warn "systemd user session not available - start the backend yourself with:  mykettle serve &"
fi

# --------------------------------------------------------------------------
step "Installing the Plasma widget"
mkdir -p "$ICON_DIR"
install -m 644 "$HERE/package/contents/icons/mykettle.svg" "$ICON_DIR/mykettle.svg"
if "$KPT" -t Plasma/Applet -s "$PLASMOID_ID" >/dev/null 2>&1; then
  "$KPT" -t Plasma/Applet -u "$HERE/package" >/dev/null
  echo "  widget upgraded"
  UPGRADED=1
else
  "$KPT" -t Plasma/Applet -i "$HERE/package" >/dev/null
  echo "  widget installed"
  UPGRADED=0
fi

# --------------------------------------------------------------------------
if [[ -f "$CONFIG_FILE" ]]; then
  # ---------------------------------------------------------------- update
  if [[ -n "$OLD_VERSION" && "$OLD_VERSION" != "$VERSION" ]]; then
    headline="Updated MyKettle from ${OLD_VERSION} to ${VERSION}."
  else
    headline="MyKettle ${VERSION} reinstalled."
  fi
  cat <<EOF

${g}${b}${headline}${n}
Your kettle settings were kept and the background service has been restarted.
EOF
  if [[ "${UPGRADED:-0}" == 1 ]]; then
    echo "Restart Plasma to load the new widget:  systemctl --user restart plasma-plasmashell"
  fi
  cat <<EOF
Change kettle settings:  ${b}mykettle setup${n}    Check everything:  ${b}mykettle doctor${n}
EOF
  exit 0
fi

# -------------------------------------------------------------- first install
cat <<EOF

${g}${b}MyKettle ${VERSION} installed.${n}
EOF

if [[ $RUN_WIZARD == 1 && -t 0 ]]; then
  read -r -p "Run the setup wizard now? [Y/n] " ans
  if [[ "${ans,,}" != n* ]]; then
    exec "$BIN/mykettle" setup
  fi
fi
cat <<EOF
Next steps:
  1. Run the setup wizard:   ${b}mykettle setup${n}   (or click "Run setup" in the widget)
  2. Add the widget: right-click the panel/desktop > Add or Manage Widgets… > "MyKettle"
Full guide: $DATA/docs/SETUP.md
EOF

#!/bin/sh
set -eu
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR"
PYTHON="${PYTHON:-/usr/bin/python3}"

"$PYTHON" -m pip install --user -r requirements.txt
chmod +x run.sh install.sh emby_health_report.py

echo "Installation abgeschlossen."
echo "Jetzt config.ini bearbeiten und ./run.sh starten."

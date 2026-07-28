#!/bin/sh
set -eu
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR"
PYTHON="${PYTHON:-/usr/bin/python3}"

if [ ! -x "$PYTHON" ]; then
    echo "Python nicht gefunden: $PYTHON" >&2
    exit 1
fi

exec "$PYTHON" emby_health_report.py config.ini

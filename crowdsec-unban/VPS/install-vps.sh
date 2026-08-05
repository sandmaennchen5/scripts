#!/bin/bash
set -Eeuo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="/var/backups/crowdsec-rescue/$(date -u +%Y%m%dT%H%M%SZ)"
WRAPPER_TARGET="/usr/local/bin/crowdsec-rescue-wrapper"
SUDOERS_TARGET="/etc/sudoers.d/crowdsec-rescue"
SCRIPTS=(
    crowdsec-rescue-status
    crowdsec-rescue-alerts
    crowdsec-rescue-unban
    crowdsec-rescue-unban-all
)

if [[ "${EUID}" -ne 0 ]]; then
    echo "Bitte als root starten: sudo bash $0" >&2
    exit 1
fi

for command in install visudo docker python3 sudo; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Erforderlicher Befehl fehlt: $command" >&2
        exit 1
    }
done

id rescue >/dev/null 2>&1 || {
    echo "Der Benutzer 'rescue' existiert nicht." >&2
    exit 1
}

for file in crowdsec-rescue-wrapper sudoers-crowdsec-rescue "${SCRIPTS[@]}"; do
    [[ -f "$SOURCE_DIR/$file" ]] || {
        echo "Quelldatei fehlt: $SOURCE_DIR/$file" >&2
        exit 1
    }
done

docker inspect crowdsec >/dev/null 2>&1 || {
    echo "Der Docker-Container 'crowdsec' wurde nicht gefunden." >&2
    exit 1
}

mkdir -p "$BACKUP_DIR"

backup_if_present() {
    local target="$1"
    if [[ -e "$target" ]]; then
        cp -a -- "$target" "$BACKUP_DIR/$(basename -- "$target")"
    fi
}

backup_if_present "$WRAPPER_TARGET"
backup_if_present "$SUDOERS_TARGET"
for script in "${SCRIPTS[@]}"; do
    backup_if_present "/usr/local/sbin/$script"
done

rollback() {
    local code=$?
    echo "Installation fehlgeschlagen – vorherige Dateien werden wiederhergestellt." >&2
    for target in "$WRAPPER_TARGET" "$SUDOERS_TARGET"; do
        local saved="$BACKUP_DIR/$(basename -- "$target")"
        if [[ -e "$saved" ]]; then cp -a -- "$saved" "$target"; else rm -f -- "$target"; fi
    done
    for script in "${SCRIPTS[@]}"; do
        local target="/usr/local/sbin/$script"
        local saved="$BACKUP_DIR/$script"
        if [[ -e "$saved" ]]; then cp -a -- "$saved" "$target"; else rm -f -- "$target"; fi
    done
    exit "$code"
}
trap rollback ERR

install -o root -g root -m 0755 "$SOURCE_DIR/crowdsec-rescue-wrapper" "$WRAPPER_TARGET"
for script in "${SCRIPTS[@]}"; do
    install -o root -g root -m 0755 "$SOURCE_DIR/$script" "/usr/local/sbin/$script"
done
install -o root -g root -m 0440 "$SOURCE_DIR/sudoers-crowdsec-rescue" "$SUDOERS_TARGET"

visudo -cf "$SUDOERS_TARGET"

TEST_IP="192.0.2.1"
STATUS_OUTPUT="$(sudo -u rescue env SSH_ORIGINAL_COMMAND="STATUS $TEST_IP" "$WRAPPER_TARGET")"
python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$STATUS_OUTPUT"

trap - ERR
echo "Installation erfolgreich."
echo "Backup: $BACKUP_DIR"
echo "Status-Test für $TEST_IP war erfolgreich."
echo "UNBAN und UNBAN_ALL wurden aus Sicherheitsgründen nicht automatisch ausgeführt."

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="Pangolin Maintenance Tool"
SCRIPT_VERSION="2.4"

# Persistent user configuration. The self-update process replaces only this
# script; maintenance.conf remains untouched. On every start the documented
# template is refreshed atomically while all existing setting values are kept.
CONFIG_FILE="${CONFIG_FILE:-./maintenance.conf}"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

LANGUAGE="${LANGUAGE:-en}"                            # de | en
SHOW_SCRIPT_INFO="${SHOW_SCRIPT_INFO:-true}"          # true | false
DEBUG="${DEBUG:-false}"                               # true | false
QUIET="${QUIET:-false}"                               # true | false
UNATTENDED="${UNATTENDED:-false}"                     # true | false

SCRIPT_UPDATE_MODE="${SCRIPT_UPDATE_MODE:-ask}"             # ask | auto | off
SCRIPT_UPDATE_URL="${SCRIPT_UPDATE_URL:-https://raw.githubusercontent.com/sandmaennchen5/scripts/refs/heads/main/pangolin/maintenance.sh}"
SCRIPT_UPDATE_TIMEOUT="${SCRIPT_UPDATE_TIMEOUT:-8}"
ENABLE_EXTERNAL_TCP_TEST="${ENABLE_EXTERNAL_TCP_TEST:-true}"
TCP_TEST_TIMEOUT="${TCP_TEST_TIMEOUT:-5}"

UPDATE_MODE="${UPDATE_MODE:-ask}"                     # ask | auto | manual | none
UPDATE_LEVEL="${UPDATE_LEVEL:-ask}"                   # ask | patch | next-minor | minor | next-major | major
DEFAULT_UPDATE_MODE="${DEFAULT_UPDATE_MODE:-auto}"
DEFAULT_UPDATE_LEVEL="${DEFAULT_UPDATE_LEVEL:-patch}"
DEFAULT_MANUAL_FILTER="${DEFAULT_MANUAL_FILTER:-series}"
DEFAULT_MANUAL_SELECTION="${DEFAULT_MANUAL_SELECTION:-0}"
RUN_COMPOSE="${RUN_COMPOSE:-ask}"
DEFAULT_RUN_COMPOSE="${DEFAULT_RUN_COMPOSE:-yes}"
STOP_CONTAINERS_FOR_BACKUP="${STOP_CONTAINERS_FOR_BACKUP:-ask}"
DEFAULT_STOP_CONTAINERS_FOR_BACKUP="${DEFAULT_STOP_CONTAINERS_FOR_BACKUP:-no}"
DEFAULT_RESTORE_SELECTION="${DEFAULT_RESTORE_SELECTION:-0}"
DEFAULT_REVERT_UNAPPLIED_CHANGES="${DEFAULT_REVERT_UNAPPLIED_CHANGES:-yes}"

BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
BACKUP_MIN_KEEP="${BACKUP_MIN_KEEP:-3}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
BACKUP_SET_DIR="${BACKUP_SET_DIR:-$BACKUP_DIR/sets}"
PRE_RESTORE_BACKUP_DIR="${PRE_RESTORE_BACKUP_DIR:-$BACKUP_DIR/pre-restore}"
TRAEFIK_CONFIG="${TRAEFIK_CONFIG:-./config/traefik/traefik_config.yml}"
COMPOSE_FILE="${COMPOSE_FILE:-./docker-compose.yml}"
ENV_FILE="${ENV_FILE:-./.env}"

case "${LANGUAGE,,}" in de|en) LANGUAGE="${LANGUAGE,,}" ;; *) echo "Invalid LANGUAGE '$LANGUAGE'. Allowed: de, en." >&2; exit 2 ;; esac


config_quote() {
    printf '%q' "$1"
}

write_config_template() {
    local output="$1"

    cat > "$output" <<'EOF'
# Pangolin Maintenance Tool configuration
#
# This file is managed by the maintenance script.
# Existing setting values are preserved when the script adds new options or
# refreshes these English descriptions. Edit only the assignment values.
# The script itself may be updated without replacing this file.

# -----------------------------------------------------------------------------
# General behavior
# -----------------------------------------------------------------------------

# Interface language.
# Allowed values: en, de
EOF
    printf 'LANGUAGE=%s\n\n' "$(config_quote "$LANGUAGE")" >> "$output"

    cat >> "$output" <<'EOF'
# Show script name and version information when starting.
# Allowed values: true, false
EOF
    printf 'SHOW_SCRIPT_INFO=%s\n\n' "$(config_quote "$SHOW_SCRIPT_INFO")" >> "$output"

    cat >> "$output" <<'EOF'
# Enable additional diagnostic output from the maintenance script.
# Allowed values: true, false
EOF
    printf 'DEBUG=%s\n\n' "$(config_quote "$DEBUG")" >> "$output"

    cat >> "$output" <<'EOF'
# Suppress ordinary informational messages. Errors and required prompts remain.
# Allowed values: true, false
EOF
    printf 'QUIET=%s\n\n' "$(config_quote "$QUIET")" >> "$output"

    cat >> "$output" <<'EOF'
# Run without interactive questions and use the configured default choices.
# Allowed values: true, false
EOF
    printf 'UNATTENDED=%s\n\n' "$(config_quote "$UNATTENDED")" >> "$output"

    cat >> "$output" <<'EOF'
# -----------------------------------------------------------------------------
# Maintenance script self-update
# -----------------------------------------------------------------------------

# Control the automatic update check performed when the script starts.
# ask: show a confirmation when a newer version exists
# auto: install a newer version automatically
# off: do not check automatically; manual menu checks still work
# Allowed values: ask, auto, off
EOF
    printf 'SCRIPT_UPDATE_MODE=%s\n\n' "$(config_quote "$SCRIPT_UPDATE_MODE")" >> "$output"

    cat >> "$output" <<'EOF'
# Raw download URL of the published maintenance script.
EOF
    printf 'SCRIPT_UPDATE_URL=%s\n\n' "$(config_quote "$SCRIPT_UPDATE_URL")" >> "$output"

    cat >> "$output" <<'EOF'
# Network timeout in seconds used for the self-update request.
# Must be a positive integer.
EOF
    printf 'SCRIPT_UPDATE_TIMEOUT=%s\n\n' "$(config_quote "$SCRIPT_UPDATE_TIMEOUT")" >> "$output"

    cat >> "$output" <<'EOF'
# Enable the public TCP reachability check for published TCP ports.
# Allowed values: true, false
EOF
    printf 'ENABLE_EXTERNAL_TCP_TEST=%s\n\n' "$(config_quote "$ENABLE_EXTERNAL_TCP_TEST")" >> "$output"

    cat >> "$output" <<'EOF'
# Timeout in seconds for each TCP reachability check.
# Must be a positive integer.
EOF
    printf 'TCP_TEST_TIMEOUT=%s\n\n' "$(config_quote "$TCP_TEST_TIMEOUT")" >> "$output"

    cat >> "$output" <<'EOF'
# -----------------------------------------------------------------------------
# Pangolin component updates
# -----------------------------------------------------------------------------

# Select how component updates are chosen.
# ask: prompt for the mode
# auto: use UPDATE_LEVEL automatically
# manual: select versions interactively
# none: do not change component versions
# Allowed values: ask, auto, manual, none
EOF
    printf 'UPDATE_MODE=%s\n\n' "$(config_quote "$UPDATE_MODE")" >> "$output"

    cat >> "$output" <<'EOF'
# Maximum version level allowed for automatic component updates.
# patch: same major and minor version
# next-minor: exactly the next minor release with patch zero
# minor: latest release within the current major version
# next-major: exactly the next major release with minor and patch zero
# major: latest available release using the same tag variant
# Allowed values: ask, patch, next-minor, minor, next-major, major
EOF
    printf 'UPDATE_LEVEL=%s\n\n' "$(config_quote "$UPDATE_LEVEL")" >> "$output"

    cat >> "$output" <<'EOF'
# Default update mode used for unattended execution or an empty answer.
# Allowed values: auto, manual, none
EOF
    printf 'DEFAULT_UPDATE_MODE=%s\n\n' "$(config_quote "$DEFAULT_UPDATE_MODE")" >> "$output"

    cat >> "$output" <<'EOF'
# Default automatic update level used for unattended execution or an empty answer.
# Allowed values: patch, next-minor, minor, next-major, major
EOF
    printf 'DEFAULT_UPDATE_LEVEL=%s\n\n' "$(config_quote "$DEFAULT_UPDATE_LEVEL")" >> "$output"

    cat >> "$output" <<'EOF'
# Initial filter shown during manual version selection.
# Allowed values: series, major, all, direct, skip
EOF
    printf 'DEFAULT_MANUAL_FILTER=%s\n\n' "$(config_quote "$DEFAULT_MANUAL_FILTER")" >> "$output"

    cat >> "$output" <<'EOF'
# Default numbered entry used in manual version lists. Zero means skip.
EOF
    printf 'DEFAULT_MANUAL_SELECTION=%s\n\n' "$(config_quote "$DEFAULT_MANUAL_SELECTION")" >> "$output"

    cat >> "$output" <<'EOF'
# Ask whether Docker Compose should pull and apply selected component changes.
# Allowed values: ask, yes, no
EOF
    printf 'RUN_COMPOSE=%s\n\n' "$(config_quote "$RUN_COMPOSE")" >> "$output"

    cat >> "$output" <<'EOF'
# Default answer for applying Docker Compose changes.
# Allowed values: yes, no
EOF
    printf 'DEFAULT_RUN_COMPOSE=%s\n\n' "$(config_quote "$DEFAULT_RUN_COMPOSE")" >> "$output"

    cat >> "$output" <<'EOF'
# -----------------------------------------------------------------------------
# Backup and restore behavior
# -----------------------------------------------------------------------------

# Ask whether containers should be stopped before creating a backup.
# Allowed values: ask, yes, no
EOF
    printf 'STOP_CONTAINERS_FOR_BACKUP=%s\n\n' "$(config_quote "$STOP_CONTAINERS_FOR_BACKUP")" >> "$output"

    cat >> "$output" <<'EOF'
# Default answer for stopping containers before a backup.
# Allowed values: yes, no
EOF
    printf 'DEFAULT_STOP_CONTAINERS_FOR_BACKUP=%s\n\n' "$(config_quote "$DEFAULT_STOP_CONTAINERS_FOR_BACKUP")" >> "$output"

    cat >> "$output" <<'EOF'
# Default numbered backup selection. Zero returns to the previous menu.
EOF
    printf 'DEFAULT_RESTORE_SELECTION=%s\n\n' "$(config_quote "$DEFAULT_RESTORE_SELECTION")" >> "$output"

    cat >> "$output" <<'EOF'
# Default answer when selected update changes were not applied and the script
# offers to restore the YAML files from the automatic backup.
# Allowed values: yes, no
EOF
    printf 'DEFAULT_REVERT_UNAPPLIED_CHANGES=%s\n\n' "$(config_quote "$DEFAULT_REVERT_UNAPPLIED_CHANGES")" >> "$output"

    cat >> "$output" <<'EOF'
# Remove backup sets older than this number of days while respecting
# BACKUP_MIN_KEEP. Use a non-negative integer.
EOF
    printf 'BACKUP_RETENTION_DAYS=%s\n\n' "$(config_quote "$BACKUP_RETENTION_DAYS")" >> "$output"

    cat >> "$output" <<'EOF'
# Minimum number of newest backup sets that are always retained.
# Use a non-negative integer.
EOF
    printf 'BACKUP_MIN_KEEP=%s\n\n' "$(config_quote "$BACKUP_MIN_KEEP")" >> "$output"

    cat >> "$output" <<'EOF'
# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------

# Root directory used for maintenance backups.
EOF
    printf 'BACKUP_DIR=%s\n\n' "$(config_quote "$BACKUP_DIR")" >> "$output"

    cat >> "$output" <<'EOF'
# Directory containing normal backup sets.
EOF
    printf 'BACKUP_SET_DIR=%s\n\n' "$(config_quote "$BACKUP_SET_DIR")" >> "$output"

    cat >> "$output" <<'EOF'
# Directory containing safety backups created immediately before a restore.
EOF
    printf 'PRE_RESTORE_BACKUP_DIR=%s\n\n' "$(config_quote "$PRE_RESTORE_BACKUP_DIR")" >> "$output"

    cat >> "$output" <<'EOF'
# Path to the Traefik static configuration used for plugin and entryPoint checks.
EOF
    printf 'TRAEFIK_CONFIG=%s\n\n' "$(config_quote "$TRAEFIK_CONFIG")" >> "$output"

    cat >> "$output" <<'EOF'
# Path to the Pangolin Docker Compose file.
EOF
    printf 'COMPOSE_FILE=%s\n\n' "$(config_quote "$COMPOSE_FILE")" >> "$output"

    cat >> "$output" <<'EOF'
# Path to the environment file included in backups and restores.
EOF
    printf 'ENV_FILE=%s\n' "$(config_quote "$ENV_FILE")" >> "$output"
}

sync_config_file() {
    local config_dir tmp_file backup_file
    config_dir=$(dirname -- "$CONFIG_FILE")
    mkdir -p -- "$config_dir"
    tmp_file=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")
    write_config_template "$tmp_file"

    if [[ -f "$CONFIG_FILE" ]] && cmp -s -- "$tmp_file" "$CONFIG_FILE"; then
        rm -f -- "$tmp_file"
        return 0
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        backup_file="${CONFIG_FILE}.bak"
        cp -p -- "$CONFIG_FILE" "$backup_file"
    fi

    chmod 600 "$tmp_file"
    mv -f -- "$tmp_file" "$CONFIG_FILE"

    if [[ -n "${backup_file:-}" ]]; then
        printf 'ℹ️ Configuration documentation updated; values preserved. Backup: %s\n' "$backup_file"
    else
        printf 'ℹ️ Configuration file created: %s\n' "$CONFIG_FILE"
    fi
}

sync_config_file

text() { if [[ "$LANGUAGE" == de ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
normalize_true_false() { case "${1,,}" in true|1|yes|y|ja|j|on) printf 'true\n';; false|0|no|n|nein|off) printf 'false\n';; *) return 1;; esac; }
SHOW_SCRIPT_INFO=$(normalize_true_false "$SHOW_SCRIPT_INFO") || exit 2
DEBUG=$(normalize_true_false "$DEBUG") || exit 2
QUIET=$(normalize_true_false "$QUIET") || exit 2
UNATTENDED=$(normalize_true_false "$UNATTENDED") || exit 2
info() { [[ "$QUIET" == true ]] || printf '%s\n' "$*"; }
debug() { [[ "$DEBUG" == true ]] && printf 'DEBUG: %s\n' "$*" >&2 || true; }

if [[ "${1:-}" == --version || "${1:-}" == -V ]]; then printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0; fi
DIRECT_ACTION="${1:-}"
DIRECT_ARGUMENT="${2:-}"

for cmd in curl jq yq docker tar; do command -v "$cmd" >/dev/null 2>&1 || { printf '❌ %s\n' "$(text "'$cmd' fehlt." "'$cmd' is missing.")" >&2; exit 1; }; done
[[ -f "$COMPOSE_FILE" ]] || { printf '❌ %s\n' "$(text "$COMPOSE_FILE wurde nicht gefunden." "$COMPOSE_FILE was not found.")" >&2; exit 1; }

traefik_config_exists=false
[[ -f "$TRAEFIK_CONFIG" ]] && traefik_config_exists=true
traefik_changed=false
compose_changed=false
updates_available=false
versions_loaded=false
BACKUP_CONTAINERS_STOPPED=false
LAST_BACKUP_DIR=""

declare -A ITEMS_ALT=() ITEMS_NEW=() ITEMS_TAGS=() ITEMS_TYPE=() ITEMS_PATH=() ITEMS_REPO=()

normalize_bool() {
    case "${1,,}" in
        y|yes|j|ja|true|1|on) printf 'yes\n' ;;
        n|no|nein|false|0|off) printf 'no\n' ;;
        ask|'') printf 'ask\n' ;;
        *) return 1 ;;
    esac
}

read_user_input() {
    local variable_name="$1"
    local prompt="$2"

    # Loops in this script may use stdin for process-substitution input.
    # Read interactive answers directly from the controlling terminal so
    # prompts do not consume loop data or immediately receive EOF.
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        IFS= read -r -p "$prompt" "$variable_name" </dev/tty
    else
        IFS= read -r -p "$prompt" "$variable_name"
    fi
}

version_is_greater() {
    local candidate="$1" current="$2"
    [[ -n "$candidate" && "$candidate" != "$current" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$current" "$candidate" | sort -V | tail -n1)" == "$candidate" ]]
}

check_script_update() {
    local force="${1:-false}"
    shift || true
    local mode="${SCRIPT_UPDATE_MODE,,}"
    local script_path remote_file remote_version answer backup_file tmp_dir

    case "$mode" in
        ask|auto|off) ;;
        *)
            printf '⚠️ %s\n' "$(text "Ungültiger SCRIPT_UPDATE_MODE '$SCRIPT_UPDATE_MODE'; Update-Prüfung wird übersprungen." "Invalid SCRIPT_UPDATE_MODE '$SCRIPT_UPDATE_MODE'; skipping script update check.")" >&2
            return 0
            ;;
    esac

    [[ "$force" == true || "$mode" != off ]] || return 0
    command -v curl >/dev/null 2>&1 || return 0

    script_path=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
    [[ -f "$script_path" && -w "$script_path" ]] || {
        [[ "$force" == true ]] && printf '❌ %s\n' "$(text "Skriptdatei ist nicht beschreibbar: $script_path" "Script file is not writable: $script_path")" >&2
        return 0
    }

    tmp_dir=$(mktemp -d)
    remote_file="$tmp_dir/maintenance.sh"
    trap 'rm -rf -- "$tmp_dir"' RETURN

    if ! curl -fsSL --connect-timeout "$SCRIPT_UPDATE_TIMEOUT" --max-time "$((SCRIPT_UPDATE_TIMEOUT * 2))"         "$SCRIPT_UPDATE_URL" -o "$remote_file"; then
        [[ "$force" == true ]] && printf '❌ %s\n' "$(text "Update-Datei konnte nicht geladen werden." "Could not download the update file.")" >&2
        return 0
    fi

    remote_version=$(sed -nE 's/^SCRIPT_VERSION="([^"]+)".*/\1/p' "$remote_file" | head -n1)
    if [[ -z "$remote_version" ]]; then
        printf '⚠️ %s\n' "$(text "Die heruntergeladene Datei enthält keine gültige SCRIPT_VERSION." "The downloaded file does not contain a valid SCRIPT_VERSION.")" >&2
        return 0
    fi

    if ! version_is_greater "$remote_version" "$SCRIPT_VERSION"; then
        [[ "$force" == true ]] && printf '✅ %s %s\n' "$(text "Das Skript ist aktuell. Version:" "The script is up to date. Version:")" "$SCRIPT_VERSION"
        return 0
    fi

    printf '⬆️  %s: %s → %s\n' "$(text "Neue Skriptversion verfügbar" "New script version available")" "$SCRIPT_VERSION" "$remote_version"
    if [[ "$mode" == auto ]]; then
        answer=yes
    else
        answer=$(prompt_yes_no "$(text "Maintenance Tool jetzt aktualisieren?" "Update the Maintenance Tool now?")" ask yes)
    fi
    [[ "$answer" == yes ]] || return 0

    if ! bash -n "$remote_file"; then
        printf '❌ %s\n' "$(text "Das heruntergeladene Skript hat Syntaxfehler. Update abgebrochen." "The downloaded script has syntax errors. Update cancelled.")" >&2
        return 1
    fi

    backup_file="${script_path}.bak-${SCRIPT_VERSION}-$(date +%Y%m%d-%H%M%S)"
    cp -p -- "$script_path" "$backup_file"
    chmod --reference="$script_path" "$remote_file" 2>/dev/null || chmod +x "$remote_file"
    if ! mv -f -- "$remote_file" "$script_path"; then
        printf '❌ %s\n' "$(text "Skript konnte nicht ersetzt werden. Sicherung: $backup_file" "Could not replace the script. Backup: $backup_file")" >&2
        return 1
    fi

    trap - RETURN
    rm -rf -- "$tmp_dir"
    printf '✅ %s %s\n' "$(text "Skript aktualisiert auf Version" "Script updated to version")" "$remote_version"
    printf 'ℹ️ %s: %s\n' "$(text "Sicherung" "Backup")" "$backup_file"
    printf '🔄 %s\n' "$(text "Das aktualisierte Skript wird neu gestartet …" "Restarting the updated script …")"
    exec "$script_path" "$@"
}

prompt_yes_no() {
    local prompt="$1"
    local configured="$2"
    local default_value="$3"
    local normalized answer suffix

    normalized=$(normalize_bool "$configured") || {
        printf "❌ %s\n" "$(text "Ungültiger Wert '$configured' für Ja/Nein-Option." "Invalid value '$configured' for yes/no option.")" >&2
        return 2
    }

    if [[ "$normalized" != "ask" ]]; then
        printf '%s\n' "$normalized"
        return 0
    fi

    if [[ "$UNATTENDED" =~ ^(true|1|yes|on)$ ]]; then
        normalize_bool "$default_value"
        return 0
    fi

    default_value=$(normalize_bool "$default_value") || return 2

    if [[ "$default_value" == "yes" ]]; then
        suffix=$(text "J/n, Standard: Ja" "Y/n, default: Yes")
    else
        suffix=$(text "j/N, Standard: Nein" "y/N, default: No")
    fi

    read_user_input answer "$prompt [$suffix]: "
    answer="${answer:-$default_value}"
    normalize_bool "$answer"
}

resolve_update_mode() {
    local mode="${UPDATE_MODE,,}"
    local choice default_choice

    case "$mode" in
        auto|manual|none) printf '%s\n' "$mode"; return 0 ;;
        ask) ;;
        *) printf "❌ %s\n" "$(text "Ungültiger UPDATE_MODE: $UPDATE_MODE" "Invalid UPDATE_MODE: $UPDATE_MODE")" >&2; return 2 ;;
    esac

    if [[ "$UNATTENDED" =~ ^(true|1|yes|on)$ ]]; then
        case "${DEFAULT_UPDATE_MODE,,}" in
            auto|manual|none) printf '%s\n' "${DEFAULT_UPDATE_MODE,,}" ;;
            *) printf "❌ %s\n" "$(text "Ungültiger DEFAULT_UPDATE_MODE: $DEFAULT_UPDATE_MODE" "Invalid DEFAULT_UPDATE_MODE: $DEFAULT_UPDATE_MODE")" >&2; return 2 ;;
        esac
        return 0
    fi

    case "${DEFAULT_UPDATE_MODE,,}" in
        auto) default_choice=1 ;;
        manual) default_choice=2 ;;
        none) default_choice=0 ;;
        *) printf "❌ %s\n" "$(text "Ungültiger DEFAULT_UPDATE_MODE: $DEFAULT_UPDATE_MODE" "Invalid DEFAULT_UPDATE_MODE: $DEFAULT_UPDATE_MODE")" >&2; return 2 ;;
    esac

    text "Wie sollen Updates übernommen werden?" "How should updates be applied?" >&2; echo >&2
    text "   [1] automatisch" "   [1] automatically" >&2; echo >&2
    text "   [2] manuell" "   [2] manually" >&2; echo >&2
    text "   [0] keine Änderungen" "   [0] no changes" >&2; echo >&2
    read_user_input choice "$(text "Auswahl" "Selection") [$default_choice]: "
    choice="${choice:-$default_choice}"
    case "$choice" in
        1) printf 'auto\n' ;;
        2) printf 'manual\n' ;;
        0) printf 'none\n' ;;
        *) printf "⚠️ %s\n" "$(text "Ungültige Auswahl – keine Änderungen." "Invalid selection – no changes.")" >&2; printf 'none\n' ;;
    esac
}

resolve_update_level() {
    local level="${UPDATE_LEVEL,,}"
    local choice default_choice

    case "${DEFAULT_UPDATE_LEVEL,,}" in
        patch) default_choice=1 ;;
        next-minor) default_choice=2 ;;
        minor) default_choice=3 ;;
        next-major) default_choice=4 ;;
        major) default_choice=5 ;;
        *)
            printf "❌ %s\n" "$(text "Ungültiger DEFAULT_UPDATE_LEVEL: $DEFAULT_UPDATE_LEVEL" "Invalid DEFAULT_UPDATE_LEVEL: $DEFAULT_UPDATE_LEVEL")" >&2
            return 2
            ;;
    esac

    case "$level" in
        patch|next-minor|minor|next-major|major)
            printf '%s\n' "$level"
            return 0
            ;;
        ask) ;;
        *)
            printf "❌ %s\n" "$(text "Ungültiger UPDATE_LEVEL: $UPDATE_LEVEL" "Invalid UPDATE_LEVEL: $UPDATE_LEVEL")" >&2
            return 2
            ;;
    esac

    if [[ "$UNATTENDED" =~ ^(true|1|yes|on)$ ]]; then
        printf '%s\n' "${DEFAULT_UPDATE_LEVEL,,}"
        return 0
    fi

    text "Wie weit dürfen automatische Updates gehen?" "How far may automatic updates go?" >&2; echo >&2
    text "   [1] Patch         – nur Bugfixes: X.Y.Z → X.Y.neu" "   [1] Patch         – bug fixes only: X.Y.Z → X.Y.new" >&2; echo >&2
    text "   [2] Next Minor    – nächste Minor-Version mit Patch 0: X.Y.Z → X.(Y+1).0" "   [2] Next Minor    – next minor version with patch 0: X.Y.Z → X.(Y+1).0" >&2; echo >&2
    text "   [3] Latest Minor  – neueste Minor derselben Major-Version" "   [3] Latest Minor  – newest minor within the same major version" >&2; echo >&2
    text "   [4] Next Major    – nächste Major-Version mit Minor/Patch 0: X.Y.Z → (X+1).0.0" "   [4] Next Major    – next major version with minor/patch 0: X.Y.Z → (X+1).0.0" >&2; echo >&2
    text "   [5] Latest Major  – neueste Version derselben Tag-Variante" "   [5] Latest Major  – newest version of the same tag variant" >&2; echo >&2
    text "   [0] Abbrechen" "   [0] Cancel" >&2; echo >&2
    read_user_input choice "$(text "Auswahl" "Selection") [$default_choice]: "
    choice="${choice:-$default_choice}"

    case "$choice" in
        1) printf 'patch\n' ;;
        2) printf 'next-minor\n' ;;
        3) printf 'minor\n' ;;
        4) printf 'next-major\n' ;;
        5) printf 'major\n' ;;
        0) printf 'cancel\n' ;;
        *)
            printf "⚠️ %s\n" "$(text "Ungültige Auswahl – Standardwert wird verwendet." "Invalid selection – default will be used.")" >&2
            printf '%s\n' "${DEFAULT_UPDATE_LEVEL,,}"
            ;;
    esac
}

# Filtert Tags nach exakt derselben Variante wie der aktuell verwendete Tag.
# Beispiele:
#   1.20.0                -> Präfix ""
#   ee-1.20.0             -> Präfix "ee-"
#   postgresql-1.20.0     -> Präfix "postgresql-"
#   ee-postgresql-1.20.0  -> Präfix "ee-postgresql-"
#   v3.7.8                -> Präfix "v"
semver_filter() {
    local prefix="$1"
    local tags="$2"
    local escaped_prefix

    # Präfix für die Verwendung in einem erweiterten regulären Ausdruck maskieren.
    escaped_prefix=$(printf '%s' "$prefix" | sed -E 's/[][(){}.^$*+?|\]/\\&/g')

    printf '%s\n' "$tags" \
        | grep -E "^${escaped_prefix}[0-9]+(\.[0-9]+){1,2}$" \
        || true
}

get_prefix() {
    local tag="$1"
    local version_part

    # Die numerische Version muss am Ende des Tags stehen.
    # Unterstützt X.Y und X.Y.Z.
    if [[ "$tag" =~ ([0-9]+(\.[0-9]+){1,2})$ ]]; then
        version_part="${BASH_REMATCH[1]}"
        printf '%s\n' "${tag%"$version_part"}"
        return 0
    fi

    return 1
}

# Wählt abhängig von der gewünschten Update-Stufe den neuesten zulässigen Tag.
# patch: gleiche Major- und Minor-Version
# next-minor: exakt nächste Minor-Version mit Patch 0
# minor: neueste Version innerhalb derselben Major-Version
# next-major: exakt nächste Major-Version mit Minor 0 und Patch 0
# major: jede neuere Version innerhalb derselben Tag-Variante / desselben Präfixes
version_is_newer() {
    local current="$1"
    local candidate="$2"
    local prefix current_version candidate_version highest

    prefix=$(get_prefix "$current") || return 1
    [[ "$candidate" == "$prefix"* ]] || return 1

    current_version="${current#"$prefix"}"
    candidate_version="${candidate#"$prefix"}"
    highest=$(printf '%s\n%s\n' "$current_version" "$candidate_version" | sort -Vr | head -n1)

    [[ "$highest" == "$candidate_version" && "$candidate_version" != "$current_version" ]]
}

filter_tags_by_major() {
    local current="$1"
    local tags="$2"
    local selected_major="$3"
    local prefix tag version major minor patch

    prefix=$(get_prefix "$current") || return 1
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        version="${tag#"$prefix"}"
        IFS='.' read -r major minor patch <<< "$version"
        [[ "$major" == "$selected_major" ]] && printf '%s\n' "$tag"
    done <<< "$tags"
}

filter_tags_by_series() {
    local current="$1"
    local tags="$2"
    local selected_major="$3"
    local selected_minor="$4"
    local prefix tag version major minor patch

    prefix=$(get_prefix "$current") || return 1
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        version="${tag#"$prefix"}"
        IFS='.' read -r major minor patch <<< "$version"
        [[ "$major" == "$selected_major" && "${minor:-0}" == "$selected_minor" ]] && printf '%s\n' "$tag"
    done <<< "$tags"
}

choose_from_numbered_list() {
    local prompt="$1"
    local default_choice="$2"
    shift 2
    local -a values=("$@")
    local choice i

    for i in "${!values[@]}"; do
        printf "      [%d] %s\n" "$((i + 1))" "${values[$i]}" >&2
    done
    text "      [0] abbrechen" "      [0] cancel" >&2; echo >&2
    read_user_input choice "   $prompt [$default_choice]: "
    choice="${choice:-$default_choice}"

    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    (( choice >= 1 && choice <= ${#values[@]} )) || return 1
    printf '%s\n' "${values[$((choice - 1))]}"
}

MANUAL_SELECTED_TAG=""

manual_select_tag() {
    local current="$1"
    local tags="$2"
    local filter_choice default_filter_choice choice direct_input prefix candidate
    local selected_major selected_minor filtered_tags version rest i
    local -a majors=() minors=() tag_list=()

    MANUAL_SELECTED_TAG=""

    case "${DEFAULT_MANUAL_FILTER,,}" in
        series) default_filter_choice=1 ;;
        major) default_filter_choice=2 ;;
        all) default_filter_choice=3 ;;
        direct) default_filter_choice=4 ;;
        skip) default_filter_choice=0 ;;
        *) default_filter_choice=1 ;;
    esac

    echo ""
    text "   Wie soll die Versionsliste gefiltert werden?" "   How should the version list be filtered?"; echo
    text "      [1] Major und Minor wählen – nur Tags einer X.Y-Reihe" "      [1] Choose major and minor – tags from one X.Y series only"; echo
    text "      [2] Major wählen – nur Tags einer X-Reihe" "      [2] Choose major – tags from one X series only"; echo
    text "      [3] Alle verfügbaren Tags anzeigen" "      [3] Show all available tags"; echo
    text "      [4] Version direkt eingeben" "      [4] Enter version directly"; echo
    text "      [0] nicht aktualisieren" "      [0] do not update"; echo
    read_user_input filter_choice "   $(text "Filter" "Filter") [$default_filter_choice]: "
    filter_choice="${filter_choice:-$default_filter_choice}"

    case "$filter_choice" in
        0) return 1 ;;
        1|2)
            prefix=$(get_prefix "$current") || return 1
            mapfile -t majors < <(
                while IFS= read -r candidate; do
                    [[ -n "$candidate" ]] || continue
                    version="${candidate#"$prefix"}"
                    printf '%s\n' "${version%%.*}"
                done <<< "$tags" | sort -Vru
            )
            text "   Verfügbare Major-Versionen:" "   Available major versions:"; echo
            selected_major=$(choose_from_numbered_list "$(text "Major-Auswahl" "Major selection")" 1 "${majors[@]}") || return 1

            if [[ "$filter_choice" == "1" ]]; then
                mapfile -t minors < <(
                    filter_tags_by_major "$current" "$tags" "$selected_major" \
                        | while IFS= read -r candidate; do
                            version="${candidate#"$prefix"}"
                            rest="${version#*.}"
                            printf '%s\n' "${rest%%.*}"
                          done \
                        | sort -Vru
                )
                text "   Verfügbare Minor-Versionen:" "   Available minor versions:"; echo
                selected_minor=$(choose_from_numbered_list "$(text "Minor-Auswahl" "Minor selection")" 1 "${minors[@]}") || return 1
                filtered_tags=$(filter_tags_by_series "$current" "$tags" "$selected_major" "$selected_minor")
            else
                filtered_tags=$(filter_tags_by_major "$current" "$tags" "$selected_major")
            fi
            ;;
        3)
            filtered_tags="$tags"
            ;;
        4)
            read_user_input direct_input "   $(text "Version/Tag direkt eingeben" "Enter version/tag directly"): "
            direct_input="${direct_input//[[:space:]]/}"
            [[ -n "$direct_input" ]] || {
                printf "   ⚠️ %s\n" "$(text "Keine Version eingegeben – übersprungen." "No version entered – skipped.")"
                return 1
            }

            prefix=$(get_prefix "$current") || return 1
            if [[ "$direct_input" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
                candidate="${prefix}${direct_input}"
            else
                candidate="$direct_input"
            fi

            if ! grep -Fxq -- "$candidate" <<< "$tags"; then
                printf "   ⚠️ %s\n" "$(text "Tag '$candidate' ist nicht verfügbar – übersprungen." "Tag '$candidate' is not available – skipped.")"
                return 1
            fi
            if ! version_is_newer "$current" "$candidate"; then
                printf "   ⚠️ %s\n" "$(text "Tag '$candidate' ist nicht neuer als '$current' – übersprungen." "Tag '$candidate' is not newer than '$current' – skipped.")"
                return 1
            fi
            MANUAL_SELECTED_TAG="$candidate"
            return 0
            ;;
        *)
            printf "   ⚠️ %s\n" "$(text "Ungültiger Filter – übersprungen." "Invalid filter – skipped.")"
            return 1
            ;;
    esac

    mapfile -t tag_list < <(
        printf '%s\n' "$filtered_tags" \
            | while IFS= read -r candidate; do
                version_is_newer "$current" "$candidate" && printf '%s\n' "$candidate" || true
              done \
            | sort -Vr
    )

    if (( ${#tag_list[@]} == 0 )); then
        printf "   ℹ️ %s\n" "$(text "Keine neueren Tags für diesen Filter gefunden." "No newer tags found for this filter.")"
        return 1
    fi

    text "   📜 Gefilterte semver-Tags:" "   📜 Filtered semver tags:"; echo
    for i in "${!tag_list[@]}"; do
        printf "      [%d] %s\n" "$((i + 1))" "${tag_list[$i]}"
    done
    text "      [0] nicht aktualisieren" "      [0] do not update"; echo

    read_user_input choice "   $(text "Auswahl" "Selection") [$DEFAULT_MANUAL_SELECTION]: "
    choice="${choice:-$DEFAULT_MANUAL_SELECTION}"

    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    (( choice >= 1 && choice <= ${#tag_list[@]} )) || return 1
    MANUAL_SELECTED_TAG="${tag_list[$((choice - 1))]}"
    return 0
}

select_latest_for_level() {
    local current="$1"
    local tags="$2"
    local level="$3"
    local prefix current_version current_major current_minor current_patch
    local next_minor next_major tag version major minor patch
    local allowed=""

    prefix=$(get_prefix "$current") || return 1
    current_version="${current#"$prefix"}"

    IFS='.' read -r current_major current_minor current_patch <<< "$current_version"
    current_minor="${current_minor:-0}"
    current_patch="${current_patch:-0}"
    next_minor=$((10#$current_minor + 1))
    next_major=$((10#$current_major + 1))

    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        version="${tag#"$prefix"}"
        IFS='.' read -r major minor patch <<< "$version"
        minor="${minor:-0}"
        patch="${patch:-0}"

        case "$level" in
            patch)
                [[ "$major" == "$current_major" && "$minor" == "$current_minor" ]] || continue
                ;;
            next-minor)
                [[ "$major" == "$current_major" && $((10#$minor)) -eq "$next_minor" && $((10#$patch)) -eq 0 ]] || continue
                ;;
            minor)
                [[ "$major" == "$current_major" ]] || continue
                ;;
            next-major)
                [[ $((10#$major)) -eq "$next_major" && $((10#$minor)) -eq 0 && $((10#$patch)) -eq 0 ]] || continue
                ;;
            major)
                ;;
            *)
                return 1
                ;;
        esac

        allowed+="${tag}"$'\n'
    done <<< "$tags"

    printf '%s' "$allowed" | sed '/^$/d' | sort -Vr | head -n1
}

# Liefert Repository und Tag eines Images.
# Images ohne expliziten Tag sowie Digest-Referenzen werden übersprungen.
parse_image() {
    local image="$1"

    if [[ "$image" == *@* ]]; then
        return 1
    fi

    local last_part="${image##*/}"
    if [[ "$last_part" != *:* ]]; then
        return 1
    fi

    IMAGE_REPO="${image%:*}"
    IMAGE_TAG="${image##*:}"

    [[ -n "$IMAGE_REPO" && -n "$IMAGE_TAG" ]]
}

fetch_github_tags() {
    local repo="$1"
    local response

    if ! response=$(curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${repo}/tags?per_page=100"); then
        return 1
    fi

    printf '%s\n' "$response" | jq -r '.[].name'
}

fetch_dockerhub_tags() {
    local repository="$1"
    local url="https://hub.docker.com/v2/repositories/${repository}/tags?page_size=100"
    local response
    local collected=""

    while [[ -n "$url" && "$url" != "null" ]]; do
        if ! response=$(curl -fsSL "$url"); then
            return 1
        fi

        collected+=$'\n'$(printf '%s\n' "$response" | jq -r '.results[]?.name')
        url=$(printf '%s\n' "$response" | jq -r '.next // empty')
    done

    printf '%s\n' "$collected" | sed '/^$/d'
}

fetch_ghcr_tags() {
    local repository="$1"
    local token
    local response

    if ! token=$(curl -fsSL \
        "https://ghcr.io/token?scope=repository:${repository}:pull" \
        | jq -r '.token // empty'); then
        return 1
    fi

    [[ -n "$token" ]] || return 1

    if ! response=$(curl -fsSL \
        -H "Authorization: Bearer $token" \
        "https://ghcr.io/v2/${repository}/tags/list?n=10000"); then
        return 1
    fi

    printf '%s\n' "$response" | jq -r '.tags[]?'
}

register_item() {
    local key="$1"
    local current="$2"
    local latest="$3"
    local tags="$4"
    local type="$5"
    local path="$6"
    local repo="${7:-}"

    ITEMS_ALT["$key"]="$current"
    ITEMS_NEW["$key"]="$latest"
    ITEMS_TAGS["$key"]="$tags"
    ITEMS_TYPE["$key"]="$type"
    ITEMS_PATH["$key"]="$path"
    ITEMS_REPO["$key"]="$repo"
    debug "Registered $key: current=$current latest=${latest:-none} type=$type path=$path repo=$repo"
}

# Löscht Backups erst, wenn sie älter als BACKUP_RETENTION_DAYS sind.
# Unabhängig vom Alter bleiben pro Muster immer mindestens die neuesten
# BACKUP_MIN_KEEP Dateien erhalten.
cleanup_old_backups() {
    local directory="$1"
    local pattern="$2"
    local label="$3"

    [[ -d "$directory" ]] || return 0

    local -a files=()
    mapfile -t files < <(
        find "$directory" -maxdepth 1 -type f -name "$pattern" \
            -printf '%T@ %p\n' \
            | sort -nr \
            | cut -d' ' -f2-
    )

    local index file deleted=0
    for index in "${!files[@]}"; do
        # Die drei neuesten Backups bleiben immer erhalten.
        (( index < BACKUP_MIN_KEEP )) && continue

        file="${files[$index]}"
        if find "$file" -maxdepth 0 -type f -mtime "+${BACKUP_RETENTION_DAYS}" -print -quit \
            | grep -q .; then
            rm -f -- "$file"
            printf "🗑 %s: %s\n" "$(text "Altes $label-Backup gelöscht" "Old $label backup deleted")" "$file"
            ((deleted += 1))
        fi
    done

    if (( deleted == 0 )); then
        info "ℹ️ $(text "Keine alten $label-Backups zu löschen (mindestens $BACKUP_MIN_KEEP bleiben erhalten)." "No old $label backups to delete (at least $BACKUP_MIN_KEEP are retained).")"
    fi
}



reset_version_cache() {
    ITEMS_ALT=(); ITEMS_NEW=(); ITEMS_TAGS=(); ITEMS_TYPE=(); ITEMS_PATH=(); ITEMS_REPO=()
    updates_available=false
}

load_available_versions() {
    reset_version_cache
    info "🔎 $(text "Aktuelle Konfiguration und verfügbare Versionen werden geladen …" "Loading current configuration and available versions …")"
    local plugins plugin module current repo all_tags prefix valid latest
    local images image repo_clean service

    plugins=""
    if [[ "$traefik_config_exists" == true ]]; then
        plugins=$(yq -r '(.experimental.plugins // {}) | keys | .[]' "$TRAEFIK_CONFIG")
    fi
    if [[ -n "$plugins" ]]; then
        while IFS= read -r plugin; do
            [[ -n "$plugin" ]] || continue
            module=$(yq -r ".experimental.plugins[\"$plugin\"].moduleName // empty" "$TRAEFIK_CONFIG")
            current=$(yq -r ".experimental.plugins[\"$plugin\"].version // empty" "$TRAEFIK_CONFIG")
            [[ -n "$module" && -n "$current" ]] || continue
            repo="${module#github.com/}"
            all_tags=$(fetch_github_tags "$repo" 2>/dev/null || true)
            # Ein leeres Präfix ist für reine Semver-Tags wie 1.0.0 gültig.
            # Deshalb den Rückgabestatus von get_prefix prüfen, nicht die Länge.
            prefix=$(get_prefix "$current" 2>/dev/null) || continue
            [[ -n "$all_tags" ]] || continue
            valid=$(semver_filter "$prefix" "$all_tags")
            latest=$(printf '%s\n' "$valid" | sort -Vr | head -n1)
            register_item "plugin:$plugin" "$current" "$latest" "$valid" plugin "$plugin"
        done <<< "$plugins"
    fi

    images=$(yq -r '.services // {} | to_entries[] | select(.value.image != null) | [.key, .value.image] | @tsv' "$COMPOSE_FILE")
    while IFS=$'\t' read -r service image; do
        [[ -n "$service" && -n "$image" ]] || continue
        parse_image "$image" || continue
        repo="$IMAGE_REPO"; current="$IMAGE_TAG"; all_tags=""
        if [[ "$repo" == docker.io/* ]]; then
            repo_clean="${repo#docker.io/}"; [[ "$repo_clean" == */* ]] || repo_clean="library/$repo_clean"
            all_tags=$(fetch_dockerhub_tags "$repo_clean" 2>/dev/null || true)
        elif [[ "$repo" == ghcr.io/* ]]; then
            repo_clean="${repo#ghcr.io/}"
            all_tags=$(fetch_ghcr_tags "$repo_clean" 2>/dev/null || true)
        else
            continue
        fi
        # Ein leeres Präfix ist für reine Semver-Tags wie Gerbil 1.0.0 gültig.
        prefix=$(get_prefix "$current" 2>/dev/null) || continue
        [[ -n "$all_tags" ]] || continue
        valid=$(semver_filter "$prefix" "$all_tags")
        latest=$(printf '%s\n' "$valid" | sort -Vr | head -n1)
        register_item "service:$service" "$current" "$latest" "$valid" image "$service" "$repo"
    done <<< "$images"
    versions_loaded=true
}

show_overview() {
    local key alt neu patch_target next_minor_target minor_target next_major_target major_target status
    updates_available=false
    echo
    echo "════════════════════════════════════════════════════════════════════════════════"
    printf '                     %s\n' "$(text "GESAMT-ÜBERSICHT" "OVERALL OVERVIEW")"
    echo "════════════════════════════════════════════════════════════════════════════════"
    if (( ${#ITEMS_ALT[@]} == 0 )); then
        printf 'ℹ️ %s\n' "$(text "Keine auswertbaren Plugins oder Container gefunden." "No usable plugins or containers found.")"
        return
    fi
    while IFS= read -r key; do
        alt="${ITEMS_ALT[$key]}"; neu="${ITEMS_NEW[$key]}"
        patch_target=$(select_latest_for_level "$alt" "${ITEMS_TAGS[$key]}" patch || true)
        next_minor_target=$(select_latest_for_level "$alt" "${ITEMS_TAGS[$key]}" next-minor || true)
        minor_target=$(select_latest_for_level "$alt" "${ITEMS_TAGS[$key]}" minor || true)
        next_major_target=$(select_latest_for_level "$alt" "${ITEMS_TAGS[$key]}" next-major || true)
        major_target=$(select_latest_for_level "$alt" "${ITEMS_TAGS[$key]}" major || true)
        for v in patch_target next_minor_target minor_target next_major_target major_target; do
            [[ -n "${!v}" && "${!v}" != "$alt" ]] || printf -v "$v" '%s' '-'
        done
        if [[ -z "$neu" ]]; then status="❌ $(text "keine gültigen Tags" "no valid tags")"
        elif [[ "$neu" == "$alt" ]]; then status="✅ $(text "aktuell" "up to date")"
        else status="🔄 $(text "Update verfügbar" "update available")"; updates_available=true; fi
        printf '%s\n' "$key"
        printf '  %s: %s\n' "$(text "Installiert" "Installed")" "$alt"
        printf '  Patch: %s | Next Minor: %s | Latest Minor: %s\n' "$patch_target" "$next_minor_target" "$minor_target"
        printf '  Next Major: %s | Latest Major: %s | %s\n' "$next_major_target" "$major_target" "$status"
        echo "────────────────────────────────────────────────────────────────────────────────"
    done < <(printf '%s\n' "${!ITEMS_ALT[@]}" | sort)
}

human_size() {
    local bytes="${1:-0}"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || printf '%s B\n' "$bytes"
    else
        awk -v b="$bytes" 'BEGIN {
            split("B KiB MiB GiB TiB", u, " "); i=1;
            while (b >= 1024 && i < 5) { b /= 1024; i++ }
            if (i == 1) printf "%.0f %s\n", b, u[i]; else printf "%.1f %s\n", b, u[i]
        }'
    fi
}

collect_container_versions_json() {
    local compose_file="${1:-$COMPOSE_FILE}"
    local result='{}' service image version

    [[ -f "$compose_file" ]] || { printf '%s\n' "$result"; return 0; }

    while IFS=$'\t' read -r service image; do
        [[ -n "$service" ]] || continue
        version="unknown"
        if [[ -n "$image" ]]; then
            if [[ "$image" == *@* ]]; then
                version="digest:${image##*@}"
            elif [[ "${image##*/}" == *:* ]]; then
                version="${image##*:}"
            else
                version="latest"
            fi
        fi
        result=$(jq --arg name "$service" --arg version "$version" '. + {($name): $version}' <<< "$result")
    done < <(yq -r '(.services // {}) | to_entries[] | [.key, (.value.image // "")] | @tsv' "$compose_file" 2>/dev/null || true)

    printf '%s\n' "$result"
}

collect_plugin_versions_json() {
    local traefik_file="${1:-$TRAEFIK_CONFIG}"
    local result='{}' plugin version

    [[ -f "$traefik_file" ]] || { printf '%s\n' "$result"; return 0; }

    while IFS=$'\t' read -r plugin version; do
        [[ -n "$plugin" ]] || continue
        version="${version:-unknown}"
        result=$(jq --arg name "$plugin" --arg version "$version" '. + {($name): $version}' <<< "$result")
    done < <(yq -r '(.experimental.plugins // {}) | to_entries[] | [.key, (.value.version // "unknown")] | @tsv' "$traefik_file" 2>/dev/null || true)

    printf '%s\n' "$result"
}

backup_type_label() {
    case "${1:-unknown}" in
        manual) text "Manuell" "Manual" ;;
        update) text "Update" "Update" ;;
        pre-restore) text "Pre-Restore" "Pre-restore" ;;
        *) printf '%s' "${1:-unknown}" ;;
    esac
}

metadata_value() {
    local file="$1" filter="$2" fallback="${3:-unknown}"
    local value
    [[ -f "$file" ]] || { printf '%s\n' "$fallback"; return 0; }
    value=$(jq -r "$filter // empty" "$file" 2>/dev/null || true)
    [[ -n "$value" && "$value" != null ]] && printf '%s\n' "$value" || printf '%s\n' "$fallback"
}

show_backup_details() {
    local dir="$1"
    local metadata="$dir/metadata.json"
    local created docker_v compose_v size_h type hostname created_by working_directory os_name kernel architecture
    local containers_json plugins_json key value

    created=$(metadata_value "$metadata" '.created_display' "$(basename "$dir" | sed 's/_/ /; s/-/:/3')")
    docker_v=$(metadata_value "$metadata" '.docker_version')
    compose_v=$(metadata_value "$metadata" '.compose_version')
    size_h=$(metadata_value "$metadata" '.statistics.backup_size_human' "$(human_size "$(du -sb "$dir" 2>/dev/null | awk '{print $1}' || echo 0)")")
    type=$(backup_type_label "$(metadata_value "$metadata" '.backup_type')")
    hostname=$(metadata_value "$metadata" '.hostname')
    created_by=$(metadata_value "$metadata" '.created_by')
    working_directory=$(metadata_value "$metadata" '.working_directory')
    os_name=$(metadata_value "$metadata" '.os')
    kernel=$(metadata_value "$metadata" '.kernel')
    architecture=$(metadata_value "$metadata" '.architecture')

    containers_json=$(jq -c '(.containers // {}) + (if .pangolin_version then {pangolin: .pangolin_version} else {} end) + (if .gerbil_version then {gerbil: .gerbil_version} else {} end)' "$metadata" 2>/dev/null || printf '{}')
    plugins_json=$(jq -c '.plugins // {}' "$metadata" 2>/dev/null || printf '{}')

    echo
    echo "════════════════════════════════════════════════════════"
    printf '                 %s\n' "$(text "Backup-Informationen" "Backup information")"
    echo "════════════════════════════════════════════════════════"
    printf '%-19s: %s\n' "$(text "Datum" "Date")" "$created"
    printf '%-19s: %s\n' "Hostname" "$hostname"
    printf '%-19s: %s\n' "$(text "Benutzer" "User")" "$created_by"
    printf '%-19s: %s\n' "$(text "Arbeitsverzeichnis" "Working directory")" "$working_directory"

    echo
    echo "────────────────────────────────────────────────────────"
    printf '%s\n' "$(text "Container" "Containers")"
    echo "────────────────────────────────────────────────────────"
    if [[ "$(jq 'length' <<< "$containers_json")" -eq 0 ]]; then
        printf '  %s\n' "$(text "Keine Containerinformationen gespeichert." "No container information stored.")"
    else
        while IFS=$'\t' read -r key value; do
            printf '  %-22s %s\n' "$key" "$value"
        done < <(jq -r 'to_entries | sort_by(.key)[] | [.key, .value] | @tsv' <<< "$containers_json")
    fi

    echo
    echo "────────────────────────────────────────────────────────"
    printf '%s\n' "Plugins"
    echo "────────────────────────────────────────────────────────"
    if [[ "$(jq 'length' <<< "$plugins_json")" -eq 0 ]]; then
        printf '  %s\n' "$(text "Keine Plugininformationen gespeichert." "No plugin information stored.")"
    else
        while IFS=$'\t' read -r key value; do
            printf '  %-22s %s\n' "$key" "$value"
        done < <(jq -r 'to_entries | sort_by(.key)[] | [.key, .value] | @tsv' <<< "$plugins_json")
    fi

    echo
    echo "────────────────────────────────────────────────────────"
    printf '%s\n' "System"
    echo "────────────────────────────────────────────────────────"
    printf '  %-22s %s\n' "Docker" "$docker_v"
    printf '  %-22s %s\n' "Compose" "$compose_v"
    printf '  %-22s %s\n' "OS" "$os_name"
    printf '  %-22s %s\n' "Kernel" "$kernel"
    printf '  %-22s %s\n' "$(text "Architektur" "Architecture")" "$architecture"

    echo
    echo "────────────────────────────────────────────────────────"
    printf '%s\n' "Backup"
    echo "────────────────────────────────────────────────────────"
    printf '  %-22s %s\n' "$(text "Typ" "Type")" "$type"
    printf '  %-22s %s\n' "$(text "Größe" "Size")" "$size_h"
    echo
    printf '%s\n' "$(text "Enthalten:" "Included:")"
    for entry in \
        "config:config.tar.gz" \
        "docker-compose.yml:docker-compose.yml" \
        "branding:branding.tar.gz" \
        "traefik_config.yml:traefik_config.yml" \
        ".env:.env"; do
        local label="${entry%%:*}" file="${entry#*:}"
        if [[ -e "$dir/$file" ]]; then printf '  ✓ %s\n' "$label"; else printf '  ✗ %s\n' "$label"; fi
    done
    echo
}

create_backup_set() {
    local backup_type="${1:-manual}" stop_answer="no" stamp dir stopped=false
    local docker_version compose_version containers_json plugins_json
    local os_name kernel architecture created_by working_directory
    local config_sha compose_sha branding_sha services_count plugins_count backup_size_bytes backup_size_human
    local has_config=false has_compose=true has_traefik=false has_branding=false has_env=false

    stamp=$(date +%F_%H-%M-%S)
    dir="$BACKUP_SET_DIR/$stamp"
    mkdir -p "$dir"
    stop_answer=$(prompt_yes_no "$(text "⏹ Container für ein konsistenteres Backup stoppen?" "⏹ Stop containers for a more consistent backup?")" "$STOP_CONTAINERS_FOR_BACKUP" "$DEFAULT_STOP_CONTAINERS_FOR_BACKUP")
    if [[ "$stop_answer" == yes ]]; then
        docker compose -f "$COMPOSE_FILE" stop
        stopped=true
    fi
    if [[ -d ./config ]]; then tar -czf "$dir/config.tar.gz" ./config; has_config=true; fi
    if [[ -d ./branding ]]; then tar -czf "$dir/branding.tar.gz" ./branding; has_branding=true; fi
    cp -- "$COMPOSE_FILE" "$dir/docker-compose.yml"
    if [[ -f "$TRAEFIK_CONFIG" ]]; then cp -- "$TRAEFIK_CONFIG" "$dir/traefik_config.yml"; has_traefik=true; fi
    if [[ -f "$ENV_FILE" ]]; then cp -- "$ENV_FILE" "$dir/.env"; has_env=true; fi

    docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || docker --version 2>/dev/null || printf 'unknown')
    compose_version=$(docker compose version --short 2>/dev/null || docker compose version 2>/dev/null || printf 'unknown')
    containers_json=$(collect_container_versions_json "$COMPOSE_FILE")
    plugins_json=$(collect_plugin_versions_json "$TRAEFIK_CONFIG")
    os_name=$(awk -F= '$1=="PRETTY_NAME" {gsub(/^"|"$/, "", $2); print $2}' /etc/os-release 2>/dev/null || true)
    os_name="${os_name:-unknown}"
    kernel=$(uname -r 2>/dev/null || printf 'unknown')
    architecture=$(uname -m 2>/dev/null || printf 'unknown')
    created_by=$(id -un 2>/dev/null || printf 'unknown')
    working_directory=$(pwd -P)
    config_sha=$([[ -f "$dir/config.tar.gz" ]] && sha256sum "$dir/config.tar.gz" | awk '{print $1}' || printf '')
    compose_sha=$(sha256sum "$dir/docker-compose.yml" | awk '{print $1}')
    branding_sha=$([[ -f "$dir/branding.tar.gz" ]] && sha256sum "$dir/branding.tar.gz" | awk '{print $1}' || printf '')
    services_count=$(yq -r '(.services // {}) | length' "$COMPOSE_FILE" 2>/dev/null || printf '0')
    plugins_count=$([[ -f "$TRAEFIK_CONFIG" ]] && yq -r '(.experimental.plugins // {}) | length' "$TRAEFIK_CONFIG" 2>/dev/null || printf '0')
    backup_size_bytes=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
    backup_size_bytes="${backup_size_bytes:-0}"
    backup_size_human=$(human_size "$backup_size_bytes")

    jq -n \
        --arg created "$(date --iso-8601=seconds)" \
        --arg created_display "$(date '+%F %H:%M')" \
        --arg script_version "$SCRIPT_VERSION" \
        --arg hostname "$(hostname)" \
        --arg created_by "$created_by" \
        --arg working_directory "$working_directory" \
        --arg os "$os_name" \
        --arg kernel "$kernel" \
        --arg architecture "$architecture" \
        --arg docker_version "$docker_version" \
        --arg compose_version "$compose_version" \
        --argjson containers "$containers_json" \
        --argjson plugin_versions "$plugins_json" \
        --arg backup_type "$backup_type" \
        --arg config_sha256 "$config_sha" \
        --arg compose_sha256 "$compose_sha" \
        --arg branding_sha256 "$branding_sha" \
        --arg backup_size_human "$backup_size_human" \
        --argjson includes_config "$has_config" \
        --argjson includes_compose "$has_compose" \
        --argjson includes_traefik "$has_traefik" \
        --argjson includes_branding "$has_branding" \
        --argjson includes_env "$has_env" \
        --argjson services "$services_count" \
        --argjson plugins "$plugins_count" \
        --argjson backup_size_bytes "$backup_size_bytes" \
        '{
            created: $created,
            created_display: $created_display,
            script_version: $script_version,
            hostname: $hostname,
            created_by: $created_by,
            working_directory: $working_directory,
            os: $os,
            kernel: $kernel,
            architecture: $architecture,
            docker_version: $docker_version,
            compose_version: $compose_version,
            containers: $containers,
            plugins: $plugin_versions,
            backup_type: $backup_type,
            includes: {
                config: $includes_config,
                docker_compose: $includes_compose,
                traefik_config: $includes_traefik,
                branding: $includes_branding,
                env_file: $includes_env
            },
            checksums: {
                config: $config_sha256,
                docker_compose: $compose_sha256,
                branding: $branding_sha256
            },
            statistics: {
                services: $services,
                plugins: $plugins,
                backup_size_bytes: $backup_size_bytes,
                backup_size_human: $backup_size_human
            }
        }' > "$dir/metadata.json"

    # Größe nach Erstellung der Metadatei nochmals exakt erfassen.
    backup_size_bytes=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
    backup_size_bytes="${backup_size_bytes:-0}"
    backup_size_human=$(human_size "$backup_size_bytes")
    jq --argjson bytes "$backup_size_bytes" --arg human "$backup_size_human" \
        '.statistics.backup_size_bytes = $bytes | .statistics.backup_size_human = $human' \
        "$dir/metadata.json" > "$dir/metadata.json.tmp"
    mv -- "$dir/metadata.json.tmp" "$dir/metadata.json"

    printf '✅ %s: %s\n' "$(text "Backup-Satz erstellt" "Backup set created")" "$dir"
    if [[ "$stopped" == true ]]; then
        if [[ "$backup_type" == update ]]; then
            BACKUP_CONTAINERS_STOPPED=true
            info "ℹ️ $(text "Die Container bleiben bis zur Update-Entscheidung gestoppt." "The containers remain stopped until the update decision.")"
        else
            docker compose -f "$COMPOSE_FILE" start
        fi
    fi
    cleanup_backup_sets
    LAST_BACKUP_DIR="$dir"
}
cleanup_backup_sets() {
    [[ -d "$BACKUP_SET_DIR" ]] || return 0
    local -a dirs=(); local i dir
    mapfile -t dirs < <(find "$BACKUP_SET_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
    for i in "${!dirs[@]}"; do
        (( i < BACKUP_MIN_KEEP )) && continue
        dir="${dirs[$i]}"
        if find "$dir" -maxdepth 0 -mtime "+$BACKUP_RETENTION_DAYS" -print -quit | grep -q .; then rm -rf -- "$dir"; fi
    done
}

select_backup_set() {
    local requested="${1:-}" choice i=1 dir metadata created pangolin gerbil size_h type
    local -a sets=()
    if [[ -n "$requested" ]]; then
        [[ "$requested" = /* ]] || requested="$(pwd)/$requested"
        [[ -d "$requested" ]] || { printf '❌ %s\n' "$(text "Backup-Verzeichnis nicht gefunden: $requested" "Backup directory not found: $requested")" >&2; return 1; }
        SELECTED_BACKUP_SET="$requested"; return 0
    fi
    mapfile -t sets < <(find "$BACKUP_SET_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort -r)
    (( ${#sets[@]} > 0 )) || { printf 'ℹ️ %s\n' "$(text "Keine Backup-Sätze gefunden." "No backup sets found.")"; return 1; }
    echo
    echo "════════════════════════════════════════════════════════"
    printf '                 %s\n' "$(text "Verfügbare Backups" "Available backups")"
    echo "════════════════════════════════════════════════════════"
    for dir in "${sets[@]}"; do
        metadata="$dir/metadata.json"
        created=$(metadata_value "$metadata" '.created_display' "$(basename "$dir" | sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})-([0-9]{2}).*/\1 \2:\3/')")
        pangolin=$(metadata_value "$metadata" '.containers.pangolin // .pangolin_version')
        gerbil=$(metadata_value "$metadata" '.containers.gerbil // .gerbil_version')
        size_h=$(metadata_value "$metadata" '.statistics.backup_size_human' "$(human_size "$(du -sb "$dir" 2>/dev/null | awk '{print $1}' || echo 0)")")
        type=$(backup_type_label "$(metadata_value "$metadata" '.backup_type')")
        printf '[%d] %s\n' "$i" "$created"
        printf '    %-9s: %s\n' 'Pangolin' "$pangolin"
        printf '    %-9s: %s\n' 'Gerbil' "$gerbil"
        printf '    %-9s: %s\n' "$(text "Größe" "Size")" "$size_h"
        printf '    %-9s: %s\n' "$(text "Typ" "Type")" "$type"
        echo
        ((i+=1))
    done
    printf '[0] %s\n' "$(text "Zurück" "Back")"
    read_user_input choice "$(text "Auswahl" "Selection") [$DEFAULT_RESTORE_SELECTION]: "
    choice="${choice:-$DEFAULT_RESTORE_SELECTION}"
    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    (( choice > 0 && choice <= ${#sets[@]} )) || return 1
    SELECTED_BACKUP_SET="${sets[$((choice-1))]}"
}

restore_backup_set() {
    local requested="${1:-}" setdir safety_stamp safety_dir confirm
    SELECTED_BACKUP_SET=""
    select_backup_set "$requested" || return 0
    setdir="$SELECTED_BACKUP_SET"
    [[ -f "$setdir/docker-compose.yml" ]] || { printf '❌ %s\n' "$(text "docker-compose.yml fehlt im Backup." "docker-compose.yml is missing from backup.")" >&2; return 1; }
    show_backup_details "$setdir"
    confirm=$(prompt_yes_no "$(text "Restore starten?" "Start restore?")" ask no)
    [[ "$confirm" == yes ]] || return 0
    safety_stamp=$(date +%F_%H-%M-%S); safety_dir="$PRE_RESTORE_BACKUP_DIR/$safety_stamp"; mkdir -p "$safety_dir"
    [[ -d ./config ]] && tar -czf "$safety_dir/config.tar.gz" ./config
    [[ -d ./branding ]] && tar -czf "$safety_dir/branding.tar.gz" ./branding
    cp -- "$COMPOSE_FILE" "$safety_dir/docker-compose.yml"
    [[ -f "$ENV_FILE" ]] && cp -- "$ENV_FILE" "$safety_dir/.env"
    docker compose -f "$COMPOSE_FILE" stop
    rm -rf ./config
    [[ -f "$setdir/config.tar.gz" ]] && tar -xzf "$setdir/config.tar.gz" -C "$(pwd)"
    if [[ -f "$setdir/branding.tar.gz" ]]; then
        rm -rf ./branding
        tar -xzf "$setdir/branding.tar.gz" -C "$(pwd)"
    fi
    cp -- "$setdir/docker-compose.yml" "$COMPOSE_FILE"
    [[ -f "$setdir/.env" ]] && cp -- "$setdir/.env" "$ENV_FILE"
    if docker compose -f "$COMPOSE_FILE" up -d --pull never; then
        printf '✅ %s\n' "$(text "Backup erfolgreich zurückgespielt." "Backup restored successfully.")"
        traefik_config_exists=false; [[ -f "$TRAEFIK_CONFIG" ]] && traefik_config_exists=true
        load_available_versions; show_overview
        return 0
    fi
    printf '❌ %s\n' "$(text "Restore fehlgeschlagen; Sicherheitsbackup wird zurückgespielt." "Restore failed; restoring safety backup.")" >&2
    rm -rf ./config
    [[ -f "$safety_dir/config.tar.gz" ]] && tar -xzf "$safety_dir/config.tar.gz" -C "$(pwd)"
    if [[ -f "$safety_dir/branding.tar.gz" ]]; then
        rm -rf ./branding
        tar -xzf "$safety_dir/branding.tar.gz" -C "$(pwd)"
    fi
    cp -- "$safety_dir/docker-compose.yml" "$COMPOSE_FILE"
    [[ -f "$safety_dir/.env" ]] && cp -- "$safety_dir/.env" "$ENV_FILE"
    docker compose -f "$COMPOSE_FILE" up -d --pull never || true
    return 1
}

apply_update() {
    local key="$1" new_tag="$2" type="${ITEMS_TYPE[$key]}" path="${ITEMS_PATH[$key]}"
    if [[ "$type" == plugin ]]; then
        yq -i -Y ".experimental.plugins[\"$path\"].version = \"$new_tag\"" "$TRAEFIK_CONFIG"
        traefik_changed=true; printf '  🔧 %s → %s\n' "$path" "$new_tag"
    else
        local repo_img="${ITEMS_REPO[$key]}"
        [[ -n "$repo_img" ]] || {
            printf '  ❌ %s
' "$(text "Repository für Service '$path' konnte nicht bestimmt werden." "Repository for service '$path' could not be determined.")" >&2
            return 1
        }
        yq -i -Y ".services[\"$path\"].image = \"$repo_img:$new_tag\"" "$COMPOSE_FILE"
        compose_changed=true; printf '  🐳 %s (%s) → %s
' "$path" "$repo_img" "$new_tag"
    fi
}

run_update_action() {
    [[ "$updates_available" == true ]] || { printf '✅ %s\n' "$(text "Keine Updates verfügbar." "No updates available.")"; return 0; }
    local update_mode update_level key alt allowed_latest neu selected_tag compose_answer revert_answer
    traefik_changed=false; compose_changed=false
    update_mode=$(resolve_update_mode)
    if [[ "$update_mode" == auto ]]; then
        update_level=$(resolve_update_level)
        [[ "$update_level" != cancel ]] || return 0
        create_backup_set update
        while IFS= read -r key; do
            alt="${ITEMS_ALT[$key]}"
            allowed_latest=$(select_latest_for_level "$alt" "${ITEMS_TAGS[$key]}" "$update_level" || true)
            [[ -n "$allowed_latest" && "$allowed_latest" != "$alt" ]] && apply_update "$key" "$allowed_latest"
        done < <(printf '%s\n' "${!ITEMS_ALT[@]}" | sort)
    elif [[ "$update_mode" == manual ]]; then
        create_backup_set update
        while IFS= read -r key; do
            alt="${ITEMS_ALT[$key]}"; neu="${ITEMS_NEW[$key]}"; [[ -n "$neu" && "$neu" != "$alt" ]] || continue
            printf '\n➡️ %s (%s: %s)\n' "$key" "$(text "aktuell" "current")" "$alt"
            MANUAL_SELECTED_TAG=""; manual_select_tag "$alt" "${ITEMS_TAGS[$key]}" || true; selected_tag="$MANUAL_SELECTED_TAG"
            [[ -n "$selected_tag" ]] && apply_update "$key" "$selected_tag"
        done < <(printf '%s\n' "${!ITEMS_ALT[@]}" | sort)
    else
        if [[ "$BACKUP_CONTAINERS_STOPPED" == true ]]; then docker compose -f "$COMPOSE_FILE" start; BACKUP_CONTAINERS_STOPPED=false; fi
        return 0
    fi
    if [[ "$traefik_changed" != true && "$compose_changed" != true ]]; then
        printf 'ℹ️ %s\n' "$(text "Keine Dateien geändert." "No files changed.")"
        if [[ "$BACKUP_CONTAINERS_STOPPED" == true ]]; then docker compose -f "$COMPOSE_FILE" start; BACKUP_CONTAINERS_STOPPED=false; fi
        return 0
    fi
    compose_answer=$(prompt_yes_no "$(text "🚀 Änderungen anwenden (pull + up -d)?" "🚀 Apply changes (pull + up -d)?")" "$RUN_COMPOSE" "$DEFAULT_RUN_COMPOSE")
    if [[ "$compose_answer" == yes ]]; then
        if docker compose -f "$COMPOSE_FILE" pull && docker compose -f "$COMPOSE_FILE" up -d; then
            BACKUP_CONTAINERS_STOPPED=false
        else
            printf '❌ %s\n' "$(text "Update fehlgeschlagen. Vorhandene Container werden wieder gestartet." "Update failed. Restarting existing containers.")" >&2
            [[ "$BACKUP_CONTAINERS_STOPPED" == true ]] && docker compose -f "$COMPOSE_FILE" start || true
            BACKUP_CONTAINERS_STOPPED=false
            return 1
        fi
        printf '🎉 %s\n' "$(text "Update erfolgreich angewendet." "Update applied successfully.")"
        load_available_versions; show_overview
    else
        revert_answer=$(prompt_yes_no "$(text "Nicht angewendete YAML-Änderungen aus dem Backup zurücknehmen?" "Revert unapplied YAML changes from backup?")" ask "$DEFAULT_REVERT_UNAPPLIED_CHANGES")
        if [[ "$revert_answer" == yes ]]; then
            cp -- "$LAST_BACKUP_DIR/docker-compose.yml" "$COMPOSE_FILE"
            [[ -f "$LAST_BACKUP_DIR/traefik_config.yml" ]] && cp -- "$LAST_BACKUP_DIR/traefik_config.yml" "$TRAEFIK_CONFIG"
            printf '↩️ %s\n' "$(text "Änderungen zurückgenommen." "Changes reverted.")"
        fi
        if [[ "$BACKUP_CONTAINERS_STOPPED" == true ]]; then
            docker compose -f "$COMPOSE_FILE" start
            BACKUP_CONTAINERS_STOPPED=false
        fi
    fi
}


compose_services() {
    yq -r '.services | keys | .[]' "$COMPOSE_FILE" 2>/dev/null || true
}

compose_images() {
    # `docker compose config --images` resolves variables from .env. Fall back
    # to direct YAML parsing when the installed Compose version lacks it.
    if docker compose -f "$COMPOSE_FILE" config --images >/dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" config --images 2>/dev/null | sed '/^$/d' | sort -u
    else
        yq -r '.services[] | select(.image != null) | .image' "$COMPOSE_FILE" 2>/dev/null | sed '/^null$/d' | sort -u
    fi
}

compose_image_repository() {
    local image="$1" without_digest last_component
    without_digest="${image%%@*}"
    last_component="${without_digest##*/}"
    if [[ "$last_component" == *:* ]]; then
        printf '%s\n' "${without_digest%:*}"
    else
        printf '%s\n' "$without_digest"
    fi
}

pause_menu() {
    local ignored
    [[ "$UNATTENDED" == true ]] && return 0
    read_user_input ignored "$(text "Weiter mit Enter" "Press Enter to continue")..."
}

show_container_status() {
    echo
    echo "════════════════════════════════════════════════════════"
    printf '                 %s\n' "$(text "Container-Status" "Container status")"
    echo "════════════════════════════════════════════════════════"
    docker compose -f "$COMPOSE_FILE" ps -a || true
}

select_compose_service() {
    local prompt="${1:-$(text "Service auswählen" "Select service")}" choice i=1 service
    local -a services=()
    mapfile -t services < <(compose_services)
    (( ${#services[@]} > 0 )) || return 1
    echo
    for service in "${services[@]}"; do
        printf '[%d] %s\n' "$i" "$service"
        ((i+=1))
    done
    printf '[0] %s\n' "$(text "Zurück" "Back")"
    read_user_input choice "$prompt: "
    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    (( choice > 0 && choice <= ${#services[@]} )) || return 1
    SELECTED_SERVICE="${services[$((choice-1))]}"
}

container_management_menu() {
    local choice confirm service
    while true; do
        echo
        echo "════════════════════════════════════════════════════════"
        printf '              %s\n' "$(text "Containerverwaltung" "Container management")"
        echo "════════════════════════════════════════════════════════"
        printf '[1] %s\n' "$(text "Alle Container starten" "Start all containers")"
        printf '[2] %s\n' "$(text "Alle Container stoppen" "Stop all containers")"
        printf '[3] %s\n' "$(text "Alle Container neu starten" "Restart all containers")"
        printf '[4] %s\n' "$(text "Status anzeigen" "Show status")"
        printf '[5] %s\n' "$(text "Logs eines Containers anzeigen" "Show container logs")"
        printf '[0] %s\n' "$(text "Zurück" "Back")"
        read_user_input choice "$(text "Auswahl" "Selection"): "
        case "$choice" in
            1)
                confirm=$(prompt_yes_no "$(text "Alle Compose-Container starten?" "Start all Compose containers?")" ask yes)
                [[ "$confirm" == yes ]] && docker compose -f "$COMPOSE_FILE" up -d
                ;;
            2)
                confirm=$(prompt_yes_no "$(text "Alle Compose-Container stoppen?" "Stop all Compose containers?")" ask no)
                [[ "$confirm" == yes ]] && docker compose -f "$COMPOSE_FILE" stop
                ;;
            3)
                confirm=$(prompt_yes_no "$(text "Alle Compose-Container neu starten?" "Restart all Compose containers?")" ask no)
                [[ "$confirm" == yes ]] && docker compose -f "$COMPOSE_FILE" restart
                ;;
            4) show_container_status; pause_menu ;;
            5)
                SELECTED_SERVICE=""
                if select_compose_service "$(text "Container für Logs auswählen" "Select container for logs")"; then
                    service="$SELECTED_SERVICE"
                    docker compose -f "$COMPOSE_FILE" logs --tail=200 "$service" || true
                    pause_menu
                fi
                ;;
            0) return 0 ;;
            *) printf '⚠️ %s\n' "$(text "Ungültige Auswahl." "Invalid selection.")" ;;
        esac
    done
}

get_dashboard_url() {
    local config_file="./config/config.yml"
    local url=""
    [[ -f "$config_file" ]] || return 1
    url=$(yq -r '.app.dashboard_url // empty' "$config_file" 2>/dev/null || true)
    url="${url%\"}"; url="${url#\"}"
    url="${url%\'}"; url="${url#\'}"
    [[ -n "$url" && "$url" != null ]] || return 1
    printf '%s\n' "$url"
}

url_host() {
    local url="$1" authority
    authority="${url#*://}"
    authority="${authority%%/*}"
    authority="${authority##*@}"
    if [[ "$authority" == \[*\]* ]]; then
        printf '%s\n' "${authority%%]*}]"
    else
        printf '%s\n' "${authority%%:*}"
    fi
}

http_probe() {
    local url="$1" code
    code=$(curl -k -sS -L -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 12 "$url" 2>/dev/null || true)
    if [[ "$code" =~ ^[123][0-9][0-9]$ ]]; then
        printf '[✓] %-8s %s — HTTP %s\n' "${url%%:*}" "$url" "$code"
        return 0
    fi
    printf '[✗] %-8s %s — HTTP %s\n' "${url%%:*}" "$url" "${code:-000}"
    return 1
}

normalize_port_spec() {
    local spec="$1" protocol="tcp" left right host_port container_port
    spec="${spec%%/*}/${spec##*/}"
    if [[ "$spec" == */tcp || "$spec" == */udp ]]; then
        protocol="${spec##*/}"
        spec="${spec%/*}"
    fi
    right="${spec##*:}"
    left="${spec%:*}"
    if [[ "$left" == "$spec" ]]; then
        host_port="$right"; container_port="$right"
    else
        container_port="$right"
        host_port="${left##*:}"
    fi
    host_port="${host_port%%-*}"
    container_port="${container_port%%-*}"
    [[ "$host_port" =~ ^[0-9]+$ && "$container_port" =~ ^[0-9]+$ ]] || return 1
    printf '%s\t%s\t%s\n' "$host_port" "$container_port" "$protocol"
}

collect_gerbil_ports() {
    local raw
    if docker compose -f "$COMPOSE_FILE" config --format json >/dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null |
            jq -r '.services.gerbil.ports[]? | if type=="object" then [(.published|tostring),(.target|tostring),(.protocol//"tcp")] | @tsv else . end' |
            while IFS= read -r raw; do
                if [[ "$raw" == *$'\t'* ]]; then printf '%s\n' "$raw"; else normalize_port_spec "$raw" || true; fi
            done
    else
        yq -r '.services.gerbil.ports[]? | tostring' "$COMPOSE_FILE" 2>/dev/null |
            while IFS= read -r raw; do normalize_port_spec "$raw" || true; done
    fi
}

collect_traefik_entrypoints() {
    [[ -f "$TRAEFIK_CONFIG" ]] || return 0
    yq -r '(.entryPoints // {}) | to_entries[] | [.key, (.value.address // "")] | @tsv' "$TRAEFIK_CONFIG" 2>/dev/null |
        while IFS=$'\t' read -r name address; do
            local protocol="tcp" port
            [[ "$address" == */udp ]] && protocol="udp"
            address="${address%/tcp}"; address="${address%/udp}"
            port="${address##*:}"
            [[ "$port" =~ ^[0-9]+$ ]] && printf '%s\t%s\t%s\n' "$name" "$port" "$protocol"
        done
}

host_port_listener() {
    local port="$1" protocol="$2"
    if command -v ss >/dev/null 2>&1; then
        if [[ "$protocol" == tcp ]]; then
            ss -H -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {found=1} END{exit !found}'
        else
            ss -H -lun 2>/dev/null | awk -v p=":$port" '$5 ~ p"$" || $4 ~ p"$" {found=1} END{exit !found}'
        fi
    else
        return 2
    fi
}

get_pangolin_tunnel_ports() {
    local config_file="./config/config.yml" site_port="51820" client_port="21820"
    if [[ -f "$config_file" ]]; then
        site_port=$(yq -r '.gerbil.start_port // 51820' "$config_file" 2>/dev/null || printf '51820')
        client_port=$(yq -r '.gerbil.clients_start_port // 21820' "$config_file" 2>/dev/null || printf '21820')
    fi
    [[ "$site_port" =~ ^[0-9]+$ ]] || site_port="51820"
    [[ "$client_port" =~ ^[0-9]+$ ]] || client_port="21820"
    printf '%s\t%s\n' "$site_port" "$client_port"
}

FIREWALL_TYPE="none"
FIREWALL_NAME=""

detect_host_firewall() {
    FIREWALL_TYPE="none"
    FIREWALL_NAME=""

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        FIREWALL_TYPE="ufw"; FIREWALL_NAME="UFW"; return 0
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qx running; then
        FIREWALL_TYPE="firewalld"; FIREWALL_NAME="firewalld"; return 0
    fi
    if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -Eq 'hook[[:space:]]+input'; then
        FIREWALL_TYPE="nftables"; FIREWALL_NAME="nftables"; return 0
    fi
    if command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -Eq '^-P INPUT (DROP|REJECT)|^-A INPUT '; then
        FIREWALL_TYPE="iptables"; FIREWALL_NAME="iptables"; return 0
    fi
    return 1
}

# Return values: 0=explicitly allowed, 1=blocked/no matching allow, 2=unknown.
firewall_port_status() {
    local port="$1" protocol="$2" rules default_zone
    case "$FIREWALL_TYPE" in
        ufw)
            rules=$(ufw status 2>/dev/null || true)
            grep -Eiq "(^|[[:space:]])${port}/${protocol}([[:space:]]|$).*ALLOW" <<<"$rules" && return 0
            grep -Eiq "(^|[[:space:]])${port}([[:space:]]|$).*ALLOW" <<<"$rules" && return 0
            grep -Eiq "(^|[[:space:]])${port}/${protocol}([[:space:]]|$).*(DENY|REJECT)" <<<"$rules" && return 1
            return 2
            ;;
        firewalld)
            default_zone=$(firewall-cmd --get-default-zone 2>/dev/null || true)
            [[ -n "$default_zone" ]] || return 2
            firewall-cmd --zone="$default_zone" --query-port="${port}/${protocol}" >/dev/null 2>&1 && return 0
            # Standard services may open the port without a direct port rule.
            [[ "$protocol/$port" == "tcp/80" ]] && firewall-cmd --zone="$default_zone" --query-service=http >/dev/null 2>&1 && return 0
            [[ "$protocol/$port" == "tcp/443" ]] && firewall-cmd --zone="$default_zone" --query-service=https >/dev/null 2>&1 && return 0
            return 1
            ;;
        nftables)
            rules=$(nft list ruleset 2>/dev/null || true)
            grep -Eiq "${protocol}[[:space:]]+dport[[:space:]]+(${port}|\{[^}]*\b${port}\b[^}]*\}).*(accept|counter.*accept)" <<<"$rules" && return 0
            grep -Eiq "${protocol}[[:space:]]+dport[[:space:]]+(${port}|\{[^}]*\b${port}\b[^}]*\}).*(drop|reject)" <<<"$rules" && return 1
            return 2
            ;;
        iptables)
            rules=$(iptables -S INPUT 2>/dev/null || true)
            grep -Eiq -- "-p ${protocol} .*--dport ${port} .*-(j|g) ACCEPT" <<<"$rules" && return 0
            grep -Eiq -- "-p ${protocol} .*--dport ${port} .*-(j|g) (DROP|REJECT)" <<<"$rules" && return 1
            grep -q '^-P INPUT ACCEPT' <<<"$rules" && return 0
            return 2
            ;;
        *) return 2 ;;
    esac
}

print_firewall_port_result() {
    local port="$1" protocol="$2" warnings_ref="$3" status
    if firewall_port_status "$port" "$protocol"; then
        printf '    [✓] %s %s %s\n' "${protocol^^}" "$port" "$(text "durch Host-Firewall erlaubt" "allowed by host firewall")"
    else
        status=$?
        if (( status == 1 )); then
            printf '    [!] %s %s %s\n' "${protocol^^}" "$port" "$(text "nicht erlaubt oder blockiert" "not allowed or blocked")"
            eval "$warnings_ref=$(( ${!warnings_ref} + 1 ))"
        else
            printf '    [i] %s %s %s\n' "${protocol^^}" "$port" "$(text "Regel nicht eindeutig bestimmbar" "rule could not be determined reliably")"
        fi
    fi
}

check_host_firewall() {
    local warnings_ref="$1" site_port="$2" client_port="$3" has_quic="$4"
    echo
    printf '%s\n' "$(text "Host-Firewall" "Host firewall")"
    echo "────────────────────────────────────────────────────────"
    if ! detect_host_firewall; then
        printf '[i] %s\n' "$(text "Keine aktive Host-Firewall erkannt." "No active host firewall detected.")"
        return 0
    fi
    printf '[✓] %s %s\n' "$FIREWALL_NAME" "$(text "aktiv" "active")"
    print_firewall_port_result 80 tcp "$warnings_ref"
    print_firewall_port_result 443 tcp "$warnings_ref"
    print_firewall_port_result "$site_port" udp "$warnings_ref"
    print_firewall_port_result "$client_port" udp "$warnings_ref"
    [[ "$has_quic" == true ]] && print_firewall_port_result 443 udp "$warnings_ref"
}

check_pangolin_ports() {
    local dashboard_url="$1" host="$2" errors_ref="$3" warnings_ref="$4"
    local published target protocol label required raw name ep_port ep_protocol site_port client_port has_quic=false
    local -a standard=()
    local -A gerbil_map=() entry_map=()

    IFS=$'\t' read -r site_port client_port < <(get_pangolin_tunnel_ports)
    standard=("${site_port}:udp:site tunnel" "${client_port}:udp:client tunnel" "80:tcp:non-SSL resources" "443:tcp:SSL resources")

    while IFS=$'\t' read -r published target protocol; do
        [[ -n "$published" ]] || continue
        gerbil_map["$published/$protocol"]="$target"
        [[ "$published/$protocol" == "443/udp" ]] && has_quic=true
    done < <(collect_gerbil_ports)
    while IFS=$'\t' read -r name ep_port ep_protocol; do
        [[ -n "$ep_port" ]] || continue
        entry_map["$ep_port/$ep_protocol"]="$name"
    done < <(collect_traefik_entrypoints)

    echo
    printf '%s\n' "$(text "Pangolin-Ports" "Pangolin ports")"
    echo "────────────────────────────────────────────────────────"
    for raw in "${standard[@]}"; do
        IFS=: read -r published protocol label <<< "$raw"
        if [[ -n "${gerbil_map[$published/$protocol]:-}" ]]; then
            printf '[✓] %-9s %-22s %s\n' "$published/$protocol" "$label" "$(text "in Gerbil veröffentlicht" "published by Gerbil")"
        else
            printf '[✗] %-9s %-22s %s\n' "$published/$protocol" "$label" "$(text "fehlt in Gerbil" "missing from Gerbil")"
            eval "$errors_ref=$(( ${!errors_ref} + 1 ))"
            continue
        fi
        if host_port_listener "$published" "$protocol"; then
            printf '    [✓] %s\n' "$(text "Host-Listener aktiv" "host listener active")"
        else
            printf '    [✗] %s\n' "$(text "kein Host-Listener erkannt" "no host listener detected")"
            eval "$errors_ref=$(( ${!errors_ref} + 1 ))"
        fi
        if [[ "$protocol" == tcp && -n "$host" && "$ENABLE_EXTERNAL_TCP_TEST" == true ]]; then
            if timeout "$TCP_TEST_TIMEOUT" bash -c "</dev/tcp/$host/$published" >/dev/null 2>&1; then
                printf '    [✓] %s:%s %s\n' "$host" "$published" "$(text "per TCP erreichbar" "reachable via TCP")"
            else
                printf '    [!] %s:%s %s\n' "$host" "$published" "$(text "TCP-Erreichbarkeit von diesem Host fehlgeschlagen" "TCP reachability from this host failed")"
                eval "$warnings_ref=$(( ${!warnings_ref} + 1 ))"
            fi
        elif [[ "$protocol" == tcp ]]; then
            printf '    [i] %s\n' "$(text "Externer TCP-Test deaktiviert oder kein Dashboard-Host erkannt." "External TCP test disabled or no dashboard host detected.")"
        else
            printf '    [i] %s\n' "$(text "Externe UDP-Erreichbarkeit kann nicht automatisch geprüft werden." "External UDP connectivity cannot be verified automatically.")"
            printf '    [i] %s\n' "$(text "Externe Cloud-/Provider-Firewalls können für UDP nicht automatisch geprüft werden." "External cloud/provider firewalls cannot be verified automatically for UDP.")"
        fi
    done

    if [[ "$has_quic" == true ]]; then
        echo
        printf '[✓] %-9s %-22s %s\n' '443/udp' 'HTTP/3 / QUIC' "$(text "optional, in Gerbil veröffentlicht" "optional, published by Gerbil")"
        if host_port_listener 443 udp; then
            printf '    [✓] %s\n' "$(text "Host-Listener aktiv" "host listener active")"
        else
            printf '    [!] %s\n' "$(text "kein Host-Listener erkannt" "no host listener detected")"
            eval "$warnings_ref=$(( ${!warnings_ref} + 1 ))"
        fi
        printf '    [i] %s\n' "$(text "Externe UDP-Erreichbarkeit kann nicht automatisch geprüft werden." "External UDP connectivity cannot be verified automatically.")"
    else
        echo
        printf '[i] %-9s %-22s %s\n' '443/udp' 'HTTP/3 / QUIC' "$(text "optional, nicht aktiviert" "optional, not enabled")"
    fi

    check_host_firewall "$warnings_ref" "$site_port" "$client_port" "$has_quic"

    echo
    printf '%s\n' "$(text "Raw-Resource-Portabgleich" "Raw resource port consistency")"
    echo "────────────────────────────────────────────────────────"
    required=0
    while IFS=$'\t' read -r published target protocol; do
        [[ -n "$published" ]] || continue
        case "$published/$protocol" in
            "$site_port/udp"|"$client_port/udp"|80/tcp|443/tcp|443/udp) continue ;;
        esac
        required=1
        name="${entry_map[$target/$protocol]:-${entry_map[$published/$protocol]:-}}"
        printf '• Gerbil %-9s → container %-9s' "$published/$protocol" "$target/$protocol"
        if [[ -n "$name" ]]; then
            printf ' [✓] Traefik entryPoint: %s\n' "$name"
        else
            printf ' [✗] %s\n' "$(text "kein passender Traefik-entryPoint" "no matching Traefik entryPoint")"
            eval "$errors_ref=$(( ${!errors_ref} + 1 ))"
        fi
        if [[ "$protocol" == tcp && "$name" != tcp-* ]]; then
            printf '    [!] %s\n' "$(text "Empfohlener Name: tcp-$target" "Recommended name: tcp-$target")"
        elif [[ "$protocol" == udp && "$name" != udp-* ]]; then
            printf '    [!] %s\n' "$(text "Empfohlener Name: udp-$target" "Recommended name: udp-$target")"
        fi
        if host_port_listener "$published" "$protocol"; then
            printf '    [✓] %s\n' "$(text "Host-Listener aktiv" "host listener active")"
        else
            printf '    [✗] %s\n' "$(text "kein Host-Listener erkannt" "no host listener detected")"
            eval "$errors_ref=$(( ${!errors_ref} + 1 ))"
        fi
    done < <(collect_gerbil_ports)
    (( required == 1 )) || printf '[–] %s\n' "$(text "Keine zusätzlichen Raw-Resource-Ports gefunden." "No additional raw resource ports found.")"

    while IFS=$'\t' read -r name ep_port ep_protocol; do
        [[ "$name" == tcp-* || "$name" == udp-* ]] || continue
        if [[ -z "${gerbil_map[$ep_port/$ep_protocol]:-}" ]]; then
            printf '[!] Traefik %-18s %s/%s — %s\n' "$name" "$ep_port" "$ep_protocol" "$(text "nicht in Gerbil veröffentlicht" "not published by Gerbil")"
            eval "$warnings_ref=$(( ${!warnings_ref} + 1 ))"
        fi
    done < <(collect_traefik_entrypoints)
}

system_diagnostics() {
    local errors=0 warnings=0 service ps_json state health status image url answer dashboard_url host
    local compose_ok=false traefik_ok=false
    echo
    echo "════════════════════════════════════════════════════════"
    printf '                 %s\n' "$(text "Systemdiagnose" "System diagnostics")"
    echo "════════════════════════════════════════════════════════"

    if docker info >/dev/null 2>&1; then printf '[✓] %s\n' "$(text "Docker-Daemon erreichbar" "Docker daemon reachable")"; else printf '[✗] %s\n' "$(text "Docker-Daemon nicht erreichbar" "Docker daemon not reachable")"; ((errors+=1)); fi
    if docker compose version >/dev/null 2>&1; then printf '[✓] %s\n' "$(text "Docker Compose verfügbar" "Docker Compose available")"; else printf '[✗] %s\n' "$(text "Docker Compose nicht verfügbar" "Docker Compose unavailable")"; ((errors+=1)); fi
    if [[ -S /var/run/docker.sock ]]; then printf '[✓] %s\n' "$(text "Docker-Socket vorhanden" "Docker socket present")"; else printf '[!] %s\n' "$(text "Docker-Socket /var/run/docker.sock nicht gefunden" "Docker socket /var/run/docker.sock not found")"; ((errors+=1)); fi

    echo
    printf '%s\n' "$(text "Container" "Containers")"
    echo "────────────────────────────────────────────────────────"
    while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        ps_json=$(docker compose -f "$COMPOSE_FILE" ps -a --format json "$service" 2>/dev/null || true)
        if [[ -z "$ps_json" ]]; then printf '[✗] %-22s %s\n' "$service" "$(text "nicht erstellt" "not created")"; ((errors+=1)); continue; fi
        state=$(printf '%s\n' "$ps_json" | jq -r 'if type=="array" then (.[0].State // "unknown") else (.State // "unknown") end' 2>/dev/null || printf 'unknown')
        health=$(printf '%s\n' "$ps_json" | jq -r 'if type=="array" then (.[0].Health // "") else (.Health // "") end' 2>/dev/null || true)
        status=$(printf '%s\n' "$ps_json" | jq -r 'if type=="array" then (.[0].Status // "") else (.Status // "") end' 2>/dev/null || true)
        case "${state,,}" in
            running)
                if [[ "${health,,}" == unhealthy ]]; then
                    printf '[✗] %-22s %-28s | health=%s\n' "$service" "${status:-Up}" "$health"; ((errors+=1))
                elif [[ -n "$health" ]]; then
                    printf '[✓] %-22s %-28s | health=%s\n' "$service" "${status:-Up}" "$health"
                else
                    printf '[✓] %-22s %-28s | Running\n' "$service" "${status:-Up}"
                fi ;;
            restarting|exited|dead|paused) printf '[✗] %-22s %s\n' "$service" "${status:-$state}"; ((errors+=1)) ;;
            *) printf '[!] %-22s %s\n' "$service" "${status:-$state}"; ((errors+=1)) ;;
        esac
    done < <(compose_services)

    echo
    printf '%s\n' "$(text "Images" "Images")"
    echo "────────────────────────────────────────────────────────"
    while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        if docker image inspect "$image" >/dev/null 2>&1; then printf '[✓] %s\n' "$image"; else printf '[✗] %s — %s\n' "$image" "$(text "fehlt" "missing")"; ((errors+=1)); fi
    done < <(compose_images)

    echo
    printf '%s\n' "$(text "Konfiguration" "Configuration")"
    echo "────────────────────────────────────────────────────────"
    if docker compose -f "$COMPOSE_FILE" config -q >/dev/null 2>&1; then printf '[✓] %s\n' "$COMPOSE_FILE"; compose_ok=true; else printf '[✗] %s — %s\n' "$COMPOSE_FILE" "$(text "ungültig" "invalid")"; ((errors+=1)); fi
    if [[ -f "$TRAEFIK_CONFIG" ]] && yq '.' "$TRAEFIK_CONFIG" >/dev/null 2>&1; then printf '[✓] %s\n' "$TRAEFIK_CONFIG"; traefik_ok=true; else printf '[✗] %s — %s\n' "$TRAEFIK_CONFIG" "$(text "fehlt oder ungültig" "missing or invalid")"; ((errors+=1)); fi
    [[ -f "$ENV_FILE" ]] && printf '[✓] %s\n' "$ENV_FILE" || printf '[i] %s — %s\n' "$ENV_FILE" "$(text "optional, nicht vorhanden" "optional, not present")"
    [[ -d ./config ]] && printf '[✓] %s\n' './config' || { printf '[!] %s — %s\n' './config' "$(text "fehlt" "missing")"; ((errors+=1)); }

    dashboard_url=$(get_dashboard_url 2>/dev/null || true)
    host=""; [[ -n "$dashboard_url" ]] && host=$(url_host "$dashboard_url")
    echo
    printf '%s\n' "$(text "Pangolin-Erreichbarkeit" "Pangolin reachability")"
    echo "────────────────────────────────────────────────────────"
    if [[ -n "$dashboard_url" ]]; then
        printf '[✓] dashboard_url: %s\n' "$dashboard_url"
        answer=$(prompt_yes_no "$(text "HTTP- und HTTPS-Test ausführen?" "Run HTTP and HTTPS tests?")" ask yes)
        if [[ "$answer" == yes ]]; then
            http_probe "http://$host" || ((errors+=1))
            http_probe "https://$host" || ((errors+=1))
        else
            printf '[–] %s\n' "$(text "HTTP/HTTPS-Test übersprungen" "HTTP/HTTPS test skipped")"
        fi
    else
        printf '[✗] %s\n' "$(text "app.dashboard_url in ./config/config.yml nicht gefunden" "app.dashboard_url not found in ./config/config.yml")"
        ((errors+=1))
    fi

    check_pangolin_ports "$dashboard_url" "$host" errors warnings

    echo
    echo "────────────────────────────────────────────────────────"
    printf '%s: %d\n' "$(text "Fehler" "Errors")" "$errors"
    printf '%s: %d\n' "$(text "Warnungen" "Warnings")" "$warnings"
    (( errors == 0 ))
}

outdated_compose_images() {
    local current repo candidate used_refs used_ids candidate_id current_id
    local -A current_refs=() current_ids=() repos=()
    while IFS= read -r current; do
        [[ -n "$current" ]] || continue
        current_refs["$current"]=1
        current_id=$(docker image inspect --format '{{.Id}}' "$current" 2>/dev/null || true)
        [[ -n "$current_id" ]] && current_ids["$current_id"]=1
        repo=$(compose_image_repository "$current")
        repos["$repo"]=1
    done < <(compose_images)
    used_refs=$(docker ps -a --format '{{.Image}}' 2>/dev/null || true)
    used_ids=$(docker ps -aq 2>/dev/null | xargs -r docker inspect --format '{{.Image}}' 2>/dev/null | sort -u || true)
    docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | while IFS= read -r candidate; do
        [[ -n "$candidate" && "$candidate" != '<none>:<none>' ]] || continue
        repo=$(compose_image_repository "$candidate")
        [[ -n "${repos[$repo]:-}" ]] || continue
        [[ -z "${current_refs[$candidate]:-}" ]] || continue
        grep -Fxq "$candidate" <<<"$used_refs" && continue
        candidate_id=$(docker image inspect --format '{{.Id}}' "$candidate" 2>/dev/null || true)
        [[ -n "$candidate_id" ]] || continue
        [[ -z "${current_ids[$candidate_id]:-}" ]] || continue
        grep -Fxq "$candidate_id" <<<"$used_ids" && continue
        printf '%s\n' "$candidate"
    done | sort -u
}

remove_outdated_compose_images() {
    local confirm image removed=0
    local -a candidates=()
    mapfile -t candidates < <(outdated_compose_images)
    if (( ${#candidates[@]} == 0 )); then
        printf '✅ %s\n' "$(text "Keine veralteten, unbenutzten Compose-Images gefunden." "No outdated, unused Compose images found.")"
        pause_menu; return 0
    fi
    echo
    printf '%s (%d):\n' "$(text "Folgende veraltete, unbenutzte Images wurden gefunden" "The following outdated, unused images were found")" "${#candidates[@]}"
    printf '  - %s\n' "${candidates[@]}"
    confirm=$(prompt_yes_no "$(text "Diese Images endgültig löschen?" "Permanently remove these images?")" ask no)
    [[ "$confirm" == yes ]] || return 0
    for image in "${candidates[@]}"; do
        if docker image rm "$image"; then ((removed+=1)); else printf '⚠️ %s\n' "$(text "Konnte nicht gelöscht werden: $image" "Could not remove: $image")"; fi
    done
    printf '✅ %s: %d\n' "$(text "Gelöschte Images" "Removed images")" "$removed"
    pause_menu
}

system_cleanup_menu() {
    local choice confirm
    while true; do
        echo
        echo "════════════════════════════════════════════════════════"
        printf '               %s\n' "$(text "Systembereinigung" "System cleanup")"
        echo "════════════════════════════════════════════════════════"
        printf '[1] %s\n' "$(text "Veraltete, unbenutzte Compose-Images entfernen" "Remove outdated, unused Compose images")"
        printf '[2] %s\n' "$(text "Dangling Images entfernen" "Remove dangling images")"
        printf '[3] %s\n' "$(text "Docker-Speicherübersicht" "Docker disk usage")"
        printf '[0] %s\n' "$(text "Zurück" "Back")"
        read_user_input choice "$(text "Auswahl" "Selection"): "
        case "$choice" in
            1) remove_outdated_compose_images ;;
            2)
                confirm=$(prompt_yes_no "$(text "Alle ungetaggten, unbenutzten Images löschen?" "Remove all untagged, unused images?")" ask no)
                [[ "$confirm" == yes ]] && docker image prune -f
                pause_menu
                ;;
            3) docker system df; pause_menu ;;
            0) return 0 ;;
            *) printf '⚠️ %s\n' "$(text "Ungültige Auswahl." "Invalid selection.")" ;;
        esac
    done
}

show_main_menu() {
    echo
    echo "════════════════════════════════════════════════════════════════════════════════"
    printf '[1] %s\n' "$(text "Update" "Update")"
    printf '[2] %s\n' "$(text "Backup erstellen" "Create backup")"
    printf '[3] %s\n' "$(text "Backup wiederherstellen" "Restore backup")"
    printf '[4] %s\n' "$(text "Versionen erneut prüfen" "Check versions again")"
    printf '[5] %s\n' "$(text "Containerverwaltung" "Container management")"
    printf '[6] %s\n' "$(text "Systemdiagnose" "System diagnostics")"
    printf '[7] %s\n' "$(text "Systembereinigung" "System cleanup")"
    printf '[8] %s\n' "$(text "Skript-Update prüfen" "Check for script update")"
    printf '[0] %s\n' "$(text "Beenden" "Exit")"
}

main_menu() {
    local choice
    while true; do
        show_main_menu
        read_user_input choice "$(text "Auswahl" "Selection"): "
        case "$choice" in
            1) run_update_action ;;
            2) create_backup_set manual ;;
            3) restore_backup_set ;;
            4) load_available_versions; show_overview ;;
            5) container_management_menu ;;
            6) system_diagnostics ;;
            7) system_cleanup_menu ;;
            8) check_script_update true; pause_menu ;;
            0) printf '%s\n' "$(text "Beendet." "Exited.")"; return 0 ;;
            *) printf '⚠️ %s\n' "$(text "Ungültige Auswahl." "Invalid selection.")" ;;
        esac
    done
}

main() {
    if [[ "$DIRECT_ACTION" == --self-update ]]; then
        check_script_update true "$@"
        exit $?
    fi

    # Check for a newer Maintenance Tool version before loading container data.
    check_script_update false "$@"

    if [[ "$SHOW_SCRIPT_INFO" == true && "$QUIET" != true ]]; then
        echo "========================================================="
        printf '        %s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        echo "========================================================="
    fi
    case "$DIRECT_ACTION" in
        --backup) create_backup_set manual; exit $? ;;
        --restore) restore_backup_set "$DIRECT_ARGUMENT"; exit $? ;;
        --check) load_available_versions; show_overview; exit $? ;;
        --diagnose) system_diagnostics; exit $? ;;
        --start) docker compose -f "$COMPOSE_FILE" up -d; exit $? ;;
        --stop) docker compose -f "$COMPOSE_FILE" stop; exit $? ;;
        --restart) docker compose -f "$COMPOSE_FILE" restart; exit $? ;;
        '' ) ;;
        *) printf '❌ %s\n' "$(text "Unbekannte Option: $DIRECT_ACTION" "Unknown option: $DIRECT_ACTION")" >&2; exit 2 ;;
    esac
    load_available_versions
    show_overview
    if [[ "$UNATTENDED" == true ]]; then run_update_action; else main_menu; fi
}

main "$@"

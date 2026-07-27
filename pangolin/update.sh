#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Script Information (fixed metadata)
# =============================================================================

SCRIPT_NAME="Pangolin Update Script"
SCRIPT_VERSION="1.1"

# =============================================================================
# Environment Configuration
# All variables below can be overridden when calling the script.
# Example:
#   LANGUAGE=en UNATTENDED=true UPDATE_MODE=auto UPDATE_LEVEL=minor \
#   RUN_COMPOSE=yes CONFIG_BACKUP=yes QUIET=true ./update.sh
# =============================================================================

# Language
LANGUAGE="${LANGUAGE:-de}"                            # de | en

# Output
SHOW_SCRIPT_INFO="${SHOW_SCRIPT_INFO:-true}"          # true | false
DEBUG="${DEBUG:-false}"                               # true | false
QUIET="${QUIET:-false}"                               # true | false

# Execution
UNATTENDED="${UNATTENDED:-false}"                     # true | false

# Update Configuration
UPDATE_MODE="${UPDATE_MODE:-ask}"                     # ask | auto | manual | none
UPDATE_LEVEL="${UPDATE_LEVEL:-ask}"                   # ask | patch | minor | major
DEFAULT_UPDATE_MODE="${DEFAULT_UPDATE_MODE:-none}"    # auto | manual | none
DEFAULT_UPDATE_LEVEL="${DEFAULT_UPDATE_LEVEL:-patch}" # patch | minor | major
DEFAULT_MANUAL_SELECTION="${DEFAULT_MANUAL_SELECTION:-0}" # 0 = skip, or tag list number

# Docker Compose
RUN_COMPOSE="${RUN_COMPOSE:-ask}"                     # ask | yes | no
DEFAULT_RUN_COMPOSE="${DEFAULT_RUN_COMPOSE:-yes}"     # yes | no

# Backups
CONFIG_BACKUP="${CONFIG_BACKUP:-ask}"                 # ask | yes | no
DEFAULT_CONFIG_BACKUP="${DEFAULT_CONFIG_BACKUP:-yes}" # yes | no
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
BACKUP_MIN_KEEP="${BACKUP_MIN_KEEP:-3}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
YAML_BACKUP_DIR="${YAML_BACKUP_DIR:-$BACKUP_DIR/yaml}"
CONFIG_BACKUP_DIR="${CONFIG_BACKUP_DIR:-$BACKUP_DIR/config}"

# Files
TRAEFIK_CONFIG="${TRAEFIK_CONFIG:-./config/traefik/traefik_config.yml}"
COMPOSE_FILE="${COMPOSE_FILE:-./docker-compose.yml}"

case "${LANGUAGE,,}" in
    de|en) LANGUAGE="${LANGUAGE,,}" ;;
    *)
        echo "Invalid LANGUAGE '$LANGUAGE'. Allowed values: de, en." >&2
        exit 2
        ;;
esac

# Returns the German or English text without appending a newline.
text() {
    local de="$1"
    local en="$2"
    if [[ "$LANGUAGE" == "de" ]]; then
        printf '%s' "$de"
    else
        printf '%s' "$en"
    fi
}

normalize_true_false() {
    case "${1,,}" in
        true|1|yes|y|on) printf 'true\n' ;;
        false|0|no|n|off) printf 'false\n' ;;
        *) return 1 ;;
    esac
}

SHOW_SCRIPT_INFO=$(normalize_true_false "$SHOW_SCRIPT_INFO") || {
    printf "❌ %s\n" "$(text "Ungültiger Wert für SHOW_SCRIPT_INFO: $SHOW_SCRIPT_INFO" "Invalid value for SHOW_SCRIPT_INFO: $SHOW_SCRIPT_INFO")" >&2
    exit 2
}

DEBUG=$(normalize_true_false "$DEBUG") || {
    printf "❌ %s\n" "$(text "Ungültiger Wert für DEBUG: $DEBUG" "Invalid value for DEBUG: $DEBUG")" >&2
    exit 2
}

QUIET=$(normalize_true_false "$QUIET") || {
    printf "❌ %s\n" "$(text "Ungültiger Wert für QUIET: $QUIET" "Invalid value for QUIET: $QUIET")" >&2
    exit 2
}

info() {
    [[ "$QUIET" == "true" ]] || printf '%s\n' "$*"
}

debug() {
    [[ "$DEBUG" == "true" ]] && printf 'DEBUG: %s\n' "$*" >&2 || true
}

if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    exit 0
fi

if [[ "$SHOW_SCRIPT_INFO" == "true" && "$QUIET" != "true" ]]; then
    printf '%s %s\n\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
fi

for cmd in curl jq yq docker; do
    command -v "$cmd" >/dev/null 2>&1 || {
        printf "❌ %s\n" "$(text "'$cmd' fehlt." "'$cmd' is missing.")"
        exit 1
    }
done

[[ -f "$COMPOSE_FILE" ]] || {
    printf "❌ %s\n" "$(text "$COMPOSE_FILE wurde nicht gefunden." "$COMPOSE_FILE was not found.")"
    exit 1
}

# Die Traefik-Konfiguration darf fehlen, wenn keine Plugins verwendet werden.
traefik_config_exists=false
if [[ -f "$TRAEFIK_CONFIG" ]]; then
    traefik_config_exists=true
fi

TIMESTAMP=$(date +%F_%H-%M-%S)
debug "LANGUAGE=$LANGUAGE UNATTENDED=$UNATTENDED UPDATE_MODE=$UPDATE_MODE UPDATE_LEVEL=$UPDATE_LEVEL RUN_COMPOSE=$RUN_COMPOSE CONFIG_BACKUP=$CONFIG_BACKUP"
debug "COMPOSE_FILE=$COMPOSE_FILE TRAEFIK_CONFIG=$TRAEFIK_CONFIG BACKUP_DIR=$BACKUP_DIR"
mkdir -p "$YAML_BACKUP_DIR"

TRAEFIK_BACKUP="$YAML_BACKUP_DIR/traefik_config_${TIMESTAMP}.yml"
COMPOSE_BACKUP="$YAML_BACKUP_DIR/docker-compose_${TIMESTAMP}.yml"

if [[ "$traefik_config_exists" == true ]]; then
    cp -- "$TRAEFIK_CONFIG" "$TRAEFIK_BACKUP"
fi
cp -- "$COMPOSE_FILE" "$COMPOSE_BACKUP"
info "📦 $(text "YAML-Backups erstellt" "YAML backups created"): $YAML_BACKUP_DIR"

traefik_changed=false
compose_changed=false

declare -A ITEMS_ALT=()
declare -A ITEMS_NEW=()
declare -A ITEMS_TAGS=()
declare -A ITEMS_TYPE=()
declare -A ITEMS_PATH=()

###############################################################
# Hilfsfunktionen
###############################################################

normalize_bool() {
    case "${1,,}" in
        y|yes|true|1|on) printf 'yes\n' ;;
        n|no|false|0|off) printf 'no\n' ;;
        ask|'') printf 'ask\n' ;;
        *) return 1 ;;
    esac
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
    [[ "$default_value" == "yes" ]] && suffix="Y/n" || suffix="y/N"
    read -r -p "$prompt ($suffix): " answer
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
    read -r -p "$(text "Auswahl" "Selection") [$default_choice]: " choice
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
        minor) default_choice=2 ;;
        major) default_choice=3 ;;
        *)
            printf "❌ %s\n" "$(text "Ungültiger DEFAULT_UPDATE_LEVEL: $DEFAULT_UPDATE_LEVEL" "Invalid DEFAULT_UPDATE_LEVEL: $DEFAULT_UPDATE_LEVEL")" >&2
            return 2
            ;;
    esac

    case "$level" in
        patch|minor|major)
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
    text "   [1] Patch  – nur X.Y.Z → X.Y.neu" "   [1] Patch  – only X.Y.Z → X.Y.new" >&2; echo >&2
    text "   [2] Minor  – innerhalb derselben Major-Version" "   [2] Minor  – within the same major version" >&2; echo >&2
    text "   [3] Major  – neueste Version derselben Tag-Variante" "   [3] Major  – newest version of the same tag variant" >&2; echo >&2
    read -r -p "$(text "Auswahl" "Selection") [$default_choice]: " choice
    choice="${choice:-$default_choice}"

    case "$choice" in
        1) printf 'patch\n' ;;
        2) printf 'minor\n' ;;
        3) printf 'major\n' ;;
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
# minor: gleiche Major-Version
# major: jede neuere Version innerhalb derselben Tag-Variante / desselben Präfixes
select_latest_for_level() {
    local current="$1"
    local tags="$2"
    local level="$3"
    local prefix current_version current_major current_minor
    local tag version major minor
    local allowed=""

    prefix=$(get_prefix "$current") || return 1
    current_version="${current#"$prefix"}"

    IFS='.' read -r current_major current_minor _ <<< "$current_version"
    current_minor="${current_minor:-0}"

    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        version="${tag#"$prefix"}"
        IFS='.' read -r major minor _ <<< "$version"
        minor="${minor:-0}"

        case "$level" in
            patch)
                [[ "$major" == "$current_major" && "$minor" == "$current_minor" ]] || continue
                ;;
            minor)
                [[ "$major" == "$current_major" ]] || continue
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

    ITEMS_ALT["$key"]="$current"
    ITEMS_NEW["$key"]="$latest"
    ITEMS_TAGS["$key"]="$tags"
    ITEMS_TYPE["$key"]="$type"
    ITEMS_PATH["$key"]="$path"
    debug "Registered $key: current=$current latest=${latest:-none} type=$type"
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

###############################################################
# 1️⃣ Optionale Traefik-Plugins prüfen
###############################################################

plugins=""
if [[ "$traefik_config_exists" == true ]]; then
    plugins=$(yq -r '(.experimental.plugins // {}) | keys | .[]' "$TRAEFIK_CONFIG")
fi

if [[ -z "$plugins" ]]; then
    info "ℹ️ $(text "Keine Traefik-Plugins konfiguriert – übersprungen." "No Traefik plugins configured – skipped.")"
else
    while IFS= read -r plugin; do
        [[ -n "$plugin" ]] || continue

        module=$(yq -r ".experimental.plugins[\"$plugin\"].moduleName // empty" "$TRAEFIK_CONFIG")
        current=$(yq -r ".experimental.plugins[\"$plugin\"].version // empty" "$TRAEFIK_CONFIG")

        if [[ -z "$module" || -z "$current" ]]; then
            printf "⚠️ %s\n" "$(text "Plugin '$plugin' hat keine gültige moduleName/version – übersprungen." "Plugin '$plugin' has no valid moduleName/version – skipped.")"
            continue
        fi

        repo="${module#github.com/}"

        if ! all_tags=$(fetch_github_tags "$repo"); then
            printf "⚠️ %s\n" "$(text "Tags für Plugin '$plugin' konnten nicht geladen werden – übersprungen." "Tags for plugin '$plugin' could not be loaded – skipped.")"
            continue
        fi

        if ! prefix=$(get_prefix "$current"); then
            printf "⚠️ %s\n" "$(text "Versionstag '$current' hat kein unterstütztes Format – übersprungen." "Version tag '$current' has an unsupported format – skipped.")"
            continue
        fi

        valid=$(semver_filter "$prefix" "$all_tags")
        latest=$(printf '%s\n' "$valid" | sort -Vr | head -n1)

        register_item \
            "plugin:$plugin" "$current" "$latest" "$valid" \
            "plugin" "$plugin"
    done <<< "$plugins"
fi

###############################################################
# 2️⃣ Vorhandene Docker-Compose-Container prüfen
###############################################################

# Nur tatsächlich vorhandene Services werden eingelesen.
# Optionale Container wie GeoIPUpdate oder CrowdSec dürfen fehlen.
images=$(yq -r '.services // {} | .[] | .image? // empty' "$COMPOSE_FILE")

if [[ -z "$images" ]]; then
    info "ℹ️ $(text "Keine Images in docker-compose.yml gefunden." "No images found in docker-compose.yml.")"
else
    while IFS= read -r image; do
        [[ -n "$image" ]] || continue

        if ! parse_image "$image"; then
            printf "⚠️ %s\n" "$(text "Image '$image' hat keinen auswertbaren Tag oder nutzt einen Digest – übersprungen." "Image '$image' has no usable tag or uses a digest – skipped.")"
            continue
        fi

        repo="$IMAGE_REPO"
        current="$IMAGE_TAG"
        all_tags=""

        if [[ "$repo" == docker.io/* ]]; then
            repo_clean="${repo#docker.io/}"

            # Offizielle Docker-Hub-Images liegen im Namespace library/.
            if [[ "$repo_clean" != */* ]]; then
                repo_clean="library/$repo_clean"
            fi

            if ! all_tags=$(fetch_dockerhub_tags "$repo_clean"); then
                printf "⚠️ %s\n" "$(text "Docker-Hub-Tags für '$image' konnten nicht geladen werden – übersprungen." "Docker Hub tags for '$image' could not be loaded – skipped.")"
                continue
            fi

        elif [[ "$repo" == ghcr.io/* ]]; then
            repo_clean="${repo#ghcr.io/}"

            if ! all_tags=$(fetch_ghcr_tags "$repo_clean"); then
                printf "⚠️ %s\n" "$(text "GHCR-Tags für '$image' konnten nicht geladen werden – übersprungen." "GHCR tags for '$image' could not be loaded – skipped.")"
                continue
            fi

        else
            printf "⚠️ %s\n" "$(text "Registry von '$image' wird nicht unterstützt – übersprungen." "Registry for '$image' is not supported – skipped.")"
            continue
        fi

        if ! prefix=$(get_prefix "$current"); then
            printf "⚠️ %s\n" "$(text "Versionstag '$current' hat kein unterstütztes Format – übersprungen." "Version tag '$current' has an unsupported format – skipped.")"
            continue
        fi

        valid=$(semver_filter "$prefix" "$all_tags")
        latest=$(printf '%s\n' "$valid" | sort -Vr | head -n1)

        register_item \
            "image:$image" "$current" "$latest" "$valid" \
            "image" "$image"
    done <<< "$images"
fi

###############################################################
# 3️⃣ Gesamtübersicht
###############################################################

echo ""
echo "=============================="
text "📋 GESAMT-ÜBERSICHT" "📋 OVERVIEW"; echo
echo "=============================="

updates_available=false

if [[ ${#ITEMS_ALT[@]} -eq 0 ]]; then
    printf "ℹ️ %s\n" "$(text "Keine auswertbaren Plugins oder Container gefunden." "No usable plugins or containers found.")"
else
    while IFS= read -r key; do
        alt="${ITEMS_ALT[$key]}"
        neu="${ITEMS_NEW[$key]}"

        if [[ -z "$neu" ]]; then
            status="$(text "❌ keine gültigen semver-Tags" "❌ no valid semver tags")"
        elif [[ "$alt" == "$neu" ]]; then
            status="$(text "✅ aktuell" "✅ up to date")"
        else
            status="$(text "🔄 Update möglich" "🔄 update available")"
            updates_available=true
        fi

        printf "%-50s | %s: %-14s | %s: %-14s | %s\n" \
            "$key" "$(text "ALT" "OLD")" "$alt" "$(text "NEU" "NEW")" "$neu" "$status"
    done < <(printf '%s\n' "${!ITEMS_ALT[@]}" | sort)
fi

###############################################################
# 4️⃣ Updates automatisch oder manuell übernehmen
###############################################################

apply_update() {
    local key="$1"
    local new_tag="$2"
    local type="${ITEMS_TYPE[$key]}"
    local path="${ITEMS_PATH[$key]}"

    if [[ "$type" == "plugin" ]]; then
        yq -i -Y \
            ".experimental.plugins[\"$path\"].version = \"$new_tag\"" \
            "$TRAEFIK_CONFIG"
        traefik_changed=true
        echo "   🔧 Plugin $path → $new_tag"
    else
        local repo_img="${path%:*}"
        yq -i -Y \
            "(.services[] | select(.image == \"$path\") | .image) = \"$repo_img:$new_tag\"" \
            "$COMPOSE_FILE"
        compose_changed=true
        echo "   🐳 Image $path → $new_tag"
    fi
}

if [[ "$updates_available" == true ]]; then
    echo ""
    update_mode=$(resolve_update_mode)

    if [[ "$update_mode" == "auto" ]]; then
        update_level=$(resolve_update_level)
        echo ""
        printf "🚀 %s\n" "$(text "Automatische Updates werden übernommen (Stufe: $update_level) …" "Automatic updates are being applied (level: $update_level) …")"

        while IFS= read -r key; do
            alt="${ITEMS_ALT[$key]}"
            allowed_latest=$(select_latest_for_level \
                "$alt" "${ITEMS_TAGS[$key]}" "$update_level" || true)

            if [[ -z "$allowed_latest" || "$alt" == "$allowed_latest" ]]; then
                printf "   ⏸ %s\n" "$(text "$key: kein zulässiges $update_level-Update" "$key: no permitted $update_level update")"
                continue
            fi

            apply_update "$key" "$allowed_latest"
        done < <(printf '%s\n' "${!ITEMS_ALT[@]}" | sort)

    elif [[ "$update_mode" == "manual" ]]; then
        if [[ "$UNATTENDED" =~ ^(true|1|yes|on)$ ]]; then
            printf "⚠️ %s\n" "$(text "Manuelle Auswahl ist im unbeaufsichtigten Modus nicht möglich – übersprungen." "Manual selection is unavailable in unattended mode – skipped.")"
        else
            echo ""
            echo "=============================="
            text "🎛 MANUELLE AUSWAHL" "🎛 MANUAL SELECTION"; echo
            echo "=============================="

            while IFS= read -r key; do
                alt="${ITEMS_ALT[$key]}"
                neu="${ITEMS_NEW[$key]}"

                [[ -n "$neu" && "$alt" != "$neu" ]] || continue

                echo ""
                echo "➡️ $key"
                printf "   %s: %s\n" "$(text "ALT" "OLD")" "$alt"
                printf "   %s: %s\n" "$(text "NEU" "NEW")" "$neu"
                text "   📜 Verfügbare semver-Tags:" "   📜 Available semver tags:"; echo

                mapfile -t tag_list < <(printf '%s\n' "${ITEMS_TAGS[$key]}" | sort -Vr)

                for i in "${!tag_list[@]}"; do
                    printf "      [%d] %s\n" "$((i + 1))" "${tag_list[$i]}"
                done
                text "      [0] nicht aktualisieren" "      [0] do not update"; echo

                read -r -p "   $(text "Auswahl" "Selection") [$DEFAULT_MANUAL_SELECTION]: " choice
                choice="${choice:-$DEFAULT_MANUAL_SELECTION}"

                if [[ "$choice" == "0" ]]; then
                    printf "   ⏸ %s\n" "$(text "übersprungen" "skipped")"
                    continue
                fi

                if [[ ! "$choice" =~ ^[0-9]+$ ]] \
                    || (( choice < 1 || choice > ${#tag_list[@]} )); then
                    printf "   ⚠️ %s\n" "$(text "Ungültige Auswahl – übersprungen." "Invalid selection – skipped.")"
                    continue
                fi

                apply_update "$key" "${tag_list[$((choice - 1))]}"
            done < <(printf '%s\n' "${!ITEMS_ALT[@]}" | sort)
        fi
    else
        printf "⏸ %s\n" "$(text "Keine Updates übernommen." "No updates applied.")"
    fi
else
    echo ""
    printf "✅ %s\n" "$(text "Keine Updates verfügbar." "No updates available.")"
fi

###############################################################
# 5️⃣ Nicht benötigte Backups löschen
###############################################################

if [[ "$traefik_config_exists" == true && "$traefik_changed" == false ]]; then
    rm -f "$TRAEFIK_BACKUP"
    printf "🗑 %s\n" "$(text "Traefik-Backup gelöscht, da keine Änderung vorgenommen wurde." "Traefik backup deleted because no changes were made.")"
fi

if [[ "$compose_changed" == false ]]; then
    rm -f "$COMPOSE_BACKUP"
    printf "🗑 %s\n" "$(text "docker-compose-Backup gelöscht, da keine Änderung vorgenommen wurde." "docker-compose backup deleted because no changes were made.")"
fi

###############################################################
# 6️⃣ Backup-Aufbewahrung anwenden
###############################################################

cleanup_old_backups "$YAML_BACKUP_DIR" "docker-compose_*.yml" "docker-compose"
cleanup_old_backups "$YAML_BACKUP_DIR" "traefik_config_*.yml" "Traefik"

###############################################################
# 7️⃣ Docker Compose aktualisieren
###############################################################

echo ""
compose_answer=$(prompt_yes_no \
    "$(text "🚀 docker-compose jetzt aktualisieren (pull + up -d)?" "🚀 Update Docker Compose now (pull + up -d)?")" \
    "$RUN_COMPOSE" "$DEFAULT_RUN_COMPOSE")

if [[ "$compose_answer" == "yes" ]]; then
    if [[ -d "./config" ]]; then
        echo ""
        config_backup_answer=$(prompt_yes_no \
            "$(text "📦 Vor dem Container-Update ein Backup von ./config erstellen?" "📦 Create a backup of ./config before updating containers?")" \
            "$CONFIG_BACKUP" "$DEFAULT_CONFIG_BACKUP")

        if [[ "$config_backup_answer" == "yes" ]]; then
            mkdir -p "$CONFIG_BACKUP_DIR"
            CONFIG_BACKUP_FILE="$CONFIG_BACKUP_DIR/config_${TIMESTAMP}.tar.gz"

            if tar -czf "$CONFIG_BACKUP_FILE" ./config; then
                printf "✅ %s: %s\n" "$(text "Config-Backup erstellt" "Config backup created")" "$CONFIG_BACKUP_FILE"
            else
                printf "❌ %s\n" "$(text "Config-Backup fehlgeschlagen. Container-Update wird abgebrochen." "Config backup failed. Container update will be aborted.")"
                exit 1
            fi
        else
            printf "⏸ %s\n" "$(text "Config-Backup übersprungen." "Config backup skipped.")"
        fi
    else
        printf "ℹ️ %s\n" "$(text "./config existiert nicht – Config-Backup übersprungen." "./config does not exist – config backup skipped.")"
    fi

    cleanup_old_backups "$CONFIG_BACKUP_DIR" "config_*.tar.gz" "Config"

    docker compose -f "$COMPOSE_FILE" pull
    docker compose -f "$COMPOSE_FILE" up -d
    printf "🎉 %s\n" "$(text "docker-compose erfolgreich aktualisiert." "Docker Compose updated successfully.")"
else
    printf "⏸ %s\n" "$(text "Aktualisierung übersprungen." "Update skipped.")"
    cleanup_old_backups "$CONFIG_BACKUP_DIR" "config_*.tar.gz" "Config"
fi

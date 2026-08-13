#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="translarr"
REPO="${TRANSLARR_REPO:-Flawkee/Translarr}"
REF="${TRANSLARR_REF:-main}"
ACTION=""
ASSUME_YES=false
NO_PROXY=false
FFMPEG_ARG=""
FFPROBE_ARG=""
MKVEXTRACT_ARG=""
GITHUB_TOKEN_FILE="${TRANSLARR_GITHUB_TOKEN_FILE:-}"

usage() {
    cat <<'EOF'
Usage: translarr.sh [options] [install|upgrade|rollback|show|uninstall|purge]

Options:
  --repo OWNER/REPO|URL   Source repository (default: Flawkee/Translarr)
  --ref REF               Git branch or tag (default: main)
  --github-token-file PATH
                          Read a private-repository token from a mode 0600 file
  --ffmpeg PATH           Override the installed ffmpeg executable
  --ffprobe PATH          Override the installed ffprobe executable
  --mkvextract PATH       Override the installed mkvextract executable
  --no-proxy              Do not configure nginx/dashboard when running with sudo
  --yes                   Confirm the irreversible purge action
  -h, --help              Show this help

Actions:
  install     Install a rootless user service; retained state is reused
  upgrade     Back up state/code, stage a release, health-check, and auto-rollback
  rollback    Restore the most recent retained pre-upgrade code and state
  show        Display paths, tool detection, service status, and URL
  uninstall   Remove service/code/proxy while preserving config, data, and backups
  purge       Remove everything owned by Translarr (requires typing PURGE or --yes)

When run through sudo on Swizzin, the installer installs FFmpeg, FFprobe, and
MKVToolNix from the host package repository. Exact executable paths remain optional.
Private repositories may use the Swizzin user's SSH configuration or a protected
GitHub token file. Authentication is applied only while staging the repository.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        install|upgrade|rollback|show|uninstall|purge)
            [[ -n "$ACTION" ]] && { echo "Only one action may be supplied." >&2; exit 2; }
            ACTION="$1"
            shift
            ;;
        --repo)
            [[ -n "${2:-}" ]] || { echo "--repo needs a value." >&2; exit 2; }
            REPO="$2"
            shift 2
            ;;
        --ref)
            [[ -n "${2:-}" ]] || { echo "--ref needs a value." >&2; exit 2; }
            REF="$2"
            shift 2
            ;;
        --github-token-file)
            [[ -n "${2:-}" ]] || { echo "--github-token-file needs a value." >&2; exit 2; }
            GITHUB_TOKEN_FILE="$2"
            shift 2
            ;;
        --ffmpeg)
            [[ -n "${2:-}" ]] || { echo "--ffmpeg needs a value." >&2; exit 2; }
            FFMPEG_ARG="$2"
            shift 2
            ;;
        --ffprobe)
            [[ -n "${2:-}" ]] || { echo "--ffprobe needs a value." >&2; exit 2; }
            FFPROBE_ARG="$2"
            shift 2
            ;;
        --mkvextract)
            [[ -n "${2:-}" ]] || { echo "--mkvextract needs a value." >&2; exit 2; }
            MKVEXTRACT_ARG="$2"
            shift 2
            ;;
        --no-proxy)
            NO_PROXY=true
            shift
            ;;
        --yes|-y)
            ASSUME_YES=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$REPO" == http://* || "$REPO" == https://* || "$REPO" == git@* ]]; then
    REPO_URL="${REPO%.git}.git"
else
    REPO="${REPO#github.com/}"
    REPO="${REPO%.git}"
    REPO_URL="https://github.com/${REPO}.git"
fi

if [[ $EUID -eq 0 ]]; then
    if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
        echo "Run with sudo from the normal Swizzin user, not from a root login." >&2
        exit 1
    fi
    SUDO_MODE=true
    target_user="$SUDO_USER"
else
    SUDO_MODE=false
    target_user="$(id -un)"
fi

target_home="$(getent passwd "$target_user" | cut -d: -f6)"
target_uid="$(id -u "$target_user")"
target_group="$(id -gn "$target_user")"
[[ -n "$target_home" && "$target_home" != "/" ]] || {
    echo "Could not resolve a safe home directory for $target_user." >&2
    exit 1
}

CONFIG_DIR="$target_home/.config/translarr"
ENV_FILE="$CONFIG_DIR/env"
UNIT_DIR="$target_home/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/translarr.service"
LEGACY_WORKER_UNIT_FILE="$UNIT_DIR/translarr-worker.service"
SHARE_DIR="$target_home/.local/share/translarr"
APP_DIR="$SHARE_DIR/app"
DATA_DIR="$SHARE_DIR/data"
TOOLS_DIR="$SHARE_DIR/tools"
BACKUP_DIR="$SHARE_DIR/backups"
LOCK_FILE="$SHARE_DIR/.installed"
NGINX_FILE="/etc/nginx/apps/translarr.conf"
PANEL_PROFILES="/opt/swizzin/core/custom/profiles.py"

as_user() {
    if $SUDO_MODE; then
        sudo -u "$target_user" -H "$@"
    else
        "$@"
    fi
}

systemctl_user() {
    if $SUDO_MODE; then
        sudo -u "$target_user" \
            XDG_RUNTIME_DIR="/run/user/$target_uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$target_uid/bus" \
            systemctl --user "$@"
    else
        systemctl --user "$@"
    fi
}

install_for_user() {
    local mode="$1" source="$2" destination="$3"
    if $SUDO_MODE; then
        install -m "$mode" -o "$target_user" -g "$target_group" "$source" "$destination"
    else
        install -m "$mode" "$source" "$destination"
    fi
}

ensure_dirs() {
    as_user mkdir -p "$CONFIG_DIR" "$UNIT_DIR" "$SHARE_DIR" "$DATA_DIR" \
        "$TOOLS_DIR" "$BACKUP_DIR"
    as_user chmod 700 "$CONFIG_DIR" "$DATA_DIR" "$BACKUP_DIR"
}

check_base_dependencies() {
    local missing=()
    local command_name
    for command_name in git python3 curl tar ss base64 stat tee; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    if ((${#missing[@]})); then
        echo "Missing installer dependencies: ${missing[*]}" >&2
        echo "Install git, Python 3.11+, python3-venv, curl, tar, iproute2, and coreutils, then retry." >&2
        exit 1
    fi
    if ! python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 11))'; then
        echo "Translarr requires Python 3.11 or newer." >&2
        exit 1
    fi
    if ! python3 -m venv --help >/dev/null 2>&1; then
        echo "Python's venv module is missing. Install python3-venv, then retry." >&2
        exit 1
    fi
}

install_media_packages() {
    local needs_ffmpeg=false needs_mkvtoolnix=false
    if [[ -z "$FFMPEG_ARG" ]] && ! command -v ffmpeg >/dev/null 2>&1; then
        needs_ffmpeg=true
    fi
    if [[ -z "$FFPROBE_ARG" ]] && ! command -v ffprobe >/dev/null 2>&1; then
        needs_ffmpeg=true
    fi
    if [[ -z "$MKVEXTRACT_ARG" ]] && ! command -v mkvextract >/dev/null 2>&1; then
        needs_mkvtoolnix=true
    fi
    if ! $needs_ffmpeg && ! $needs_mkvtoolnix; then
        return 0
    fi
    if ! $SUDO_MODE || ! command -v apt-get >/dev/null 2>&1; then
        echo "FFmpeg, FFprobe, and MKVToolNix are required." >&2
        echo "Run the installer through sudo on Swizzin or provide absolute tool paths." >&2
        exit 1
    fi
    local packages=()
    $needs_ffmpeg && packages+=(ffmpeg)
    $needs_mkvtoolnix && packages+=(mkvtoolnix)
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
}

enable_linger() {
    $SUDO_MODE || return 0
    if ! loginctl show-user "$target_user" 2>/dev/null | grep -q '^Linger=yes$'; then
        loginctl enable-linger "$target_user"
    fi
}

choose_port() {
    local port
    for _ in {1..300}; do
        port="$(shuf -i 18000-29999 -n 1)"
        if ! ss -Htan | awk '{print $4}' | grep -Eq "(^|:)$port$"; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    echo "Unable to select a free port." >&2
    return 1
}

env_value() {
    local key="$1"
    [[ -f "$ENV_FILE" ]] || return 0
    sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1
}

write_initial_env() {
    [[ -f "$ENV_FILE" ]] && return 0
    local port root_path tmp
    port="$(choose_port)"
    if $SUDO_MODE && ! $NO_PROXY; then
        root_path="/translarr"
    else
        root_path=""
    fi
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
TRANSLARR_HOST=127.0.0.1
TRANSLARR_PORT=$port
TRANSLARR_DATA_DIR=$DATA_DIR
TRANSLARR_ROOT_PATH=$root_path
TRANSLARR_SECURE_COOKIES=$([[ -n "$root_path" ]] && echo true || echo false)
PATH=$TOOLS_DIR:$target_home/.local/bin:/usr/local/bin:/usr/bin:/bin
EOF
    install_for_user 0600 "$tmp" "$ENV_FILE"
    rm -f "$tmp"
}

prepare_proxy_env() {
    $SUDO_MODE || return 0
    $NO_PROXY && return 0
    local tmp
    tmp="$(mktemp)"
    awk '
        BEGIN { root_seen = 0; cookie_seen = 0 }
        /^TRANSLARR_ROOT_PATH=/ { print "TRANSLARR_ROOT_PATH=/translarr"; root_seen = 1; next }
        /^TRANSLARR_SECURE_COOKIES=/ { print "TRANSLARR_SECURE_COOKIES=true"; cookie_seen = 1; next }
        { print }
        END {
            if (!root_seen) print "TRANSLARR_ROOT_PATH=/translarr"
            if (!cookie_seen) print "TRANSLARR_SECURE_COOKIES=true"
        }
    ' "$ENV_FILE" >"$tmp"
    install_for_user 0600 "$tmp" "$ENV_FILE"
    rm -f "$tmp"
}

link_external_tool() {
    local name="$1" supplied="$2" resolved
    [[ -n "$supplied" ]] || return 0
    if [[ "$supplied" != /* || ! -x "$supplied" ]]; then
        echo "$name path must be an absolute executable file: $supplied" >&2
        exit 1
    fi
    resolved="$(readlink -f "$supplied")"
    as_user ln -sfn "$resolved" "$TOOLS_DIR/$name"
    echo "External $name exposed to Translarr as $TOOLS_DIR/$name"
}

configure_tools() {
    link_external_tool ffmpeg "$FFMPEG_ARG"
    link_external_tool ffprobe "$FFPROBE_ARG"
    link_external_tool mkvextract "$MKVEXTRACT_ARG"

    local tool found
    for tool in ffmpeg ffprobe mkvextract; do
        if [[ -x "$TOOLS_DIR/$tool" ]]; then
            found="$(readlink -f "$TOOLS_DIR/$tool")"
        else
            found="$(as_user env PATH="$target_home/.local/bin:/usr/local/bin:/usr/bin:/bin" \
                sh -c "command -v $tool" 2>/dev/null || true)"
        fi
        if [[ -n "$found" ]]; then
            echo "Detected $tool: $found"
        elif [[ "$tool" == "mkvextract" ]]; then
            echo "Optional mkvextract was not detected."
        else
            echo "Warning: $tool was not detected; install it externally or set its path in the UI."
        fi
    done
}

stage_release() {
    local stage
    stage="$(as_user mktemp -d "$SHARE_DIR/.stage.XXXXXX")"
    echo "Fetching $REPO_URL at $REF..." >&2
    if ! clone_repository "$stage"; then
        as_user rm -rf "$stage"
        return 1
    fi
    if ! as_user python3 -m venv "$stage/.venv"; then
        as_user rm -rf "$stage"
        return 1
    fi
    if ! as_user "$stage/.venv/bin/python" -m pip install --quiet --upgrade pip; then
        as_user rm -rf "$stage"
        return 1
    fi
    if ! as_user "$stage/.venv/bin/python" -m pip install --quiet "$stage"; then
        as_user rm -rf "$stage"
        return 1
    fi
    if ! as_user "$stage/.venv/bin/python" -c 'import translarr; import translarr.cli'; then
        as_user rm -rf "$stage"
        return 1
    fi
    printf '%s\n' "$stage"
}

clone_repository() {
    local destination="$1" token="${TRANSLARR_GITHUB_TOKEN:-${GH_TOKEN:-}}" encoded permissions clone_status=0 auth_file=""
    if [[ -n "$GITHUB_TOKEN_FILE" ]]; then
        [[ "$GITHUB_TOKEN_FILE" == /* ]] || GITHUB_TOKEN_FILE="$(pwd)/$GITHUB_TOKEN_FILE"
        if [[ ! -f "$GITHUB_TOKEN_FILE" || -L "$GITHUB_TOKEN_FILE" ]]; then
            echo "GitHub token file must be a regular, non-symlink file: $GITHUB_TOKEN_FILE" >&2
            return 1
        fi
        permissions="$(stat -c '%a' "$GITHUB_TOKEN_FILE")"
        permissions="${permissions: -3}"
        if (( (8#$permissions & 8#077) != 0 )); then
            echo "GitHub token file must not be readable by group or others: $GITHUB_TOKEN_FILE" >&2
            return 1
        fi
        token="$(<"$GITHUB_TOKEN_FILE")"
    fi
    if [[ -z "$token" ]]; then
        as_user git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$destination"
        return
    fi
    if [[ "$REPO_URL" != https://github.com/* ]]; then
        echo "GitHub token authentication requires an https://github.com/ repository URL." >&2
        return 1
    fi
    if [[ "$token" == *$'\n'* || "$token" == *$'\r'* || "$token" == *[[:space:]]* ]]; then
        echo "GitHub token contains invalid whitespace." >&2
        return 1
    fi
    encoded="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
    auth_file="$(as_user mktemp "$SHARE_DIR/.git-auth.XXXXXX")"
    if ! printf '[http "https://github.com/"]\n\textraHeader = Authorization: Basic %s\n' "$encoded" | \
        as_user tee "$auth_file" >/dev/null; then
        as_user rm -f "$auth_file"
        token=""
        encoded=""
        return 1
    fi
    if ! as_user chmod 600 "$auth_file"; then
        as_user rm -f "$auth_file"
        token=""
        encoded=""
        return 1
    fi
    as_user env GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL="$auth_file" \
        git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$destination" || clone_status=$?
    if ! as_user rm -f "$auth_file"; then
        echo "Could not remove the temporary GitHub authentication file: $auth_file" >&2
        clone_status=1
    fi
    token=""
    encoded=""
    auth_file=""
    return "$clone_status"
}

write_unit() {
    local tmp service_command
    if as_user "$APP_DIR/.venv/bin/python" -m translarr run --help >/dev/null 2>&1; then
        service_command="$APP_DIR/.venv/bin/python -m translarr run --workers 2"
    else
        service_command="$APP_DIR/.venv/bin/python -m translarr serve"
    fi
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
[Unit]
Description=Translarr subtitle translation service
Wants=network-online.target
After=network-online.target

[Service]
Type=exec
EnvironmentFile=$ENV_FILE
WorkingDirectory=$APP_DIR
ExecStart=$service_command
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
NoNewPrivileges=true
PrivateTmp=true
UMask=0077

[Install]
WantedBy=default.target
EOF
    install_for_user 0644 "$tmp" "$UNIT_FILE"
    rm -f "$tmp"
    systemctl_user disable translarr-worker 2>/dev/null || true
    as_user rm -f "$LEGACY_WORKER_UNIT_FILE"
    systemctl_user daemon-reload
}

stop_service() {
    systemctl_user stop translarr-worker 2>/dev/null || true
    systemctl_user stop translarr 2>/dev/null || true
}

start_service() {
    systemctl_user enable --now translarr
}

health_wait() {
    local port health_path
    port="$(env_value TRANSLARR_PORT)"
    if as_user "$APP_DIR/.venv/bin/python" -m translarr run --help >/dev/null 2>&1; then
        health_path="/health/ready"
    else
        health_path="/health"
    fi
    for _ in {1..30}; do
        if curl -fsS --max-time 3 "http://127.0.0.1:${port}${health_path}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

snapshot_state() {
    local destination="$1"
    as_user mkdir -p "$destination"
    as_user tar -C "$target_home" -czf "$destination/state.tar.gz" \
        .config/translarr .local/share/translarr/data
}

restore_state_with_quarantine() {
    local archive="$1" quarantine="$2"
    as_user mkdir -p "$quarantine"
    [[ ! -d "$CONFIG_DIR" ]] || as_user mv "$CONFIG_DIR" "$quarantine/config"
    [[ ! -d "$DATA_DIR" ]] || as_user mv "$DATA_DIR" "$quarantine/data"
    as_user tar -C "$target_home" -xzf "$archive"
}

configure_nginx() {
    $SUDO_MODE || return 0
    $NO_PROXY && return 0
    local port auth_block="" htpasswd_file tmp
    port="$(env_value TRANSLARR_PORT)"
    htpasswd_file="/etc/htpasswd.d/htpasswd.${target_user}"
    if [[ -f "$htpasswd_file" ]]; then
        auth_block="    auth_basic \"Restricted\";
    auth_basic_user_file $htpasswd_file;"
    fi
    mkdir -p /etc/nginx/apps
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
location = /translarr {
    return 301 \$scheme://\$host/translarr/;
}

location /translarr/ {
    proxy_pass http://127.0.0.1:${port}/;
    proxy_http_version 1.1;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Prefix /translarr;
    proxy_redirect off;
${auth_block}
}
EOF
    install -m 0644 "$tmp" "$NGINX_FILE"
    rm -f "$tmp"
    if nginx -t; then
        systemctl reload nginx
    else
        rm -f "$NGINX_FILE"
        echo "nginx validation failed; removed $NGINX_FILE." >&2
        return 1
    fi
}

configure_dashboard() {
    $SUDO_MODE || return 0
    $NO_PROXY && return 0
    mkdir -p "$(dirname "$PANEL_PROFILES")" /install
    touch "$PANEL_PROFILES"
    if ! grep -q '^class translarr_meta:' "$PANEL_PROFILES"; then
        cat >>"$PANEL_PROFILES" <<'EOF'


class translarr_meta:
    name = "translarr"
    pretty_name = "Translarr"
    baseurl = "/translarr"
    systemd = "translarr"
    img = "translarr"
    runas = "user"
EOF
    fi
    if [[ -f "$APP_DIR/src/translarr/static/logo.png" ]]; then
        install -D -m 0644 "$APP_DIR/src/translarr/static/logo.png" \
            /opt/swizzin/static/img/apps/translarr.png
    fi
    touch /install/.translarr.lock
    systemctl restart panel 2>/dev/null || true
}

remove_proxy_dashboard() {
    if ! $SUDO_MODE; then
        [[ ! -e "$NGINX_FILE" ]] || echo "Run uninstall with sudo to remove $NGINX_FILE."
        return 0
    fi
    rm -f "$NGINX_FILE" /install/.translarr.lock /opt/swizzin/static/img/apps/translarr.png
    if [[ -f "$PANEL_PROFILES" ]]; then
        PANEL_PROFILES="$PANEL_PROFILES" python3 - <<'PY'
import os
import re

path = os.environ["PANEL_PROFILES"]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
text = re.sub(r"\n*class translarr_meta:.*?(?=\nclass |\Z)", "", text, flags=re.S)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.rstrip() + "\n")
PY
    fi
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
    fi
    systemctl restart panel 2>/dev/null || true
}

install_app() {
    check_base_dependencies
    install_media_packages
    enable_linger
    ensure_dirs
    write_initial_env
    prepare_proxy_env
    configure_tools
    if [[ -f "$LOCK_FILE" && -d "$APP_DIR" ]]; then
        echo "Translarr is already installed. Use upgrade instead." >&2
        return 1
    fi
    local stage
    stage="$(stage_release)" || { echo "Release staging failed." >&2; return 1; }
    stop_service
    [[ ! -e "$APP_DIR" ]] || as_user mv "$APP_DIR" "$BACKUP_DIR/incomplete-$(date +%Y%m%d-%H%M%S)"
    as_user mv "$stage" "$APP_DIR"
    write_unit
    start_service
    if ! health_wait; then
        stop_service
        echo "Translarr did not become healthy. Inspect: journalctl --user -u translarr -n 100" >&2
        return 1
    fi
    as_user touch "$LOCK_FILE"
    configure_nginx
    configure_dashboard
    show_status
}

upgrade_app() {
    [[ -f "$LOCK_FILE" && -d "$APP_DIR" ]] || {
        echo "Translarr is not installed. Use install." >&2
        return 1
    }
    check_base_dependencies
    install_media_packages
    ensure_dirs
    configure_tools
    local stage stamp backup
    stage="$(stage_release)" || { echo "Release staging failed; current service was untouched." >&2; return 1; }
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup="$BACKUP_DIR/pre-upgrade-$stamp"
    stop_service
    snapshot_state "$backup"
    as_user mv "$APP_DIR" "$backup/app"
    as_user mv "$stage" "$APP_DIR"
    write_unit
    start_service
    if health_wait; then
        echo "Upgrade succeeded. Rollback backup retained at $backup"
        configure_nginx
        configure_dashboard
        return 0
    fi

    echo "Upgrade health check failed; restoring old code and state." >&2
    stop_service
    as_user mv "$APP_DIR" "$backup/failed-app"
    as_user mv "$backup/app" "$APP_DIR"
    restore_state_with_quarantine "$backup/state.tar.gz" "$backup/failed-state"
    write_unit
    start_service
    if health_wait; then
        echo "Automatic rollback succeeded. Failed release retained at $backup/failed-app" >&2
    else
        echo "Rollback also failed. Inspect: journalctl --user -u translarr -n 100" >&2
    fi
    return 1
}

newest_rollback_backup() {
    local candidate newest=""
    shopt -s nullglob
    for candidate in "$BACKUP_DIR"/*; do
        [[ -d "$candidate/app" && -f "$candidate/state.tar.gz" ]] || continue
        if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then
            newest="$candidate"
        fi
    done
    shopt -u nullglob
    printf '%s\n' "$newest"
}

rollback_app() {
    [[ -d "$APP_DIR" ]] || { echo "Active application code was not found." >&2; return 1; }
    local selected stamp current
    selected="$(newest_rollback_backup)"
    [[ -n "$selected" ]] || { echo "No usable rollback backup was found." >&2; return 1; }
    stamp="$(date +%Y%m%d-%H%M%S)"
    current="$BACKUP_DIR/pre-rollback-$stamp"
    echo "Rolling back to $selected"
    stop_service
    snapshot_state "$current"
    as_user mv "$APP_DIR" "$current/app"
    as_user mv "$selected/app" "$APP_DIR"
    restore_state_with_quarantine "$selected/state.tar.gz" "$current/displaced-state"
    write_unit
    start_service
    if health_wait; then
        echo "Rollback succeeded. The replaced version is retained at $current"
        return 0
    fi

    echo "Rollback target failed health check; restoring the version just replaced." >&2
    stop_service
    as_user mv "$APP_DIR" "$selected/failed-rollback-app"
    as_user mv "$current/app" "$APP_DIR"
    restore_state_with_quarantine "$current/state.tar.gz" "$selected/failed-rollback-state"
    write_unit
    start_service
    health_wait || echo "Restored version is not healthy; inspect the user journal." >&2
    return 1
}

show_status() {
    local port root_path status url tool found
    port="$(env_value TRANSLARR_PORT)"
    root_path="$(env_value TRANSLARR_ROOT_PATH)"
    status="$(systemctl_user is-active translarr 2>/dev/null || true)"
    if [[ -f "$NGINX_FILE" ]]; then
        url="https://$(hostname -f)/translarr/"
    else
        url="http://$(hostname -f):${port:-unknown}${root_path:-/}"
    fi
    echo
    echo "Translarr status"
    echo "  service : ${status:-not installed}"
    echo "  URL     : $url"
    echo "  port    : ${port:-unknown} (retained across upgrades)"
    echo "  config  : $CONFIG_DIR"
    echo "  data    : $DATA_DIR"
    echo "  code    : $APP_DIR"
    echo "  backups : $BACKUP_DIR"
    for tool in ffmpeg ffprobe mkvextract; do
        if [[ -x "$TOOLS_DIR/$tool" ]]; then
            found="$(readlink -f "$TOOLS_DIR/$tool")"
        else
            found="$(as_user env PATH="$target_home/.local/bin:/usr/local/bin:/usr/bin:/bin" \
                sh -c "command -v $tool" 2>/dev/null || true)"
        fi
        echo "  $tool : ${found:-not detected}"
    done
    echo
    echo "Commands:"
    echo "  systemctl --user status translarr"
    echo "  journalctl --user -u translarr -f"
    echo
}

uninstall_app() {
    systemctl_user disable --now translarr-worker translarr 2>/dev/null || true
    as_user rm -f "$UNIT_FILE" "$LEGACY_WORKER_UNIT_FILE" "$LOCK_FILE"
    systemctl_user daemon-reload 2>/dev/null || true
    [[ ! -d "$APP_DIR" ]] || as_user rm -rf "$APP_DIR"
    remove_proxy_dashboard
    echo "Translarr service and code removed. Config, database, and backups were preserved."
    echo "Run '$0 purge' only if you intend to delete all retained Translarr state."
}

purge_app() {
    if ! $ASSUME_YES; then
        echo "This deletes Translarr config, credentials, database, code, and backups."
        echo "It does not delete media or generated subtitle files."
        read -r -p "Type PURGE to continue: " confirmation
        [[ "$confirmation" == "PURGE" ]] || { echo "Purge cancelled."; return 0; }
    fi
    uninstall_app
    [[ ! -d "$CONFIG_DIR" ]] || as_user rm -rf "$CONFIG_DIR"
    [[ ! -d "$SHARE_DIR" ]] || as_user rm -rf "$SHARE_DIR"
    echo "Deleted $CONFIG_DIR and $SHARE_DIR. Recovery requires an external backup."
}

if [[ -z "$ACTION" ]]; then
    echo "Translarr installer"
    echo "  install | upgrade | rollback | show | uninstall | purge | exit"
    read -r -p "Action: " ACTION
fi

case "$ACTION" in
    install) install_app ;;
    upgrade) upgrade_app ;;
    rollback) rollback_app ;;
    show) show_status ;;
    uninstall) uninstall_app ;;
    purge) purge_app ;;
    exit) exit 0 ;;
    *) echo "Unknown action: $ACTION" >&2; usage >&2; exit 2 ;;
esac

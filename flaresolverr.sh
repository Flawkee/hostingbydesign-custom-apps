#!/bin/bash
# FlareSolverr installer for swizzin-based servers
# Based on seerr.sh — same environment assumptions (systemd --user, swizzin layout)
# Downloads the pre-built Linux binary from GitHub — no build step required.

# --- Privilege detection -----------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    if [[ -z "${SUDO_USER:-}" ]] || [[ "$SUDO_USER" == "root" ]]; then
        echo "Run this script with sudo from your normal user account (not directly as root)."
        exit 1
    fi
    SUDO_MODE=true
    target_user="$SUDO_USER"
else
    SUDO_MODE=false
    target_user="$(whoami)"
fi
target_home="$(getent passwd "$target_user" | cut -d: -f6)"
target_uid="$(id -u "$target_user")"

if ! $SUDO_MODE; then
    echo ""
    echo "Not running with sudo."
    echo "Without sudo this installer cannot ensure all system dependencies are present."
    echo ""
    read -r -p "Type 'continue' to install FlareSolverr without those steps, or anything else to exit: " sudo_choice
    if [[ "$sudo_choice" != "continue" ]]; then
        echo "Aborting."
        exit 0
    fi
fi

export user="$target_user"
mkdir -p "$target_home/.logs/"
touch "$target_home/.logs/flaresolverr.log"
if $SUDO_MODE; then
    chown -R "$target_user:$target_user" "$target_home/.logs"
fi
export log="$target_home/.logs/flaresolverr.log"

# --- Helpers -----------------------------------------------------------------
run_as_user() {
    if $SUDO_MODE; then
        sudo -u "$target_user" -H bash -lc "$1"
    else
        bash -lc "$1"
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

_check_linger() {
    if loginctl show-user "$target_user" 2>/dev/null | grep -q 'Linger=yes'; then
        return 0
    fi
    echo "Linger is not enabled for $target_user — enabling now..."
    loginctl enable-linger "$target_user"
    echo "Linger enabled for $target_user."
}

# --- Architecture check ------------------------------------------------------
_check_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64)  echo "linux_x64" ;;
        aarch64|arm64) echo "linux_arm64" ;;
        *)
            echo "Unsupported architecture: $machine"
            echo "FlareSolverr only provides pre-built binaries for x86_64 and arm64."
            exit 1
            ;;
    esac
}

# --- Pick a free port --------------------------------------------------------
_port() {
    local low=$1 high=$2
    comm -23 \
        <(seq "$low" "$high" | sort) \
        <(ss -Htan | awk '{print $4}' | cut -d':' -f2 | sort -u) \
    | shuf | head -n 1
}

_pick_port() {
    # Prefer FlareSolverr's default port; fall back to a random one if taken.
    if ! ss -Htan | awk '{print $4}' | grep -q ':8191$'; then
        echo 8191
    else
        echo "Port 8191 is already in use, picking a random port..." >&2
        _port 8000 18000
    fi
}

# --- Install steps -----------------------------------------------------------
function _deps() {
    if ! $SUDO_MODE; then
        echo "Skipping dependency check (not running as sudo)."
        return
    fi

    echo "Checking dependencies..."

    # FlareSolverr needs Chromium (or Google Chrome) on the host.
    if command -v chromium-browser &>/dev/null || command -v chromium &>/dev/null || command -v google-chrome &>/dev/null; then
        echo "Chromium/Chrome found."
    else
        echo "Chromium not found — installing chromium..."
        apt-get install -y chromium >> "$log" 2>&1 || {
            echo "Failed to install chromium. Install it manually and re-run."
            exit 1
        }
        echo "Chromium installed."
    fi

    # Ensure curl and jq are available for the download step.
    local missing=()
    command -v curl &>/dev/null || missing+=(curl)
    command -v jq   &>/dev/null || missing+=(jq)
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Installing: ${missing[*]}"
        apt-get install -y "${missing[@]}" >> "$log" 2>&1 || {
            echo "Failed to install dependencies: ${missing[*]}"
            exit 1
        }
    fi
    echo "All dependencies satisfied."
}

function _flaresolverr_install() {
    local arch
    arch="$(_check_arch)"
    echo "Architecture detected: $arch"

    echo "Fetching latest FlareSolverr release..."
    local dlurl
    dlurl="$(curl -sS https://api.github.com/repos/FlareSolverr/FlareSolverr/releases/latest \
        | jq -r ".assets[] | select(.name == \"flaresolverr_${arch}.tar.gz\") | .browser_download_url")"

    if [[ -z "$dlurl" ]]; then
        echo "Could not find a release asset for arch '$arch'."
        echo "Check https://github.com/FlareSolverr/FlareSolverr/releases"
        exit 1
    fi

    echo "Downloading $dlurl"
    run_as_user "wget '$dlurl' -q -O '$target_home/flaresolverr.tar.gz'" >> "$log" 2>&1 || {
        echo "Download failed. See $log"
        exit 1
    }

    echo "Extracting..."
    run_as_user "mkdir -p '$target_home/flaresolverr' && \
        tar --strip-components=1 -C '$target_home/flaresolverr' \
            -xzf '$target_home/flaresolverr.tar.gz' && \
        rm '$target_home/flaresolverr.tar.gz'" >> "$log" 2>&1 || {
        echo "Extraction failed. See $log"
        exit 1
    }

    run_as_user "chmod +x '$target_home/flaresolverr/flaresolverr'"
    echo "FlareSolverr extracted to $target_home/flaresolverr/"
}

function _service() {
    _check_linger
    run_as_user "mkdir -p '$target_home/.config/systemd/user' '$target_home/.install'"

    local FLARESOLVERR_PORT
    FLARESOLVERR_PORT="$(_pick_port)"

    # Write env.conf — add/override any FlareSolverr env vars here.
    local tmp_env
    tmp_env="$(mktemp)"
    cat > "$tmp_env" << EOF
PORT=$FLARESOLVERR_PORT
HOST=127.0.0.1
LOG_LEVEL=info
HEADLESS=true
EOF
    install -m 0644 -o "$target_user" -g "$target_user" \
        "$tmp_env" "$target_home/flaresolverr/env.conf"
    rm -f "$tmp_env"

    local tmp_unit
    tmp_unit="$(mktemp)"
    cat > "$tmp_unit" << EOF
[Unit]
Description=FlareSolverr
Wants=network-online.target
After=network-online.target
[Service]
EnvironmentFile=%h/flaresolverr/env.conf
Type=exec
Restart=on-failure
WorkingDirectory=%h/flaresolverr
ExecStart=%h/flaresolverr/flaresolverr
[Install]
WantedBy=default.target
EOF
    install -m 0644 -o "$target_user" -g "$target_user" \
        "$tmp_unit" "$target_home/.config/systemd/user/flaresolverr.service"
    rm -f "$tmp_unit"

    systemctl_user daemon-reload
    systemctl_user enable --now -q flaresolverr
    run_as_user "touch '$target_home/.install/.flaresolverr.lock'"

    echo "FlareSolverr is up and running on http://$(hostname -f):$FLARESOLVERR_PORT"
    echo "API endpoint: http://$(hostname -f):$FLARESOLVERR_PORT/v1"
}

function _show() {
    local lock="$target_home/.install/.flaresolverr.lock"
    if [[ ! -f "$lock" ]]; then
        echo "FlareSolverr is not installed. Run 'install' first."
        return
    fi

    local port=""
    local env_conf="$target_home/flaresolverr/env.conf"
    if [[ -f "$env_conf" ]]; then
        port="$(grep -E '^PORT=' "$env_conf" | cut -d= -f2)"
    fi

    local svc_status
    svc_status="$(systemctl_user is-active flaresolverr 2>/dev/null || echo "unknown")"

    echo ""
    echo "=============================="
    echo "  FlareSolverr status"
    echo "=============================="
    echo "  Service status: $svc_status"
    echo "  Port          : ${port:-unknown}"
    echo "  URL           : http://$(hostname -f):${port:-?}"
    echo "  API endpoint  : http://$(hostname -f):${port:-?}/v1"
    echo ""
    echo "  Useful commands:"
    echo "    systemctl --user status flaresolverr"
    echo "    systemctl --user restart flaresolverr"
    echo "    journalctl --user -u flaresolverr -f"
    echo "    tail -f $target_home/.logs/flaresolverr.log"
    echo ""
    echo "  Config: $target_home/flaresolverr/env.conf"
    echo "    Edit that file and restart the service to change PORT, HOST,"
    echo "    LOG_LEVEL, HEADLESS, PROXY_URL, TZ, etc."
    echo "=============================="
    echo ""
}

function _remove() {
    systemctl_user disable --now flaresolverr 2>/dev/null || true
    sleep 2
    run_as_user "rm -rf \
        '$target_home/flaresolverr' \
        '$target_home/.config/systemd/user/flaresolverr.service' \
        '$target_home/.install/.flaresolverr.lock'"
    systemctl_user daemon-reload 2>/dev/null || true
    echo "FlareSolverr removed."
}

# --- Entry point -------------------------------------------------------------
echo 'This is unsupported software. You will not get help with this, please answer `yes` if you understand and wish to proceed'
if [[ -z ${eula:-} ]]; then
    read -r eula
fi

if ! [[ $eula =~ yes ]]; then
    echo "You did not accept the above. Exiting..."
    exit 1
else
    echo "Proceeding with installation"
fi

echo ""
echo "Welcome to the FlareSolverr installer..."
echo ""
echo "What do you like to do?"
echo ""
echo "show      = Show current installation status and configuration"
echo "install   = Download and install FlareSolverr"
echo "uninstall = Completely remove FlareSolverr"
echo "exit      = Exit installer"
echo ""
while true; do
    read -r -p "Enter it here: " choice
    case $choice in
        "show")
            _show
            ;;
        "install")
            clear
            _deps
            _flaresolverr_install
            _service
            break
            ;;
        "uninstall")
            _remove
            break
            ;;
        "exit")
            break
            ;;
        *)
            echo "Unknown option."
            ;;
    esac
done
exit

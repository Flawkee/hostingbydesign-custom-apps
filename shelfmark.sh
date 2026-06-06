#!/bin/bash
# thx flyingsausages and swizzin team
# based on the seerr install script
# shelfmark — calibrain/shelfmark (Python/Flask + React/Vite)

# --- Argument parsing --------------------------------------------------------
GITHUB_REPO="calibrain/shelfmark"

_usage() {
    cat << 'EOF'
Usage: shelfmark.sh [OPTIONS]

Options:
  --repo REPO    GitHub repo to install from (default: calibrain/shelfmark)
                 Accepts 'owner/repo' or full GitHub URL
  --help         Show this help message

Examples:
  sudo bash shelfmark.sh
  sudo bash shelfmark.sh --repo myfork/shelfmark
  sudo bash shelfmark.sh --repo https://github.com/myfork/shelfmark
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            [[ -z "${2:-}" ]] && { echo "Error: --repo requires a value."; exit 1; }
            # Normalize: strip https://github.com/ prefix and .git suffix
            GITHUB_REPO="${2#https://github.com/}"
            GITHUB_REPO="${GITHUB_REPO%.git}"
            shift 2
            ;;
        --help|-h)
            _usage
            ;;
        *)
            echo "Unknown option: $1"
            _usage
            ;;
    esac
done

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
    echo "Without sudo this installer cannot:"
    echo "  - configure nginx so shelfmark is reachable at https://<host>/shelfmark"
    echo "  - add shelfmark to the swizzin dashboard"
    echo ""
    read -r -p "Type 'continue' to install shelfmark without those steps, or anything else to exit: " sudo_choice
    if [[ "$sudo_choice" != "continue" ]]; then
        echo "Aborting."
        exit 0
    fi
fi

export user="$target_user"
mkdir -p "$target_home/.logs/"
touch "$target_home/.logs/shelfmark.log"
if $SUDO_MODE; then
    chown -R "$target_user:$target_user" "$target_home/.logs"
fi
export log="$target_home/.logs/shelfmark.log"

# --- Helpers to run things as the target user --------------------------------
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

# Ensure systemd --user services survive logout.
_check_linger() {
    if loginctl show-user "$target_user" 2>/dev/null | grep -q 'Linger=yes'; then
        return 0
    fi
    echo "Linger is not enabled for $target_user — enabling now..."
    loginctl enable-linger "$target_user"
    echo "Linger enabled for $target_user."
}

# --- Install steps -----------------------------------------------------------
function _deps() {
    # Node (required to build the React frontend)
    if [[ ! -d "$target_home/.nvm" ]]; then
        echo "Installing nvm/node..."
        run_as_user 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/refs/heads/master/install.sh | bash' >> "$log" 2>&1
        echo "nvm installed."
    else
        echo "nvm already installed."
    fi
    run_as_user '
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        nvm install --lts
    ' >> "$log" 2>&1 || {
        echo "node failed to install"
        exit 1
    }
    echo "Node LTS installed."

    # uv (Python package manager — handles Python 3.14 and deps)
    if ! run_as_user 'export PATH="$HOME/.local/bin:$PATH"; command -v uv' >> "$log" 2>&1; then
        echo "Installing uv..."
        run_as_user 'curl -LsSf https://astral.sh/uv/install.sh | sh' >> "$log" 2>&1 || {
            echo "uv failed to install"
            exit 1
        }
        echo "uv installed."
    else
        echo "uv already installed."
    fi

    # Python 3.14 (shelfmark requires >=3.14; uv fetches a managed build)
    echo "Installing Python 3.14 via uv..."
    run_as_user '
        export PATH="$HOME/.local/bin:$PATH"
        uv python install 3.14
    ' >> "$log" 2>&1 || {
        echo "Python 3.14 failed to install"
        exit 1
    }
    echo "Python 3.14 installed."
}

function _shelfmark_install() {
    echo "Downloading and extracting source code (repo: $GITHUB_REPO)..."
    dlurl="$(curl -sS "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null | jq -r .tarball_url)"

    if [[ -z "$dlurl" ]] || [[ "$dlurl" == "null" ]]; then
        echo "No releases found, using main branch..."
        dlurl="https://github.com/$GITHUB_REPO/archive/refs/heads/main.tar.gz"
    fi

    run_as_user "wget '$dlurl' -q -O '$target_home/shelfmark.tar.gz'" >> "$log" 2>&1 || {
        echo "Download failed"
        exit 1
    }
    run_as_user "mkdir -p '$target_home/shelfmark' && tar --strip-components=1 -C '$target_home/shelfmark' -xzvf '$target_home/shelfmark.tar.gz' && rm '$target_home/shelfmark.tar.gz'" >> "$log" 2>&1
    echo "Code extracted."

    echo "Installing frontend dependencies..."
    run_as_user "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
        make -C '$target_home/shelfmark' install
    " >> "$log" 2>&1 || {
        echo "Frontend dependency install failed"
        exit 1
    }
    echo "Frontend dependencies installed."

    echo "Building frontend and syncing to backend (this might take a while)..."
    run_as_user "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
        make -C '$target_home/shelfmark' build-serve
    " >> "$log" 2>&1 || {
        echo "Frontend build failed"
        exit 1
    }
    echo "Frontend built and synced."

    echo "Installing Python dependencies via uv (this might take a while)..."
    run_as_user "
        export PATH=\"\$HOME/.local/bin:\$PATH\"
        cd '$target_home/shelfmark'
        uv sync --locked --extra browser
    " >> "$log" 2>&1 || {
        echo "Python dependencies failed to install"
        exit 1
    }
    echo "Python dependencies installed."
}

function _port() {
    LOW_BOUND=$1
    UPPER_BOUND=$2
    comm -23 <(seq "${LOW_BOUND}" "${UPPER_BOUND}" | sort) <(ss -Htan | awk '{print $4}' | cut -d':' -f2 | sort -u) | shuf | head -n 1
}

function _service() {
    _check_linger
    run_as_user "mkdir -p '$target_home/.config/systemd/user' '$target_home/.install' '$target_home/.config/shelfmark' '$target_home/books' '$target_home/.logs/shelfmark'"

    uv_path="$(run_as_user 'export PATH="$HOME/.local/bin:$PATH"; which uv' | tail -n1)"

    SHELFMARK_PORT=$(_port 1000 18000)

    tmp_env="$(mktemp)"
    cat > "$tmp_env" << EOF
FLASK_HOST=0.0.0.0
FLASK_PORT=$SHELFMARK_PORT
CONFIG_DIR=$target_home/.config/shelfmark
INGEST_DIR=$target_home/books
LOG_ROOT=$target_home/.logs
EOF
    install -m 0644 -o "$target_user" -g "$target_user" "$tmp_env" "$target_home/shelfmark/env.conf"
    rm -f "$tmp_env"

    tmp_unit="$(mktemp)"
    cat > "$tmp_unit" << EOF
[Unit]
Description=shelfmark Service
Wants=network-online.target
After=network-online.target
[Service]
EnvironmentFile=%h/shelfmark/env.conf
Type=exec
Restart=on-failure
WorkingDirectory=%h/shelfmark
ExecStart=$uv_path run gunicorn --log-level INFO --access-logfile - --error-logfile - --worker-class geventwebsocket.gunicorn.workers.GeventWebSocketWorker --workers 1 -t 300 -b \${FLASK_HOST}:\${FLASK_PORT} shelfmark.main:app
[Install]
WantedBy=default.target
EOF
    install -m 0644 -o "$target_user" -g "$target_user" "$tmp_unit" "$target_home/.config/systemd/user/shelfmark.service"
    rm -f "$tmp_unit"

    systemctl_user daemon-reload
    systemctl_user enable --now -q shelfmark
    run_as_user "touch '$target_home/.install/.shelfmark.lock'"

    if $SUDO_MODE; then
        echo "shelfmark listening on 127.0.0.1:$SHELFMARK_PORT (nginx will expose it at /shelfmark)"
    else
        echo "shelfmark is up and running on http://$(hostname -f):$SHELFMARK_PORT"
    fi
}

# --- Nginx + swizzin dashboard (root only) -----------------------------------
function _nginx() {
    if [[ -z "${SHELFMARK_PORT:-}" ]]; then
        echo "SHELFMARK_PORT not set, skipping nginx config."
        return 1
    fi

    htpasswd_file="/etc/htpasswd.d/htpasswd.${target_user}"
    auth_block=""
    if [[ -f "$htpasswd_file" ]]; then
        auth_block="    auth_basic              \"What's the password?\";
    auth_basic_user_file    ${htpasswd_file};"
    fi

    local hostname
    hostname="$(hostname -f)"
    read -r -p "  Hostname for shelfmark redirect [$hostname]: " hostname_input
    [[ -n "$hostname_input" ]] && hostname="$hostname_input"

    mkdir -p /etc/nginx/apps
    cat > /etc/nginx/apps/shelfmark.conf << EOF
location /shelfmark {
    return 301 http://${hostname}:${SHELFMARK_PORT}/;
}
EOF

    if nginx -t >> "$log" 2>&1; then
        systemctl reload nginx
        echo "nginx configured. shelfmark reachable at https://$(hostname -f)/shelfmark"
    else
        echo "nginx config test failed. Check $log and /etc/nginx/apps/shelfmark.conf."
        return 1
    fi
}

function _dashboard() {
    icon_dir="/opt/swizzin/static/img/apps"
    icon_url="https://raw.githubusercontent.com/Flawkee/swizzin.apps/main/shelfmark.png"
    if curl -fsSL -o "$icon_dir/shelfmark.png" "$icon_url" 2>>"$log"; then
        echo "Icon installed to $icon_dir/shelfmark.png"
    else
        echo "Could not download shelfmark icon from $icon_url (continuing without custom icon)."
    fi

    profiles="/opt/swizzin/core/custom/profiles.py"
    mkdir -p "$(dirname "$profiles")"
    [[ -f "$profiles" ]] || touch "$profiles"

    if ! grep -q "^class shelfmark_meta:" "$profiles"; then
        cat >> "$profiles" << 'EOF'


class shelfmark_meta:
    name = "shelfmark"
    pretty_name = "Shelfmark"
    baseurl = "/shelfmark"
    systemd = "shelfmark"
    img = "shelfmark"
    runas = "user"
EOF
        echo "Appended shelfmark_meta to $profiles"
    else
        echo "shelfmark_meta already present in $profiles"
    fi

    mkdir -p /install
    touch /install/.shelfmark.lock
    systemctl restart panel
    echo "swizzin dashboard updated."
}

function _remove() {
    systemctl_user disable --now shelfmark 2>/dev/null || true
    sleep 2
    run_as_user "rm -rf '$target_home/shelfmark' '$target_home/.config/shelfmark' '$target_home/.config/systemd/user/shelfmark.service' '$target_home/.install/.shelfmark.lock'"

    if $SUDO_MODE; then
        rm -f /etc/nginx/apps/shelfmark.conf
        if nginx -t >> "$log" 2>&1; then
            systemctl reload nginx
        fi

        rm -f /install/.shelfmark.lock
        if [[ -f /opt/swizzin/core/custom/profiles.py ]]; then
            python3 - << 'PY'
import re
p = "/opt/swizzin/core/custom/profiles.py"
with open(p) as f:
    t = f.read()
t = re.sub(r"\n*class shelfmark_meta:.*?(?=\nclass |\Z)", "", t, flags=re.S)
with open(p, "w") as f:
    f.write(t.rstrip() + "\n")
PY
        fi
        rm -f /opt/swizzin/static/img/apps/shelfmark.png
        systemctl restart panel 2>/dev/null || true
    fi
}

# --- Entry point -------------------------------------------------------------
echo 'This is unsupported software. You will not get help with this, please answer `yes` if you understand and wish to proceed'
if [[ -z ${eula} ]]; then
    read -r eula
fi

if ! [[ $eula =~ yes ]]; then
    echo "You did not accept the above. Exiting..."
    exit 1
else
    echo "Proceeding with installation"
fi

function _show() {
    lock="$target_home/.install/.shelfmark.lock"
    if [[ ! -f "$lock" ]]; then
        echo "shelfmark is not installed. Run 'install' first."
        return
    fi

    port=""
    env_conf="$target_home/shelfmark/env.conf"
    if [[ -f "$env_conf" ]]; then
        port="$(grep -E '^FLASK_PORT=' "$env_conf" | cut -d= -f2)"
    fi

    svc_status="$(systemctl_user is-active shelfmark 2>/dev/null || echo "unknown")"

    nginx_conf="/etc/nginx/apps/shelfmark.conf"
    if [[ -f "$nginx_conf" ]]; then
        nginx_status="configured  ($nginx_conf)"
        url="http://$(hostname -f):${port:-?}  (nginx /shelfmark redirects here)"
    else
        nginx_status="not configured"
        url="http://$(hostname -f):${port:-?}"
    fi

    panel_lock="/install/.shelfmark.lock"
    if [[ -f "$panel_lock" ]] && grep -q "^class shelfmark_meta:" /opt/swizzin/core/custom/profiles.py 2>/dev/null; then
        panel_status="configured"
    else
        panel_status="not configured"
    fi

    echo ""
    echo "=============================="
    echo "  shelfmark installation summary"
    echo "=============================="
    echo "  Service name  : shelfmark"
    echo "  Service status: $svc_status"
    echo "  Repo          : $GITHUB_REPO"
    echo "  Port          : ${port:-unknown}"
    echo "  URL           : $url"
    echo "  nginx         : $nginx_status"
    echo "  swizzin panel : $panel_status"
    echo "  Books dir     : $target_home/books"
    echo "  Config dir    : $target_home/.config/shelfmark"
    echo ""
    echo "  Useful commands:"
    echo "    systemctl --user status shelfmark"
    echo "    systemctl --user restart shelfmark"
    echo "    journalctl --user -u shelfmark -f"
    echo "    tail -f $target_home/.logs/shelfmark.log"
    echo "=============================="
    echo ""
}

echo "Welcome to the shelfmark installer..."
echo ""
echo "What do you like to do?"
echo ""
echo "show      = Show current installation status and configuration"
echo "install   = Install shelfmark"
echo "uninstall = Completely removes shelfmark"
echo "exit      = Exits Installer"
while true; do
    read -r -p "Enter it here: " choice
    case $choice in
        "show")
            _show
            ;;
        "install")
            clear
            _deps
            _shelfmark_install
            _service
            if $SUDO_MODE; then
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  nginx + swizzin dashboard setup — please read before continuing"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "  The following will be configured:"
                echo ""
                echo "  1. /etc/nginx/apps/shelfmark.conf"
                echo "     - Redirects https://<host>/shelfmark → http://$(hostname -f):$SHELFMARK_PORT/"
                echo "     - Simple redirect: no path rewriting, shelfmark runs directly on its port."
                echo ""
                echo "  2. /opt/swizzin/core/custom/profiles.py"
                echo "     - Appends shelfmark_meta so shelfmark appears in the swizzin panel sidebar."
                echo ""
                echo "  3. /install/.shelfmark.lock + panel restart"
                echo ""
                read -r -p "  Proceed with nginx + dashboard setup? [yes/skip]: " nginx_confirm
                if [[ "$nginx_confirm" == "yes" ]]; then
                    _nginx
                    _dashboard
                else
                    echo "  Skipped. shelfmark is running on http://$(hostname -f):$SHELFMARK_PORT"
                    echo "  You can re-run the installer and choose 'install' again to set it up later."
                fi
                echo ""
            fi
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
            echo "Unknown Option."
            ;;
    esac
done
exit
